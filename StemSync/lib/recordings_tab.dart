import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

class RecordingsTab extends StatefulWidget {
  const RecordingsTab({super.key});

  @override
  State<RecordingsTab> createState() => RecordingsTabState();
}

class RecordingsTabState extends State<RecordingsTab> {
  List<File> _recordings = [];
  bool _loading = true;
  String _debugPath = "";
  
  SoundHandle? _playingHandle;
  AudioSource? _playingSource;
  File? _playingFile;

  @override
  void initState() {
    super.initState();
    loadRecordings();
  }


  @override
  void dispose() {
    if (_playingHandle != null) SoLoud.instance.stop(_playingHandle!);
    if (_playingSource != null) SoLoud.instance.disposeSource(_playingSource!);
    super.dispose();
  }

  Future<void> loadRecordings() async {
    setState(() => _loading = true);
    final docDir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${docDir.path}/Recordings');
    
    if (recDir.existsSync()) {
      _debugPath = recDir.path;
      final allEntities = recDir.listSync();
      setState(() {
        _recordings = allEntities.whereType<File>().where((f) => f.path.toLowerCase().endsWith('.wav')).toList();
        _recordings.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        _loading = false;
      });
    } else {
      _debugPath = "${docDir.path}/Recordings (Does not exist)";
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    
    if (_recordings.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.mic_off, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text("No live gigs recorded yet.", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text("Checked: $_debugPath", textAlign: TextAlign.center, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: loadRecordings,
              icon: const Icon(Icons.refresh),
              label: const Text("Force Refresh"),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.teal),
            )
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: loadRecordings,
      color: Colors.tealAccent,
      backgroundColor: const Color(0xFF1A1A1A),
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 100), // padding for FAB
          child: Column(
            children: _recordings.map((file) {
              try {
                final name = file.path.split(Platform.pathSeparator).last.replaceAll(RegExp(r'\.wav$', caseSensitive: false), '');
                final size = (file.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
                final dateStr = file.lastModifiedSync().toString().split('.')[0];
                
                final isPlaying = _playingFile == file;
                return ListTile(
                  leading: CircleAvatar(backgroundColor: isPlaying ? Colors.teal : Colors.redAccent, child: Icon(isPlaying ? Icons.multitrack_audio : Icons.mic, color: Colors.white)),
                  title: Text(name, style: TextStyle(fontWeight: FontWeight.bold, color: isPlaying ? Colors.tealAccent : Colors.white)),
                  subtitle: Text('$size MB  •  $dateStr', style: const TextStyle(color: Colors.grey)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(isPlaying ? Icons.stop_circle : Icons.play_circle_fill, color: Colors.tealAccent, size: 28),
                        onPressed: () async {
                          if (isPlaying) {
                            if (_playingHandle != null) SoLoud.instance.stop(_playingHandle!);
                            if (_playingSource != null) SoLoud.instance.disposeSource(_playingSource!);
                            setState(() {
                              _playingHandle = null;
                              _playingSource = null;
                              _playingFile = null;
                            });
                          } else {
                            if (_playingHandle != null) SoLoud.instance.stop(_playingHandle!);
                            if (_playingSource != null) SoLoud.instance.disposeSource(_playingSource!);
                            
                            final source = await SoLoud.instance.loadFile(file.path);
                            final handle = SoLoud.instance.play(source);
                            setState(() {
                              _playingSource = source;
                              _playingHandle = handle;
                              _playingFile = file;
                            });
                          }
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.share, color: Colors.white70),
                        onPressed: () {
                          Share.shareXFiles([XFile(file.path)], text: 'Check out this live gig recording!');
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent),
                        onPressed: () async {
                          bool confirm = await showDialog(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              backgroundColor: const Color(0xFF1A1A1A),
                              title: const Text("Delete Recording?", style: TextStyle(color: Colors.white)),
                              content: Text("Are you sure you want to permanently delete:\n\n$name?", style: const TextStyle(color: Colors.white70)),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel", style: TextStyle(color: Colors.tealAccent))),
                                TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Delete", style: TextStyle(color: Colors.redAccent))),
                              ],
                            ),
                          ) ?? false;
                          
                          if (confirm) {
                            if (isPlaying && _playingHandle != null) {
                              SoLoud.instance.stop(_playingHandle!);
                            }
                            await file.delete();
                            loadRecordings();
                          }
                        },
                      ),
                    ],
                  ),
                );
              } catch (e) {
                return ListTile(
                  title: const Text("Error loading file", style: TextStyle(color: Colors.red)),
                  subtitle: Text(e.toString(), style: const TextStyle(color: Colors.redAccent)),
                );
              }
            }).toList(),
          ),
        ),
      ),
    );
  }
}
