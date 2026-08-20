# StemSync

StemSync is a two-part AI-powered audio ecosystem consisting of a Python desktop Packager and a mobile Flutter Application. It allows you to package AI-separated instrument stems (from UVR5), automatically extract acoustic metadata (chords, tempo, song sections, and synced lyrics), and play them back in an interactive multitrack mobile player.

## Features
* **Auto-Metadata Extraction:** Automatically detects Key, Tempo (BPM), and song sections using \librosa\.
* **Lyric Scraping:** Automatically scrapes synced \.lrc\ lyrics from the internet during packaging.
* **Interactive Mobile Player:** Solo/Mute instruments, scrub through interactive lyrics, and view live chord progressions.
* **Auto-Metronome:** Generates a mathematically perfect click-track perfectly synced to the original tempo.

---

## 1. Prerequisites: Ultimate Vocal Remover (UVR5)
Before you can use StemSync, you need to use an AI model to split your MP3/WAV songs into isolated instrument stems.

1. Download and install **Ultimate Vocal Remover 5 (UVR5)** from their official GitHub: [https://github.com/Anjok07/ultimatevocalremovergui](https://github.com/Anjok07/ultimatevocalremovergui)
2. Open UVR5 and select your target song.
3. Select a **Demucs** model (e.g., \htdemucs_ft\).
4. In the settings, ensure you choose **4-Stem Output** (Vocals, Drums, Bass, Other).
5. Process the song. You should end up with a folder containing 4 files:
   - \ocals.mp3\ (or .wav)
   - \drums.mp3\`n   - \ass.mp3\`n   - \other.mp3\`n
*Note: Place all 4 of these files into a single folder named after your song (e.g., \Ufaq/\). This is your **Stems Folder**.*

---

## 2. StemSync Packager (Desktop)
The Python Packager is a professional GUI tool that processes your separated stems into a \.zip\ package for the mobile app.

### Installation
You must have Python 3.9+ installed on your system.

\\\ash
pip install librosa soundfile shazamio customtkinter numpy syncedlyrics
\\\`n
### Usage
1. Double-click \StemSync Packager.pyw\ inside the \packager\ folder.
2. Enter the **Song Name** and **Artist**.
3. Select your **UVR5 Stems Folder** (the one containing your 4 isolated tracks).
4. Click **Start Packaging**.

*Note: If the packager fails to find synced lyrics online for obscure songs, simply create a \lyrics.lrc\ text file with your lyrics, drop it into your stems folder, and run the packager again!*

---

## 3. StemSync Mobile App (Flutter)
The mobile app allows you to load the \.zip\ packages and interact with the stems.

### Installation
* Flutter SDK
* Android Studio / Xcode

### Usage
1. Connect your mobile device or launch an emulator.
2. Navigate into the \StemSync\ mobile app folder.
3. Run \lutter pub get\.
4. Run \lutter run\.
5. Tap the **Load New .zip** button in the app to import the package you created from your computer!
