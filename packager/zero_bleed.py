import os
import gc
import numpy as np
import librosa
import soundfile as sf
import sys
from pathlib import Path

try:
    import imageio_ffmpeg
    os.environ["PATH"] += os.pathsep + os.path.dirname(imageio_ffmpeg.get_ffmpeg_exe())
except Exception:
    pass

if hasattr(sys, '_MEIPASS'):
    os.environ["PATH"] = sys._MEIPASS + os.pathsep + os.environ["PATH"]

from audio_separator.separator import Separator

class ZeroBleedEngine:
    def __init__(self, output_dir="separated_stems", out_format="flac", is_studio=False):
        self.output_dir = Path(output_dir)
        self.output_dir.mkdir(parents=True, exist_ok=True)
        self.out_format = out_format
        self.is_studio = is_studio
        
    def _run_pass(self, model_name, input_file, is_demucs=False):
        print(f"Loading {model_name}...")
        # Initialize separator per pass to control memory.
        params = {}
        if is_demucs:
            shifts = 2 if self.is_studio else 0
            params = {'demucs_params': {'shifts': shifts}}
        
        separator = Separator(
            output_dir=str(self.output_dir),
            output_format=self.out_format,
            **params
        )
        separator.load_model(model_name)
        print(f"Running inference for {model_name}...")
        outputs = separator.separate(input_file)
        
        # Destroy and cleanup to free RAM/VRAM
        del separator
        gc.collect()
        
        try:
            import torch
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
        except ImportError:
            pass
            
        return outputs

    def _safe_stft(self, y):
        # Backward compatibility for librosa < 0.10.0 which crashes on stereo (2D) arrays
        if y.ndim == 1:
            return librosa.stft(y)
        return np.array([librosa.stft(y[i]) for i in range(y.shape[0])])
        
    def _safe_istft(self, S, length):
        if S.ndim == 2:
            return librosa.istft(S, length=length)
        return np.array([librosa.istft(S[i], length=length) for i in range(S.shape[0])])

    def _spectral_allocation(self, bleed_path, stems_dict):
        print("Running Spectral Energy-Proportional Allocation for transient bleed...")
        
        y_bleed, sr = librosa.load(bleed_path, sr=44100, mono=False)
        stft_bleed = self._safe_stft(y_bleed)
        
        print(" -> Calculating total spectral energy...")
        total_mag = None
        for name, path in stems_dict.items():
            y, _ = librosa.load(path, sr=44100, mono=False)
            mag = np.abs(self._safe_stft(y))
            
            if total_mag is None:
                total_mag = mag.astype(np.float32) + 1e-8
            else:
                total_mag += mag
                
            del y, mag
            gc.collect()
            
        print(" -> Reintegrating and saving corrected stems...")
        for name, path in stems_dict.items():
            y, _ = librosa.load(path, sr=44100, mono=False)
            S = self._safe_stft(y)
            
            ratio = np.abs(S) / total_mag
            S += (stft_bleed * ratio)
            
            y_out = self._safe_istft(S, length=y.shape[-1])
            sf.write(str(path), y_out.T, 44100)
            
            del y, S, y_out, ratio
            gc.collect()
            
        print("Spectral Allocation complete!")

    def _safe_path(self, f):
        p = Path(f)
        return p if p.is_absolute() else self.output_dir / p

    def process(self, master_audio_path):
        input_path = str(master_audio_path)
        
        # 1. Primary Drum Isolation (Pass 1)
        if self.is_studio:
            print("\n--- Pass 1: BS-RoFormer Drum Isolation (STUDIO MODE) ---")
            p1_model = 'model_bs_roformer_ep_317_sdr_12.9755.ckpt'
        else:
            print("\n--- Pass 1: MDX-Net Drum Isolation (STANDARD MODE) ---")
            p1_model = 'kuielab_b_drums.onnx'
            
        p1_outputs = self._run_pass(p1_model, input_path)
        
        d_clean_path = None
        r_inst_path = None
        
        for f in p1_outputs:
            lower_f = f.lower()
            if "(drums)" in lower_f or (lower_f.endswith("drums.wav") and not lower_f.endswith("no_drums.wav") and not lower_f.endswith("no drums.wav")):
                d_clean_path = self._safe_path(f)
            elif "(no drums)" in lower_f or "instrumental" in lower_f or lower_f.endswith("no_drums.wav") or lower_f.endswith("no drums.wav"):
                r_inst_path = self._safe_path(f)
                
        if not d_clean_path or not r_inst_path:
            raise Exception("AI failed to output expected drum stem files!")
            
        # Rename D_clean to standard naming for the final zip. Use os.replace to avoid WinError 183.
        final_drums = self.output_dir / f"drums.{self.out_format}"
        if d_clean_path.exists():
            os.replace(d_clean_path, final_drums)

        # 2. 6-Stem Residual Processing (Pass 2)
        print("\n--- Pass 2: Demucs 6-Stem on Residual ---")
        demucs_outputs = self._run_pass('htdemucs_6s.yaml', str(r_inst_path), is_demucs=True)
        
        # Identify Demucs outputs robustly by exact suffix
        d_bleed_path = None
        other_stems = {}
        
        for f in demucs_outputs:
            path = self._safe_path(f)
            lower_f = f.lower()
            
            # audio-separator appends the model name at the end, so we can't use endswith.
            if "(drums)" in lower_f or "(drum)" in lower_f:
                d_bleed_path = path
            elif "(vocals)" in lower_f or "(vocal)" in lower_f:
                other_stems["vocals"] = path
            elif "(bass)" in lower_f:
                other_stems["bass"] = path
            elif "(guitar)" in lower_f:
                other_stems["guitar"] = path
            elif "(piano)" in lower_f:
                other_stems["piano"] = path
            elif "(other)" in lower_f or "(instrumental)" in lower_f:
                # Wait, Pass 1 creates an (Instrumental) file. Demucs uses (Other).
                if "htdemucs" in lower_f:
                    other_stems["other"] = path
                
        # Rename Demucs outputs to clean standard names to avoid chained model filenames
        clean_other_stems = {}
        for name, ugly_path in other_stems.items():
            clean_path = self.output_dir / f"{name}.{self.out_format}"
            if ugly_path.exists():
                os.replace(ugly_path, clean_path)
                clean_other_stems[name] = clean_path
                
        # 3. Spectral Allocation
        if d_bleed_path and d_bleed_path.exists():
            self._spectral_allocation(d_bleed_path, clean_other_stems)
            # D_bleed has been mathematically re-integrated. Delete the mistake track.
            try: os.remove(d_bleed_path)
            except: pass
            
        # Clean up the residual
        if r_inst_path.exists():
            try: os.remove(r_inst_path)
            except: pass
        
        print("\nZero-Bleed Separation Complete!")
        print(f"Stems saved to: {self.output_dir}")

