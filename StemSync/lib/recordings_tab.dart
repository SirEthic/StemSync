import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:share_plus/share_plus.dart';

class RecordingsTab extends StatefulWidget {
  const RecordingsTab({super.key});

  @override
  State<RecordingsTab> createState() => _RecordingsTabState();
}

class _RecordingsTabState extends State<RecordingsTab> {
  List<File> _recordings = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadRecordings();
  }

  Future<void> _loadRecordings() async {
    final docDir = await getApplicationDocumentsDirectory();
    final recDir = Directory('${docDir.path}/Recordings');
    if (recDir.existsSync()) {
      setState(() {
        _recordings = recDir.listSync().whereType<File>().where((f) => f.path.endsWith('.wav')).toList();
        _recordings.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_recordings.isEmpty) {
      return const Center(child: Text("No live gigs recorded yet.\nConnect your mixer and hit Record!", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)));
    }

    return ListView.builder(
      itemCount: _recordings.length,
      itemBuilder: (context, index) {
        final file = _recordings[index];
        final name = file.path.split(Platform.pathSeparator).last.replaceAll('.wav', '');
        final size = (file.lengthSync() / (1024 * 1024)).toStringAsFixed(1);
        
        return ListTile(
          leading: const CircleAvatar(backgroundColor: Colors.redAccent, child: Icon(Icons.mic, color: Colors.white)),
          title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('$size MB  •  ${file.lastModifiedSync().toString().split('.')[0]}', style: const TextStyle(color: Colors.grey)),
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
                  _loadRecordings();
                },
              ),
            ],
          ),
        );
      },
    );
  }
}
