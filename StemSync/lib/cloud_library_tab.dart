import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

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
  
  // Use API key from local .env file to protect it from GitHub
  String get _apiKey => dotenv.env['GOOGLE_DRIVE_API_KEY'] ?? '';

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

  Future<void> _promptForFolderLink() async {
    final controller = TextEditingController();
    
    // Auto-check clipboard for a Google Drive link
    try {
      final clipboardData = await Clipboard.getData('text/plain');
      final text = clipboardData?.text ?? '';
      if (text.contains('drive.google.com/drive/folders/')) {
        controller.text = text;
      }
    } catch (_) {}

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Connect Google Drive', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            hintText: "Paste Google Drive Folder Link",
            hintStyle: const TextStyle(color: Colors.white54),
            suffixIcon: IconButton(
              icon: const Icon(Icons.content_paste, color: Colors.tealAccent),
              onPressed: () async {
                final clipboardData = await Clipboard.getData('text/plain');
                if (clipboardData != null && clipboardData.text != null) {
                  controller.text = clipboardData.text!;
                }
              },
            ),
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to fetch songs from Google Drive. Check link or API Key.'))
          );
        }
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
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to download song.'))
          );
        }
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
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.1),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.cloud_sync_rounded, size: 80, color: Colors.tealAccent),
              ),
              const SizedBox(height: 32),
              const Text(
                "Connect Band Drive",
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              const Text(
                "Paste a public Google Drive folder link to instantly access your band's stems and zip files anywhere.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 16, height: 1.4),
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton.icon(
                  onPressed: _promptForFolderLink,
                  icon: const Icon(Icons.link, size: 24),
                  label: const Text("Paste Drive Link", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    elevation: 8,
                    shadowColor: Colors.teal.withValues(alpha: 0.5),
                  ),
                ),
              )
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Container(
          margin: const EdgeInsets.all(16.0),
          padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.teal.withValues(alpha: 0.3), width: 1),
          ),
          child: Row(
            children: [
              const Icon(Icons.cloud_done, color: Colors.tealAccent, size: 28),
              const SizedBox(width: 16),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Connected to Drive", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    Text("Auto-syncing .zip files", style: TextStyle(color: Colors.white54, fontSize: 12)),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.refresh, color: Colors.white70),
                tooltip: "Refresh List",
                onPressed: _fetchCloudSongs,
              ),
              IconButton(
                icon: const Icon(Icons.edit, color: Colors.white70),
                tooltip: "Change Folder",
                onPressed: _promptForFolderLink,
              ),
            ],
          ),
        ),
        Expanded(
          child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.tealAccent))
            : _cloudSongs.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_open, size: 48, color: Colors.white24),
                      SizedBox(height: 16),
                      Text("No .zip files found in this folder.", style: TextStyle(color: Colors.white54)),
                    ],
                  )
                )
              : ListView.builder(
                  itemCount: _cloudSongs.length,
                  itemBuilder: (context, index) {
                    final song = _cloudSongs[index];
                    final String name = song['name'].toString().replaceAll('.zip', '');
                    final String id = song['id'];
                    final bool isDownloading = _downloadingIds.contains(id);

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                      leading: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: isDownloading ? Colors.teal.withValues(alpha: 0.2) : const Color(0xFF1A1A1A),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: isDownloading ? Colors.teal : Colors.white12),
                        ),
                        child: Icon(
                          isDownloading ? Icons.cloud_download : Icons.cloud_outlined, 
                          color: isDownloading ? Colors.tealAccent : Colors.white70
                        ),
                      ),
                      title: Text(name, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: isDownloading ? Colors.tealAccent : Colors.white)),
                      subtitle: Text(isDownloading ? "Downloading..." : "Tap to download", style: TextStyle(color: isDownloading ? Colors.tealAccent.withValues(alpha: 0.7) : Colors.grey)),
                      trailing: isDownloading
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(color: Colors.tealAccent, strokeWidth: 2),
                            )
                          : const Icon(Icons.download_rounded, color: Colors.tealAccent),
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
