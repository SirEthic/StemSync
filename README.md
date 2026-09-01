# StemSync

![StemSync Logo](StemSync/assets/icon_foreground.png)

**StemSync** is a powerful mobile application designed for musicians, producers, and singers. It allows you to take your AI-separated instrument stems and dynamically mix, pitch-shift, and tempo-shift them in real-time directly on your Android device.

## 🌟 Key Features

*   **🎸 6-Part Stem Mixing:** StemSync is built to perfectly support 6 distinct parts: Vocals, Drums, Bass, Guitar, Keys, and Other.
*   **🎛️ Real-Time Studio Mixer:** A fully interactive studio mixer built right into your phone. Features dynamic volume control, magnetic center-snapping stereo panning (L/R), and dedicated Mute & Solo buttons for every stem.
*   **⏱️ Pitch & Tempo Manipulation:** Instantly shift the key of the song without affecting the tempo, or speed up/slow down the tempo without altering the pitch. Perfect for practice and rehearsal.
*   **🎼 Dynamic Ribbon UI:** Beautiful, scrolling visual ribbons for Lyrics, Chords, and Song Sections that track automatically with the playback timestamp.
*   **📋 Setlists:** Create custom setlists to organize your practice sessions and gigs, and seamlessly auto-advance through them.
*   **📄 PDF Chord Sheet Export:** Instantly generate clean, vector-based A4 rhythm slash notation PDF chord sheets directly from the app.
*   **🎧 Audio Mixdown & Sharing:** Export your custom stem mix as a single WAV file to share with bandmates or use in other software.
*   **🔁 Advanced Playback Controls:** Includes a customizable Count-In (1-4 bars), Scrubber UI to seamlessly seek across all 6 stems simultaneously, and A/B looping controls.
*   **🥁 Integrated Metronome:** A built-in customizable metronome with subdivision support (1x, 0.5x, 2x) that synchronizes perfectly with the track's BPM.
*   **💽 Rich Song Metadata:** Displays full track details including Album Art, Genre, Release Year, original key, and precise BPM.
*   **💾 Persistent Mixes:** Your custom volume, pan, and mute states are saved automatically per song. When you load the track again, your mix is exactly how you left it.

*   **☁️ Cloud Band Drive:** Native Google Drive integration. Directly browse, stream, and download your band's shared ZIP stems and setlists right from the cloud tab without manual file transfers.
*   **🤝 Collaborative Setlists:** Effortlessly sync JSON setlists across devices via the cloud. See which songs you're missing as grayed-out "ghost items" and download them directly from the setlist view with a single tap.
*   **🛡️ Enterprise Proxy Support:** Full system proxy support for strict school and corporate Wi-Fi environments.

## 📥 Installation & Usage

StemSync operates in a blazing fast two-part workflow. The heavy AI separation is done offline on your PC using the StemSync Packager Engine, and the resulting `.bandtrack` zip is sent to your phone for mixing.

### 1. The Windows Packager (PC)
1. Navigate to the [Releases](https://github.com/SirEthic/StemSync/releases) page and download **StemSync_Windows_Engine_GPU_Setup.exe** (NVIDIA graphics card) or **StemSync_Windows_Engine_CPU_Setup.exe** (standard laptop).
2. Install the program.
3. Open the Packager and select any raw `.mp3` file. 
4. The Packager will automatically deploy a Zero-Bleed AI algorithm (MDX-Net + HTDemucs) to separate the stems, fetch synchronized `.lrc` lyrics, generate librosa metronomes, fingerprint the song via Shazam for metadata, and compile everything into a single `.zip` StemSync file.

### 2. The StemSync App (Android)
1. Download the latest Android APK (e.g., `StemSync_Android_arm64-v8a_v2.0.apk`) from the [Releases](https://github.com/SirEthic/StemSync/releases) page and install it on your Android phone.
2. Upload the compiled `.zip` project file(s) from the Packager to your shared Google Drive folder.
3. Open StemSync, navigate to the **Cloud Tab**, enter your band's shared Google Drive Folder ID, and tap to seamlessly download your songs.
4. Start mixing and creating collaborative setlists!

## 🛠️ Built With

*   **Flutter & Dart** - Mobile Application UI (optimized with a pure OLED black theme)
*   **SoLoud** - High-performance C++ audio engine for low-latency, multi-track playback
*   **Python (ONNX & PyTorch)** - Packager backend for Zero-Bleed AI audio isolation
*   **Shazamio** - Audio fingerprinting and metadata retrieval

## 📄 License

This project is open-source and available under standard licenses.
