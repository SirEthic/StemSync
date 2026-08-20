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
        if len(dynamic_beats) >= 2 and (dynamic_beats[1] - dynamic_beats[0]) > 0.1:
            avg_intro_interval = dynamic_beats[1] - dynamic_beats[0]
        else:
            avg_intro_interval = 60.0 / (bpm if bpm > 0 else 120.0)
            
        first_beat = dynamic_beats[0]
        while first_beat >= avg_intro_interval:
            first_beat -= avg_intro_interval
            dynamic_beats.insert(0, first_beat)
            
        # 2. Project forwards to the end of the song if librosa stopped detecting early
        if len(dynamic_beats) >= 2 and (dynamic_beats[-1] - dynamic_beats[-2]) > 0.1:
            avg_outro_interval = dynamic_beats[-1] - dynamic_beats[-2]
        else:
            avg_outro_interval = 60.0 / (bpm if bpm > 0 else 120.0)
            
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



import asyncio, traceback
try:
    create_bandtrack_zip("Ufaq", "E:/AI Instrument seperator/Ufaq_test", "E:/AI Instrument seperator", manual_artist="Anand Bhaskar")
    print("SUCCESS")
except Exception as e:
    traceback.print_exc()
