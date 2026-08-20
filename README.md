# StemSync

StemSync is a toolkit for packaging and playing isolated audio stems. It uses Ultimate Vocal Remover 5 (UVR5) to split tracks, a Python script to package them with metadata, and a Flutter app for interactive multitrack playback.

## 1. Prerequisites

Before using StemSync, you need isolated audio stems.

1. Download and install [Ultimate Vocal Remover 5 (UVR5)](https://github.com/Anjok07/ultimatevocalremovergui).
2. Process your audio file using a Demucs model (e.g., \htdemucs_ft\).
3. Select the 4-stem output option to generate:
   - \ocals.mp3\`n   - \drums.mp3\`n   - \ass.mp3\`n   - \other.mp3\`n4. Place these 4 files into a single directory named after your song.

## 2. Packager

The packager is a Python desktop application that analyzes your stems, extracts metadata (BPM, key, chords, sections, lyrics), and bundles them into a \.zip\ file for the mobile app.

### Setup

Requires Python 3.9 or higher.

\\\ash
pip install librosa soundfile shazamio customtkinter numpy syncedlyrics
\\\`n
### Usage

1. Navigate to the \packager\ directory.
2. Run the application:
   \\\ash
   python "StemSync Packager.pyw"
   \\\`n3. Enter the track details and select your stems directory.
4. Click **Start Packaging** to generate the \.zip\ file.

*Note: If synced lyrics cannot be found automatically, you can place a \lyrics.lrc\ file in the stems directory before packaging.*

## 3. Mobile Player

The mobile player is a Flutter application that loads the packaged \.zip\ files, allowing you to mute/solo individual stems, view live chords, and scrub through synced lyrics.

### Setup

- Flutter SDK
- iOS Simulator or Android Emulator

### Usage

1. Navigate to the \StemSync\ directory.
2. Install dependencies:
   \\\ash
   flutter pub get
   \\\`n3. Run the application:
   \\\ash
   flutter run
   \\\`n4. Use the **Load New .zip** button to import the package generated in step 2.
