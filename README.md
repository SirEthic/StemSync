# 🚀 StemSync v2.0

![StemSync Logo](StemSync/assets/icon_foreground.png)

**StemSync** is a revolutionary two-part AI ecosystem designed for musicians, producers, and singers. It replaces complex audio engineering workflows with a fully automated **Zero-Bleed Windows Packager Engine** that generates studio-grade `.bandtrack` files, and a beautiful **Flutter Mobile App** to mix, pitch-shift, and tempo-shift them in real-time.

---

## 🎸 The Windows Packager Engine (New in v2.0!)

Say goodbye to manual UVR5 stem routing. The brand new StemSync Packager is a fully automated, offline Python AI engine that turns any raw `.mp3` into a fully interactive bandtrack in under 30 seconds.

*   **Zero-Bleed Separation (ONNX & MDX-Net):** Deploys an aggressive *Spectral Energy-Proportional Allocation* algorithm that isolates Drums via MDX-Net, and then dynamically filters out all transient bleed from the HTDemucs 6-stem residual mix for unprecedented clarity.
*   **Automatic Metadata Ripping:** Seamlessly integrates with the **Shazam API** to acoustically fingerprint your audio and automatically embed the original Album Art, Song Title, and Artist.
*   **Tempo-Mapped Metronomes:** Uses Librosa to dynamically calculate exact BPM and transient beats, mathematically generating perfectly synced click-tracks (`1x`, `0.5x`, and `2x` subdivisions).
*   **Automatic Synced Lyrics:** Automatically searches the global `.lrc` database and bundles time-synced lyrics into your track.

## 📱 The Mobile Player App

Drop your generated `.bandtrack` zip file directly into the StemSync Android app for a fully interactive studio experience.

*   **6-Part Real-Time Studio Mixer:** Fully interactive volume control, magnetic center-snapping stereo panning (L/R), and dedicated Mute & Solo buttons for Vocals, Drums, Bass, Guitar, Keys, and Other.
*   **Pitch & Tempo Manipulation:** Instantly shift the key of the song without affecting the tempo, or speed up/slow down the tempo without altering the pitch. Perfect for practice and rehearsal.
*   **Dynamic UI Ribbons:** Beautiful, scrolling visual ribbons for Lyrics, Chords, and Song Sections that track perfectly in time with the music.
*   **Scrubber UI & A/B Looping:** Seamlessly scrub through all 6 stems simultaneously without losing sync, or set A/B loop points to infinitely practice specific guitar solos.
*   **Cloud Band Drive & Setlists:** Sync JSON setlists and stream `.bandtrack` ZIP files directly from your band's shared Google Drive without manual file transfers.
*   **PDF Chord Sheet Export:** Instantly generate clean, vector-based A4 rhythm slash notation PDF chord sheets directly from the app.

---

## 📥 Installation & Usage

StemSync operates in a blazing fast two-part workflow:

### 1. Generate the Bandtrack (Windows PC)
1. Download either the `GPU` (NVIDIA) or `CPU` version of the **StemSync Packager** from the [Releases](https://github.com/SirEthic/StemSync/releases/tag/v2.0) page.
2. Select your raw `.mp3` song.
3. Click "Process". The engine will automatically separate the 6 stems, rip the Shazam metadata, fetch the `.lrc` lyrics, generate the metronomes, and output a clean `.zip` file.

### 2. Play the Bandtrack (Android Phone)
1. Download the **StemSync Android APK** (`arm64-v8a` recommended) from the Releases page.
2. Transfer the generated `.zip` file to your phone.
3. Tap "Import Song" inside the app, select the `.zip`, and instantly start mixing!

---

*StemSync is proudly open-source and built for live musicians.*
