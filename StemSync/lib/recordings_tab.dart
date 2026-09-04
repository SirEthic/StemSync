import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:share_plus/share_plus.dart';

class RecordingsTab extends StatefulWidget {
  const RecordingsTab({super.key});

  @override
  State<RecordingsTab> createState() => RecordingsTabState();
}

class RecordingsTabState extends State<RecordingsTab> {
  List<File> _recordings = [];
  bool _loading = true;
  String _debugPath = "";

  @override
  void initState() {
    super.initState();
    loadRecordings();
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
                
                return ListTile(
                  leading: const CircleAvatar(backgroundColor: Colors.redAccent, child: Icon(Icons.mic, color: Colors.white)),
                  title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text('$size MB  •  $dateStr', style: const TextStyle(color: Colors.grey)),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.share, color: Colors.tealAccent),
                        onPressed: () {
                          Share.shareXFiles([XFile(file.path)], text: 'Check out this live gig recording!');
                        },
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent),
                        onPressed: () async {
                          await file.delete();
                          loadRecordings();
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
