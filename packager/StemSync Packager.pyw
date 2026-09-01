import os
import json
import zipfile
import warnings
from pathlib import Path

# Inject PyTorch's CUDA DLLs into the search path for ONNX Runtime to use
try:
    import torch
except ImportError:
    pass

# Suppress librosa warnings for cleaner terminal output
warnings.filterwarnings("ignore")

try:
    import librosa
except ImportError:
    print("Error: 'librosa' is not installed.")
    print("Please run: pip install librosa soundfile")
    exit(1)

def create_bandtrack_zip(song_name, stem_folder_path, output_path, manual_artist="", original_track_path=""):
    stem_folder = Path(stem_folder_path)
    if not stem_folder.exists() or not stem_folder.is_dir():
        raise Exception("Invalid stem folder selected!")
        
    print(f"\nProcessing '{song_name}'...")
    audio_files = list(stem_folder.glob("*.wav")) + list(stem_folder.glob("*.mp3")) + list(stem_folder.glob("*.ogg")) + list(stem_folder.glob("*.flac"))
    
    if not audio_files:
        raise Exception("No audio files found in the selected folder!")

    sr = 22050
    metro_sr = 44100
    
    print("Combining stems for accurate full-mix beat detection...")
    import numpy as np
    
    # Find the longest stem to initialize y
    max_len = 0
    for file in audio_files:
        y_stem, _ = librosa.load(file, sr=sr)
        if len(y_stem) > max_len:
            max_len = len(y_stem)
            
    y = np.zeros(max_len)
    for file in audio_files:
        y_stem, _ = librosa.load(file, sr=sr)
        if len(y_stem) < len(y):
            y_stem = np.pad(y_stem, (0, len(y) - len(y_stem)))
        y += y_stem
            
    artist_name = manual_artist.strip()
    if not artist_name:
        print("Fingerprinting audio to identify Song and Artist (Shazam)...")
        import asyncio
        from shazamio import Shazam
        import soundfile as sf
        import tempfile
        import os
        
        try:
            total_duration = len(y) / sr
            # Try multiple 15-second slices to increase detection chance
            test_points = [min(60.0, total_duration / 3.0), 30.0, 90.0]
            
            # Find vocal stem as fallback
            y_vocals = None
            for file in audio_files:
                if "vocal" in file.name.lower():
                    y_vocals, _ = librosa.load(file, sr=sr)
                    break
                    
            temp_wav = tempfile.NamedTemporaryFile(suffix='.wav', delete=False).name
            shazam = Shazam(language='en-IN', endpoint_country='IN')
            
            async def try_recognize(audio_data, start_sec):
                start_sample = int(start_sec * sr)
                end_sample = int(min(start_sec + 15.0, total_duration) * sr)
                
                if start_sample >= len(audio_data): return None
                
                y_slice = audio_data[start_sample:end_sample]
                if len(y_slice) == 0: return None
                
                # Resample to 44100Hz because Shazamio spectrogram fails at 22050Hz
                import librosa
                y_shazam = librosa.resample(y_slice, orig_sr=sr, target_sr=44100)
                y_norm = y_shazam / np.max(np.abs(y_shazam) + 1e-8)
                
                # Force 16-bit PCM WAV (Shazamio doesn't like float32/float64 WAVs)
                sf.write(temp_wav, y_norm, 44100, subtype='PCM_16')
                
                out = await shazam.recognize(temp_wav)
                return out if 'track' in out else None

            async def aggressive_shazam():
                # 0. Try original un-separated song if provided
                if original_track_path and os.path.exists(original_track_path):
                    print("  -> Trying the original studio master track!")
                    y_orig, orig_sr = librosa.load(original_track_path, sr=44100)
                    start_sample = int(min(60.0, len(y_orig)/orig_sr/3.0) * 44100)
                    end_sample = int(min(start_sample/44100 + 15.0, len(y_orig)/orig_sr) * 44100)
                    y_slice = y_orig[start_sample:end_sample]
                    y_norm = y_slice / np.max(np.abs(y_slice) + 1e-8)
                    sf.write(temp_wav, y_norm, 44100, subtype='PCM_16')
                    res = await shazam.recognize(temp_wav)
                    if 'track' in res: return res
                    print("  -> Original track failed, falling back to stems...")
            
                # 1. Try full mix at different timestamps
                for point in test_points:
                    print(f"  -> Trying full mix at {point}s...")
                    res = await try_recognize(y, point)
                    if res: return res
                
                # 2. If all mix tests fail, try the isolated vocals
                if y_vocals is not None:
                    for point in test_points:
                        print(f"  -> Trying isolated vocals at {point}s...")
                        res = await try_recognize(y_vocals, point)
                        if res: return res
                return None
                
            out = asyncio.run(aggressive_shazam())
            
            if os.path.exists(temp_wav):
                try: os.unlink(temp_wav)
                except: pass
                
            if out and 'track' in out:
                track = out['track']
                title = track.get('title', song_name)
                artist_name = track.get('subtitle', '')
                print(f"Shazam detected: {title} by {artist_name}")
                song_name = title
            else:
                print("Shazam could not identify the song after multiple attempts.")
                
        except Exception as e:
            print(f"Shazam fingerprinting failed: {e}")
    else:
        print(f"Using manual Artist Name: {artist_name}")
            
    # Find the best audio source for beat detection
    y_percussion = None
    for file in audio_files:
        if "drums" in file.name.lower() or "percussion" in file.name.lower():
            y_percussion, _ = librosa.load(file, sr=sr)
            print(f"Using {file.name} for crystal clear transient beat detection!")
            break
            
    if y_percussion is None:
        y_percussion = y
        print("No isolated drums found. Falling back to full mix for beat detection.")
            
    tempo, beat_frames = librosa.beat.beat_track(y=y_percussion, sr=sr)
    
    # Convert frames to exact timestamps (seconds)
    beat_times = librosa.frames_to_time(beat_frames, sr=sr)
    
    # Extract the scalar value from the tempo array if needed (librosa 0.10+ returns an array)
    bpm = float(tempo[0]) if isinstance(tempo, (list, tuple)) or hasattr(tempo, '__iter__') else float(tempo)
    
    # Extrapolate beats backwards to the beginning of the song
    if len(beat_times) > 0 and beat_times[0] > 0.5:
        beat_interval = 60.0 / bpm
        current_early_beat = beat_times[0] - beat_interval
        early_beats = []
        while current_early_beat > 0:
            early_beats.append(current_early_beat)
            current_early_beat -= beat_interval
        early_beats.reverse()
        import numpy as np
        beat_times = np.concatenate((early_beats, beat_times))
    
    print(f"Detected Tempo: {bpm:.1f} BPM")
    print(f"Found {len(beat_times)} beats.")

    # ==== HARMONIC ANALYSIS (KEY & CHORDS) ====
    import numpy as np
    
    print("Mixing stems for rich harmonic analysis...")
    y_harm = None
    sr_harm = 22050  # Downsample for 4x faster processing and reduced overtone noise
    valid_harmony = ['guitar', 'piano', 'other', 'instrumental', 'accompaniment', 'music']
    for file in audio_files:
        n = file.name.lower()
        if any(stem in n for stem in valid_harmony) or 'bass' in n:
            # 22kHz is perfectly detailed for chroma CQT
            y_stem, _ = librosa.load(file, sr=sr_harm)
            
            # Bass waves carry massive energy and can overwhelm the CQT, throwing off key detection
            if 'bass' in n:
                y_stem = y_stem * 0.4
                
            if y_harm is None:
                y_harm = np.copy(y_stem)
            else:
                m_len = min(len(y_harm), len(y_stem))
                y_harm[:m_len] += y_stem[:m_len]
                
    # Robust fallback: Avoid drums and vocals if standard stem names weren't found
    if y_harm is None and len(audio_files) > 0:
        fallback = audio_files[0]
        for f in audio_files:
            fn = f.name.lower()
            if 'drum' not in fn and 'vocal' not in fn:
                fallback = f
                break
        y_harm, sr_harm = librosa.load(fallback, sr=22050)
    print("Extracting chromagram...")
    # Raw CQT preserves volume energy, making it vastly superior for global Key Detection
    chroma_raw = librosa.feature.chroma_cqt(y=y_harm, sr=sr_harm)
    
    maj_profile = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
    min_profile = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
    maj_profile = maj_profile / np.linalg.norm(maj_profile)
    min_profile = min_profile / np.linalg.norm(min_profile)
    
    chroma_sum = np.sum(chroma_raw, axis=1)
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
        root = keys[i]
        
        # 1. Major (Triad - Penalty 1.0)
        t = np.zeros(12); t[[0, 4, 7]] = 1; t = np.roll(t, i)
        chord_templates.append(t / np.linalg.norm(t)); chord_names.append(root)
        # 2. Minor (Triad - Penalty 1.0)
        t = np.zeros(12); t[[0, 3, 7]] = 1; t = np.roll(t, i)
        chord_templates.append(t / np.linalg.norm(t)); chord_names.append(root + "m")
        # 3. Diminished (Triad - Penalty 1.0)
        t = np.zeros(12); t[[0, 3, 6]] = 1; t = np.roll(t, i)
        chord_templates.append(t / np.linalg.norm(t)); chord_names.append(root + "dim")
        # 4. Augmented (Triad - Penalty 1.0)
        t = np.zeros(12); t[[0, 4, 8]] = 1; t = np.roll(t, i)
        chord_templates.append(t / np.linalg.norm(t)); chord_names.append(root + "aug")
        # 5. Major 7 (4-note - Penalty 0.9)
        t = np.zeros(12); t[[0, 4, 7, 11]] = 1; t = np.roll(t, i)
        chord_templates.append((t / np.linalg.norm(t)) * 0.9); chord_names.append(root + "maj7")
        # 6. Minor 7 (4-note - Penalty 0.9)
        t = np.zeros(12); t[[0, 3, 7, 10]] = 1; t = np.roll(t, i)
        chord_templates.append((t / np.linalg.norm(t)) * 0.9); chord_names.append(root + "m7")
        # 7. Dominant 7 (4-note - Penalty 0.9)
        t = np.zeros(12); t[[0, 4, 7, 10]] = 1; t = np.roll(t, i)
        chord_templates.append((t / np.linalg.norm(t)) * 0.9); chord_names.append(root + "7")
        # 8. Sus 2 (3-note but highly ambiguous - Penalty 0.95)
        t = np.zeros(12); t[[0, 2, 7]] = 1; t = np.roll(t, i)
        chord_templates.append((t / np.linalg.norm(t)) * 0.95); chord_names.append(root + "sus2")
        # 9. Sus 4 (3-note but highly ambiguous - Penalty 0.95)
        t = np.zeros(12); t[[0, 5, 7]] = 1; t = np.roll(t, i)
        chord_templates.append((t / np.linalg.norm(t)) * 0.95); chord_names.append(root + "sus4")
        # 10. Power Chord (2-note, captures heavy rock correctly without guessing Major/Minor)
        t = np.zeros(12); t[[0, 7]] = 1; t = np.roll(t, i)
        chord_templates.append(t / np.linalg.norm(t)); chord_names.append(root + "5")
        
    chord_templates = np.array(chord_templates)
    chords_output = []
    
    # ==== HARMONIC ANALYSIS (CHORDS) ====
    print("Detecting chords...")
    # Use raw CQT to prevent the heavy temporal smearing of CENS, allowing us to catch fast passing chords
    chord_preds = []
    for j in range(len(beat_times)):
        start_f = int(librosa.time_to_frames(beat_times[j], sr=sr_harm))
        if j < len(beat_times) - 1:
            end_f = int(librosa.time_to_frames(beat_times[j+1], sr=sr_harm))
        else:
            end_f = chroma_raw.shape[1]
            
        if end_f <= start_f:
            end_f = start_f + 1
            
        # Average the raw CQT energy over the ENTIRE beat duration. 
        # This acts as a perfect temporal smoother for the exact duration of the beat, eliminating transient noise.
        frame_chroma = np.mean(chroma_raw[:, start_f:end_f], axis=1)
        chord_idx = np.argmax(np.dot(chord_templates, frame_chroma)) if np.max(frame_chroma) > 0.05 else -1
        chord_preds.append(chord_idx)
        
    if len(chord_preds) > 8:
        # Pass 1: 3-beat rolling deterministic mode to smooth out 1-beat rapid flicker / passing notes
        smoothed_preds = []
        for i in range(len(chord_preds)):
            start = max(0, i - 1)
            end = min(len(chord_preds), i + 2)
            window = chord_preds[start:end]
            counts = {}
            for c in window: counts[c] = counts.get(c, 0) + 1
            # Sort by count, tie-break by favoring the previous smoothed chord for maximum stability
            prev = smoothed_preds[-1] if smoothed_preds else -1
            best_chord = sorted(counts.keys(), key=lambda c: (counts[c], c == prev), reverse=True)[0]
            smoothed_preds.append(best_chord)
            
        # Pass 2: Hysteresis filter (Requires 2 consecutive beats to change UI chords)
        final_preds = []
        current_chord = smoothed_preds[0]
        for i in range(len(smoothed_preds)):
            if smoothed_preds[i] == current_chord:
                final_preds.append(current_chord)
            else:
                ahead = smoothed_preds[i : i + 2]
                if len(ahead) == 2 and ahead.count(smoothed_preds[i]) == 2:
                    current_chord = smoothed_preds[i]
                    final_preds.append(current_chord)
                else:
                    final_preds.append(current_chord)
                    
        chord_preds = final_preds
    for j in range(len(beat_times)):
        chord_idx = chord_preds[j]
        best_chord = chord_names[chord_idx] if chord_idx >= 0 else "N/C"
        chords_output.append({"time": float(beat_times[j]) + 0.045, "chord": best_chord})

    # ==== STRUCTURAL SEGMENTATION (Spectral Heuristic) ====
    print("Detecting song sections (Spectral Heuristic)...")
    sections_output = []
    try:
        # MFCC + Spectral Contrast clustering + RMS loudness labelling
        mfcc_full     = librosa.feature.mfcc(y=y, sr=sr, n_mfcc=13)
        contrast_full = librosa.feature.spectral_contrast(y=y, sr=sr)
        
        def norm_feat(f):
            std = f.std(axis=1, keepdims=True)
            std[std == 0] = 1
            return (f - f.mean(axis=1, keepdims=True)) / std
        
        combined = np.vstack([norm_feat(mfcc_full), norm_feat(contrast_full)])
        beat_frames_full = librosa.time_to_frames(beat_times, sr=sr)
        
        if len(beat_frames_full) > 10:
            total_frames = combined.shape[1]
            valid_beats  = [f for f in beat_frames_full if 0 < f < total_frames]
            full_frames  = sorted(list(set([0] + valid_beats + [total_frames])))
            feat_sync    = librosa.util.sync(combined, full_frames, pad=False)
            n_sections   = min(10, max(4, feat_sync.shape[1] // 14))
            bounds       = librosa.segment.agglomerative(feat_sync, n_sections)
            
            bound_times = [float(librosa.frames_to_time(full_frames[b], sr=sr)) for b in bounds]
            bound_times.append(float(librosa.get_duration(y=y, sr=sr)))
            
            merged_bounds = [bound_times[0]]
            for i in range(1, len(bound_times) - 1):
                if bound_times[i] - merged_bounds[-1] >= 12.0:
                    merged_bounds.append(bound_times[i])
            merged_bounds.append(bound_times[-1])
            
            seg_rms = []
            for i in range(len(merged_bounds) - 1):
                chunk = y[int(merged_bounds[i]*sr):int(merged_bounds[i+1]*sr)]
                seg_rms.append(float(np.sqrt(np.mean(chunk**2))) if len(chunk) > 0 else 0.0)
            
            n_segs = len(seg_rms)
            chorus_idxs = set(idx for idx, _ in sorted(enumerate(seg_rms), key=lambda x: x[1], reverse=True)[:max(1, round(n_segs*0.40))])
            chorus_count = verse_count = 0
            
            for i in range(n_segs):
                start_t, end_t = merged_bounds[i], merged_bounds[i+1]
                if i == 0:
                    label = "Intro"
                elif i == n_segs - 1:
                    label = "Outro"
                elif i in chorus_idxs:
                    chorus_count += 1
                    label = "Chorus" if chorus_count == 1 else f"Chorus {chorus_count}"
                elif i > n_segs // 2 and verse_count >= 2 and chorus_count >= 1:
                    label = "Bridge"
                else:
                    verse_count += 1
                    label = "Verse" if verse_count == 1 else f"Verse {verse_count}"
                sections_output.append({"name": label, "start_time": start_t + 0.045, "end_time": end_t + 0.045})
    except Exception as e:
        print(f"Warning: Section detection failed: {e}")
        sections_output = []= []

    duration = librosa.get_duration(y=y, sr=sr)
    interval = 60.0 / bpm if bpm > 0 else 0.5
    first_beat = beat_times[0] if len(beat_times) > 0 else 0.0
    while first_beat >= interval:
        first_beat -= interval
    first_beat += 0.045
    
    # --- Fetch Extended iTunes Metadata ---
    print("Fetching extended metadata and album cover...")
    album_name = "Unknown Album"
    genre = "Unknown Genre"
    release_year = ""
    has_cover = False
    
    import urllib.request
    import urllib.parse
    try:
        query = urllib.parse.quote(f"{song_name} {artist_name}".strip())
        url = f"https://itunes.apple.com/search?term={query}&entity=song&limit=1"
        req = urllib.request.Request(url, headers={'User-Agent': 'Mozilla/5.0'})
        with urllib.request.urlopen(req, timeout=5) as response:
            data = json.loads(response.read().decode())
            if data['resultCount'] > 0:
                track = data['results'][0]
                album_name = track.get('collectionName', album_name)
                genre = track.get('primaryGenreName', genre)
                if 'releaseDate' in track:
                    release_year = track['releaseDate'][:4]
                
                # Download optimized Cover Art (400x400)
                cover_url = track.get('artworkUrl100', '').replace('100x100bb', '400x400bb')
                if cover_url:
                    cover_req = urllib.request.Request(cover_url, headers={'User-Agent': 'Mozilla/5.0'})
                    with urllib.request.urlopen(cover_req, timeout=5) as cover_res:
                        with open(stem_folder / "cover.jpg", "wb") as cf:
                            cf.write(cover_res.read())
                    has_cover = True
                    print("Downloaded album cover.")
    except Exception as e:
        print(f"Warning: Extended metadata fetch failed: {e}")

    # Create the metadata JSON
    metadata = {
        "song_name": song_name,
        "artist": artist_name,
        "album": album_name,
        "genre": genre,
        "release_year": release_year,
        "has_cover": has_cover,
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
    
    # We generate the metronome at 44100Hz so it perfectly matches the standard MP3 stems.
    # Generating at 22050Hz against 44100Hz stems causes fractional sample misalignment and jitter.
    metro_sr = 44100
    metro_duration = librosa.get_duration(y=y, sr=sr)
    
    # Create a punchy, professional transient "woodblock" click instead of a soft sine wave
    def make_click_array(freq):
        # 50ms click
        t = np.linspace(0, 0.05, int(metro_sr * 0.05), endpoint=False)
        # Fixed frequency sine wave
        wave = np.sin(2 * np.pi * freq * t)
        # Extremely sharp exponential decay envelope so it sounds percussive
        env = np.exp(-150 * t)
        return wave * env
        
    click_1x = make_click_array(1500.0)
    click_05x = make_click_array(1000.0)
    click_2x = make_click_array(2000.0)
    
    if len(beat_times) > 0:
        # beat_times is the array of actual human beats detected by librosa
        dynamic_beats = list(beat_times)
        
        # 1. Project backwards to 0.0 using the robust MEDIAN interval, not just the first two beats
        intervals = np.diff(dynamic_beats)
        valid_intervals = intervals[intervals > 0.1]
        median_interval = np.median(valid_intervals) if len(valid_intervals) > 0 else (60.0 / (bpm if bpm > 0 else 120.0))
            
        first_beat = dynamic_beats[0]
        while first_beat >= median_interval:
            first_beat -= median_interval
            dynamic_beats.insert(0, first_beat)
            
        # 2. Project forwards to the end of the song
        last_beat = dynamic_beats[-1]
        while last_beat + median_interval <= metro_duration:
            last_beat += median_interval
            dynamic_beats.append(last_beat)
            
        dynamic_beats = np.array(dynamic_beats)
        
        # Add a precisely measured 26ms shift for Gapless MP3 encoder padding.
        # Previously we guessed 45ms, but standard LAME/FFmpeg padding is 1152 samples at 44100Hz = 26.12ms.
        dynamic_beats += 0.026
        
        dynamic_beats = dynamic_beats[dynamic_beats < metro_duration]
        
        if len(dynamic_beats) > 0:
            # 1x Subdivision
            click_track_1x = librosa.clicks(times=dynamic_beats, sr=metro_sr, click=click_1x, length=int(metro_duration * metro_sr))
            path_1x = stem_folder / "0_Metronome_1x.flac"
            sf.write(str(path_1x), click_track_1x, metro_sr, format='FLAC')
            audio_files.append(path_1x)
            
            # 0.5x Subdivision
            beats_05x = []
            if len(dynamic_beats) > 0:
                beats_05x.append(dynamic_beats[0])
                last_clicked = dynamic_beats[0]
                for b in dynamic_beats[1:]:
                    if (b - last_clicked) >= (median_interval * 1.5):
                        beats_05x.append(b)
                        last_clicked = b
            
            beats_05x = np.array(beats_05x)
            click_track_05x = librosa.clicks(times=beats_05x, sr=metro_sr, click=click_05x, length=int(metro_duration * metro_sr))
            path_05x = stem_folder / "0_Metronome_0_5x.flac"
            sf.write(str(path_05x), click_track_05x, metro_sr, format='FLAC')
            audio_files.append(path_05x)
            
            # 2x Subdivision
            beats_2x = []
            for i in range(len(dynamic_beats) - 1):
                beats_2x.append(dynamic_beats[i])
                halfway = (dynamic_beats[i] + dynamic_beats[i+1]) / 2.0
                if halfway < metro_duration:
                    beats_2x.append(halfway)
            beats_2x.append(dynamic_beats[-1])
            beats_2x = np.array(beats_2x)
            
            click_track_2x = librosa.clicks(times=beats_2x, sr=metro_sr, click=click_2x, length=int(metro_duration * metro_sr))
            path_2x = stem_folder / "0_Metronome_2x.flac"
            sf.write(str(path_2x), click_track_2x, metro_sr, format='FLAC')
            audio_files.append(path_2x)
    
    # Zip it all up
    print("Checking for lyrics...")
    
    # Helper to find any .lrc file in the folder (newest first)
    def find_lrc():
        # First check the temp folder
        lrc_files = list(stem_folder.glob("*.lrc"))
        
        # If not in temp folder, check right next to the original MP3!
        if not lrc_files and original_track_path:
            master_dir = Path(original_track_path).parent
            lrc_files = list(master_dir.glob("*.lrc"))
            
        if not lrc_files:
            return None
        # Sort by most recently modified, so if they have multiple, we pick the one they just downloaded!
        lrc_files.sort(key=lambda x: x.stat().st_mtime, reverse=True)
        return lrc_files[0]

    lrc_path = find_lrc()
    
    if lrc_path:
        print(f"Found existing lyrics file '{lrc_path.name}'. Skipping download!")
    else:
        print("Downloading lyrics...")
        try:
            import syncedlyrics
            search_query = f"{song_name} {artist_name}".strip()
            lrc_content = syncedlyrics.search(search_query)
            if lrc_content:
                lrc_path = stem_folder / "lyrics.lrc"
                with open(lrc_path, "w", encoding="utf-8") as f:
                    f.write(lrc_content)
                print("Successfully downloaded synced lyrics (.lrc)!")
            else:
                raise Exception("No lyrics found in database.")
        except Exception as e:
            print(f"Automated lyrics download failed: {e}")
            import webbrowser
            import urllib.parse
            from tkinter import messagebox
            
            wants_manual = messagebox.askyesno(
                "Lyrics Not Found", 
                f"We couldn't automatically find synced lyrics for '{song_name}'.\n\nWould you like to manually download them from Lyricsify.com right now?"
            )
            
            if wants_manual:
                query = urllib.parse.quote(f"{song_name} {artist_name}".strip())
                webbrowser.open(f"https://www.lyricsify.com/search?q={query}")
                
                messagebox.showinfo(
                    "Waiting for Lyrics...", 
                    f"1. Download the correct .lrc file from the website.\n2. Move that downloaded file directly into the SAME folder as your original MP3 file:\n{Path(original_track_path).parent if original_track_path else stem_folder}\n(No need to rename it!)\n\nClick OK *ONLY AFTER* you have dropped the file in the folder to resume packaging!"
                )
                
                lrc_path = find_lrc()
                if lrc_path:
                    print(f"Awesome! Successfully loaded your manual '{lrc_path.name}' file!")
                else:
                    print("No .lrc file found in the folder. Proceeding without lyrics...")
            else:
                print("Skipping lyrics. Proceeding without them...")

    zip_filename = Path(output_path) / f"{song_name.replace(' ', '_')}.zip"
    
    print(f"Creating {zip_filename.name}...")
    with zipfile.ZipFile(zip_filename, 'w', zipfile.ZIP_DEFLATED) as zipf:
        zipf.write(metadata_path, arcname="song_metadata.json")
        if lrc_path and lrc_path.exists():
            zipf.write(lrc_path, arcname="lyrics.lrc")
        if (stem_folder / "cover.jpg").exists():
            zipf.write(stem_folder / "cover.jpg", arcname="cover.jpg")
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
        def __init__(self, root_ref, textbox, progress_bar):
            self.root_ref = root_ref
            self.textbox = textbox
            self.progress_bar = progress_bar

        def write(self, text):
            self.root_ref.after(0, lambda t=text: self._safe_write(t))
            
        def _safe_write(self, text):
            import re
            match = re.search(r'(\d+)%\|', text)
            if match:
                try:
                    val = float(match.group(1)) / 100.0
                    self.progress_bar.set(val)
                except:
                    pass
                    
            if '\r' in text:
                return
                
            self.textbox.insert(tk.END, text)
            self.textbox.see(tk.END)
            
        def flush(self):
            pass

    def select_audio_file():
        file = filedialog.askopenfilename(title="Select Master Audio File", filetypes=[("Audio", "*.mp3 *.wav *.flac")])
        if file:
            folder_var.set(file)
            if not song_var.get():
                song_var.set(Path(file).stem)
                
    def select_out_dir():
        out = filedialog.askdirectory(title="Select Output Directory for Zip")
        if out:
            out_var.set(out)

    def start_packaging():
        song = song_var.get().strip()
        artist = artist_var.get().strip()
        master_file = folder_var.get().strip()
        out = out_var.get().strip()
        
        if not song or not master_file:
            messagebox.showerror("Error", "Please provide both a Song Name and Master Audio Input.")
            return
            
        if not out:
            out = os.path.dirname(master_file)
            
        btn_package.configure(state="disabled")
        btn_folder.configure(state="disabled")
        btn_out.configure(state="disabled")
        
        def run_task():
            try:
                root.after(0, lambda: progress_bar.set(0.0))
                
                out_fmt = format_var.get().split()[0].lower() # "flac", "mp3", "wav"
                is_studio = "Studio" in quality_var.get()
                
                print(f"=== Starting StemSync Packaging: {song} ===")
                import tempfile, shutil
                from zero_bleed import ZeroBleedEngine
                
                temp_dir = tempfile.mkdtemp()
                try:
                    engine = ZeroBleedEngine(output_dir=temp_dir, out_format=out_fmt, is_studio=is_studio)
                    stems = engine.process(master_file)
                    create_bandtrack_zip(song, temp_dir, out, manual_artist=artist, original_track_path=master_file)
                finally:
                    if 'temp_dir' in locals():
                        shutil.rmtree(temp_dir, ignore_errors=True)
            except Exception as e:
                print(f"\\n[ERROR]: {e}")
                err_msg = str(e)
                root.after(0, lambda msg=err_msg: messagebox.showerror("Error", msg))
            finally:
                root.after(0, lambda: btn_package.configure(state="normal", text="Start Packaging"))
                root.after(0, lambda: btn_folder.configure(state="normal"))
                root.after(0, lambda: btn_out.configure(state="normal"))
                
        threading.Thread(target=run_task, daemon=True).start()

    # === PROFESSIONAL ENTERPRISE UI REDESIGN ===
    root = ctk.CTk()
    
    # Robustly find icon path (works in dev and PyInstaller bundle)
    try:
        base_path = sys._MEIPASS
    except Exception:
        base_path = os.path.abspath(os.path.dirname(__file__))
    icon_path = os.path.join(base_path, "icon.ico")
    
    if os.path.exists(icon_path):
        root.iconbitmap(icon_path)
        
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
    
    # -- Card 2: Input & Output --
    card2 = ctk.CTkFrame(main_frame, corner_radius=6, fg_color="#252526", border_width=1, border_color="#3E3E42")
    card2.grid(row=1, column=0, sticky="ew", pady=(0, 20))
    card2.grid_columnconfigure(1, weight=1)
    
    ctk.CTkLabel(card2, text="Input & Output", font=ctk.CTkFont(size=14, weight="normal"), text_color="#D4D4D4").grid(row=0, column=0, columnspan=3, sticky="w", padx=25, pady=(15, 10))
    
    folder_var = tk.StringVar()
    out_var = tk.StringVar()
    format_var = tk.StringVar(value="FLAC (Lossless)")
    quality_var = tk.StringVar(value="Standard (Fast ~5m)")
    
    ctk.CTkLabel(card2, text="Master Audio Input", font=ctk.CTkFont(size=12), text_color="#A6A6A6").grid(row=1, column=0, sticky="w", padx=25, pady=(0, 10))
    ctk.CTkEntry(card2, textvariable=folder_var, border_width=1, border_color="#3E3E42", fg_color="#1E1E1E", text_color="#D4D4D4", height=32, corner_radius=4).grid(row=1, column=1, sticky="ew", padx=(0, 15), pady=(0, 10))
    btn_folder = ctk.CTkButton(card2, text="Browse...", width=80, height=32, corner_radius=4, fg_color="#333337", hover_color="#3F3F46", text_color="#D4D4D4", command=select_audio_file)
    btn_folder.grid(row=1, column=2, padx=(0, 25), pady=(0, 10))
    
    ctk.CTkLabel(card2, text="Output Zip Dir", font=ctk.CTkFont(size=12), text_color="#A6A6A6").grid(row=2, column=0, sticky="w", padx=25, pady=(0, 15))
    ctk.CTkEntry(card2, textvariable=out_var, border_width=1, border_color="#3E3E42", fg_color="#1E1E1E", text_color="#D4D4D4", height=32, corner_radius=4).grid(row=2, column=1, sticky="ew", padx=(0, 15), pady=(0, 15))
    btn_out = ctk.CTkButton(card2, text="Browse...", width=80, height=32, corner_radius=4, fg_color="#333337", hover_color="#3F3F46", text_color="#D4D4D4", command=select_out_dir)
    btn_out.grid(row=2, column=2, padx=(0, 25), pady=(0, 15))

    ctk.CTkLabel(card2, text="Stem Format", font=ctk.CTkFont(size=12), text_color="#A6A6A6").grid(row=3, column=0, sticky="w", padx=25, pady=(0, 15))
    ctk.CTkOptionMenu(card2, variable=format_var, values=["FLAC (Lossless)", "MP3 (Small Size)", "WAV (Raw)"], fg_color="#333337", button_color="#3F3F46", button_hover_color="#4F4F56").grid(row=3, column=1, sticky="ew", padx=(0, 15), pady=(0, 15))

    ctk.CTkLabel(card2, text="AI Quality", font=ctk.CTkFont(size=12), text_color="#A6A6A6").grid(row=4, column=0, sticky="w", padx=25, pady=(0, 20))
    ctk.CTkOptionMenu(card2, variable=quality_var, values=["Standard (Fast ~5m)", "Studio (Zero-Bleed ~1h)"], fg_color="#333337", button_color="#3F3F46", button_hover_color="#4F4F56").grid(row=4, column=1, sticky="ew", padx=(0, 15), pady=(0, 20))
    
    # -- Action Area --
    btn_package = ctk.CTkButton(main_frame, text="Start Packaging", command=start_packaging, font=ctk.CTkFont(size=14, weight="normal"), height=40, corner_radius=4, fg_color="#0E639C", text_color="#FFFFFF", hover_color="#1177BB")
    btn_package.grid(row=2, column=0, sticky="ew", pady=(0, 20))
    
    # -- Console --
    console = ctk.CTkTextbox(main_frame, height=140, font=ctk.CTkFont(family="Consolas", size=12), text_color="#CCCCCC", fg_color="#1E1E1E", border_width=1, border_color="#3E3E42", corner_radius=4)
    console.grid(row=3, column=0, sticky="nsew")
    main_frame.grid_rowconfigure(3, weight=1)
    
    progress_bar = ctk.CTkProgressBar(main_frame, height=12, corner_radius=4, progress_color="#0E639C")
    progress_bar.grid(row=4, column=0, sticky="ew", pady=(10, 0))
    progress_bar.set(0.0)

    sys.stdout = PrintLogger(root, console, progress_bar)
    sys.stderr = PrintLogger(root, console, progress_bar)
    
    root.mainloop()
