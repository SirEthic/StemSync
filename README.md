# StemSync

StemSync is a two-part AI-powered audio ecosystem consisting of a Python desktop Packager and a mobile Flutter Application. It allows you to package AI-separated instrument stems (from UVR5), automatically extract acoustic metadata (chords, tempo, song sections, and synced lyrics), and play them back in an interactive multitrack mobile player.

## Features
* **Auto-Metadata Extraction:** Automatically detects Key, Tempo (BPM), and song sections using librosa.
* **Lyric Scraping:** Automatically scrapes synced .lrc lyrics from the internet during packaging.
* **Interactive Mobile Player:** Solo/Mute instruments, scrub through interactive lyrics, and view live chord progressions.
* **Auto-Metronome:** Generates a mathematically perfect click-track perfectly synced to the original tempo.

## 1. StemSync Packager (Desktop)
The Python Packager is a professional GUI tool that processes your separated stems into a .zip package for the mobile app.

### Prerequisites
You must have Python 3.9+ installed on your system.

\\\ash
pip install librosa soundfile shazamio customtkinter numpy syncedlyrics
\\\`n
### Usage
1. Ensure you have 4 isolated stems from UVR5: \ocals\, \drums\, \ass\, \other\.
2. Double-click \StemSync Packager.pyw\ inside the \packager\ folder.
3. Select your stems folder.
4. Click **Start Packaging**.

*Note: If the packager fails to find synced lyrics online, simply drop a \lyrics.lrc\ file into your stems folder before packaging.*

## 2. StemSync Mobile App (Flutter)
The mobile app allows you to load the .zip packages and interact with the stems.

### Prerequisites
* Flutter SDK
* Android Studio / Xcode

### Usage
1. Connect your mobile device or launch an emulator.
2. Navigate into the \moises_app\ folder.
3. Run \lutter pub get\.
4. Run \lutter run\.
5. Tap the **Load New .zip** button in the app to import the package you created!
