# -*- mode: python ; coding: utf-8 -*-


from PyInstaller.utils.hooks import copy_metadata, collect_data_files, collect_submodules
def safe_metadata(name):
    try: return copy_metadata(name)
    except: return []
def safe_data(name):
    try: return collect_data_files(name)
    except: return []
def safe_submodules(name):
    try: return collect_submodules(name)
    except: return []

a = Analysis(
    ['StemSync Packager.pyw'],
    pathex=[],
    binaries=[('ffmpeg.exe', '.')],
    datas=[('icon.ico', '.')] + safe_metadata('audio-separator') + safe_metadata('onnxruntime-gpu') + safe_metadata('onnxruntime') + safe_data('audio_separator') + safe_data('demucs'),
    hiddenimports=['shazamio', 'pydantic', 'audio_separator', 'librosa', 'soundfile', 'audioread', 'onnxruntime'] + safe_submodules('audio_separator') + safe_submodules('demucs') + safe_submodules('torch') + safe_submodules('librosa') + safe_submodules('onnxruntime'),
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=['matplotlib', 'IPython', 'notebook', 'PyQt5', 'PySide6', 'tensorboard'],
    noarchive=False,
    optimize=0,
)
pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,
    name='StemSync Packager',
    debug=False,
    bootloader_ignore_signals=False,
    strip=False,
    upx=True,
    console=False,
    disable_windowed_traceback=False,
    argv_emulation=False,
    target_arch=None,
    codesign_identity=None,
    entitlements_file=None,
    icon=['icon.ico'],
)

coll = COLLECT(
    exe,
    a.binaries,
    a.datas,
    strip=False,
    upx=True,
    upx_exclude=[],
    name='StemSync Packager',
)
