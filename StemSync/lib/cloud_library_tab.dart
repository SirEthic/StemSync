import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'proxy_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class CloudLibraryTab extends StatefulWidget {
  final Set<String> downloadedFolderNames;
  final Function(File) onDownloadComplete;
  final Function(Map<String, List<String>>) onSetlistsSynced;

  const CloudLibraryTab({
    Key? key,
    required this.downloadedFolderNames,
    required this.onDownloadComplete,
    required this.onSetlistsSynced,
  }) : super(key: key);

  @override
  State<CloudLibraryTab> createState() => CloudLibraryTabState();
}

class CloudLibraryTabState extends State<CloudLibraryTab> {
  String _folderId = '';
  List<dynamic> _cloudSongs = [];
  bool _isLoading = false;
  final Set<String> _downloadingIds = {};
  final Map<String, String> _downloadProgressMap = {};
  final Map<String, double> _downloadRatioMap = {};
  final Map<String, http.Client> _activeClients = {};
  final Map<String, bool> _pausedDownloads = {};
  final Map<String, bool> _cancelledDownloads = {};
  
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
      // Intentionally do not auto-fetch to prevent excessive API calls.
      // User must manually pull-to-refresh.
    }
  }

  Future<void> _saveFolderId(String id) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('drive_folder_id', id);
    setState(() {
      _folderId = id;
    });
    fetchCloudSongs();
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: Colors.teal.withValues(alpha: 0.15), shape: BoxShape.circle),
              child: const Icon(Icons.add_link_rounded, color: Colors.tealAccent, size: 28),
            ),
            const SizedBox(width: 16),
            const Expanded(child: Text('Connect Drive', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 22))),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Paste the link to your band's public Google Drive folder containing the .zip stems.",
              style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: controller,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: "https://drive.google.com/...",
                hintStyle: const TextStyle(color: Colors.white38),
                filled: true,
                fillColor: Colors.black45,
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: const BorderSide(color: Colors.tealAccent, width: 1.5),
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.content_paste_rounded, color: Colors.tealAccent),
                  tooltip: "Paste from clipboard",
                  onPressed: () async {
                    final clipboardData = await Clipboard.getData('text/plain');
                    if (clipboardData != null && clipboardData.text != null) {
                      controller.text = clipboardData.text!;
                    }
                  },
                ),
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.only(right: 24, bottom: 24, left: 24, top: 8),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
            ),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey, fontSize: 16, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            onPressed: () {
              final id = _extractFolderId(controller.text);
              if (id.isNotEmpty) {
                _saveFolderId(id);
              }
              Navigator.pop(ctx);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              elevation: 4,
            ),
            child: const Text('Connect Folder', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ),
        ],
      ),
    );
  }

  Future<void> fetchCloudSongs() async {
    if (_folderId.isEmpty) return;
    setState(() { _isLoading = true; });

    try {
      final url = Uri.parse("https://www.googleapis.com/drive/v3/files?q='$_folderId'+in+parents+and+name+contains+'.zip'&fields=files(id,name,size)&key=$_apiKey");
      final client = await ProxyClient.createClient(url.toString()); final response = await client.get(url); client.close();

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final docDir = await getApplicationDocumentsDirectory();
        
        setState(() {
          _cloudSongs = data['files'] ?? [];
          for (var file in _cloudSongs) {
            final rawName = file['name'];
            final tempZip = File('${docDir.path}/$rawName');
            if (tempZip.existsSync()) {
              final size = tempZip.lengthSync();
              final total = int.tryParse(file['size']?.toString() ?? '0') ?? 0;
              if (size > 0) {
                if (total > 0 && size >= total) {
                  _downloadProgressMap[file['id']] = "Downloaded (Tap to extract)";
                  _downloadRatioMap[file['id']] = 1.0;
                } else {
                  _downloadProgressMap[file['id']] = total > 0 
                      ? "Paused at ${_formatBytes(size)} / ${_formatBytes(total)}"
                      : "Paused at ${_formatBytes(size)}";
                  if (total > 0) {
                    _downloadRatioMap[file['id']] = size / total;
                  }
                }
              }
            }
          }
        });

        // 🚀 COLLABORATIVE SETLISTS SYNC
        try {
          final setlistsUrl = Uri.parse("https://www.googleapis.com/drive/v3/files?q='$_folderId'+in+parents+and+name='setlists.json'&fields=files(id)&key=$_apiKey");
          final client = await ProxyClient.createClient(setlistsUrl.toString()); final setlistsRes = await client.get(setlistsUrl); client.close();
          if (setlistsRes.statusCode == 200) {
            final setlistData = json.decode(setlistsRes.body);
            final setlistFiles = setlistData['files'] as List;
            if (setlistFiles.isNotEmpty) {
              final fileId = setlistFiles.first['id'];
              final dlUrl = Uri.parse("https://www.googleapis.com/drive/v3/files/$fileId?alt=media&key=$_apiKey");
              final client = await ProxyClient.createClient(dlUrl.toString()); final dlRes = await client.get(dlUrl); client.close();
              if (dlRes.statusCode == 200) {
                final Map<String, dynamic> rawMap = json.decode(dlRes.body);
                Map<String, List<String>> result = {};
                rawMap.forEach((key, value) {
                  if (value is List) {
                    result[key] = value.map((e) => e.toString()).toList();
                  }
                });
                widget.onSetlistsSynced(result);
              }
            }
          }
        } catch (e) {
          debugPrint("Exception syncing setlists: $e");
        }
        
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

  void startDownloadByName(String songName) {
    if (_cloudSongs.isEmpty) {
      fetchCloudSongs().then((_) {
        _triggerDownloadByName(songName);
      });
    } else {
      _triggerDownloadByName(songName);
    }
  }

  void _triggerDownloadByName(String songName) {
    try {
      final file = _cloudSongs.firstWhere((f) {
        String name = f['name'].toString();
        if (name.toLowerCase().endsWith('.zip')) name = name.substring(0, name.length - 4);
        return name == songName;
      });
      final fileId = file['id'];
      final rawName = file['name'];
      _downloadSong(fileId, rawName);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Started downloading '$songName' from Cloud!")));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Could not find '$songName' in Cloud.")));
    }
  }

  String _formatBytes(int bytes) {
    final double mb = bytes / (1024 * 1024);
    return "${mb.toStringAsFixed(1)} MB";
  }

  void _pauseDownload(String fileId) {
    if (_downloadingIds.contains(fileId)) {
      _pausedDownloads[fileId] = true;
    }
  }

  void _confirmCancelDownload(String fileId, String fileName, String songName) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Cancel Download', style: TextStyle(color: Colors.white)),
        content: Text('Are you sure you want to cancel downloading $songName? All progress will be lost.', style: const TextStyle(color: Colors.grey, fontSize: 12)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Keep', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _cancelDownload(fileId, fileName);
            },
            child: const Text('Cancel', style: TextStyle(color: Colors.redAccent)),
          )
        ],
      ),
    );
  }

  Future<void> _cancelDownload(String fileId, String fileName) async {
    if (_downloadingIds.contains(fileId)) {
      _cancelledDownloads[fileId] = true;
    } else {
      setState(() {
        _downloadProgressMap.remove(fileId);
        _downloadRatioMap.remove(fileId);
      });
      final docDir = await getApplicationDocumentsDirectory();
      final tempZip = File('${docDir.path}/$fileName');
      if (tempZip.existsSync()) {
        try { tempZip.deleteSync(); } catch (_) {}
      }
    }
  }

  Future<void> _downloadSong(String fileId, String fileName) async {
    _pausedDownloads[fileId] = false;
    _cancelledDownloads[fileId] = false;
    setState(() { 
      _downloadingIds.add(fileId); 
      // Do not reset _downloadRatioMap so the progress bar doesn't reset to 0
      if (!_downloadProgressMap.containsKey(fileId) || _downloadProgressMap[fileId]!.startsWith('Paused')) {
        _downloadProgressMap[fileId] = "Connecting...";
      }
    });
    
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final tempZip = File('${docDir.path}/$fileName');
      int existingBytes = 0;
      if (tempZip.existsSync()) {
        existingBytes = tempZip.lengthSync();
      }

      final url = Uri.parse("https://www.googleapis.com/drive/v3/files/$fileId?alt=media&key=$_apiKey");
      final request = http.Request('GET', url);
      
      if (existingBytes > 0) {
        request.headers['Range'] = 'bytes=$existingBytes-';
      }

      final client = await ProxyClient.createClient(url.toString());
      _activeClients[fileId] = client;
      final response = await client.send(request);

      if (response.statusCode == 200 || response.statusCode == 206) {
        int totalBytes = 0;
        int receivedBytes = 0;

        if (response.statusCode == 206) {
          // Resuming partial content
          final contentRange = response.headers['content-range'];
          if (contentRange != null && contentRange.contains('/')) {
            totalBytes = int.tryParse(contentRange.split('/').last) ?? 0;
          }
          receivedBytes = existingBytes;
        } else {
          // Fresh start or server ignored range
          totalBytes = response.contentLength ?? 0;
          receivedBytes = 0;
          existingBytes = 0; 
        }

        int lastUpdatedBytes = receivedBytes;
        final sink = tempZip.openWrite(mode: existingBytes > 0 && response.statusCode == 206 ? FileMode.append : FileMode.write);
        
        await for (final chunk in response.stream) {
          if (_pausedDownloads[fileId] == true || _cancelledDownloads[fileId] == true) {
            break; // Break the stream to pause or cancel
          }
          receivedBytes += chunk.length;
          sink.add(chunk);
          
          if (receivedBytes - lastUpdatedBytes > 500 * 1024 || receivedBytes == totalBytes) {
            lastUpdatedBytes = receivedBytes;
            if (totalBytes > 0) {
              final String progStr = "${_formatBytes(receivedBytes)} / ${_formatBytes(totalBytes)}";
              if (mounted) {
                setState(() {
                  _downloadProgressMap[fileId] = progStr;
                  _downloadRatioMap[fileId] = receivedBytes / totalBytes;
                });
              }
            } else if (mounted) {
              setState(() {
                _downloadProgressMap[fileId] = "${_formatBytes(receivedBytes)} downloaded";
              });
            }
          }
        }
        
        await sink.close();
        client.close();
        _activeClients.remove(fileId);

        if (_cancelledDownloads[fileId] == true) {
          _cancelledDownloads.remove(fileId);
          if (tempZip.existsSync()) {
            try { tempZip.deleteSync(); } catch (_) {}
          }
          if (mounted) {
            setState(() {
              _downloadingIds.remove(fileId);
              _downloadProgressMap.remove(fileId);
              _downloadRatioMap.remove(fileId);
            });
          }
          return;
        }

        if (_pausedDownloads[fileId] == true) {
          if (mounted) {
            setState(() {
              _downloadingIds.remove(fileId);
              _downloadProgressMap[fileId] = totalBytes > 0 
                  ? "Paused at ${_formatBytes(receivedBytes)} / ${_formatBytes(totalBytes)}"
                  : "Paused at ${_formatBytes(receivedBytes)}";
            });
          }
          return;
        }
        // Pass it back to main.dart to unzip and add to local library
        if (mounted) {
          setState(() {
            _downloadingIds.remove(fileId);
            _downloadProgressMap.remove(fileId);
            _downloadRatioMap.remove(fileId);
          });
        }
        widget.onDownloadComplete(tempZip);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to download song.'))
          );
          setState(() {
            _downloadingIds.remove(fileId);
            _downloadProgressMap.remove(fileId);
            _downloadRatioMap.remove(fileId);
          });
        }
      }
    } catch (e) {
      debugPrint("Exception downloading file: $e");
      if (mounted) {
        setState(() { 
          _downloadingIds.remove(fileId); 
          _downloadProgressMap.remove(fileId);
          _downloadRatioMap.remove(fileId);
        });
      }
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
            : RefreshIndicator(
                color: Colors.tealAccent,
                backgroundColor: const Color(0xFF1A1A1A),
                onRefresh: fetchCloudSongs,
                child: _cloudSongs.isEmpty
                  ? ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        SizedBox(height: MediaQuery.of(context).size.height * 0.25),
                        const Icon(Icons.folder_open, size: 48, color: Colors.white24),
                        const SizedBox(height: 16),
                        const Center(child: Text("No .zip files found in this folder.", style: TextStyle(color: Colors.white54))),
                      ],
                    )
                  : ListView.builder(
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: _cloudSongs.length,
                      itemBuilder: (context, index) {
                        final song = _cloudSongs[index];
                        final String rawName = song['name'].toString();
                        final String name = rawName.replaceAll('.zip', '');
                        final String folderName = name.replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
                        final String id = song['id'];
                        final bool isDownloading = _downloadingIds.contains(id);
                        final bool isAlreadyDownloaded = widget.downloadedFolderNames.contains(folderName);
                        final bool isPaused = !isDownloading && _downloadProgressMap.containsKey(id);
                        final double ratio = _downloadRatioMap[id] ?? 0.0;
                        
                        String subText = "Tap to download";
                        if (isDownloading) {
                          subText = _downloadProgressMap[id] ?? "Downloading...";
                        } else if (isPaused) {
                          subText = _downloadProgressMap[id] ?? "Paused";
                        } else if (isAlreadyDownloaded) {
                          subText = "Downloaded (Tap to update)";
                        }

                        Color iconColor = Colors.white70;
                        if (isDownloading) iconColor = Colors.tealAccent;
                        else if (isPaused) iconColor = Colors.white54;
                        else if (isAlreadyDownloaded) iconColor = Colors.greenAccent;

                        IconData leadIcon = Icons.cloud_outlined;
                        if (isDownloading) leadIcon = Icons.cloud_download;
                        else if (isPaused) leadIcon = Icons.pause_circle_outline;
                        else if (isAlreadyDownloaded) leadIcon = Icons.cloud_done;

                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                          leading: Container(
                            width: 50,
                            height: 50,
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A1A1A),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: isDownloading ? Colors.teal : (isPaused ? Colors.white24 : Colors.white12)),
                            ),
                            clipBehavior: Clip.hardEdge,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                if (isDownloading || isPaused)
                                  Positioned(
                                    bottom: 0,
                                    left: 0,
                                    right: 0,
                                    child: AnimatedContainer(
                                      duration: const Duration(milliseconds: 300),
                                      height: 50 * ratio,
                                      color: isPaused ? Colors.white.withValues(alpha: 0.1) : Colors.teal.withValues(alpha: 0.3),
                                    ),
                                  ),
                                Icon(leadIcon, color: iconColor),
                              ],
                            ),
                          ),
                          title: Text(name, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: isDownloading ? Colors.tealAccent : (isPaused ? Colors.white70 : Colors.white))),
                          subtitle: Text(
                            subText, 
                            style: TextStyle(color: isDownloading ? Colors.tealAccent.withValues(alpha: 0.7) : (isPaused ? Colors.white54 : (isAlreadyDownloaded ? Colors.greenAccent.withValues(alpha: 0.7) : Colors.grey)))
                          ),
                          trailing: isDownloading || isPaused
                              ? GestureDetector(
                                  onTap: () => _confirmCancelDownload(id, rawName, name),
                                  behavior: HitTestBehavior.opaque,
                                  child: const Padding(
                                    padding: EdgeInsets.only(left: 16.0, top: 8.0, bottom: 8.0),
                                    child: Icon(Icons.close, color: Colors.white30),
                                  ),
                                )
                              : (isAlreadyDownloaded 
                                  ? const Icon(Icons.check_circle, color: Colors.greenAccent)
                                  : const Icon(Icons.download_rounded, color: Colors.tealAccent)),
                          onTap: () {
                            if (isDownloading) {
                              _pauseDownload(id);
                            } else if (isPaused) {
                              _downloadSong(id, rawName);
                            } else {
                              if (isAlreadyDownloaded) {
                                showDialog(
                                  context: context,
                                  builder: (ctx) => AlertDialog(
                                    backgroundColor: const Color(0xFF1A1A1A),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                                    title: const Text('Update Song?', style: TextStyle(color: Colors.white)),
                                    content: const Text('This song is already downloaded. Do you want to download it again to grab the latest changes?', style: TextStyle(color: Colors.white70)),
                                    actions: [
                                      TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
                                      ElevatedButton(
                                        onPressed: () {
                                          Navigator.pop(ctx);
                                          _downloadSong(id, rawName);
                                        },
                                        style: ElevatedButton.styleFrom(backgroundColor: Colors.teal, foregroundColor: Colors.white),
                                        child: const Text('Update'),
                                      )
                                    ],
                                  )
                                );
                              } else {
                                _downloadSong(id, rawName);
                              }
                            }
                          },
                        );
                      },
                    ),
              ),
        ),
      ],
    );
  }
}
