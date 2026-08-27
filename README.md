# StemSync

![StemSync Logo](assets/icon.jpg)

**StemSync** is a powerful mobile application designed for musicians, producers, and singers. It allows you to take your AI-separated instrument stems and dynamically mix, pitch-shift, and tempo-shift them in real-time directly on your Android device.

## ?? Key Features

*   **?? Cloud Band Drive (New in v1.3.0+):** Native Google Drive integration. Directly browse, stream, and download your band's shared ZIP stems and setlists right from the cloud tab without manual file transfers.
*   **?? Collaborative Setlists (New in v1.4.0):** Effortlessly sync JSON setlists across devices via the cloud. See which songs you're missing as grayed-out "ghost items" and download them directly from the setlist view with a single tap.
*   **?? 6-Part Stem Mixing:** Perfectly supports separation models. Dynamically handles 6 distinct parts: Vocals, Drums, Bass, Guitar, Piano, and Other.
*   **??? Real-Time Studio Mixer:** A fully interactive studio mixer with volume control, magnetic center-snapping stereo panning, and dedicated Mute & Solo buttons.
*   **?? Pitch & Tempo Manipulation:** Instantly shift the key of the song or speed up/slow down the tempo without altering the pitch.
*   **?? Dynamic Ribbon UI:** Beautiful, scrolling visual ribbons for Lyrics, Chords, and Song Sections that track automatically with the playback timestamp.
*   **?? PDF Chord Sheet Export:** Generate clean, vector-based A4 rhythm slash notation PDF chord sheets directly from the app.
*   **?? Audio Mixdown & Sharing:** Export your custom stem mix as a single WAV file to share with bandmates.
*   **?? Integrated Metronome:** Built-in metronome with subdivision support that synchronizes perfectly with the track's BPM.
*   **?? Persistent Mixes:** Your custom volume, pan, and mute states are saved automatically per song. 
*   **??? Enterprise Network Support:** Full system proxy support for strict school and corporate Wi-Fi environments.

## ?? Installation & Usage

StemSync operates in a two-part workflow. The heavy AI separation is done on your PC using tools like UVR5, and the resulting stems are packaged and downloaded to your phone for mixing.

### 1. The Windows Packager (PC)
1. Use [Ultimate Vocal Remover 5](https://ultimatevocalremover.com/) to separate your audio into 6 stems (Vocals, Drums, Bass, Guitar, Piano, Other) into a single folder.
2. Download the latest StemSync_Packager_Setup.exe from the [Releases](https://github.com/SirEthic/StemSync/releases) page and install it.
3. Open the Packager and select the folder. It will analyze the audio, fetch synced lyrics and chords, fingerprint the song via Shazam, and compile a .zip StemSync project file.
4. Upload the compiled .zip file to a shared Google Drive folder.

### 2. The StemSync App (Android)
1. Download the latest StemSync-v1.4.0-arm64-v8a.apk (or the architecture for your device) from the [Releases](https://github.com/SirEthic/StemSync/releases) page and install it.
2. Open StemSync, navigate to the **Cloud Tab**, enter your band's shared Google Drive Folder ID, and tap to download your songs.
3. Start mixing and creating collaborative setlists!

## ??? Built With

*   **Flutter & Dart** - Mobile Application UI (optimized with a pure OLED black theme)
*   **SoLoud** - High-performance C++ audio engine for low-latency, multi-track playback
*   **Python** - Packager backend for audio analysis and compiling
*   **Shazamio** - Audio fingerprinting and metadata retrieval

## ?? License

This project is open-source and available under standard licenses.
