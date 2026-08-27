# StemSync

![StemSync Logo](StemSync/assets/icon_foreground.png)

**StemSync** is a powerful mobile application designed for musicians, producers, and singers. It allows you to take your AI-separated instrument stems and dynamically mix, pitch-shift, and tempo-shift them in real-time directly on your Android device.

## 🌟 Key Features

*   **🎸 6-Part Stem Mixing:** StemSync is built to perfectly support **Ultimate Vocal Remover 5 (UVR5)** separation models. It dynamically handles 6 distinct parts: Vocals, Drums, Bass, Guitar, Piano, and Other.
*   **🎛️ Real-Time Studio Mixer:** A fully interactive studio mixer built right into your phone. Features dynamic volume control, magnetic center-snapping stereo panning (L/R), and dedicated Mute & Solo buttons for every stem.
*   **⏱️ Pitch & Tempo Manipulation:** Instantly shift the key of the song without affecting the tempo, or speed up/slow down the tempo without altering the pitch. Perfect for practice and rehearsal.
*   **🎼 Dynamic Ribbon UI:** Beautiful, scrolling visual ribbons for Lyrics, Chords, and Song Sections that track automatically with the playback timestamp.
*   **📋 Setlists:** Create custom setlists to organize your practice sessions and gigs, and seamlessly auto-advance through them.
*   **📄 PDF Chord Sheet Export:** Instantly generate clean, vector-based A4 rhythm slash notation PDF chord sheets directly from the app.
*   **🎧 Audio Mixdown & Sharing:** Export your custom stem mix as a single WAV file to share with bandmates or use in other software.
*   **🔁 Advanced Playback Controls:** Includes a customizable Count-In (1-4 bars) and looping controls (Repeat Song or Auto-Advance).
*   **🥁 Integrated Metronome:** A built-in customizable metronome with subdivision support that synchronizes perfectly with the track's BPM.
*   **💽 Rich Song Metadata:** Displays full track details including Album Art, Genre, Release Year, original key, and precise BPM.
*   **💾 Persistent Mixes:** Your custom volume, pan, and mute states are saved automatically per song. When you load the track again, your mix is exactly how you left it.

## 📥 Installation & Usage

StemSync operates in a two-part workflow. The heavy AI separation is done on your PC using tools like UVR5, and the resulting stems are packaged and sent to your phone for mixing.

### 1. Prerequisites (UVR5)
Before using StemSync, you must separate your track. Use [Ultimate Vocal Remover 5 (UVR5)](https://ultimatevocalremover.com/) (or a similar tool) to separate your audio file into 6 distinct stems: **Vocals, Drums, Bass, Guitar, Piano, and Other**. Place these output `.wav`, `.mp3`, or `.flac` files into a single folder.

### 2. The Windows Packager (PC)
1. Navigate to the [Releases](https://github.com/SirEthic/StemSync/releases) page and download `StemSync_Packager_Setup.exe`.
2. Install the program.
3. Open the Packager and select the folder containing your separated stems. 
4. The packager will automatically analyze the audio, fetch synchronized lyrics and chords, fingerprint the song via Shazam for metadata, and compile everything into a single `.zip` StemSync project file.

### 3. The StemSync App (Android)
1. Download the latest `StemSync_v1.0.0_arm64.apk` from the [Releases](https://github.com/SirEthic/StemSync/releases) page and install it on your Android phone.
2. Transfer the compiled `.zip` project file(s) from your PC onto your phone.
3. Open StemSync, tap the **Library Add (FAB)** icon, select the `.zip` file, and start mixing!

## 🛠️ Built With

*   **Flutter & Dart** - Mobile Application UI (optimized with a pure OLED black theme)
*   **SoLoud** - High-performance C++ audio engine for low-latency, multi-track playback
*   **Python** - Packager backend for audio analysis and compiling
*   **Shazamio** - Audio fingerprinting and metadata retrieval

## 📄 License

This project is open-source and available under standard licenses.
