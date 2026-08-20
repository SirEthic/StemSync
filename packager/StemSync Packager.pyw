import os
import json
import zipfile
import warnings
from pathlib import Path

# Suppress librosa warnings for cleaner terminal output
warnings.filterwarnings("ignore")

try:
    import librosa
except ImportError:
    print("Error: 'librosa' is not installed.")
    print("Please run: pip install librosa soundfile")
    exit(1)

def create_bandtrack_zip(song_name, stem_folder_path, output_path, manual_artist=""):
    stem_folder = Path(stem_folder_path)
    if not stem_folder.exists() or not stem_folder.is_dir():
        print(f"Error: Folder '{stem_folder}' does not exist.")
        return

    print(f"\nProcessing '{song_name}'...")
    
    audio_files = []
    for ext in ['*.wav', '*.mp3', '*.flac']:
        for file in stem_folder.glob(ext):
            if "0_Metronome" not in file.name:
                audio_files.append(file)
        
    if not audio_files:
        print("No audio files found in the folder!")
        return
        
    print("Combining stems for accurate full-mix beat detection...")
    import numpy as np
    y = None
    sr = 22050
    for file in audio_files:
        y_stem, _ = librosa.load(file, sr=sr)
        if y is None:
            y = y_stem
        else:
            if len(y_stem) > len(y):
                y = np.pad(y, (0, len(y_stem) - len(y)))
            elif len(y) > len(y_stem):
                y_stem = np.pad(y_stem, (0, len(y) - len(y_stem)))
            y += y_stem
            
    artist_name = manual_artist.strip()
    if not artist_name:
        print("Fingerprinting combined full-mix audio to identify Song and Artist (Shazam)...")
        import asyncio
        from shazamio import Shazam
        import soundfile as sf
        import tempfile
        import os
        
        try:
            # Write a 15-second slice from the MIDDLE of the song to a temporary .wav
            temp_wav = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name
            
            # Calculate the middle of the song (seek to 1:00 where vocals usually are)
            total_duration = len(y) / sr
            start_sec = min(60.0, total_duration / 3.0) 
            start_sample = int(start_sec * sr)
            end_sample = int((start_sec + 15.0) * sr)
            
            # y is the sum of 4 stems, so its amplitude likely exceeds 1.0 (clipping!)
            # We MUST normalize it before writing to a 16-bit PCM WAV file, 
            # otherwise Shazam just hears distorted static noise.
            y_slice = y[start_sample:end_sample]
            y_norm = y_slice / np.max(np.abs(y_slice) + 1e-8)
            
            sf.write(temp_wav, y_norm, sr)
            
            async def recognize_mix():
                shazam = Shazam()
                return await shazam.recognize(temp_wav)
                
            out = asyncio.run(recognize_mix())
            
            if os.path.exists(temp_wav):
                try: os.unlink(temp_wav)
                except: pass
                
            if 'track' in out:
                track = out['track']
                title = track.get('title', song_name)
                artist_name = track.get('subtitle', '')
                print(f"Shazam detected: {title} by {artist_name}")
                song_name = title
            else:
                print("Shazam could not identify the song from the full mix.")
                
        except Exception as e:
            print(f"Shazam fingerprinting failed: {e}")
    else:
        print(f"Using manual Artist Name: {artist_name}")
            
    # Run the beat tracker on the full mix so it catches drum-less intros
    tempo, beat_frames = librosa.beat.beat_track(y=y, sr=sr)
    
    # Convert frames to exact timestamps (seconds)
    beat_times = librosa.frames_to_time(beat_frames, sr=sr)
    
    # Extract the scalar value from the tempo array if needed (librosa 0.10+ returns an array)
    bpm = float(tempo[0]) if isinstance(tempo, (list, tuple)) or hasattr(tempo, '__iter__') else float(tempo)
    
    print(f"Detected Tempo: {bpm:.1f} BPM")
    print(f"Found {len(beat_times)} beats.")

    # ==== HARMONIC ANALYSIS (KEY & CHORDS) ====
    import numpy as np
    
    harmonic_track = audio_files[0]
    for file in audio_files:
        if 'other' in file.name.lower() or 'piano' in file.name.lower() or 'guitar' in file.name.lower():
            harmonic_track = file
            break
            
    print(f"Analyzing harmony using: {harmonic_track.name} (This may take a minute...)")
    y_harm, sr_harm = librosa.load(harmonic_track, sr=None)
    chroma = librosa.feature.chroma_cqt(y=y_harm, sr=sr_harm)
    
    maj_profile = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
    min_profile = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
    maj_profile = maj_profile / np.linalg.norm(maj_profile)
    min_profile = min_profile / np.linalg.norm(min_profile)
    
    chroma_sum = np.sum(chroma, axis=1)
    if np.linalg.norm(chroma_sum) > 0:
        chroma_sum = chroma_sum / np.linalg.norm(chroma_sum)
    
    keys = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B']
    best_corr, best_key = -1, "C Major"
    
    for i in range(12):
        shifted_maj = np.roll(maj_profile, i)
        shifted_min = np.roll(min_profile, i)
        corr_maj = np.correlate(chroma_sum, shifted_maj)[0]
        corr_min = np.correlate(chroma_sum, shifted_min)[0]
        if corr_maj > best_corr: best_corr, best_key = corr_maj, f"{keys[i]} Major"
        if corr_min > best_corr: best_corr, best_key = corr_min, f"{keys[i]} Minor"
            
    print(f"Detected Key: {best_key}")
    
    beat_frames_harm = librosa.time_to_frames(beat_times, sr=sr_harm)
    chord_templates, chord_names = [], []
    for i in range(12):
        t_maj = np.zeros(12); t_maj[[0, 4, 7]] = 1; t_maj = np.roll(t_maj, i)
        chord_templates.append(t_maj / np.linalg.norm(t_maj)); chord_names.append(keys[i])
        t_min = np.zeros(12); t_min[[0, 3, 7]] = 1; t_min = np.roll(t_min, i)
        chord_templates.append(t_min / np.linalg.norm(t_min)); chord_names.append(keys[i] + "m")
        
    chord_templates = np.array(chord_templates)
    chords_output = []
    
    # ==== HARMONIC ANALYSIS (CHORDS) ====
    print("Detecting chords...")
    chroma = librosa.feature.chroma_cqt(y=y_harm, sr=sr_harm)
    chord_preds = []
    for j in range(len(beat_times)):
        frame = int(librosa.time_to_frames(beat_times[j], sr=sr_harm))
        # Analyze the window strictly AFTER the beat to capture sustained harmony, ignoring early strums
        start_f = frame
        end_f = min(chroma.shape[1], frame + 5)
        frame_chroma = np.mean(chroma[:, start_f:end_f], axis=1)
        chord_idx = np.argmax(np.dot(chord_templates, frame_chroma)) if np.sum(frame_chroma) > 0 else -1
        chord_preds.append(chord_idx)
        
    if len(chord_preds) > 8:
        # Pass 1: 7-beat rolling mode to smooth out noise
        smoothed_preds = []
        for i in range(len(chord_preds)):
            start = max(0, i - 3)
            end = min(len(chord_preds), i + 4)
            window = chord_preds[start:end]
            smoothed_preds.append(max(set(window), key=window.count))
            
        # Pass 2: Hysteresis filter (Run-Length constraint)
        # A chord MUST be solidly detected for at least 4 consecutive beats before we allow the UI to change to it.
        final_preds = []
        current_chord = smoothed_preds[0]
        for i in range(len(smoothed_preds)):
            if smoothed_preds[i] == current_chord:
                final_preds.append(current_chord)
            else:
                # Look ahead to see if the new chord sustains
                ahead = smoothed_preds[i : i + 2]
                if len(ahead) == 2 and ahead.count(smoothed_preds[i]) == 2:
                    # New chord is solid, accept it
                    current_chord = smoothed_preds[i]
                    final_preds.append(current_chord)
                else:
                    # Passing chord or noise, ignore it and sustain the old chord
                    final_preds.append(current_chord)
                    
        chord_preds = final_preds
        
    for j in range(len(beat_times)):
        chord_idx = chord_preds[j]
        best_chord = chord_names[chord_idx] if chord_idx >= 0 else "N/C"
        chords_output.append({"time": float(beat_times[j]) + 0.045, "chord": best_chord})

    # ==== STRUCTURAL SEGMENTATION ====
    print("Detecting song sections...")
    try:
        mfcc = librosa.feature.mfcc(y=y_harm, sr=sr_harm, n_mfcc=13)
        if len(beat_frames_harm) > 10:
            total_frames = mfcc.shape[1]
            valid_beats = [f for f in beat_frames_harm if f > 0 and f < total_frames]
            full_frames = sorted(list(set([0] + valid_beats + [total_frames])))
            
            mfcc_sync = librosa.util.sync(mfcc, full_frames, pad=False)
            n_sections = min(10, max(4, mfcc_sync.shape[1] // 16))
            bounds = librosa.segment.agglomerative(mfcc_sync, n_sections)
            
            bound_times = [float(librosa.frames_to_time(full_frames[b], sr=sr_harm)) for b in bounds]
            bound_times.append(float(librosa.get_duration(y=y_harm, sr=sr_harm)))
            
            # Merge tiny fragments (< 15 seconds) into adjacent sections to prevent 4-second choruses
            merged_bounds = [bound_times[0]]
            for i in range(1, len(bound_times) - 1):
                if bound_times[i] - merged_bounds[-1] >= 15.0:
                    merged_bounds.append(bound_times[i])
            merged_bounds.append(bound_times[-1])
            
            section_names = ["Intro", "Verse 1", "Chorus 1", "Verse 2", "Chorus 2", "Bridge", "Chorus 3", "Outro"]
            sections_output = []
            for i in range(len(merged_bounds) - 1):
                name = section_names[i] if i < len(section_names) else f"Section {i+1}"
                if i == len(merged_bounds) - 2 and i > 0:
                    name = "Outro" # Force absolute last valid section to be Outro
                
                sections_output.append({
                    "name": name,
                    "start_time": merged_bounds[i] + 0.045,
                    "end_time": merged_bounds[i+1] + 0.045
                })
        else:
            sections_output = []
    except Exception as e:
        print(f"Warning: Section detection failed: {e}")
        sections_output = []

    duration = librosa.get_duration(y=y, sr=sr)
    interval = 60.0 / bpm if bpm > 0 else 0.5
    first_beat = beat_times[0] if len(beat_times) > 0 else 0.0
    while first_beat >= interval:
        first_beat -= interval
    first_beat += 0.045
    
    # Create the metadata JSON
    metadata = {
        "song_name": song_name,
        "artist": artist_name,
        "tempo_bpm": bpm,
        "first_beat": first_beat,
        "key": best_key,
        "sections": sections_output,
        "chords": chords_output,
        "stems": [f.name for f in audio_files]
    }
    
    metadata_path = stem_folder / "song_metadata.json"
    with open(metadata_path, 'w') as f:
        json.dump(metadata, f, indent=4)
        
    print("Generated song_metadata.json")
    
    print("Generating SMART dynamic Metronome tracks...")
    import soundfile as sf
    import numpy as np
    
    duration = librosa.get_duration(y=y, sr=sr)
    if len(beat_times) > 0:
        # beat_times is the array of actual human beats detected by librosa
        dynamic_beats = list(beat_times)
        
        # 1. Project backwards to 0.0 using the first available beat interval
        if len(dynamic_beats) >= 2:
            avg_intro_interval = dynamic_beats[1] - dynamic_beats[0]
        else:
            avg_intro_interval = 60.0 / bpm
            
        first_beat = dynamic_beats[0]
        while first_beat >= avg_intro_interval:
            first_beat -= avg_intro_interval
            dynamic_beats.insert(0, first_beat)
            
        # 2. Project forwards to the end of the song if librosa stopped detecting early
        if len(dynamic_beats) >= 2:
            avg_outro_interval = dynamic_beats[-1] - dynamic_beats[-2]
        else:
            avg_outro_interval = 60.0 / bpm
            
        last_beat = dynamic_beats[-1]
        while last_beat + avg_outro_interval <= duration:
            last_beat += avg_outro_interval
            dynamic_beats.append(last_beat)
            
        dynamic_beats = np.array(dynamic_beats)
        
        # Add 45ms shift for MP3 encoder padding when played alongside MP3 stems in SoLoud
        dynamic_beats += 0.045
        
        # 1x Subdivision (Dynamic)
        click_track_1x = librosa.clicks(times=dynamic_beats, sr=sr, click_freq=1500.0, click_duration=0.1, length=len(y))
        path_1x = stem_folder / "0_Metronome_1x.ogg"
        sf.write(str(path_1x), click_track_1x, sr, format='OGG')
        audio_files.append(path_1x)
        
        # 0.5x Subdivision (Dynamic Half Time - Take every other beat)
        beats_05x = dynamic_beats[::2]
        click_track_05x = librosa.clicks(times=beats_05x, sr=sr, click_freq=1000.0, click_duration=0.1, length=len(y))
        path_05x = stem_folder / "0_Metronome_0_5x.ogg"
        sf.write(str(path_05x), click_track_05x, sr, format='OGG')
        audio_files.append(path_05x)
        
        # 2x Subdivision (Dynamic Double Time - Interpolate exactly halfway between each dynamic beat)
        beats_2x = []
        for i in range(len(dynamic_beats) - 1):
            beats_2x.append(dynamic_beats[i])
            halfway = (dynamic_beats[i] + dynamic_beats[i+1]) / 2.0
            beats_2x.append(halfway)
        beats_2x.append(dynamic_beats[-1])
        beats_2x = np.array(beats_2x)
        
        click_track_2x = librosa.clicks(times=beats_2x, sr=sr, click_freq=2000.0, click_duration=0.1, length=len(y))
        path_2x = stem_folder / "0_Metronome_2x.ogg"
        sf.write(str(path_2x), click_track_2x, sr, format='OGG')
        audio_files.append(path_2x)
    
    # Zip it all up
    print("Downloading lyrics...")
    try:
        import syncedlyrics
        lrc_path = stem_folder / "lyrics.lrc"
        if not lrc_path.exists():
            search_query = f"{song_name} {artist_name}".strip()
            lrc_content = syncedlyrics.search(search_query)
            if lrc_content:
                with open(lrc_path, "w", encoding="utf-8") as f:
                    f.write(lrc_content)
                print("Successfully downloaded synced lyrics (.lrc)!")
            else:
                print("Could not find synced lyrics online. (You can manually add a 'lyrics.lrc' file here later).")
        else:
            print("Found existing 'lyrics.lrc' file in folder.")
    except Exception as e:
        print(f"Lyrics download failed: {e}")

    zip_filename = Path(output_path) / f"{song_name.replace(' ', '_')}.zip"
    
    print(f"Creating {zip_filename.name}...")
    with zipfile.ZipFile(zip_filename, 'w', zipfile.ZIP_DEFLATED) as zipf:
        zipf.write(metadata_path, arcname="song_metadata.json")
        if (stem_folder / "lyrics.lrc").exists():
            zipf.write(stem_folder / "lyrics.lrc", arcname="lyrics.lrc")
        for audio_file in audio_files:
            zipf.write(audio_file, arcname=audio_file.name)
            
    print(f"\nSuccess! '{zip_filename.name}' is ready to be loaded into StemSync.")
    metadata_path.unlink()
    if 'lrc_content' in locals() and lrc_content: 
        pass # Leave the lyrics file in the folder for the user!
    if 'path_1x' in locals() and path_1x.exists(): path_1x.unlink()
    if 'path_05x' in locals() and path_05x.exists(): path_05x.unlink()
    if 'path_2x' in locals() and path_2x.exists(): path_2x.unlink()

if __name__ == "__main__":
    import tkinter as tk
    import customtkinter as ctk
    from tkinter import filedialog, messagebox
    import threading
    import sys

    # Set modern theme
    ctk.set_appearance_mode("dark")
    ctk.set_default_color_theme("green")

    class PrintLogger:
        def __init__(self, root_ref, textbox):
            self.root_ref = root_ref
            self.textbox = textbox

        def write(self, text):
            self.root_ref.after(0, lambda t=text: self._safe_write(t))
            
        def _safe_write(self, text):
            self.textbox.insert(tk.END, text)
            self.textbox.see(tk.END)
            
        def flush(self):
            pass

    def select_folder():
        folder = filedialog.askdirectory(title="Select UVR5 Stems Folder")
        if folder:
            folder_var.set(folder)
            if not song_var.get():
                song_var.set(Path(folder).name)
                
    def select_out_dir():
        out = filedialog.askdirectory(title="Select Output Directory for Zip")
        if out:
            out_var.set(out)

    def start_packaging():
        song = song_var.get().strip()
        artist = artist_var.get().strip()
        folder = folder_var.get().strip()
        out = out_var.get().strip()
        
        if not song or not folder:
            messagebox.showerror("Error", "Please provide both a Song Name and Stems Folder.")
            return
            
        if not out:
            out = folder
            
        btn_package.configure(state="disabled")
        btn_folder.configure(state="disabled")
        btn_out.configure(state="disabled")
        
        def run_task():
            try:
                print(f"=== Starting StemSync Packaging: {song} ===")
                create_bandtrack_zip(song, folder, out, manual_artist=artist)
            except Exception as e:
                print(f"\n[ERROR]: {e}")
                err_msg = str(e)
                root.after(0, lambda msg=err_msg: messagebox.showerror("Error", msg))
            finally:
                root.after(0, lambda: btn_package.configure(state="normal"))
                root.after(0, lambda: btn_folder.configure(state="normal"))
                root.after(0, lambda: btn_out.configure(state="normal"))
                
        threading.Thread(target=run_task, daemon=True).start()

    # === PROFESSIONAL ENTERPRISE UI REDESIGN ===
    root = ctk.CTk()
    root.title("StemSync Engine")
    root.geometry("750x650")
    
    # Configure grid layout
    root.grid_columnconfigure(0, weight=1)
    root.grid_rowconfigure(1, weight=1)
    
    # --- HEADER ---
    header_frame = ctk.CTkFrame(root, height=70, corner_radius=0, fg_color="#1E1E1E")
    header_frame.grid(row=0, column=0, sticky="ew")
    header_frame.grid_columnconfigure(0, weight=1)
    
    logo_label = ctk.CTkLabel(header_frame, text="StemSync Packager", font=ctk.CTkFont(size=20, weight="normal"), text_color="#E0E0E0")
    logo_label.grid(row=0, column=0, pady=15)
    
    # --- MAIN CONTENT ---
    main_frame = ctk.CTkFrame(root, fg_color="transparent")
    main_frame.grid(row=1, column=0, sticky="nsew", padx=40, pady=20)
    main_frame.grid_columnconfigure(0, weight=1)
    
    # -- Card 1: Metadata --
    card1 = ctk.CTkFrame(main_frame, corner_radius=6, fg_color="#252526", border_width=1, border_color="#3E3E42")
    card1.grid(row=0, column=0, sticky="ew", pady=(0, 15))
    card1.grid_columnconfigure(1, weight=1)
    
    ctk.CTkLabel(card1, text="Metadata", font=ctk.CTkFont(size=14, weight="normal"), text_color="#D4D4D4").grid(row=0, column=0, columnspan=2, sticky="w", padx=25, pady=(15, 10))
    
    song_var = tk.StringVar()
    artist_var = tk.StringVar()
    
    ctk.CTkLabel(card1, text="Track Title", font=ctk.CTkFont(size=12), text_color="#A6A6A6").grid(row=1, column=0, sticky="w", padx=25, pady=(0, 10))
    ctk.CTkEntry(card1, textvariable=song_var, border_width=1, border_color="#3E3E42", fg_color="#1E1E1E", text_color="#D4D4D4", height=32, corner_radius=4).grid(row=1, column=1, sticky="ew", padx=(0, 25), pady=(0, 10))
    
    ctk.CTkLabel(card1, text="Artist (Optional)", font=ctk.CTkFont(size=12), text_color="#A6A6A6").grid(row=2, column=0, sticky="w", padx=25, pady=(0, 20))
    ctk.CTkEntry(card1, textvariable=artist_var, border_width=1, border_color="#3E3E42", fg_color="#1E1E1E", text_color="#D4D4D4", height=32, corner_radius=4, placeholder_text="Auto-detected if blank").grid(row=2, column=1, sticky="ew", padx=(0, 25), pady=(0, 20))
    
    # -- Card 2: Directories --
    card2 = ctk.CTkFrame(main_frame, corner_radius=6, fg_color="#252526", border_width=1, border_color="#3E3E42")
    card2.grid(row=1, column=0, sticky="ew", pady=(0, 20))
    card2.grid_columnconfigure(1, weight=1)
    
    ctk.CTkLabel(card2, text="Directories", font=ctk.CTkFont(size=14, weight="normal"), text_color="#D4D4D4").grid(row=0, column=0, columnspan=3, sticky="w", padx=25, pady=(15, 10))
    
    folder_var = tk.StringVar()
    out_var = tk.StringVar()
    
    ctk.CTkLabel(card2, text="UVR5 Stems", font=ctk.CTkFont(size=12), text_color="#A6A6A6").grid(row=1, column=0, sticky="w", padx=25, pady=(0, 10))
    ctk.CTkEntry(card2, textvariable=folder_var, border_width=1, border_color="#3E3E42", fg_color="#1E1E1E", text_color="#D4D4D4", height=32, corner_radius=4).grid(row=1, column=1, sticky="ew", padx=(0, 15), pady=(0, 10))
    btn_folder = ctk.CTkButton(card2, text="Browse...", width=80, height=32, corner_radius=4, fg_color="#333337", hover_color="#3F3F46", text_color="#D4D4D4", command=select_folder)
    btn_folder.grid(row=1, column=2, padx=(0, 25), pady=(0, 10))
    
    ctk.CTkLabel(card2, text="Output", font=ctk.CTkFont(size=12), text_color="#A6A6A6").grid(row=2, column=0, sticky="w", padx=25, pady=(0, 20))
    ctk.CTkEntry(card2, textvariable=out_var, border_width=1, border_color="#3E3E42", fg_color="#1E1E1E", text_color="#D4D4D4", height=32, corner_radius=4).grid(row=2, column=1, sticky="ew", padx=(0, 15), pady=(0, 20))
    btn_out = ctk.CTkButton(card2, text="Browse...", width=80, height=32, corner_radius=4, fg_color="#333337", hover_color="#3F3F46", text_color="#D4D4D4", command=select_out_dir)
    btn_out.grid(row=2, column=2, padx=(0, 25), pady=(0, 20))
    
    # -- Action Area --
    btn_package = ctk.CTkButton(main_frame, text="Start Packaging", command=start_packaging, font=ctk.CTkFont(size=14, weight="normal"), height=40, corner_radius=4, fg_color="#0E639C", text_color="#FFFFFF", hover_color="#1177BB")
    btn_package.grid(row=2, column=0, sticky="ew", pady=(0, 20))
    
    # -- Console --
    console = ctk.CTkTextbox(main_frame, height=140, font=ctk.CTkFont(family="Consolas", size=12), text_color="#CCCCCC", fg_color="#1E1E1E", border_width=1, border_color="#3E3E42", corner_radius=4)
    console.grid(row=3, column=0, sticky="nsew")
    main_frame.grid_rowconfigure(3, weight=1)
    
    sys.stdout = PrintLogger(root, console)
    sys.stderr = PrintLogger(root, console)
    
    root.mainloop()
