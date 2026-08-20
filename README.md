# StemSync

StemSync is a two-part toolkit for packaging and playing back AI-separated audio stems. A Python desktop app handles the analysis and packaging, and a Flutter mobile app handles playback.

---

## Prerequisites

Before using StemSync, you need to split a song into its individual instruments using [Ultimate Vocal Remover 5 (UVR5)](https://github.com/Anjok07/ultimatevocalremovergui).

1. Download and install UVR5.
2. Open UVR5, load your song, and select a **Demucs** model (htdemucs_ft is recommended).
3. Set the output to **6 stems**. This produces:
   - vocals.mp3
   - drums.mp3
   - bass.mp3
   - guitar.mp3
   - piano.mp3
   - other.mp3
4. Place all six files into a single folder named after your song.

---

## Part 1 - Packager

The packager analyzes your stems and produces a .zip file containing the audio, metadata (BPM, key, chords, song sections), and synced lyrics.

### Requirements

Python 3.9 or higher.

`
pip install librosa soundfile shazamio customtkinter numpy syncedlyrics
`

### Running

Double-click StemSync Packager.pyw inside the packager folder. No terminal will open.

1. Fill in the track title. The artist name is optional - the packager will attempt to detect it automatically via Shazam.
2. Select your stems folder.
3. Click **Start Packaging**.

The output .zip will be saved in the same folder as your stems.

> If lyrics cannot be found automatically (common for obscure tracks), download a .lrc file from a site like [lyricsify.com](https://www.lyricsify.com), rename it lyrics.lrc, and place it in the stems folder before packaging.

---

## Part 2 - Mobile App

The Flutter mobile app loads the packaged .zip files for playback. Features include per-stem volume control, a live chord display, song section navigation, a metronome, and tappable synced lyrics.

### Requirements

- Flutter SDK
- Android or iOS device / emulator

### Running

`
cd StemSync
flutter pub get
flutter run
`

Once running, tap **Load New .zip** to import a package from your device storage.
