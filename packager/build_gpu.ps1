$ErrorActionPreference = "Stop"

# Route PIP cache to E: drive to save C: drive space
$env:PIP_CACHE_DIR="E:\pip_cache_gpu"

Write-Host "=== Creating GPU Virtual Environment ==="
python -m venv gpu_env
& .\gpu_env\Scripts\Activate.ps1

Write-Host "=== Installing CUDA PyTorch (This is a 2.5GB download, please wait...) ==="
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121

Write-Host "=== Installing ONNX GPU and Audio Separator ==="
# Uninstall CPU version if it accidentally got pulled
pip uninstall -y onnxruntime
pip install onnxruntime-gpu
pip install "audio-separator[gpu]" audioread customtkinter pillow pyinstaller

Write-Host "=== Building the massive GPU executable ==="
pyinstaller -y "StemSync Packager.spec"

Write-Host "=== Compiling the final GPU Installer ==="
& "C:\Users\vidha\AppData\Local\Programs\Inno Setup 6\iscc.exe" "installer_gpu.iss"

Write-Host "=== GPU BUILD COMPLETE ==="
