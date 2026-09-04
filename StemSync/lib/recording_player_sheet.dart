import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:share_plus/share_plus.dart';

class RecordingPlayerSheet extends StatefulWidget {
  final File file;
  final String title;

  const RecordingPlayerSheet({super.key, required this.file, required this.title});

  @override
  State<RecordingPlayerSheet> createState() => _RecordingPlayerSheetState();
}

class _RecordingPlayerSheetState extends State<RecordingPlayerSheet> {
  AudioSource? _source;
  SoundHandle? _handle;
  
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Timer? _timer;
  bool _isDragging = false;
  bool _isLoaded = false;

  @override
  void initState() {
    super.initState();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    try {
      _source = await SoLoud.instance.loadFile(widget.file.path);
      final length = SoLoud.instance.getLength(_source!);
      _duration = length;
      
      _handle = SoLoud.instance.play(_source!);
      
      setState(() {
        _isPlaying = true;
        _isLoaded = true;
      });

      _timer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
        if (!mounted || _handle == null || _isDragging) return;
        
        final pos = SoLoud.instance.getPosition(_handle!);
        final isValid = SoLoud.instance.getIsValidVoiceHandle(_handle!);
        
        if (!isValid) {
          // Song ended naturally
          setState(() {
            _isPlaying = false;
            _position = Duration.zero;
          });
          return;
        }

        setState(() {
          _position = pos;
          _isPlaying = !SoLoud.instance.getPause(_handle!);
        });
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error playing audio: $e'), backgroundColor: Colors.red));
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_handle != null) SoLoud.instance.stop(_handle!);
    if (_source != null) SoLoud.instance.disposeSource(_source!);
    super.dispose();
  }

  void _togglePlayPause() {
    if (_handle == null || _source == null) return;
    
    final isValid = SoLoud.instance.getIsValidVoiceHandle(_handle!);
    if (!isValid) {
      // Replay from start
      _handle = SoLoud.instance.play(_source!);
      setState(() {
        _isPlaying = true;
        _position = Duration.zero;
      });
      return;
    }
    
    final isPaused = SoLoud.instance.getPause(_handle!);
    SoLoud.instance.setPause(_handle!, !isPaused);
    setState(() => _isPlaying = isPaused);
  }

  String _formatDuration(Duration d) {
    String twoDigits(int n) => n.toString().padLeft(2, "0");
    String twoDigitMinutes = twoDigits(d.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(d.inSeconds.remainder(60));
    if (d.inHours > 0) {
      return "${d.inHours}:$twoDigitMinutes:$twoDigitSeconds";
    }
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  Widget build(BuildContext context) {
    if (!_isLoaded) {
      return const SizedBox(
        height: 250,
        child: Center(child: CircularProgressIndicator(color: Colors.tealAccent)),
      );
    }

    return Container(
      padding: const EdgeInsets.all(24),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A1A),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 24),
          
          Text(widget.title, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 8),
          const Text("Live Gig Recording", style: TextStyle(color: Colors.tealAccent, fontSize: 14)),
          const SizedBox(height: 32),
          
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.tealAccent,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.tealAccent,
              overlayColor: Colors.tealAccent.withOpacity(0.2),
              trackHeight: 6,
            ),
            child: Slider(
              min: 0.0,
              max: _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 1.0,
              value: _position.inMilliseconds.toDouble().clamp(0.0, _duration.inMilliseconds.toDouble() > 0 ? _duration.inMilliseconds.toDouble() : 1.0),
              onChangeStart: (_) => _isDragging = true,
              onChanged: (val) {
                setState(() => _position = Duration(milliseconds: val.toInt()));
              },
              onChangeEnd: (val) {
                if (_handle != null) {
                  SoLoud.instance.seek(_handle!, Duration(milliseconds: val.toInt()));
                }
                _isDragging = false;
              },
            ),
          ),
          
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_formatDuration(_position), style: const TextStyle(color: Colors.white54, fontSize: 12)),
                Text(_formatDuration(_duration), style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ],
            ),
          ),
          
          const SizedBox(height: 16),
          
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: const Icon(Icons.replay_10, color: Colors.white70, size: 32),
                onPressed: () {
                  if (_handle != null) {
                    final newPos = _position - const Duration(seconds: 10);
                    SoLoud.instance.seek(_handle!, newPos.isNegative ? Duration.zero : newPos);
                  }
                },
              ),
              GestureDetector(
                onTap: _togglePlayPause,
                child: Container(
                  height: 64,
                  width: 64,
                  decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.tealAccent),
                  child: Icon(_isPlaying ? Icons.pause : Icons.play_arrow, color: Colors.black, size: 36),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.forward_10, color: Colors.white70, size: 32),
                onPressed: () {
                  if (_handle != null) {
                    final newPos = _position + const Duration(seconds: 10);
                    if (newPos < _duration) SoLoud.instance.seek(_handle!, newPos);
                  }
                },
              ),
            ],
          ),
          
          const SizedBox(height: 16),
          TextButton.icon(
            icon: const Icon(Icons.share, color: Colors.white70),
            label: const Text("Export Master File", style: TextStyle(color: Colors.white70)),
            onPressed: () {
              Share.shareXFiles([XFile(widget.file.path)], text: 'Check out this live gig recording!');
            },
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
