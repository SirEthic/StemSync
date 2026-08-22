# 🚀 StemSync v1.1.0: Setlists, Chord Sheets & Optimizations

This is a massive update for StemSync bringing major new features to the mobile app and drastically reducing the Windows Packager size.

## 📱 Mobile App (Android)
*   **📋 Setlists:** You can now create custom setlists to organize your gigs and practice sessions.
*   **📄 PDF Chord Sheet Export:** Instantly generate clean, A4 rhythm slash notation PDF chord sheets directly from the app (built in pure Dart).
*   **🎧 Audio Mixdown Export:** Export your custom stem mix as a single `.wav` file to share with bandmates.
*   **🔁 Advanced Playback:** Added a customizable Count-In (1-4 bars) and looping controls (Repeat Song or Auto-Advance).
*   **💽 Rich Song Metadata:** The new Song Details view displays full track details including Album Art, Genre, Release Year, and exact BPM.
*   **🎨 UI Polish:** Fully optimized pure OLED black theme (`#000000`) and refined typography.

## 💻 Windows Packager
*   **⚡ Instant Loading:** Completely rewritten the PyInstaller configuration from "One-File" to "One-Folder", wrapping it cleanly in Inno Setup. The packager now launches instantly (1-2 seconds) instead of hanging.
*   **📦 Massive Size Reduction:** Stripped out over 350MB of unused ML bloat dependencies (like `PyTorch` and `onnxruntime`).
*   **🎨 Brand New Icon:** The packager setup and desktop shortcuts now feature the newly chosen high-res StemSync layered vinyl logo.

---

### 📥 Downloads
Download the **`StemSync_Packager_Setup.exe`** for your PC, and the appropriate **`.apk`** for your Android device (`arm64-v8a` is recommended for 99% of modern phones).
