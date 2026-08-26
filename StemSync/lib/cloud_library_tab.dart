import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

class CloudLibraryTab extends StatefulWidget {
  final Function(File) onDownloadComplete;
  
  const CloudLibraryTab({super.key, required this.onDownloadComplete});

  @override
  State<CloudLibraryTab> createState() => _CloudLibraryTabState();
}

class _CloudLibraryTabState extends State<CloudLibraryTab> {
  String _folderId = '';
  List<dynamic> _cloudSongs = [];
  bool _isLoading = false;
  final Set<String> _downloadingIds = {};
  
  // You will need to replace this with your actual Google Cloud API Key
  final String _apiKey = 'YOUR_GOOGLE_DRIVE_API_KEY';

  @override
  void initState() {
    super.initState();
    _loadFolderId();
  }

  Future<void> _loadFolderId() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _folderId = prefs.getString('drive_folder_id') ?? '';
    });
    if (_folderId.isNotEmpty) {
      _fetchCloudSongs();
    }
  }

  Future<void> _saveFolderId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('drive_folder_id', id);
    setState(() {
      _folderId = id;
    });
    _fetchCloudSongs();
  }

  String _extractFolderId(String url) {
    // Basic regex to find Google Drive folder ID in a URL
    final regExp = RegExp(r'folders/([a-zA-Z0-9_-]+)');
    final match = regExp.firstMatch(url);
    if (match != null && match.groupCount >= 1) {
      return match.group(1)!;
    }
    return url; // Assume they just pasted the ID directly
  }

  void _promptForFolderLink() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Connect Google Drive', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: "Paste Google Drive Folder Link",
            hintStyle: TextStyle(color: Colors.white54),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              final id = _extractFolderId(controller.text);
              if (id.isNotEmpty) {
                _saveFolderId(id);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Connect', style: TextStyle(color: Colors.tealAccent)),
          ),
        ],
      ),
    );
  }

  Future<void> _fetchCloudSongs() async {
    if (_folderId.isEmpty) return;
    setState(() { _isLoading = true; });

    try {
      final url = Uri.parse("https://www.googleapis.com/drive/v3/files?q='$_folderId'+in+parents+and+mimeType='application/zip'&fields=files(id,name,size)&key=$_apiKey");
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _cloudSongs = data['files'] ?? [];
        });
      } else {
        debugPrint("Error fetching Drive files: ${response.body}");
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to fetch songs from Google Drive. Check link or API Key.'))
        );
      }
    } catch (e) {
      debugPrint("Exception fetching Drive files: $e");
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  Future<void> _downloadSong(String fileId, String fileName) async {
    setState(() { _downloadingIds.add(fileId); });
    try {
      final url = Uri.parse("https://www.googleapis.com/drive/v3/files/$fileId?alt=media&key=$_apiKey");
      final response = await http.get(url);

      if (response.statusCode == 200) {
        final docDir = await getApplicationDocumentsDirectory();
        final tempZip = File('${docDir.path}/$fileName');
        await tempZip.writeAsBytes(response.bodyBytes);
        
        // Pass it back to main.dart to unzip and add to local library
        widget.onDownloadComplete(tempZip);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to download song.'))
        );
      }
    } catch (e) {
      debugPrint("Exception downloading file: $e");
    } finally {
      setState(() { _downloadingIds.remove(fileId); });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_folderId.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_download_outlined, size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            const Text(
              "No Cloud Folder Connected",
              style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            const Text(
              "Paste a public Google Drive folder link\nto access your band's songs anywhere.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _promptForFolderLink,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.teal,
                foregroundColor: Colors.white,
              ),
              child: const Text("Connect Drive Folder"),
            )
          ],
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text("Cloud Library", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.refresh, color: Colors.tealAccent),
                    onPressed: _fetchCloudSongs,
                  ),
                  IconButton(
                    icon: const Icon(Icons.link, color: Colors.grey),
                    onPressed: _promptForFolderLink,
                  ),
                ],
              )
            ],
          ),
        ),
        Expanded(
          child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.tealAccent))
            : _cloudSongs.isEmpty
              ? const Center(child: Text("No .zip files found in this folder.", style: TextStyle(color: Colors.grey)))
              : ListView.builder(
                  itemCount: _cloudSongs.length,
                  itemBuilder: (context, index) {
                    final song = _cloudSongs[index];
                    final String name = song['name'].toString().replaceAll('.zip', '');
                    final String id = song['id'];
                    final bool isDownloading = _downloadingIds.contains(id);

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      leading: const CircleAvatar(
                        backgroundColor: Colors.teal,
                        child: Icon(Icons.cloud, color: Colors.white),
                      ),
                      title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                      subtitle: const Text("Tap to download", style: TextStyle(color: Colors.grey)),
                      trailing: isDownloading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(color: Colors.tealAccent, strokeWidth: 2),
                            )
                          : IconButton(
                              icon: const Icon(Icons.download, color: Colors.tealAccent),
                              onPressed: () => _downloadSong(id, song['name']),
                            ),
                      onTap: () {
                        if (!isDownloading) _downloadSong(id, song['name']);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}
