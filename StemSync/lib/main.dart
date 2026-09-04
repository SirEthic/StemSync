import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'proxy_client.dart';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/scheduler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';
import 'package:archive/archive_io.dart';
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'chord_sheet_generator.dart';
import 'cloud_library_tab.dart';
import 'recordings_tab.dart';

Future<void> _extractZipInIsolate(Map<String, String> args) async {
  final targetPath = args['targetPath']!;
  final inputStream = InputFileStream(args['zipPath']!);
  final archive = ZipDecoder().decodeStream(inputStream);
  
  for (final archiveFile in archive) {
    if (archiveFile.isFile) {
      final outputStream = OutputFileStream('$targetPath/${archiveFile.name}');
      archiveFile.writeContent(outputStream);
      outputStream.close();
    }
  }
  inputStream.close();
}

class LyricLine {
  final double time;
  final String text;
  LyricLine({required this.time, required this.text});
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await SoLoud.instance.init();
  WakelockPlus.enable();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const StemSyncApp());
}

class TrackData {
  String name;
  SoundHandle handle;
  AudioSource source;
  File file;
  double volume;
  bool isMuted;
  bool isSoloed;
  double pan;

  TrackData({
    required this.name, 
    required this.handle, 
    required this.source, 
    required this.file, 
    required this.volume,
    this.isMuted = false,
    this.isSoloed = false,
    this.pan = 0.0,
  });
}

class StemSyncApp extends StatelessWidget {
  const StemSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'StemSync',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        splashFactory: NoSplash.splashFactory,
        splashColor: Colors.transparent,
        highlightColor: Colors.white10,
        scaffoldBackgroundColor: const Color(0xFF000000),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF000000),
          elevation: 0,
          scrolledUnderElevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: Colors.tealAccent,
          inactiveTrackColor: Colors.grey[800],
          thumbColor: Colors.grey[400],
          overlayColor: Colors.tealAccent.withValues(alpha: 0.2),
          trackHeight: 4.0,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: Colors.grey[900],
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          contentTextStyle: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        ),
      ),
      home: const MixerScreen(),
    );
  }
}

class MixerScreen extends StatefulWidget {
  final String? stemsDir;
  const MixerScreen({super.key, this.stemsDir});

  @override
  State<MixerScreen> createState() => _MixerScreenState();
}

class _MixerScreenState extends State<MixerScreen> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  final GlobalKey<CloudLibraryTabState> _cloudTabKey = GlobalKey<CloudLibraryTabState>();
  bool _isLoading = false;
  bool _isGigMode = false;
  StreamSubscription<UserAccelerometerEvent>? _accelSubscription;
  DateTime _lastKnock = DateTime.now();
  DateTime? _lastBackPressTime;
  
  // USB Recording State
  final _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  String? _currentRecordingPath;
  Timer? _recordingTimer;
  int _recordingSeconds = 0;

  List<TrackData> _tracks = [];
  Map<double, TrackData> _metronomeTracks = {};
  final Map<String, AudioSource> _audioSourceCache = {};
  Map<String, dynamic>? _songMetadata;
  Bus? _stemsBus;

  // Smart Metronome & Tempo State
  bool _isMetronomeOn = false;
  
  // View States
  bool _showChords = false;
  bool _showSections = false;
  bool _showLyrics = false;
  
  double _baseTempo = 120.0;
  double _currentTempo = 120.0;
  double _firstBeat = 0.0;
  double _metronomeVolume = 0.7;
  double _metronomePan = 0.0;
  double _playbackSpeed = 1.0;
  double _subdivision = 1.0;
  
  // Audio State
  double _songLength = 1.0;
  final ValueNotifier<double> _currentPositionNotifier = ValueNotifier(0.0);
  final ValueNotifier<int> _activeChordNotifier = ValueNotifier(-1);
  final ValueNotifier<int> _activeSectionNotifier = ValueNotifier(-1);
  final ValueNotifier<int> _activeLyricNotifier = ValueNotifier(-1);
  late Ticker _ticker;
  bool _isScrubbing = false;
  bool _isScrubbingChords = false;
  
  String _songKey = "Unknown";
  double _pitchShiftSemitones = 0.0;
  
  List<Map<String, dynamic>> _chords = [];
  List<Map<String, dynamic>> _sections = [];
  List<LyricLine> _lyrics = [];
  
  final ScrollController _chordScrollController = ScrollController();
  final ScrollController _lyricScrollController = ScrollController();
  final ScrollController _sectionScrollController = ScrollController();

  // Library State
  List<Map<String, dynamic>> _savedSongs = [];
  bool _isLibraryLoading = true;
  Directory? _activeSongDir; // Used for UI state (null = library view)
  Directory? _loadedSongDir; // Used to track what is currently loaded in memory
  
  String _searchQuery = "";
  String _sortMode = "Newest Added";
  final TextEditingController _searchController = TextEditingController();

  Map<String, List<String>> _playlists = {};
  String? _activePlaylist;
  int _libraryTabIndex = 0;

  Future<void> _loadPlaylists() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final file = File('${docDir.path}/playlists.json');
      if (file.existsSync()) {
        final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
        setState(() {
          _playlists = data.map((k, v) => MapEntry(k, List<String>.from(v)));
        });
      }
    } catch (e) {
      debugPrint("Error loading playlists: $e");
    }
  }

  Future<void> _savePlaylists() async {
    try {
      final docDir = await getApplicationDocumentsDirectory();
      final file = File('${docDir.path}/playlists.json');
      file.writeAsStringSync(jsonEncode(_playlists));
    } catch (e) {
      debugPrint("Error saving playlists: $e");
    }
  }
  
  void _showExportDialog() {
    if (_playlists.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No setlists to export.")));
      return;
    }

    final Map<String, bool> selected = {};
    for (var key in _playlists.keys) {
      selected[key] = true;
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateSB) {
            return AlertDialog(
              backgroundColor: Colors.grey[900],
              title: const Text("Export Setlists", style: TextStyle(color: Colors.white)),
              content: SizedBox(
                width: double.maxFinite,
                child: ListView(
                  shrinkWrap: true,
                  children: _playlists.keys.map((pName) {
                    return CheckboxListTile(
                      title: Text(pName, style: const TextStyle(color: Colors.white70)),
                      value: selected[pName],
                      activeColor: Colors.teal,
                      checkColor: Colors.white,
                      side: const BorderSide(color: Colors.grey),
                      onChanged: (val) {
                        setStateSB(() {
                          selected[pName] = val ?? false;
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
                ),
                TextButton(
                  onPressed: () async {
                    Navigator.pop(ctx);
                    final filteredPlaylists = Map<String, List<String>>.from(_playlists)
                      ..removeWhere((key, value) => !(selected[key] ?? false));
                    
                    if (filteredPlaylists.isEmpty) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No setlists selected.")));
                      return;
                    }

                    final String jsonStr = json.encode(filteredPlaylists);
                    final docDir = await getApplicationDocumentsDirectory();
                    final file = File('${docDir.path}/setlists.json');
                    await file.writeAsString(jsonStr);
                    
                    // ignore: deprecated_member_use
                    Share.shareXFiles(
                      // ignore: deprecated_member_use
                      [XFile(file.path)], 
                      text: 'Upload this to your band\'s Google Drive folder to instantly sync setlists!'
                    );
                  },
                  child: const Text("Export", style: TextStyle(color: Colors.tealAccent)),
                ),
              ],
            );
          },
        );
      },
    );
  }
  void _createPlaylist({String? autoAddDirName}) {
    TextEditingController ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("New Setlist"),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(hintText: "e.g., Friday Gig"),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
          TextButton(
            onPressed: () {
              if (ctrl.text.trim().isNotEmpty) {
                setState(() {
                  _playlists[ctrl.text.trim()] = [];
                  if (autoAddDirName != null) {
                    _playlists[ctrl.text.trim()]!.add(autoAddDirName);
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Added to ${ctrl.text.trim()}")));
                  }
                  _activePlaylist = ctrl.text.trim();
                });
                _savePlaylists();
              }
              Navigator.pop(context);
            },
            child: const Text("Create"),
          ),
        ],
      ),
    );
  }
  
  void _showSongDetails(Directory dir) {
    String title = dir.path.split(Platform.pathSeparator).last;
    String artist = "Unknown";
    String key = "Unknown";
    String bpm = "Unknown";
    String genre = "Unknown";
    String year = "Unknown";
    
    final metaFile = File('${dir.path}/song_metadata.json');
    if (metaFile.existsSync()) {
      try {
        final meta = jsonDecode(metaFile.readAsStringSync());
        title = meta['song_name'] ?? title;
        artist = meta['artist'] ?? artist;
        if (meta['key'] != null) key = meta['key'].toString();
        if (meta['tempo_bpm'] != null) bpm = (meta['tempo_bpm'] as num).toStringAsFixed(2);
        if (meta['genre'] != null) genre = meta['genre'].toString();
        if (meta['release_year'] != null) year = meta['release_year'].toString();
      } catch (e) {}
    }
    
    int stemCount = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.mp3') || f.path.endsWith('.wav')).length;
    final coverFile = File('${dir.path}/cover.jpg');
    
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        titlePadding: const EdgeInsets.only(top: 32, left: 24, right: 24, bottom: 16),
        contentPadding: const EdgeInsets.only(left: 24, right: 24, bottom: 24),
        title: Column(
          children: [
            coverFile.existsSync() 
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(16), 
                    child: Image.file(coverFile, width: 96, height: 96, fit: BoxFit.cover)
                  )
                : const Icon(Icons.album_outlined, size: 80, color: Colors.tealAccent),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: Colors.white)),
            const SizedBox(height: 4),
            Text(artist, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, color: Colors.grey)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(color: Colors.white24, height: 32),
            _buildDetailRow(Icons.music_note, "Key Signature", key),
            const SizedBox(height: 16),
            _buildDetailRow(Icons.speed, "Tempo (BPM)", bpm),
            const SizedBox(height: 16),
            _buildDetailRow(Icons.category, "Genre", genre),
            const SizedBox(height: 16),
            _buildDetailRow(Icons.calendar_today, "Release Year", year),
            const SizedBox(height: 16),
            _buildDetailRow(Icons.layers, "Available Stems", "$stemCount"),
          ],
        ),
        actionsPadding: const EdgeInsets.only(bottom: 16, right: 16),
        actions: [ 
          TextButton(
            onPressed: () => Navigator.pop(ctx), 
            child: const Text("Close", style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold, fontSize: 16))
          ) 
        ]
      )
    );
  }

  Widget _buildDetailRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 20),
        const SizedBox(width: 16),
        Expanded(child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 16))),
        Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
      ],
    );
  }

  void _showLibrarySongOptions(Directory dir, String dirName) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Wrap(
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 32, top: 24, bottom: 16),
                  child: Text("Song Options", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
              ),
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 24),
                  leading: const Icon(Icons.info_outline, color: Colors.white),
                title: const Text('View Song Details', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showSongDetails(dir);
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 24),
                  leading: const Icon(Icons.playlist_add, color: Colors.white),
                title: const Text('Add to Setlist', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _addToPlaylist(dirName);
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 24),
                  leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
                title: const Text('Delete Song', style: TextStyle(color: Colors.redAccent)),
                onTap: () {
                  Navigator.pop(ctx);
                  _deleteSong(dir);
                },
              ),
            ],
          ),
        );
      }
    );
  }

  void _addToPlaylist(String dirName) {
    String searchQuery = "";
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final filteredKeys = _playlists.keys.where((k) => k.toLowerCase().contains(searchQuery.toLowerCase())).toList();
          
          return AlertDialog(
            title: const Text("Add to Setlist"),
            contentPadding: const EdgeInsets.only(top: 16),
            content: SizedBox(
              width: double.maxFinite,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_playlists.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: TextField(
                        decoration: InputDecoration(
                          hintText: "Search setlists...",
                          prefixIcon: const Icon(Icons.search, color: Colors.grey),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                          filled: true,
                          fillColor: Colors.black26,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 0),
                        ),
                        onChanged: (val) {
                          setDialogState(() {
                            searchQuery = val;
                          });
                        },
                      ),
                    ),
                  if (_playlists.isNotEmpty)
                    const SizedBox(height: 16),
                  
                  if (_playlists.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                      child: Text(
                        "You don't have any setlists yet. Create one to organize your gig!",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white70),
                      ),
                    ),

                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      padding: const EdgeInsets.only(bottom: 16),
                      children: [
                        ...filteredKeys.map((pName) {
                          final bool isInPlaylist = _playlists[pName]!.contains(dirName);
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                            title: Text(pName, style: const TextStyle(fontSize: 16)),
                            trailing: Icon(
                              isInPlaylist ? Icons.remove_circle_outline : Icons.add_circle_outline, 
                              color: isInPlaylist ? Colors.redAccent : Colors.tealAccent
                            ),
                            onTap: () {
                              setState(() {
                                if (isInPlaylist) {
                                  _playlists[pName]!.remove(dirName);
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Removed from $pName")));
                                } else {
                                  _playlists[pName]!.add(dirName);
                                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Added to $pName")));
                                }
                                _savePlaylists();
                              });
                              Navigator.pop(context);
                            },
                          );
                        }),
                        if (_playlists.isEmpty || (searchQuery.isNotEmpty && filteredKeys.isEmpty))
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                            leading: const Icon(Icons.add_circle, color: Colors.tealAccent),
                            title: const Text("Create New Setlist", style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)),
                            onTap: () {
                              Navigator.pop(context);
                              _createPlaylist(autoAddDirName: dirName);
                            },
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        }
      ),
    );
  }

  final List<String> _chromaticScale = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

  // Count In State
  int _countInClicks = 0;
  Timer? _countInTimer;
  final Stopwatch _countInStopwatch = Stopwatch();
  int _currentCountInTick = 0;
  List<SoundHandle> _countInHandles = [];
  AudioSource? _beepSource;
  bool _isSongLooping = false;
  bool _autoAdvance = false;
  bool _simplifyChords = false;
  
  // Bouncing State
  bool _isBouncing = false;
  
  // Auto Save State
  Timer? _autoSaveTimer;
  Timer? _scrubGraceTimer;
  String _lastSavedState = "";
  
  
  

  StreamSubscription? _intentDataStreamSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    _accelSubscription = userAccelerometerEventStream(samplingPeriod: SensorInterval.fastestInterval).listen((UserAccelerometerEvent event) {
      if (!_isGigMode) return;
      double magnitude = event.x.abs() + event.y.abs() + event.z.abs();
      // 3.0 on userAccelerometer means a solid physical knock to the phone
      if (magnitude > 15.0 && DateTime.now().difference(_lastKnock).inMilliseconds > 1000) {
        _togglePlayPause();
        _lastKnock = DateTime.now();
      }
    });

    _initializeApp();
    _setupSharingIntent();
    
    _autoSaveTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
      _saveMixState();
    });
    
    _ticker = createTicker((elapsed) {
      if (_countInTimer != null && _countInTimer!.isActive) {
           double interval = 60.0 / _currentTempo;
           double elapsedSec = _countInStopwatch.elapsedMicroseconds / 1000000.0;
           int expectedTick = (elapsedSec / interval).floor();
           if (expectedTick > _currentCountInTick) {
               _currentCountInTick = expectedTick;
               // Beeps are already perfectly scheduled in C++, this just updates the visual countdown number
               setState(() {});
           }
           return; // Do not process normal playback time updates while counting in!
      }

      if (!_isScrubbing && !_isScrubbingChords && _tracks.isNotEmpty && !SoLoud.instance.getPause(_tracks.first.handle)) {
         final actualPos = SoLoud.instance.getPosition(_tracks.first.handle).inMilliseconds / 1000.0;
         
         double current = _currentPositionNotifier.value;
         double diff = actualPos - current;
         
         if (diff.abs() > 0.5) { 
             // Hard snap only on manual seeking jumps (> 500ms) or native wrap-around
             _currentPositionNotifier.value = actualPos;
             
             // Detect native wrap-around (song finished and looped back to start natively)
             if (diff < -5.0 && current > _songLength / 2) {
                 if (_isSongLooping) {
                     if (_countInClicks > 0) {
                         for (var t in _tracks) SoLoud.instance.setPause(t.handle, true);
                         for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, true);
                         
                         for (var t in _tracks) SoLoud.instance.seek(t.handle, Duration.zero);
                         for (var t in _metronomeTracks.values) SoLoud.instance.seek(t.handle, Duration.zero);
                         _currentPositionNotifier.value = 0.0;
                         _updateActiveChord(0.0);
                         _updateActiveSection(0.0);
                         _updateActiveLyric(0.0);
                         
                         _togglePlayPause(); // Triggers the count in!
                     }
                 } else {
                     for (var t in _tracks) SoLoud.instance.setPause(t.handle, true);
                     for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, true);
                     
                     for (var t in _tracks) SoLoud.instance.seek(t.handle, Duration.zero);
                     for (var t in _metronomeTracks.values) SoLoud.instance.seek(t.handle, Duration.zero);
                     _currentPositionNotifier.value = 0.0;
                     _updateActiveChord(0.0);
                     _updateActiveSection(0.0);
                     _updateActiveLyric(0.0);
                     
                     setState(() {});
                     
                     if (_autoAdvance) {
                         _playNextSong(autoPlay: true);
                     }
                 }
             }
         } else {
             // Exponential moving average: lerps 20% toward true audio clock per frame.
             // At 60fps, this flawlessly smooths out AAudio buffer chunking jitter.
             _currentPositionNotifier.value = current + (diff * 0.2);
         }
         
         final pos = _currentPositionNotifier.value;
         _updateActiveChord(pos);
         _updateActiveSection(pos);
         _updateActiveLyric(pos);
      }
    });
    _ticker.start();
  }

  Future<void> _initBeep() async {
    int sampleRate = 44100;
    int durationMs = 50;
    int numSamples = (sampleRate * durationMs) ~/ 1000;
    int byteRate = sampleRate * 2;
    
    var buffer = ByteData(44 + numSamples * 2);
    buffer.setUint8(0, 0x52); buffer.setUint8(1, 0x49); buffer.setUint8(2, 0x46); buffer.setUint8(3, 0x46); // RIFF
    buffer.setUint32(4, 36 + numSamples * 2, Endian.little);
    buffer.setUint8(8, 0x57); buffer.setUint8(9, 0x41); buffer.setUint8(10, 0x56); buffer.setUint8(11, 0x45); // WAVE
    buffer.setUint8(12, 0x66); buffer.setUint8(13, 0x6D); buffer.setUint8(14, 0x74); buffer.setUint8(15, 0x20); // fmt 
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little); // PCM
    buffer.setUint16(22, 1, Endian.little); // Mono
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, byteRate, Endian.little);
    buffer.setUint16(32, 2, Endian.little); // Block align
    buffer.setUint16(34, 16, Endian.little); // Bits per sample
    buffer.setUint8(36, 0x64); buffer.setUint8(37, 0x61); buffer.setUint8(38, 0x74); buffer.setUint8(39, 0x61); // data
    buffer.setUint32(40, numSamples * 2, Endian.little);
    
    for (int i = 0; i < numSamples; i++) {
      double t = i / sampleRate;
      
      // Smooth attack for the first 2ms to prevent starting pops
      double attack = 1.0;
      if (t < 0.002) {
          attack = t / 0.002;
      }
      
      // Exponential decay
      double env = exp(-t * 80.0);
      
      // Smooth release for the last 5ms to prevent ending clicks
      double release = 1.0;
      double remaining = (durationMs / 1000.0) - t;
      if (remaining < 0.005) {
          release = remaining / 0.005;
      }
      
      double sample = sin(2 * pi * 1000.0 * t) * env * attack * release;
      buffer.setInt16(44 + i * 2, (sample * 32767).toInt(), Endian.little);
    }
    
    final docDir = await getApplicationDocumentsDirectory();
    final beepFile = File('${docDir.path}/beep.wav');
    await beepFile.writeAsBytes(buffer.buffer.asUint8List());
    
    _beepSource = await SoLoud.instance.loadFile(beepFile.path);
  }

  Future<void> _toggleRecording() async {
    if (_isRecording) {
      final path = await _audioRecorder.stop();
      _recordingTimer?.cancel();
      setState(() {
        _isRecording = false;
        _recordingSeconds = 0;
      });
      if (path != null && mounted) {
        // Move from temp to recordings folder
        final docDir = await getApplicationDocumentsDirectory();
        final recDir = Directory('${docDir.path}/Recordings');
        if (!recDir.existsSync()) recDir.createSync();
        
        final safeName = _songMetadata != null ? (_songMetadata!['title'] ?? 'Live') : 'Live';
        final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-').split('.')[0];
        final finalFile = File('${recDir.path}/${safeName}_$timestamp.wav');
        
        await File(path).copy(finalFile.path);
        await File(path).delete();
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gig recorded and saved to Recordings!', style: TextStyle(color: Colors.white)), backgroundColor: Colors.teal),
        );
      }
    } else {
      if (await _audioRecorder.hasPermission()) {
        final tempDir = await getTemporaryDirectory();
        _currentRecordingPath = '${tempDir.path}/temp_record.wav';
        
        await _audioRecorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 44100,
            numChannels: 2,
            bitRate: 1411200,
          ),
          path: _currentRecordingPath!,
        );
        
        setState(() {
          _isRecording = true;
          _recordingSeconds = 0;
        });
        
        _recordingTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
          setState(() { _recordingSeconds++; });
        });
      }
    }
  }

  void _showMixerOptionsMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Wrap(
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 32, top: 24, bottom: 16),
                child: Text("Options", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
              ),
              if (_loadedSongDir != null) ...[

                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 32, right: 24),
                    leading: const Icon(Icons.stay_current_landscape, color: Colors.tealAccent),
                    title: const Text('Enter Gig Mode', style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold)),
                    onTap: () {
                      Navigator.pop(ctx);
                      _toggleGigMode();
                    },
                  ),

                ListTile(
                  contentPadding: const EdgeInsets.only(left: 32, right: 24),
                  leading: const Icon(Icons.info_outline, color: Colors.white),
                  title: const Text('Song Details', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _showSongDetails(_loadedSongDir!);
                  },
                ),
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 32, right: 24),
                  leading: const Icon(Icons.playlist_add, color: Colors.white),
                  title: const Text('Add to Setlist', style: TextStyle(color: Colors.white)),
                  onTap: () {
                    Navigator.pop(ctx);
                    _addToPlaylist(_loadedSongDir!.path.split(Platform.pathSeparator).last);
                  },
                ),
                const Divider(color: Colors.white12, indent: 32, endIndent: 24),
              ],
              StatefulBuilder(
                builder: (context, setModalState) {
                  return Column(
                    children: [
                      ListTile(
                        contentPadding: const EdgeInsets.only(left: 32, right: 24),
                        leading: const Icon(Icons.repeat_one, color: Colors.white),
                        title: const Text('Loop Song', style: TextStyle(color: Colors.white)),
                        trailing: Switch(
                          value: _isSongLooping,
                          activeColor: Colors.tealAccent,
                          onChanged: (val) {
                            setModalState(() { _isSongLooping = val; });
                            setState(() { _isSongLooping = val; });
                          },
                        ),
                        onTap: () {
                          bool val = !_isSongLooping;
                          setModalState(() { _isSongLooping = val; });
                          setState(() { _isSongLooping = val; });
                        },
                      ),
                      ListTile(
                        contentPadding: const EdgeInsets.only(left: 32, right: 24),
                        leading: const Icon(Icons.skip_next, color: Colors.white),
                        title: const Text('Auto-Advance to Next', style: TextStyle(color: Colors.white)),
                        trailing: Switch(
                          value: _autoAdvance,
                          activeColor: Colors.tealAccent,
                          onChanged: (val) {
                            setModalState(() { _autoAdvance = val; });
                            setState(() { _autoAdvance = val; });
                          },
                        ),
                        onTap: () {
                          bool val = !_autoAdvance;
                          setModalState(() { _autoAdvance = val; });
                          setState(() { _autoAdvance = val; });
                        },
                      ),
                      ListTile(
                        contentPadding: const EdgeInsets.only(left: 32, right: 24),
                        leading: Icon(Icons.auto_fix_high, color: _simplifyChords ? Colors.tealAccent : Colors.white),
                        title: const Text('Simplified Chords', style: TextStyle(color: Colors.white)),
                        subtitle: const Text('Strips 7ths and extensions', style: TextStyle(color: Colors.grey, fontSize: 12)),
                        trailing: Switch(
                          value: _simplifyChords,
                          activeColor: Colors.tealAccent,
                          onChanged: (val) {
                            setModalState(() { _simplifyChords = val; });
                            setState(() { _simplifyChords = val; });
                          },
                        ),
                        onTap: () {
                          bool val = !_simplifyChords;
                          setModalState(() { _simplifyChords = val; });
                          setState(() { _simplifyChords = val; });
                        },
                      ),
                    ],
                  );
                }
              ),
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 24),
                leading: Icon(Icons.onetwothree, color: _countInClicks > 0 ? Colors.tealAccent : Colors.white),
                title: const Text('Count In', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showCountInMenu();
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 24),
                leading: const Icon(Icons.ios_share, color: Colors.white),
                title: const Text('Export & Share', style: TextStyle(color: Colors.white)),
                onTap: () {
                  Navigator.pop(ctx);
                  _showExportMenu();
                },
              ),
              if (_chords.isNotEmpty)
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 24),
                leading: const Icon(Icons.library_music, color: Colors.white),
                title: const Text('Chord Sheet', style: TextStyle(color: Colors.white)),
                subtitle: const Text('Export a rhythm slash lead sheet as PDF', style: TextStyle(color: Colors.grey, fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportChordSheet();
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      }
    );
  }

  void _showExportMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) {
        return SafeArea(
          child: Wrap(
            children: [
              const Padding(
                padding: EdgeInsets.only(left: 32, top: 24, bottom: 16),
                  child: Text("Export / Share", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
              ),
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 24),
                  leading: const Icon(Icons.audio_file, color: Colors.white),
                title: const Text('Export Mixdown (Audio File)', style: TextStyle(color: Colors.white)),
                subtitle: const Text("Export the final mixed track to a single WAV file", style: TextStyle(color: Colors.grey, fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  _exportMix();
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 24),
                  leading: const Icon(Icons.tune, color: Colors.white),
                title: const Text('Share Modified Stems (ZIP)', style: TextStyle(color: Colors.white)),
                subtitle: const Text("Zip and share the stems with your pitch/tempo/volume changes", style: TextStyle(color: Colors.grey, fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareModifiedStems();
                },
              ),
              ListTile(
                contentPadding: const EdgeInsets.only(left: 32, right: 24),
                  leading: const Icon(Icons.folder_zip, color: Colors.white),
                title: const Text('Share Original Song (ZIP)', style: TextStyle(color: Colors.white)),
                subtitle: const Text("Zip and share the original, unmodified song folder", style: TextStyle(color: Colors.grey, fontSize: 12)),
                onTap: () {
                  Navigator.pop(ctx);
                  _shareOriginalSong();
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        );
      }
    );
  }

  Future<void> _shareOriginalSong() async {
    if (_activeSongDir == null) return;
    setState(() => _isBouncing = true);
    
    final docDir = await getApplicationDocumentsDirectory();
    final outZip = '${docDir.path}/${_activeSongDir!.path.split(Platform.pathSeparator).last}_Original.zip';
    
    var encoder = ZipFileEncoder();
    encoder.create(outZip);
    for (var file in _activeSongDir!.listSync()) {
      if (file is File) {
        encoder.addFile(file);
      }
    }
    encoder.close();
    
    setState(() => _isBouncing = false);
    await Share.shareXFiles([XFile(outZip)], text: 'Original Stems');
  }

  Future<void> _shareModifiedStems() async {
    if (_activeSongDir == null || _tracks.isEmpty) return;
    setState(() => _isBouncing = true);
    
    final docDir = await getApplicationDocumentsDirectory();
    final tempDir = Directory('${docDir.path}/temp_stems');
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    tempDir.createSync();
    
    double pitchRatio = pow(2.0, _pitchShiftSemitones / 12.0).toDouble();
    
    String buildAtempo(double ratio) {
      if (ratio == 1.0) return "";
      if (ratio >= 0.5 && ratio <= 2.0) return "atempo=$ratio,";
      if (ratio < 0.5) return "atempo=0.5,atempo=${ratio/0.5},";
      return "atempo=2.0,atempo=${ratio/2.0},";
    }

    List<TrackData> activeTracks = [..._tracks];
    if (_isMetronomeOn && _metronomeTracks.containsKey(_subdivision)) {
      activeTracks.add(_metronomeTracks[_subdivision]!);
    }
    
    for (var track in activeTracks) {
      double amp = track.volume;
      bool isMetronome = track.name.toLowerCase().contains("metronome");
      if (!isMetronome) {
         amp = _getAmplitudeFromSlider(track.volume);
      } else {
         amp = _getAmplitudeFromSlider(_metronomeVolume);
      }
      
      String trackFilter = "";
      if (isMetronome) {
        trackFilter = buildAtempo(_playbackSpeed);
      } else {
        if (_pitchShiftSemitones != 0.0 || _playbackSpeed != 1.0) {
           int newRate = (44100 * pitchRatio).toInt();
           double atempoRatio = _playbackSpeed / pitchRatio;
           trackFilter = "asetrate=$newRate,${buildAtempo(atempoRatio)}";
        }
      }
      
      String finalFilter = "${trackFilter}volume=$amp";
      if (finalFilter.endsWith(',')) finalFilter = finalFilter.substring(0, finalFilter.length - 1);
      
      String outPath = '${tempDir.path}/${track.name}.wav';
      String cmd = "-i \"${track.file.path}\" -af \"$finalFilter\" -y \"$outPath\"";
      await FFmpegKit.execute(cmd);
    }
    
    File meta = File('${_activeSongDir!.path}/song_metadata.json');
    if (meta.existsSync()) meta.copySync('${tempDir.path}/song_metadata.json');
    
    final outZip = '${docDir.path}/${_activeSongDir!.path.split(Platform.pathSeparator).last}_Modified.zip';
    var encoder = ZipFileEncoder();
    encoder.create(outZip);
    for (var file in tempDir.listSync()) {
      if (file is File) encoder.addFile(file);
    }
    encoder.close();
    
    setState(() => _isBouncing = false);
    await Share.shareXFiles([XFile(outZip)], text: 'Modified Stems');
  }

  Future<void> _exportChordSheet() async {
    if (_chords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("No chords found for this song.")));
      return;
    }
    
    
    try {
      final title = _songMetadata != null ? (_songMetadata!['song_name'] ?? _activeSongDir!.path.split(Platform.pathSeparator).last) : "Chord Sheet";
      
      String subtitle = "";
      if (_pitchShiftSemitones != 0) {
        subtitle += "Transposed: ${_pitchShiftSemitones > 0 ? '+' : ''}${_pitchShiftSemitones.toInt()}  ";
      }
      if (_simplifyChords) {
        subtitle += "(Simplified)";
      }
      
      // Process chords before generating PDF to respect Pitch Shifting and Simplified Chords toggle
      final processedChords = _chords.map((c) {
        return {
          'time': c['time'],
          'chord': _transposeChord(c['chord'] as String, _pitchShiftSemitones.toInt())
        };
      }).toList();
      
      final processedLyrics = _lyrics.map((l) => {'time': l.time, 'text': l.text}).toList();
      final file = await ChordSheetGenerator.generateAndSaveChordSheet(title, subtitle, processedChords, processedLyrics, _baseTempo);
      if (file != null) {
        final xFile = XFile(file.path, mimeType: 'application/pdf');
        await Share.shareXFiles([xFile], text: "$title - Chord Sheet");
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error generating chord sheet: $e")));
    }
  }

  Future<void> _exportMix() async {
    if (_isBouncing || _tracks.isEmpty) return;

    setState(() => _isBouncing = true);

    List<TrackData> activeTracks = [..._tracks];
    if (_isMetronomeOn && _metronomeTracks.containsKey(_subdivision)) {
      activeTracks.add(_metronomeTracks[_subdivision]!);
    }

    if (activeTracks.isEmpty) {
      setState(() => _isBouncing = false);
      return;
    }

    final docDir = await getApplicationDocumentsDirectory();
    final outPath = '${docDir.path}/StemSync_Mix.wav';
    final outFile = File(outPath);
    if (outFile.existsSync()) outFile.deleteSync();

    String inputs = "";
    String filter = "";
    int index = 0;
    
    double pitchRatio = pow(2.0, _pitchShiftSemitones / 12.0).toDouble();
  
    for (var track in activeTracks) {
      inputs += "-i \"${track.file.path}\" "; 
      
      double amp = track.volume;
      bool isMetronome = track.name.toLowerCase().contains("metronome");
      
      if (!isMetronome) {
         amp = _getAmplitudeFromSlider(track.volume);
      } else {
         amp = _getAmplitudeFromSlider(_metronomeVolume);
      }
      
      String trackFilter = "";
      
      // Helper to chain atempo filters if the ratio exceeds FFmpeg's 0.5 - 2.0 limit
      String buildAtempo(double ratio) {
        if (ratio == 1.0) return "";
        if (ratio >= 0.5 && ratio <= 2.0) return "atempo=$ratio,";
        if (ratio < 0.5) return "atempo=0.5,atempo=${ratio/0.5},";
        return "atempo=2.0,atempo=${ratio/2.0},";
      }
      
      if (isMetronome) {
        // Metronome: Only tempo shift, never pitch shift (prevents squeaking)
        trackFilter = buildAtempo(_playbackSpeed);
      } else {
        // Musical tracks: Compound Pitch shift AND tempo shift
        if (_pitchShiftSemitones != 0.0 || _playbackSpeed != 1.0) {
           int newRate = (44100 * pitchRatio).toInt();
           double atempoRatio = _playbackSpeed / pitchRatio;
           trackFilter = "asetrate=$newRate,${buildAtempo(atempoRatio)}";
        }
      }
      
      filter += "[$index:a]${trackFilter}volume=$amp[a$index]; ";
      index++;
    }

    String amixInputs = "";
    for (int i = 0; i < index; i++) {
      amixInputs += "[a$i]";
    }
    
    filter += "${amixInputs}amix=inputs=$index:duration=longest[out]";

    String command = "$inputs -filter_complex \"$filter\" -map \"[out]\" -y \"$outPath\"";
    
    final session = await FFmpegKit.executeAsync(command, (session) async {
       final returnCode = await session.getReturnCode();
       if (ReturnCode.isSuccess(returnCode)) {
         final fileBytes = await outFile.readAsBytes();
         final uri = await FilePicker.saveFile(
           fileName: 'StemSync_Mix.wav',
           bytes: fileBytes,
           dialogTitle: 'Save Custom Mix',
         );
         if (uri != null && mounted) {
           ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Mix exported successfully!")));
         }
       } else {
         final logs = await session.getLogsAsString();
         if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Export failed!")));
         debugPrint("FFmpeg error: $logs");
       }
       if (mounted) setState(() => _isBouncing = false);
    });
  }

  void _playBeep() {
    if (_beepSource != null) {
      SoLoud.instance.play(_beepSource!, volume: 0.8);
    }
  }

  void _showCountInMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              height: 380,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
                      const Expanded(child: Center(child: Text("Count in", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)))),
                      const SizedBox(width: 48),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Text("Clicks before playback starts", style: TextStyle(color: Colors.grey, fontSize: 14)),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.remove, color: Colors.white),
                        onPressed: () {
                          if (_countInClicks > 0) {
                            setModalState(() => _countInClicks--);
                            setState(() {});
                          }
                        },
                      ),
                      const SizedBox(width: 16),
                      Column(
                        children: [
                          Container(
                            width: 60, height: 60,
                            decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                            child: Center(child: Text("$_countInClicks", style: const TextStyle(color: Colors.black, fontSize: 24, fontWeight: FontWeight.bold))),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: List.generate(16, (index) {
                              bool isActive = index < _countInClicks;
                              return Container(
                                width: 2, height: isActive ? 24 : 16,
                                margin: const EdgeInsets.symmetric(horizontal: 2),
                                color: isActive ? Colors.white : Colors.grey[800],
                              );
                            }),
                          )
                        ],
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        icon: const Icon(Icons.add, color: Colors.white),
                        onPressed: () {
                          if (_countInClicks < 16) {
                            setModalState(() => _countInClicks++);
                            setState(() {});
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  TextButton(
                    onPressed: () {
                      setModalState(() => _countInClicks = 0);
                      setState(() {});
                    },
                    child: const Text("Reset to original", style: TextStyle(color: Colors.grey)),
                  ),
                  const Spacer(),
                  const Text("The playback start time adjusts to match the nearest beat.", style: TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            );
          }
        );
      }
    );
  }

    void _cancelCountIn() {
    if (_countInTimer != null) {
      _countInTimer!.cancel();
      _countInTimer = null;
    }
    _countInStopwatch.stop();
    for (var h in _countInHandles) {
      try { SoLoud.instance.stop(h); } catch (_) {}
    }
    _countInHandles.clear();
  }

  void _seekBy(double seconds) {
    if (_tracks.isEmpty) return;
    HapticFeedback.lightImpact();
    double current = _currentPositionNotifier.value;
    double newPos = current + seconds;
    if (newPos < 0) newPos = 0;
    if (newPos > _songLength) newPos = _songLength;
    
    _cancelCountIn();
    
    for (var t in _tracks) {
      SoLoud.instance.seek(t.handle, Duration(milliseconds: (newPos * 1000).toInt()));
    }
    for (var t in _metronomeTracks.values) {
      SoLoud.instance.seek(t.handle, Duration(milliseconds: (newPos * 1000).toInt()));
    }
    
    _currentPositionNotifier.value = newPos;
    _updateActiveChord(newPos);
    _updateActiveSection(newPos);
    
    if (_showChords && _chordScrollController.hasClients) {
        _chordScrollController.jumpTo(newPos * 160.0);
    }
    setState((){});
  }
  void _togglePlayPause() {
    if (_tracks.isEmpty) return;

    if (_countInTimer != null && _countInTimer!.isActive) {
      _cancelCountIn();
      setState(() {});
      return;
    }

    bool isPlaying = !SoLoud.instance.getPause(_tracks.first.handle);
    if (isPlaying) {
      for (var t in _tracks) SoLoud.instance.setPause(t.handle, true);
      for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, true);
      setState(() {});
    } else {
      if (_countInClicks > 0 && _currentPositionNotifier.value <= (_firstBeat + 0.1)) {
        // Snap to nearest beat
        double interval = 60.0 / _currentTempo;
        double currentPos = _currentPositionNotifier.value;
        double beatsSinceFirst = (currentPos - _firstBeat) / interval;
        int nearestBeat = beatsSinceFirst.round();
        double snappedPos = _firstBeat + nearestBeat * interval;
        if (snappedPos < 0) snappedPos = _firstBeat; // Snap forward to actual first beat to maintain phase!
        
        for (var t in _tracks) SoLoud.instance.seek(t.handle, Duration(milliseconds: (snappedPos * 1000).toInt()));
        for (var t in _metronomeTracks.values) SoLoud.instance.seek(t.handle, Duration(milliseconds: (snappedPos * 1000).toInt()));
        
        _currentPositionNotifier.value = snappedPos;
        _updateActiveChord(snappedPos);
        _updateActiveSection(snappedPos);
        _currentCountInTick = 0;
        setState(() {});

        // 1. Schedule all beeps with perfect sample-accuracy!
        final now = SoLoud.instance.getEngineTime();
        Duration offsetTime = Duration.zero;
        int intervalUs = (interval * 1000000).toInt();
        _countInHandles.clear();
        for (int i = 0; i < _countInClicks; i++) {
           if (_beepSource != null) {
              final h = SoLoud.instance.playScheduled(_beepSource!, now + offsetTime, volume: _getAmplitudeFromSlider(_metronomeVolume));
              _countInHandles.add(h);
           }
           offsetTime += Duration(microseconds: intervalUs);
        }

        // 2. Start the stopwatch so the UI can loosely track visual updates
        _countInStopwatch.reset();
        _countInStopwatch.start();
        
        // 3. Set a Timer to unpause the tracks precisely when the count-in finishes
        _countInTimer = Timer(Duration(microseconds: intervalUs * _countInClicks), () {
            if (_countInTimer == null) return;
            _countInTimer = null;
            _countInStopwatch.stop();
            for (var t in _tracks) SoLoud.instance.setPause(t.handle, false);
            for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, false);
            setState((){});
        });
      } else {
        for (var t in _tracks) SoLoud.instance.setPause(t.handle, false);
        for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, false);
        setState(() {});
      }
    }
  }

  Future<void> _deleteSong(Directory dir) async {
    bool confirm = await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text("Delete Song", style: TextStyle(color: Colors.white)),
        content: const Text("Are you sure you want to permanently delete this song and all its separated stems?", style: TextStyle(color: Colors.grey, fontSize: 12)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel", style: TextStyle(color: Colors.grey))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Delete", style: TextStyle(color: Colors.redAccent))),
        ],
      )
    ) ?? false;

    if (confirm) {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
      if (_loadedSongDir?.path == dir.path) {
        _closeMixer();
        _loadedSongDir = null;
      }
      _loadLibrary();
    }
  }

  Future<void> _loadLibrary() async {
    final docDir = await getApplicationDocumentsDirectory();
    final songsDir = Directory('${docDir.path}/songs');
    if (!songsDir.existsSync()) {
      songsDir.createSync(recursive: true);
    }
    
    List<Map<String, dynamic>> loaded = [];
    for (var dir in songsDir.listSync().whereType<Directory>()) {
      String title = dir.path.split(Platform.pathSeparator).last;
      String subtitle = "";
      int timestamp = dir.statSync().modified.millisecondsSinceEpoch;
      
      final metaFile = File('${dir.path}/song_metadata.json');
      if (metaFile.existsSync()) {
        try {
          final meta = jsonDecode(metaFile.readAsStringSync());
          title = meta['song_name'] ?? title;
          
          List<String> details = [];
          if (meta['artist'] != null && meta['artist'].toString().trim().isNotEmpty && meta['artist'].toString().trim() != "Unknown Artist") {
            details.add(meta['artist'].toString());
          }
          if (meta['genre'] != null && meta['genre'].toString().trim().isNotEmpty && meta['genre'].toString().trim() != "Unknown Genre") {
            details.add(meta['genre'].toString());
          }
          if (meta['release_year'] != null && meta['release_year'].toString().trim().isNotEmpty) {
            details.add(meta['release_year'].toString());
          }
          subtitle = details.join(' • ');
        } catch (_) {}
      }
      
      loaded.add({
        'dir': dir,
        'title': title,
        'subtitle': subtitle,
        'searchKey': '${title.toLowerCase()} ${subtitle.toLowerCase()} ${dir.path.toLowerCase()}',
        'timestamp': timestamp,
      });
    }

    setState(() {
      _savedSongs = loaded;
      _isLibraryLoading = false;
    });
    
    await _loadPlaylists();
  }

  void _updateActiveLyric(double pos) {
    if (_lyrics.isEmpty) return;
    int newIdx = -1;
    for (var i = 0; i < _lyrics.length; i++) {
      if (pos >= _lyrics[i].time) {
        newIdx = i;
      } else {
        break;
      }
    }
      if (newIdx != _activeLyricNotifier.value) {
        _activeLyricNotifier.value = newIdx;
        if (_showLyrics && newIdx >= 0 && _lyricScrollController.hasClients) {
          double offset = max(0.0, (newIdx * 75.0) - 100.0); 
          _lyricScrollController.animateTo(offset, duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic);
        }
      }
  }

  void _parseLrcContent(String content) {
    final lines = content.split('\n');
    final RegExp timeRegExp = RegExp(r'\[(\d{2,}):(\d{2}\.\d{1,3})\]');
    List<LyricLine> parsed = [];
    
    for (var line in lines) {
      final match = timeRegExp.firstMatch(line);
      if (match != null) {
        final mins = int.parse(match.group(1)!);
        final secs = double.parse(match.group(2)!);
        final time = (mins * 60) + secs;
        final text = line.substring(match.end).trim();
        if (text.isNotEmpty) {
          parsed.add(LyricLine(time: time, text: text));
        }
      }
    }
    
    // Inject Instrumental gaps automatically
    List<LyricLine> finalParsed = [];
    if (parsed.isNotEmpty && parsed.first.time > 12.0) {
      // Long intro
      finalParsed.add(LyricLine(time: 0.0, text: '♪'));
    }

    for (int i = 0; i < parsed.length; i++) {
      finalParsed.add(parsed[i]);
      if (i < parsed.length - 1) {
        double timeDiff = parsed[i + 1].time - parsed[i].time;
        if (timeDiff > 14.0) {
          // If there is more than a 14 second gap between lines, inject a music symbol 5 seconds after the previous line ends
          finalParsed.add(LyricLine(time: parsed[i].time + 5.0, text: '♪'));
        }
      }
    }
    
    if (finalParsed.isNotEmpty && mounted) {
      setState(() => _lyrics = finalParsed);
    }
  }

  Future<void> _fetchLyricsFromLRCLIB(Directory targetDir, String songName, String? artistName) async {
    try {
      String query = songName;
      if (artistName != null && artistName.isNotEmpty) query += " $artistName";
      
      final uri = Uri.parse("https://lrclib.net/api/search?q=${Uri.encodeComponent(query)}");
      final client = await ProxyClient.createClient(uri.toString());
      final response = await client.get(uri);
      client.close();
      
      if (response.statusCode == 200) {
        final List<dynamic> results = jsonDecode(response.body);
        for (var result in results) {
          if (result['syncedLyrics'] != null && result['syncedLyrics'].toString().trim().isNotEmpty) {
            String syncedLyrics = result['syncedLyrics'];
            final file = File('${targetDir.path}/lyrics.lrc');
            await file.writeAsString(syncedLyrics);
            _parseLrcContent(syncedLyrics);
            break;
          }
        }
      }
    } catch (e) {
      debugPrint("Failed to fetch lyrics: $e");
    }
  }

  void _updateActiveSection(double pos) {
    if (_sections.isEmpty) return;
    int newIdx = -1;
    for (var i = 0; i < _sections.length; i++) {
      double start = (_sections[i]['start_time'] as num).toDouble();
      double end = (_sections[i]['end_time'] as num).toDouble();
      if (pos >= start && pos < end) {
        newIdx = i;
        break;
      }
    }
    if (newIdx != _activeSectionNotifier.value) {
      _activeSectionNotifier.value = newIdx;
      if (newIdx >= 0 && _sectionScrollController.hasClients) {
        // Each pill is roughly 120px wide (padding + text + margin).
        // Scroll so the active pill is roughly centred on screen.
        const double pillWidth = 120.0;
        final double target = (newIdx * pillWidth) - 80.0;
        _sectionScrollController.animateTo(
          target.clamp(0.0, _sectionScrollController.position.maxScrollExtent),
          duration: const Duration(milliseconds: 400),
          curve: Curves.easeInOut,
        );
      }
    }
  }

  void _updateTrackVolumes() {
    bool isAnySoloed = _tracks.any((t) => t.isSoloed);
    for (var track in _tracks) {
      double effectiveAmp = 0.0;
      if (isAnySoloed) {
        effectiveAmp = track.isSoloed ? _getAmplitudeFromSlider(track.volume) : 0.0;
      } else {
        effectiveAmp = track.isMuted ? 0.0 : _getAmplitudeFromSlider(track.volume);
      }
      SoLoud.instance.setVolume(track.handle, effectiveAmp);
    }
  }

  void _updateActiveChord(double pos) {
    if (_chords.isEmpty) return;
    int newIdx = -1;
    for (var i = 0; i < _chords.length; i++) {
      double start = (_chords[i]['time'] as num).toDouble();
      double end = i < _chords.length - 1 ? (_chords[i + 1]['time'] as num).toDouble() : _songLength;
      if (pos >= start && pos < end) {
        newIdx = i;
        break;
      }
    }
    if (newIdx != _activeChordNotifier.value) {
      _activeChordNotifier.value = newIdx;
      
      // Paginated Scroll: Scroll smoothly every 4 beats (measure)
      if (newIdx % 4 == 0) {
        if (_showChords && _chordScrollController.hasClients && !_isScrubbingChords && !_isScrubbing) {
          double targetPos = (_chords[newIdx]['time'] as num).toDouble() * 160.0;
          
          _chordScrollController.animateTo(
            targetPos,
            duration: const Duration(milliseconds: 600),
            curve: Curves.easeOutCubic,
          );
        }
      }
    }
  }

  String _transposeChord(String chord, int semitones) {
    if (chord == "N/C" || chord.isEmpty) return chord;
    
    // Dynamically split the root note (e.g. C#) from any complex extension (e.g. maj7, sus4, m7)
    final match = RegExp(r'^([A-G][#b]?)(.*)$').firstMatch(chord);
    if (match == null) return chord;
    
    String root = match.group(1)!;
    String extension = match.group(2)!;
    
    int idx = _chromaticScale.indexOf(root);
    if (idx == -1) return chord;
    
    int newIdx = (idx + semitones) % 12;
    if (newIdx < 0) newIdx += 12;
    String transposedRoot = _chromaticScale[newIdx];
    
    if (_simplifyChords) {
        if (extension == 'maj7') extension = '';
        else if (extension == 'sus2') extension = '';
        else if (extension == 'sus4') extension = '';
        else if (extension == 'aug') extension = '';
        else if (extension == 'm7') extension = 'm';
        else if (extension == 'dim') extension = 'm';
        else if (extension == '7') extension = '';
    }
    
    return "$transposedRoot$extension";
  }


  String _transposeKey(String key, int semitones) {
    if (!key.contains(" ")) return key;
    List<String> parts = key.split(" ");
    String root = parts[0];
    String scale = parts[1];
    
    int idx = _chromaticScale.indexOf(root);
    if (idx == -1) return key;
    
    int newIdx = (idx + semitones) % 12;
    if (newIdx < 0) newIdx += 12;
    
    return "${_chromaticScale[newIdx]} $scale";
  }


  void _seekToChord(int index) {
    if (index < 0 || index >= _chords.length) return;
    double start = (_chords[index]['time'] as num).toDouble();
    for (var t in _tracks) {
      SoLoud.instance.seek(t.handle, Duration(milliseconds: (start * 1000).toInt()));
    }
    for (var t in _metronomeTracks.values) {
      SoLoud.instance.seek(t.handle, Duration(milliseconds: (start * 1000).toInt()));
    }
    _cancelCountIn();
    _updateActiveChord(start);
    _updateActiveSection(start);
    _currentPositionNotifier.value = start;
    if (_chordScrollController.hasClients) {
      _chordScrollController.animateTo(
        start * 160.0,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _getIconForTrack(String filename) {
    final lower = filename.toLowerCase();
    if (lower.contains('vocal')) return const FaIcon(FontAwesomeIcons.microphone, color: Colors.white, size: 22);
    if (lower.contains('drum')) return const FaIcon(FontAwesomeIcons.drum, color: Colors.white, size: 22);
    if (lower.contains('bass')) return Image.asset('assets/bass_icon.png', height: 38, color: Colors.white);
    if (lower.contains('guitar')) return Image.asset('assets/guitar_icon.png', height: 32, color: Colors.white);
    if (lower.contains('piano')) return const Icon(Icons.piano, color: Colors.white, size: 24);
    return const FaIcon(FontAwesomeIcons.music, color: Colors.white, size: 22);
  }

  String _getDisplayNameForTrack(String filename) {
    final lower = filename.toLowerCase();
    if (lower.contains('vocal')) return "Vocals";
    if (lower.contains('drum')) return "Drums";
    if (lower.contains('bass')) return "Bass";
    if (lower.contains('guitar')) return "Guitar";
    if (lower.contains('piano')) return "Piano";
    if (lower.contains('other')) return "Other";
    
    // Fallback: capitalize whatever it is
    String clean = filename.split('.').first.replaceAll('_', ' ').replaceAll(RegExp(r'[0-9]'), '').trim();
    if (clean.isEmpty) return "Track";
    return '${clean[0].toUpperCase()}${clean.substring(1)}';
  }

  Future<void> _processZipFile(String zipPath, String zipNameRaw) async {
    try {
      setState(() { _isLibraryLoading = true; });
      final zipName = zipNameRaw.replaceAll('.zip', '').replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_');
      
      final docDir = await getApplicationDocumentsDirectory();
      final targetDir = Directory('${docDir.path}/songs/$zipName');
      
      if (targetDir.existsSync()) {
        targetDir.deleteSync(recursive: true);
      }
      targetDir.createSync(recursive: true);

      await compute(_extractZipInIsolate, {
        'zipPath': zipPath,
        'targetPath': targetDir.path,
      });
      
      await _loadLibrary();
    } catch (e) {
      setState(() { _isLibraryLoading = false; });
      debugPrint("Error extracting zip: $e");
    }
  }

  Future<void> _loadZipFile() async {
    try {
      List<PlatformFile>? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (result != null && result.isNotEmpty) {
        final zipPath = result.single.path!;
        final zipNameRaw = result.single.name;
        await _processZipFile(zipPath, zipNameRaw);
      }
    } catch (e) {
      debugPrint("Error picking zip: $e");
    }
  }

  void _playNextSong({bool autoPlay = false}) {
    Directory? nextDir;
    if (_activePlaylist != null) {
      final list = _playlists[_activePlaylist!]!;
      final currentName = _activeSongDir!.path.split(Platform.pathSeparator).last;
      int idx = list.indexOf(currentName);
      if (idx != -1 && idx < list.length - 1) {
        String nextName = list[idx + 1];
        try {
          nextDir = _savedSongs.firstWhere((s) => s['dir'].path.endsWith(nextName))['dir'];
        } catch (_) {}
      }
    } else {
      var currentList = _savedSongs.where((s) => s['searchKey'].toString().contains(_searchQuery)).toList();
      if (_sortMode == 'A-Z') {
        currentList.sort((a, b) => a['title'].toString().compareTo(b['title'].toString()));
      } else {
        currentList.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
      }
      
      int idx = currentList.indexWhere((s) => s['dir'].path == _activeSongDir!.path);
      if (idx != -1 && idx < currentList.length - 1) {
        nextDir = currentList[idx + 1]['dir'];
      }
    }
    
    if (nextDir != null) {
      _closeMixer();
      _openSong(nextDir, autoPlay: autoPlay);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("End of list")));
    }
  }

  void _playPrevSong() {
    Directory? prevDir;
    if (_activePlaylist != null) {
      final list = _playlists[_activePlaylist!]!;
      final currentName = _activeSongDir!.path.split(Platform.pathSeparator).last;
      int idx = list.indexOf(currentName);
      if (idx > 0) {
        String prevName = list[idx - 1];
        try {
          prevDir = _savedSongs.firstWhere((s) => s['dir'].path.endsWith(prevName))['dir'];
        } catch (_) {}
      }
    } else {
      var currentList = _savedSongs.where((s) => s['searchKey'].toString().contains(_searchQuery)).toList();
      if (_sortMode == 'A-Z') {
        currentList.sort((a, b) => a['title'].toString().compareTo(b['title'].toString()));
      } else {
        currentList.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
      }
      
      int idx = currentList.indexWhere((s) => s['dir'].path == _activeSongDir!.path);
      if (idx > 0) {
        prevDir = currentList[idx - 1]['dir'];
      }
    }
    
    if (prevDir != null) {
      _closeMixer();
      _openSong(prevDir);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Beginning of list")));
    }
  }

  Future<void> _openSong(Directory targetDir, {bool autoPlay = false}) async {
    try {
      if (_loadedSongDir?.path == targetDir.path && _tracks.isNotEmpty) {
        setState(() {
          _activeSongDir = targetDir;
        });
        return; // Already loaded! Just go to the mixer.
      }

      setState(() { 
        _isLoading = true; 
        _activeSongDir = targetDir;
        _loadedSongDir = targetDir;
        _isScrubbing = false;
        _isScrubbingChords = false;
      });

      // Predict next song for preloading cache management
      Directory? nextDir;
      if (_activePlaylist != null) {
        final list = _playlists[_activePlaylist!]!;
        final currentName = targetDir.path.split(Platform.pathSeparator).last;
        int idx = list.indexOf(currentName);
        if (idx != -1 && idx < list.length - 1) {
          String nextName = list[idx + 1];
          try {
            nextDir = _savedSongs.firstWhere((s) => s['dir'].path.endsWith(nextName))['dir'];
          } catch (_) {}
        }
      } else {
        var currentList = _savedSongs.where((s) => s['searchKey'].toString().contains(_searchQuery)).toList();
        if (_sortMode == "A-Z") {
          currentList.sort((a, b) => a['title'].toString().compareTo(b['title'].toString()));
        } else {
          currentList.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
        }
        final currentName = targetDir.path.split(Platform.pathSeparator).last;
        int idx = currentList.indexWhere((s) => (s['dir'] as Directory).path.endsWith(currentName));
        if (idx != -1 && idx < currentList.length - 1) {
          nextDir = currentList[idx + 1]['dir'];
        }
      }

      final audioFiles = targetDir.listSync(recursive: true).whereType<File>().where((f) => 
        f.path.endsWith('.wav') || f.path.endsWith('.mp3') || f.path.endsWith('.ogg') || f.path.endsWith('.flac')
      ).toList();

      List<String> keepPaths = audioFiles.map((f) => f.path).toList();
      if (nextDir != null) {
        final nextFiles = nextDir.listSync(recursive: true).whereType<File>().where((f) => 
          f.path.endsWith('.wav') || f.path.endsWith('.mp3') || f.path.endsWith('.ogg') || f.path.endsWith('.flac')
        ).toList();
        keepPaths.addAll(nextFiles.map((f) => f.path));
      }

      for (var t in _tracks) SoLoud.instance.stop(t.handle);
      for (var t in _metronomeTracks.values) SoLoud.instance.stop(t.handle);
      
      _audioSourceCache.removeWhere((path, source) {
        if (!keepPaths.contains(path)) {
          SoLoud.instance.disposeSource(source);
          return true;
        }
        return false;
      });

      if (_stemsBus != null) {
        try { _stemsBus!.dispose(); } catch (_) {}
        _stemsBus = null;
      }
      _metronomeTracks.clear();
      _tracks.clear();
      _songMetadata = null;
      _chords.clear();
      _sections.clear();
      _songKey = "Unknown";
      _pitchShiftSemitones = 0.0;
      _lyrics.clear();
      _activeLyricNotifier.value = -1;
      _showChords = false;
      _showSections = false;
      _showLyrics = false;
      _currentPositionNotifier.value = 0.0;

      audioFiles.sort((a, b) {
        int order(String name) {
          final l = name.toLowerCase();
          if (l.contains('vocal')) return 1;
          if (l.contains('drum')) return 2;
          if (l.contains('bass')) return 3;
          if (l.contains('guitar')) return 4;
          if (l.contains('piano')) return 5;
          return 6;
        }
        return order(a.path).compareTo(order(b.path));
      });

      // Start loading audio into memory (using preloaded cache if available)
      final audioLoadFuture = Future.wait(audioFiles.map((f) async {
        if (_audioSourceCache.containsKey(f.path)) return _audioSourceCache[f.path]!;
        final source = await SoLoud.instance.loadFile(f.path, mode: LoadMode.memory);
        _audioSourceCache[f.path] = source;
        return source;
      }));

      final metaFile = File('${targetDir.path}/song_metadata.json');
      if (metaFile.existsSync()) {
        _songMetadata = jsonDecode(metaFile.readAsStringSync());
        if (_songMetadata!['tempo_bpm'] != null) {
          _baseTempo = (_songMetadata!['tempo_bpm'] as num).toDouble();
          _currentTempo = _baseTempo;
        }
        if (_songMetadata!['first_beat'] != null) {
          _firstBeat = (_songMetadata!['first_beat'] as num).toDouble();
        }
        if (_songMetadata!['key'] != null) {
          _songKey = _songMetadata!['key'] as String;
        }
        if (_songMetadata!['chords'] != null) {
          _chords = List<Map<String, dynamic>>.from(_songMetadata!['chords']);
          _activeChordNotifier.value = 0;
        }
        if (_songMetadata!['sections'] != null) {
          _sections = List<Map<String, dynamic>>.from(_songMetadata!['sections']);
          _activeSectionNotifier.value = -1;
        }
      }

      final lrcFile = File('${targetDir.path}/lyrics.lrc');
      if (lrcFile.existsSync()) {
        _parseLrcContent(lrcFile.readAsStringSync());
      }






      Map<String, double> savedVolumes = {};
      Map<String, double> savedPans = {};
      Map<String, bool> savedMutes = {};
      Map<String, bool> savedSolos = {};
      final mixStateFile = File('${targetDir.path}/mix_state.json');
      if (mixStateFile.existsSync()) {
        try {
          final data = jsonDecode(mixStateFile.readAsStringSync());
          if (data['volumes'] != null) {
            savedVolumes = Map<String, double>.from(data['volumes']);
          }
          if (data['pans'] != null) {
            savedPans = Map<String, double>.from(data['pans']);
          }
          if (data['mutes'] != null) {
            savedMutes = Map<String, bool>.from(data['mutes']);
          }
          if (data['solos'] != null) {
            savedSolos = Map<String, bool>.from(data['solos']);
          }
          if (data['pitchShift'] != null) _pitchShiftSemitones = (data['pitchShift'] as num).toDouble();
          if (data['tempo'] != null) {
            _currentTempo = (data['tempo'] as num).toDouble();
            _playbackSpeed = _currentTempo / _baseTempo;
          }
          if (data['metronomeVolume'] != null) _metronomeVolume = (data['metronomeVolume'] as num).toDouble();
          if (data['metronomePan'] != null) _metronomePan = (data['metronomePan'] as num).toDouble();
          if (data['subdivision'] != null) _subdivision = (data['subdivision'] as num).toDouble();
          if (data['isMetronomeOn'] != null) _isMetronomeOn = data['isMetronomeOn'] as bool;
          if (data['countInClicks'] != null) _countInClicks = data['countInClicks'] as int;
          if (data['isSongLooping'] != null) _isSongLooping = data['isSongLooping'] as bool;
          if (data['autoAdvance'] != null) _autoAdvance = data['autoAdvance'] as bool;
        } catch (_) {}
      }

      _stemsBus = SoLoud.instance.createMixingBus(name: 'stems');
      _stemsBus!.playOnEngine();
      _stemsBus!.filters.limiterFilter.activate(); // Prevent digital clipping from overlapping FFT windows
      // Pitch shift filter is activated lazily in _applyPitchAndTempo only when needed.

      final sources = await audioLoadFuture;
      for (int i = 0; i < audioFiles.length; i++) {
        final audioFile = audioFiles[i];
        final filename = audioFile.path.split(Platform.pathSeparator).last;
        final source = sources[i];
        
        bool isMetronome = filename.toLowerCase().contains('metronome');
        
        final handle = isMetronome
            ? SoLoud.instance.play(source, paused: true, looping: true)
            : _stemsBus!.play(source, paused: true, looping: true);
            
        SoLoud.instance.setProtectVoice(handle, true);
        
        if (isMetronome) {
           double sub = 1.0;
           if (filename.contains('0_5x')) sub = 0.5;
           if (filename.contains('2x')) sub = 2.0;
           
           double raw = (_isMetronomeOn && _subdivision == sub) ? _getAmplitudeFromSlider(_metronomeVolume) : 0.0;
           SoLoud.instance.setVolume(handle, raw);
           SoLoud.instance.setPan(handle, _metronomePan);
           _metronomeTracks[sub] = TrackData(name: filename, handle: handle, source: source, file: audioFile, volume: _metronomeVolume);
        } else {
              double initialVol = savedVolumes.containsKey(filename) ? savedVolumes[filename]! : 0.7;
              double initialPan = savedPans.containsKey(filename) ? savedPans[filename]! : 0.0;
              bool initialMute = savedMutes.containsKey(filename) ? savedMutes[filename]! : false;
              bool initialSolo = savedSolos.containsKey(filename) ? savedSolos[filename]! : false;
              
              SoLoud.instance.setVolume(handle, _getAmplitudeFromSlider(initialVol));
              SoLoud.instance.setPan(handle, initialPan);
              _tracks.add(TrackData(
                name: filename, 
                handle: handle, 
                source: source, 
                file: audioFile, 
                volume: initialVol,
                pan: initialPan,
                isMuted: initialMute,
                isSoloed: initialSolo,
              ));
        }
        
        _songLength = SoLoud.instance.getLength(source).inMilliseconds / 1000.0;
        if (_songLength <= 0.0) _songLength = 1.0;
      }

      _updateTrackVolumes();
      setState(() { _isLoading = false; });
      
      if (autoPlay) {
        _togglePlayPause();
      }

      // 6. Lookahead Preloader for the NEXT song!
      if (nextDir != null) {
        Future.microtask(() async {
          final nextFiles = nextDir!.listSync(recursive: true).whereType<File>().where((f) => 
            f.path.endsWith('.wav') || f.path.endsWith('.mp3') || f.path.endsWith('.ogg') || f.path.endsWith('.flac')
          ).toList();
          for (var f in nextFiles) {
            if (!_audioSourceCache.containsKey(f.path)) {
              try {
                final source = await SoLoud.instance.loadFile(f.path, mode: LoadMode.memory);
                _audioSourceCache[f.path] = source;
              } catch (_) {}
            }
          }
        });
      }

    } catch (e) {
      setState(() { _isLoading = false; });
      debugPrint("Error loading song: $e");
    }
  }

  double _getAmplitudeFromSlider(double val) {
    if (val <= 0.7) {
      double normalized = val / 0.7;
      return (normalized * normalized) * 2.0; 
    } else {
      double normalized = (val - 0.7) / 0.3;
      return 2.0 + (normalized * 0.824);
    }
  }

  void _updateMetronomeVolumes() {
    for (var entry in _metronomeTracks.entries) {
      double amp = (_isMetronomeOn && _subdivision == entry.key) ? _getAmplitudeFromSlider(_metronomeVolume) : 0.0;
      SoLoud.instance.setVolume(entry.value.handle, amp);
    }
  }

  void _setTempo(double newTempo, {bool snap = true}) {
    if (snap && (newTempo - _baseTempo).abs() < 3.0) {
      newTempo = _baseTempo;
    }
    setState(() {
      _currentTempo = newTempo.clamp(10.0, 300.0);
      _playbackSpeed = _currentTempo / _baseTempo;
    });
  }

  void _applyPitchAndTempo() {
    for (var t in _tracks) {
      SoLoud.instance.setRelativePlaySpeed(t.handle, _playbackSpeed);
    }
    for (var t in _metronomeTracks.values) {
      SoLoud.instance.setRelativePlaySpeed(t.handle, _playbackSpeed);
    }
    
    // Total shift must counteract the tempo speed-up AND apply user's key transposition.
    double tempoShift = 1.0 / _playbackSpeed;
    double keyShift = pow(2.0, _pitchShiftSemitones / 12.0).toDouble();
    double totalShift = tempoShift * keyShift;
    
    if (_stemsBus != null) {
      try {
        const double epsilon = 0.001;
        final bool needsShift = (totalShift - 1.0).abs() > epsilon;
        final bool isActive = _stemsBus!.filters.pitchShiftFilter.isActive;
        
        if (needsShift) {
          // Activate filter only if it isn't already on.
          if (!isActive) _stemsBus!.filters.pitchShiftFilter.activate();
          _stemsBus!.filters.pitchShiftFilter.shift().value = totalShift;
        } else {
          // No shift needed — deactivate so the FFT stops running entirely.
          if (isActive) _stemsBus!.filters.pitchShiftFilter.deactivate();
        }
      } catch (e) {
        debugPrint("Error setting pitch shift on bus: $e");
      }
    }
  }

  void _showTrackOptions(TrackData track) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_getDisplayNameForTrack(track.name), style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: track.isSoloed ? Colors.tealAccent : Colors.grey[800],
                          foregroundColor: track.isSoloed ? Colors.black : Colors.white,
                        ),
                        icon: const Icon(Icons.headphones),
                        label: const Text("Solo"),
                        onPressed: () {
                          setState(() { track.isSoloed = !track.isSoloed; });
                          setModalState(() {});
                          _updateTrackVolumes();
                        },
                      ),
                      ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: track.isMuted ? Colors.redAccent : Colors.grey[800],
                          foregroundColor: track.isMuted ? Colors.white : Colors.white,
                        ),
                        icon: const Icon(Icons.volume_off),
                        label: const Text("Mute"),
                        onPressed: () {
                          setState(() { track.isMuted = !track.isMuted; });
                          setModalState(() {});
                          _updateTrackVolumes();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Align(alignment: Alignment.centerLeft, child: Text("Stereo Panning (L / R)", style: TextStyle(color: Colors.grey))),
                  StatefulBuilder(
                    builder: (context, setSliderState) {
                      return Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 2,
                            height: 12,
                            color: Colors.white54,
                          ),
                          Slider(
                            value: track.pan,
                            min: -1.0,
                            max: 1.0,
                            activeColor: Colors.tealAccent,
                            inactiveColor: Colors.grey[800],
                            onChanged: (v) {
                              if (v.abs() < 0.1) {
                                if (track.pan != 0.0) {
                                  HapticFeedback.selectionClick();
                                }
                                v = 0.0;
                              }
                              track.pan = v;
                              setSliderState(() {});
                              SoLoud.instance.setPan(track.handle, v);
                            },
                          ),
                        ],
                      );
                    }
                  ),
                ],
              ),
            );
          }
        );
      }
    );
  }


  void _showMetronomeMenu() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 24.0, right: 24.0, top: 24.0, 
                bottom: MediaQuery.of(context).viewInsets.bottom + 24.0
              ),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text("Smart Metronome", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        Switch(
                          value: _isMetronomeOn,
                          activeColor: Colors.tealAccent,
                          onChanged: (v) {
                            setState(() => _isMetronomeOn = v);
                            setModalState(() {});
                            _updateMetronomeVolumes();
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("Volume", style: TextStyle(color: Colors.grey)),
                              LayoutBuilder(
                                builder: (context, constraints) {
                                  double trackWidth = constraints.maxWidth - 48.0;
                                  if (trackWidth < 0) trackWidth = 0;
                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      // 70% Baseline Marker
                                      Positioned(
                                        left: 24.0 + (trackWidth * 0.7),
                                        child: Container(
                                          width: 2,
                                          height: 12,
                                          color: Colors.white54,
                                        ),
                                      ),
                                      Slider(
                                        value: _metronomeVolume,
                                        min: 0.0,
                                        max: 1.0,
                                        activeColor: Colors.tealAccent,
                                        onChanged: (v) {
                                          if ((v - 0.7).abs() < 0.03) {
                                            if (_metronomeVolume != 0.7) {
                                              HapticFeedback.selectionClick();
                                            }
                                            v = 0.7;
                                          }
                                          _metronomeVolume = v;
                                          setModalState(() {});
                                          _updateMetronomeVolumes();
                                        },
                                      ),
                                    ],
                                  );
                                }
                              )
                            ],
                          ),
                        ),
                        Expanded(
                          flex: 1,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Text("L & R", style: TextStyle(color: Colors.grey)),
                              StatefulBuilder(
                                builder: (context, setSliderState) {
                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      Container(
                                        width: 2,
                                        height: 12,
                                        color: Colors.white54,
                                      ),
                                      Slider(
                                        value: _metronomePan,
                                        min: -1.0,
                                        max: 1.0,
                                        activeColor: Colors.tealAccent,
                                        inactiveColor: Colors.grey[800],
                                        onChanged: (v) {
                                          if (v.abs() < 0.1) {
                                            if (_metronomePan != 0.0) {
                                              HapticFeedback.selectionClick();
                                            }
                                            v = 0.0;
                                          }
                                          _metronomePan = v;
                                          setSliderState(() {});
                                          for (var entry in _metronomeTracks.values) {
                                            SoLoud.instance.setPan(entry.handle, _metronomePan);
                                          }
                                        },
                                      ),
                                    ],
                                  );
                                }
                              ),
                            ],
                          ),
                        )
                      ],
                    ),
                    const SizedBox(height: 24),
                    const Align(alignment: Alignment.centerLeft, child: Text("Subdivision", style: TextStyle(color: Colors.grey))),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        _buildSubdivBtn("0.5x", _subdivision == 0.5, () { setState(() => _subdivision = 0.5); setModalState((){}); _updateMetronomeVolumes(); }),
                        _buildSubdivBtn("1x", _subdivision == 1.0, () { setState(() => _subdivision = 1.0); setModalState((){}); _updateMetronomeVolumes(); }),
                        _buildSubdivBtn("2x", _subdivision == 2.0, () { setState(() => _subdivision = 2.0); setModalState((){}); _updateMetronomeVolumes(); }),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: const BoxDecoration(shape: BoxShape.circle, color: Colors.white),
                      child: Text(
                        _currentTempo.round().toString(), 
                        style: TextStyle(color: _currentTempo == _baseTempo ? Colors.tealAccent : Colors.black, fontSize: 20, fontWeight: FontWeight.bold)
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        IconButton(icon: const Icon(Icons.remove), onPressed: () {
                           _setTempo(_currentTempo - 1, snap: false);
                           _applyPitchAndTempo();
                           setModalState((){});
                        }),
                        Expanded(
                          child: Slider(
                            value: _currentTempo.clamp(max(10.0, _baseTempo * 0.5), min(300.0, _baseTempo * 2.0)),
                            min: max(10.0, _baseTempo * 0.5),
                            max: min(300.0, _baseTempo * 2.0),
                            activeColor: Colors.grey,
                            inactiveColor: Colors.grey[800],
                            onChanged: (v) {
                              _setTempo(v);
                              setModalState((){});
                            },
                            onChangeEnd: (v) {
                              _applyPitchAndTempo();
                            },
                          ),
                        ),
                        IconButton(icon: const Icon(Icons.add), onPressed: () {
                           _setTempo(_currentTempo + 1, snap: false);
                           _applyPitchAndTempo();
                           setModalState((){});
                        }),
                      ],
                    ),
                    TextButton(
                      onPressed: () {
                        _setTempo(_baseTempo, snap: false);
                        _applyPitchAndTempo();
                        setModalState((){});
                      },
                      child: const Text("Reset to original", style: TextStyle(color: Colors.grey)),
                    )
                  ],
                ),
              ),
            );
          }
        );
      }
    );
  }

  void _showPitchMenu() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.grey[900],
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            String currentKey = _transposeKey(_songKey, _pitchShiftSemitones.toInt());
            
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text("Song Key", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 24),
                    Text(currentKey, style: const TextStyle(fontSize: 48, fontWeight: FontWeight.bold, color: Colors.white)),
                    const SizedBox(height: 8),
                    Text("${_pitchShiftSemitones > 0 ? '+' : ''}${_pitchShiftSemitones.toInt()} Semitones", style: const TextStyle(fontSize: 18, color: Colors.tealAccent, fontWeight: FontWeight.bold)),
                    Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove, color: Colors.white),
                          onPressed: () {
                            if (_pitchShiftSemitones > -12.0) {
                              setState(() { _pitchShiftSemitones -= 1.0; });
                              setModalState(() {});
                              _applyPitchAndTempo();
                            }
                          }
                        ),
                        Expanded(
                          child: Slider(
                            value: _pitchShiftSemitones,
                            min: -12.0,
                            max: 12.0,
                            divisions: 24,
                            activeColor: Colors.tealAccent,
                            inactiveColor: Colors.grey[800],
                            onChanged: (v) {
                              setState(() { _pitchShiftSemitones = v; });
                              setModalState(() {});
                              _applyPitchAndTempo();
                            }
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.add, color: Colors.white),
                          onPressed: () {
                            if (_pitchShiftSemitones < 12.0) {
                              setState(() { _pitchShiftSemitones += 1.0; });
                              setModalState(() {});
                              _applyPitchAndTempo();
                            }
                          }
                        ),
                      ],
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() { _pitchShiftSemitones = 0.0; });
                        setModalState(() {});
                        _applyPitchAndTempo();
                      },
                      child: const Text("Reset to original key", style: TextStyle(color: Colors.grey)),
                    )
                  ],
                ),
              ),
            );
          }
        );
      }
    );
  }

  Widget _buildSubdivBtn(String text, bool active, VoidCallback onTap) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 4),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.transparent,
            border: Border.all(color: Colors.grey[800]!),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Center(
            child: Text(text, style: TextStyle(color: active ? Colors.black : Colors.grey, fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }

  String _formatTime(double seconds) {
    final mins = (seconds / 60).floor();
    final secs = (seconds % 60).floor().toString().padLeft(2, '0');
    return "$mins:$secs";
  }

  Future<void> _initializeApp() async {
    try {
      await SoLoud.instance.init(
        bufferSize: Platform.isAndroid ? 8192 : 4096,
        lowLatency: Platform.isAndroid ? false : true,
      );
    } catch (e) {
      debugPrint("Initial SoLoud init failed: $e");
      try {
        SoLoud.instance.deinit();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        await SoLoud.instance.init(
          bufferSize: Platform.isAndroid ? 8192 : 4096,
          lowLatency: Platform.isAndroid ? false : true,
        );
      } catch (e2) {
        debugPrint("SoLoud completely failed to init: $e2");
      }
    }
    
    if (mounted) {
      _loadLibrary();
      _initBeep();
    }
    
  }

  void _setupSharingIntent() {
    // Listen to media sharing incoming files when the app is in memory
    _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> value) {
      if (value.isNotEmpty && value.first.path.endsWith('.zip')) {
        final filename = value.first.path.split(Platform.pathSeparator).last;
        _processZipFile(value.first.path, filename);
      }
    }, onError: (err) {
      debugPrint("getIntentDataStream error: $err");
    });

    // Get the media sharing incoming files when the app is closed and opened via intent
    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> value) {
      if (value.isNotEmpty && value.first.path.endsWith('.zip')) {
        final filename = value.first.path.split(Platform.pathSeparator).last;
        _processZipFile(value.first.path, filename);
        // Clear the intent to avoid re-processing on hot restarts
        ReceiveSharingIntent.instance.reset();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      _saveMixState();
    }
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _intentDataStreamSubscription?.cancel();
    _ticker.dispose();
    _autoSaveTimer?.cancel();
    _recordingTimer?.cancel();
    _audioRecorder.dispose();
    _countInTimer?.cancel();
    _scrubGraceTimer?.cancel();
    for (var t in _tracks) SoLoud.instance.stop(t.handle);
    for (var t in _metronomeTracks.values) SoLoud.instance.stop(t.handle);
    for (var source in _audioSourceCache.values) {
      SoLoud.instance.disposeSource(source);
    }
    _audioSourceCache.clear();
    if (_beepSource != null) {
      SoLoud.instance.disposeSource(_beepSource!);
    }
    _chordScrollController.dispose();
    super.dispose();
  }

  void _saveMixState() {
    if (_loadedSongDir == null) return;
    
    Map<String, dynamic> data = {
      'pitchShift': _pitchShiftSemitones,
      'tempo': _currentTempo,
      'metronomeVolume': _metronomeVolume,
      'metronomePan': _metronomePan,
      'subdivision': _subdivision,
      'isMetronomeOn': _isMetronomeOn,
      'countInClicks': _countInClicks,
      'isSongLooping': _isSongLooping,
      'autoAdvance': _autoAdvance,
      'volumes': <String, double>{},
      'pans': <String, double>{},
      'mutes': <String, bool>{},
      'solos': <String, bool>{},
    };
    
    for (var t in _tracks) {
      data['volumes'][t.name] = t.volume;
      data['pans'][t.name] = t.pan;
      data['mutes'][t.name] = t.isMuted;
      data['solos'][t.name] = t.isSoloed;
    }
    
    String jsonStr = jsonEncode(data);
    if (jsonStr == _lastSavedState) return;
    _lastSavedState = jsonStr;
    
    try {
      final file = File('${_loadedSongDir!.path}/mix_state.json');
      file.writeAsStringSync(jsonStr);
    } catch (_) {}
  }

  void _closeMixer() {
    _saveMixState();
    _cancelCountIn();
    for (var t in _tracks) SoLoud.instance.setPause(t.handle, true);
    for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, true);
    setState(() => _activeSongDir = null);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        
        if (_isGigMode) {
          _toggleGigMode();
          return;
        }
        
        if (_activeSongDir != null) {
          _closeMixer();
          return;
        }
        
        if (_activePlaylist != null) {
          setState(() { _activePlaylist = null; });
          return;
        }
        
        final now = DateTime.now();
        if (_lastBackPressTime == null || now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Press back again to exit', textAlign: TextAlign.center, style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)), 
              duration: const Duration(seconds: 2), 
              backgroundColor: Colors.grey[900],
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              width: 250,
            ),
          );
          return;
        }
        
        SystemNavigator.pop();
      },
      child: _buildContent(context),
    );
  }

  
  void _toggleGigMode() {
    setState(() {
      _isGigMode = !_isGigMode;
    });
    if (_isGigMode) {
      WakelockPlus.enable();
      SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      WakelockPlus.disable();
      SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
  }

  Widget _buildContent(BuildContext context) {
    bool isPlaying = _tracks.isNotEmpty && !SoLoud.instance.getPause(_tracks.first.handle);
    String songName = _songMetadata?['song_name'] ?? 'Select a Song';

    if (_activeSongDir == null) {
      if (_activePlaylist != null) {
        // --- SPECIFIC SETLIST VIEW ---
        final pList = _playlists[_activePlaylist!]!;
        List<Map<String, dynamic>> setlistSongs = [];
        int missingCount = 0;
        
        for (String dirName in pList) {
          final match = _savedSongs.where((s) => (s['dir'] as Directory).path.endsWith(dirName)).toList();
          if (match.isNotEmpty) {
            setlistSongs.add(match.first);
          } else {
            missingCount++;
            setlistSongs.add({
              'isMissing': true,
              'title': dirName,
            });
          }
        }
        
        return Scaffold(
          appBar: AppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _activePlaylist = null),
            ),
            title: Text(_activePlaylist!, style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          body: Column(
            children: [
              if (missingCount > 0)
                Container(
                  color: Colors.redAccent.withValues(alpha: 0.1),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: Row(
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          "Missing $missingCount song(s) from this setlist. Download them from the Cloud.",
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _activePlaylist = null;
                            _libraryTabIndex = 2;
                          });
                        },
                        child: const Text("Go to Cloud", style: TextStyle(color: Colors.redAccent)),
                      )
                    ],
                  ),
                ),
              Expanded(
                child: pList.isEmpty 
                  ? const Center(child: Text("Setlist is empty.\nGo to 'Songs' to add some!", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
                  : ReorderableListView.builder(
                      itemCount: setlistSongs.length,
                      onReorder: (oldIndex, newIndex) {
                        setState(() {
                          if (newIndex > oldIndex) newIndex -= 1;
                          final item = _playlists[_activePlaylist!]!.removeAt(oldIndex);
                          _playlists[_activePlaylist!]!.insert(newIndex, item);
                          _savePlaylists();
                        });
                      },
                      itemBuilder: (context, index) {
                        final songData = setlistSongs[index];
                        
                        // ❌ MISSING SONG GHOST ITEM
                        if (songData['isMissing'] == true) {
                          final dirName = songData['title'] as String;
                          return ListTile(
                            key: ValueKey('missing_$dirName\_$index'),
                            contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                            leading: const CircleAvatar(backgroundColor: Colors.white10, child: Icon(Icons.cloud_off, color: Colors.grey)),
                            title: Text(dirName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.grey)),
                            subtitle: const Text("Not downloaded", style: TextStyle(color: Colors.redAccent)),
                            trailing: IconButton(
                              icon: const Icon(Icons.cloud_download_outlined, color: Colors.tealAccent),
                              tooltip: "Go to Cloud",
                              onPressed: () {
                                setState(() {
                                  _activePlaylist = null;
                                  _libraryTabIndex = 2; // Jump to cloud tab
                                });
                                Future.delayed(const Duration(milliseconds: 300), () {
                                  _cloudTabKey.currentState?.startDownloadByName(dirName);
                                });
                              },
                            ),
                            onLongPress: () {
                              showModalBottomSheet(
                                context: context,
                                backgroundColor: const Color(0xFF1A1A1A),
                                shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                                builder: (ctx) {
                                  return SafeArea(
                                    child: Wrap(
                                      children: [
                                        const Padding(
                                          padding: EdgeInsets.only(left: 32, top: 24, bottom: 16),
                                          child: Text("Missing Song Options", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
                                        ),
                                        ListTile(
                                          contentPadding: const EdgeInsets.only(left: 32, right: 24),
                                          leading: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                                          title: const Text('Remove from Setlist', style: TextStyle(color: Colors.redAccent)),
                                          onTap: () {
                                            Navigator.pop(ctx);
                                            setState(() {
                                              _playlists[_activePlaylist!]!.removeAt(index);
                                              _savePlaylists();
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              );
                            },
                          );
                        }

                        // ✅ LOCALLY AVAILABLE SONG ITEM
                        final dir = songData['dir'] as Directory;
                        final name = songData['title'] as String;
                        final subtitleText = songData['subtitle'] as String;
                  
                  final coverFile = File('${dir.path}/cover.jpg');
                  Widget leadingWidget = coverFile.existsSync()
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.file(coverFile, width: 50, height: 50, fit: BoxFit.cover),
                        )
                      : const CircleAvatar(backgroundColor: Colors.teal, child: Icon(Icons.music_note, color: Colors.white));

                  return ListTile(
                    key: ValueKey('${dir.path}_$index'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    leading: leadingWidget,
                    title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    subtitle: subtitleText.isNotEmpty ? Text(subtitleText, style: const TextStyle(color: Colors.grey)) : null,
                    trailing: ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 8.0, right: 8.0),
                        child: Icon(Icons.drag_handle, color: Colors.grey),
                      ),
                    ),
                    onTap: () => _openSong(dir),
                    onLongPress: () {
                      showModalBottomSheet(
                        context: context,
                        backgroundColor: const Color(0xFF1A1A1A),
                        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
                        builder: (ctx) {
                          return SafeArea(
                            child: Wrap(
                              children: [
                                const Padding(
                                  padding: EdgeInsets.only(left: 32, top: 24, bottom: 16),
                                  child: Text("Song Options", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.white)),
                                ),
                                ListTile(
                                  contentPadding: const EdgeInsets.only(left: 32, right: 24),
                                  leading: const Icon(Icons.remove_circle_outline, color: Colors.redAccent),
                                  title: const Text('Remove from Setlist', style: TextStyle(color: Colors.redAccent)),
                                  onTap: () {
                                    Navigator.pop(ctx);
                                    setState(() {
                                      _playlists[_activePlaylist!]!.removeAt(index);
                                      _savePlaylists();
                                    });
                                  },
                                ),
                              ],
                            ),
                          );
                        }
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      );
    }

    // --- MAIN LIBRARY TABS VIEW ---
      var filteredSongs = _savedSongs.where((s) => s['searchKey'].toString().contains(_searchQuery)).toList();
      if (_sortMode == 'A-Z') {
        filteredSongs.sort((a, b) => a['title'].toString().compareTo(b['title'].toString()));
      } else {
        filteredSongs.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
      }
      
      var filteredPlaylists = _playlists.keys.where((k) => k.toLowerCase().contains(_searchQuery)).toList();
      
      return Scaffold(
        appBar: AppBar(
          title: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: "Search library...",
              hintStyle: const TextStyle(color: Colors.white54),
              border: InputBorder.none,
              prefixIcon: const Icon(Icons.search, color: Colors.white),
              suffixIcon: _searchQuery.isNotEmpty
                ? IconButton(
                    icon: const Icon(Icons.clear, color: Colors.white),
                    onPressed: () {
                      _searchController.clear();
                      setState(() { _searchQuery = ""; });
                    },
                  )
                : null,
            ),
            style: const TextStyle(color: Colors.white, fontSize: 18),
            onChanged: (val) {
              setState(() { _searchQuery = val.toLowerCase(); });
              if (_searchQuery.isNotEmpty) {
                 var filtered = _savedSongs.where((s) => s['searchKey'].toString().contains(_searchQuery)).toList();
                 if (filtered.isNotEmpty) {
                    if (_sortMode == "A-Z") {
                      filtered.sort((a, b) => a['title'].toString().compareTo(b['title'].toString()));
                    } else {
                      filtered.sort((a, b) => b['timestamp'].compareTo(a['timestamp']));
                    }
                    final target = filtered.first['dir'] as Directory;
                    if (target.path != _loadedSongDir?.path) {
                       Future.microtask(() async {
                         final files = target.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.wav') || f.path.endsWith('.mp3') || f.path.endsWith('.flac')).toList();
                         for (var f in files) {
                           if (!_audioSourceCache.containsKey(f.path)) {
                             try {
                               final src = await SoLoud.instance.loadFile(f.path, mode: LoadMode.memory);
                               _audioSourceCache[f.path] = src;
                             } catch (_) {}
                           }
                         }
                       });
                    }
                 }
              }
            },
          ),
          actions: [
            if (_libraryTabIndex == 1)
              IconButton(
                icon: const Icon(Icons.cloud_upload_outlined, color: Colors.tealAccent),
                tooltip: "Export Setlists to Drive",
                onPressed: () {
                  _showExportDialog();
                },
              ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.sort),
              onSelected: (String result) {
                setState(() { _sortMode = result; });
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'Newest Added',
                  child: Text('Newest Added'),
                ),
                const PopupMenuItem<String>(
                  value: 'A-Z',
                  child: Text('A-Z'),
                ),
              ],
            ),
          ],
        ),
        body: Stack(
          children: [
            IndexedStack(
              index: _libraryTabIndex,
              children: [
                // TAB 0: SONGS
                _savedSongs.isEmpty
                  ? const Center(child: Text("No songs loaded.\nTap the button below to load a .zip!", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
                  : filteredSongs.isEmpty
                    ? const Center(child: Text("No songs match your search.", style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        itemCount: filteredSongs.length,
                        itemBuilder: (context, index) {
                          final songData = filteredSongs[index];
                          final dir = songData['dir'] as Directory;
                          final name = songData['title'] as String;
                          final subtitleText = songData['subtitle'] as String;
                          
                          final coverFile = File('${dir.path}/cover.jpg');
                          Widget leadingWidget = coverFile.existsSync()
                              ? ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.file(coverFile, width: 50, height: 50, fit: BoxFit.cover),
                                )
                              : const CircleAvatar(backgroundColor: Colors.teal, child: Icon(Icons.music_note, color: Colors.white));
      
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                            leading: leadingWidget,
                            title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                            subtitle: subtitleText.isNotEmpty ? Text(subtitleText, style: const TextStyle(color: Colors.grey)) : null,
                            trailing: IconButton(
                              icon: const Icon(Icons.more_vert, color: Colors.grey),
                              onPressed: () => _showLibrarySongOptions(dir, dir.path.split(Platform.pathSeparator).last),
                            ),
                            onTap: () => _openSong(dir),
                            onLongPress: () => _showLibrarySongOptions(dir, dir.path.split(Platform.pathSeparator).last),
                          );
                        },
                      ),
                      
                // TAB 1: SETLISTS
                Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      color: Colors.tealAccent.withValues(alpha: 0.05),
                      child: const Row(
                        children: [
                          Icon(Icons.info_outline, color: Colors.tealAccent, size: 20),
                          SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              "Pull down to sync collaborative setlists from your band's Google Drive.",
                              style: TextStyle(color: Colors.white70, fontSize: 13),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: RefreshIndicator(
                        color: Colors.tealAccent,
                        backgroundColor: const Color(0xFF1A1A1A),
                        onRefresh: () async {
                          if (_cloudTabKey.currentState != null) {
                            await _cloudTabKey.currentState!.fetchCloudSongs();
                          } else {
                            setState(() { _libraryTabIndex = 2; });
                            await Future.delayed(const Duration(milliseconds: 100));
                            if (_cloudTabKey.currentState != null) {
                              await _cloudTabKey.currentState!.fetchCloudSongs();
                            }
                            setState(() { _libraryTabIndex = 1; });
                          }
                        },
                        child: filteredPlaylists.isEmpty
                          ? ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                SizedBox(
                                  height: 400,
                                  child: Center(
                                    child: Text(_playlists.isEmpty ? "No Setlists created yet." : "No Setlists match your search.", style: const TextStyle(color: Colors.grey))
                                  ),
                                ),
                              ],
                            )
                          : ListView.builder(
                              physics: const AlwaysScrollableScrollPhysics(),



                            padding: const EdgeInsets.only(bottom: 80),
                            itemCount: filteredPlaylists.length,
                            itemBuilder: (context, index) {
                              final pName = filteredPlaylists[index];
                              final songCount = _playlists[pName]!.length;
                              return ListTile(
                                contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                leading: const CircleAvatar(
                                  backgroundColor: Colors.black26,
                                  child: Icon(Icons.queue_music, color: Colors.tealAccent),
                                ),
                                title: Text(pName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                                subtitle: Text("$songCount song${songCount == 1 ? '' : 's'}", style: const TextStyle(color: Colors.grey)),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.grey),
                                  onPressed: () async {
                                    bool confirm = await showDialog(
                                      context: context,
                                      builder: (ctx) => AlertDialog(
                                        backgroundColor: Colors.grey[900],
                                        title: const Text("Delete Setlist", style: TextStyle(color: Colors.white)),
                                        content: const Text("Are you sure you want to delete this setlist? Your separated songs will remain safely in your library.", style: TextStyle(color: Colors.grey, fontSize: 12)),
                                        actions: [
                                          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel", style: TextStyle(color: Colors.grey))),
                                          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Delete", style: TextStyle(color: Colors.redAccent))),
                                        ],
                                      ),
                                    ) ?? false;
                                    
                                    if (confirm) {
                                      setState(() {
                                        _playlists.remove(pName);
                                        _savePlaylists();
                                      });
                                    }
                                  },
                                ),
                                onTap: () => setState(() => _activePlaylist = pName),
                              );
                            },
                          ),
                        ),
                      ),
                  ],
                ),


                CloudLibraryTab(
                  key: _cloudTabKey,
                  downloadedFolderNames: _savedSongs.map((s) => (s['dir'] as Directory).path.split(Platform.pathSeparator).last).toSet(),
                  onSetlistsSynced: (Map<String, List<String>> newSetlists) {
                    setState(() {
                      bool changed = false;
                      newSetlists.forEach((key, value) {
                        _playlists[key] = value;
                        changed = true;
                      });
                      if (changed) {
                        _savePlaylists();
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Synced setlists from Google Drive!')));
                      }
                    });
                  },
                  onDownloadComplete: (zipFile) {
                    final filename = zipFile.path.split(Platform.pathSeparator).last;
                    final scaffold = ScaffoldMessenger.of(context);
                    _processZipFile(zipFile.path, filename).then((_) {
                      if (mounted) {
                        scaffold.showSnackBar(
                          const SnackBar(
                            content: Text('Song extracted and added to library!', textAlign: TextAlign.center), 
                            duration: Duration(seconds: 3), 
                          )
                        );
                      }
                      // Optional: delete the temp zip file after extracting
                      try { zipFile.deleteSync(); } catch (_) {}
                    });
                  },
                ),
              ],
            ),
            if (_isLibraryLoading)
              Container(
                color: Colors.black.withValues(alpha: 0.6),
                child: const Center(
                  child: CircularProgressIndicator(color: Colors.tealAccent),
                ),
              ),
          ],
        ),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _libraryTabIndex,
          onTap: (idx) => setState(() => _libraryTabIndex = idx),
          selectedItemColor: Colors.tealAccent,
          unselectedItemColor: Colors.grey,
          backgroundColor: Colors.black,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.music_note), label: "Songs"),
            BottomNavigationBarItem(icon: Icon(Icons.queue_music), label: "Setlists"),
            BottomNavigationBarItem(icon: Icon(Icons.cloud), label: "Cloud"),
            BottomNavigationBarItem(icon: Icon(Icons.mic), label: "Recordings"),
          ],
          type: BottomNavigationBarType.fixed,
        ),
        floatingActionButton: (_libraryTabIndex == 2 || _libraryTabIndex == 3)
          ? null 
          : _libraryTabIndex == 0 
          ? FloatingActionButton.extended(
              onPressed: _loadZipFile,
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              icon: const Icon(Icons.library_add),
              label: const Text("Import Song", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ) 
          : FloatingActionButton.extended(
              onPressed: _createPlaylist,
              elevation: 8,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              icon: const Icon(Icons.add),
              label: const Text("New Setlist", style: TextStyle(fontWeight: FontWeight.bold, letterSpacing: 1.2)),
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ),
      );
    }

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Colors.tealAccent)),
      );
    }
    if (_isGigMode) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: ValueListenableBuilder<double>(
          valueListenable: _currentPositionNotifier,
          builder: (context, pos, child) {
            double pulse = 0.0;
            if (_isMetronomeOn && isPlaying && pos > _firstBeat && _currentTempo > 0) {
              double interval = 60.0 / _currentTempo;
              double beats = (pos - _firstBeat) / interval;
              double beatFraction = beats - beats.floor();
              pulse = max(0.0, 1.0 - (beatFraction * 2.5)); // Slower, smoother fade
            }
            
            return GestureDetector(
              onDoubleTap: _togglePlayPause,
              behavior: HitTestBehavior.opaque,
              child: Container(
                color: Colors.tealAccent.withValues(alpha: pulse * 0.2),
                child: child,
              ),
            );
          },
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ValueListenableBuilder<int>(
                      valueListenable: _activeSectionNotifier,
                      builder: (context, activeIdx, child) {
                        String sectionText = "";
                        if (activeIdx >= 0 && activeIdx < _sections.length) {
                          sectionText = _sections[activeIdx]['name'];
                        }
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          child: Text(
                            sectionText, 
                            key: ValueKey<int>(activeIdx),
                            style: const TextStyle(color: Colors.tealAccent, fontSize: 24, fontWeight: FontWeight.bold)
                          ),
                        );
                      }
                    ),
                    ValueListenableBuilder<int>(
                      valueListenable: _activeChordNotifier,
                      builder: (context, activeIdx, child) {
                        String chordText = "-";
                        String nextChordText = "";
                        if (activeIdx >= 0 && activeIdx < _chords.length) {
                          chordText = _transposeChord(_chords[activeIdx]['chord'], _pitchShiftSemitones.toInt());
                          
                          for (int i = activeIdx + 1; i < _chords.length; i++) {
                            String candidate = _transposeChord(_chords[i]['chord'], _pitchShiftSemitones.toInt());
                            if (candidate != chordText) {
                              nextChordText = candidate;
                              break;
                            }
                          }
                        }
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 250),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          child: Column(
                            key: ValueKey<int>(activeIdx),
                            children: [
                              Text(chordText, style: const TextStyle(color: Colors.white, fontSize: 100, fontWeight: FontWeight.bold, height: 1.1)),
                              if (nextChordText.isNotEmpty)
                                Text("Next: $nextChordText", style: const TextStyle(color: Colors.white30, fontSize: 24, fontWeight: FontWeight.bold)),
                            ],
                          ),
                        );
                      }
                    ),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: _togglePlayPause,
                      child: Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(color: (_countInTimer?.isActive ?? false) ? Colors.tealAccent : Colors.white12, shape: BoxShape.circle),
                        child: Center(
                          child: (_countInTimer?.isActive ?? false) 
                            ? Text("${_countInClicks - _currentCountInTick}", style: const TextStyle(color: Colors.black, fontSize: 32, fontWeight: FontWeight.bold))
                            : Icon(
                                isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.tealAccent,
                                size: 40,
                              ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                top: 24,
                left: 24,
                bottom: 80,
                width: 250,
                child: Builder(
                  builder: (ctx) {
                    if (_activePlaylist == null || _loadedSongDir == null) return const SizedBox.shrink();
                    final pList = _playlists[_activePlaylist!];
                    if (pList == null || pList.isEmpty) return const SizedBox.shrink();
                    
                    String currentDirName = _loadedSongDir!.path.split(Platform.pathSeparator).last;
                    int currentIdx = pList.indexOf(currentDirName);
                    
                    double itemHeight = 24.0;
                    double offset = currentIdx > 2 ? (currentIdx - 2) * itemHeight : 0.0;
                    
                    return ListView.builder(
                      controller: ScrollController(initialScrollOffset: offset),
                      physics: const BouncingScrollPhysics(),
                      itemCount: pList.length,
                      itemBuilder: (context, index) {
                        bool isPast = index < currentIdx;
                        bool isCurrent = index == currentIdx;
                        
                        String songTitle = pList[index].replaceAll(RegExp(r'^\d+_'), '').replaceAll('.mp3', '');
                        
                        return SizedBox(
                          height: itemHeight,
                          child: Text(
                            "${index + 1}. $songTitle",
                            style: TextStyle(
                              color: isCurrent ? Colors.tealAccent : (isPast ? Colors.white24 : Colors.white70),
                              fontSize: isCurrent ? 14 : 12,
                              fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                              decoration: isPast ? TextDecoration.lineThrough : null,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    );
                  }
                ),
              ),
              Positioned(
                top: 20,
                right: 20,
                child: IconButton(
                  iconSize: 40,
                  icon: const Icon(Icons.close, color: Colors.white54),
                  onPressed: _toggleGigMode,
                ),
              ),
              Positioned(
                bottom: 32,
                left: 60,
                right: 60,
                child: ValueListenableBuilder<double>(
                  valueListenable: _currentPositionNotifier,
                  builder: (context, pos, child) {
                    return ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _songLength > 0 ? pos / _songLength : 0,
                        backgroundColor: Colors.white10,
                        valueColor: const AlwaysStoppedAnimation(Colors.tealAccent),
                        minHeight: 4,
                      ),
                    );
                  }
                )
              )
            ],
          ),
        )
      );
    }



    return Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.keyboard_arrow_down), 
            onPressed: _closeMixer,
          ),
          title: Column(
          children: [
            Text(songName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(_transposeKey(_songKey, _pitchShiftSemitones.toInt()), style: const TextStyle(color: Colors.tealAccent, fontSize: 12)),
          ]
        ),
          centerTitle: true,
          actions: [
            if (_isRecording)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: Text(
                    "${(_recordingSeconds ~/ 60).toString().padLeft(2, '0')}:${(_recordingSeconds % 60).toString().padLeft(2, '0')}",
                    style: const TextStyle(color: Colors.redAccent, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            IconButton(
              icon: Icon(
                _isRecording ? Icons.stop_circle : Icons.fiber_manual_record, 
                color: _isRecording ? Colors.redAccent : Colors.white70,
                size: _isRecording ? 32 : 28,
              ),
              onPressed: _toggleRecording,
            ),
            IconButton(
              icon: const Icon(Icons.more_vert),
              onPressed: _showMixerOptionsMenu,
            ),
          ],
        ),
        body: Column(
            children: [
              if (_isBouncing)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  color: Colors.tealAccent.withValues(alpha: 0.1),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.tealAccent, strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text("EXPORTING AUDIO...", style: TextStyle(color: Colors.tealAccent, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
                    ],
                  ),
                ),
              if (_showChords)
            SizedBox(
              height: 60,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  NotificationListener<ScrollNotification>(
                    onNotification: (ScrollNotification scrollInfo) {
                      if (scrollInfo is ScrollStartNotification && scrollInfo.dragDetails != null) {
                        _scrubGraceTimer?.cancel();
                        _isScrubbingChords = true;
                      } else if (scrollInfo is ScrollEndNotification && _isScrubbingChords) {
                        _scrubGraceTimer?.cancel();
                        _scrubGraceTimer = Timer(const Duration(seconds: 3), () {
                          if (mounted) setState(() => _isScrubbingChords = false);
                        });
                      }
                      return false;
                    },
                      child: SizedBox(
                        height: 60,
                        child: ListView.builder(
                          controller: _chordScrollController,
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: 24.0),
                          itemCount: _chords.length > 0 ? _chords.length + 2 : 0,
                          itemBuilder: (context, index) {
                             if (index == 0) {
                                double firstStart = (_chords[0]['time'] as num).toDouble();
                                return SizedBox(width: firstStart * 160.0);
                             }
                             if (index == _chords.length + 1) {
                                // Add a trailing spacer so the last chord doesn't hit a maxScrollExtent wall
                                return SizedBox(width: MediaQuery.of(context).size.width);
                             }
                             
                             int chordIdx = index - 1;
                             double start = (_chords[chordIdx]['time'] as num).toDouble();
                             double end;
                             if (chordIdx < _chords.length - 1) {
                               end = (_chords[chordIdx + 1]['time'] as num).toDouble();
                             } else {
                               // For the very last chord, extrapolate its duration based on the previous chord's duration
                               double prevDuration = chordIdx > 0 
                                   ? start - (_chords[chordIdx - 1]['time'] as num).toDouble() 
                                   : 2.0;
                               end = start + prevDuration;
                               if (end > _songLength) end = _songLength;
                             }
                             
                             if (end < start) end = start + 0.1;
                             double width = (end - start) * 160.0;
                             bool isDownbeat = (chordIdx % 4 == 0);
                             
                             return ValueListenableBuilder<int>(
                               valueListenable: _activeChordNotifier,
                               builder: (context, activeIndex, _) {
                                  bool isActive = chordIdx == activeIndex;
                                  
                                  return GestureDetector(
                                    onTap: () => _seekToChord(chordIdx),
                                    child: Container(
                                      width: width,
                                      decoration: BoxDecoration(
                                        color: isActive ? Colors.white : Colors.grey[900],
                                        border: Border(
                                          left: isDownbeat ? const BorderSide(color: Colors.white24, width: 2.0) : BorderSide.none,
                                          right: const BorderSide(color: Colors.black, width: 2.0),
                                          top: const BorderSide(color: Colors.black, width: 1.0),
                                          bottom: const BorderSide(color: Colors.black, width: 1.0),
                                        ),
                                      ),
                                      child: Center(
                                        child: Builder(
                                          builder: (context) {
                                            bool isRepeat = chordIdx > 0 && _chords[chordIdx]['chord'] == _chords[chordIdx - 1]['chord'];
                                            bool showText = !isRepeat || isDownbeat;
                                            bool isGrey = isRepeat && isDownbeat;
                                            
                                            if (!showText) return const SizedBox.shrink();
                                            
                                            return Padding(
                                              padding: const EdgeInsets.symmetric(horizontal: 8.0),
                                              child: FittedBox(
                                                fit: BoxFit.scaleDown,
                                                child: Text(
                                                  _transposeChord(_chords[chordIdx]['chord'] as String, _pitchShiftSemitones.toInt()),
                                                  style: TextStyle(
                                                    color: isActive 
                                                      ? (isGrey ? Colors.black54 : Colors.black) 
                                                      : (isGrey ? Colors.grey[600] : Colors.white),
                                                    fontSize: isActive ? 16 : 14,
                                                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal
                                                  )
                                                ),
                                              ),
                                            );
                                          }
                                        )
                                      )
                                    )
                                  );
                               }
                             );
                          }
                        )
                      ),
                    ),
                  ],
                ),
              ),
            if (_showChords)
            const SizedBox(height: 16),
          
          if (_showLyrics)
            Expanded(
                child: _lyrics.isEmpty 
                  ? const Center(child: Text("No lyrics found.", style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      controller: _lyricScrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 100),
                      itemExtent: 75.0,
                      itemCount: _lyrics.length,
                      itemBuilder: (context, index) {
                        return ValueListenableBuilder<int>(
                          valueListenable: _activeLyricNotifier,
                          builder: (context, activeIndex, _) {
                            bool isActive = index == activeIndex;
                            return GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () {
                                double start = _lyrics[index].time;
                                for (var t in _tracks) {
                                  SoLoud.instance.seek(t.handle, Duration(milliseconds: (start * 1000).toInt()));
                                }
                                for (var t in _metronomeTracks.values) {
                                  SoLoud.instance.seek(t.handle, Duration(milliseconds: (start * 1000).toInt()));
                                }
                                if (_countInTimer != null && _countInTimer!.isActive) {
                                  _countInTimer!.cancel();
                                  _countInTimer = null;
                                  for (var t in _tracks) SoLoud.instance.setPause(t.handle, false);
                                  for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, false);
                                }
                                _updateActiveChord(start);
                                _updateActiveSection(start);
                                _updateActiveLyric(start);
                                _currentPositionNotifier.value = start;
                              },
                              child: Container(
                                alignment: Alignment.center,
                                child: Text(
                                  _lyrics[index].text,
                                  style: TextStyle(
                                    fontSize: _lyrics[index].text == '♪' 
                                      ? (isActive ? 36 : 28) 
                                      : (isActive ? 22 : 16),
                                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                                    color: isActive ? Colors.tealAccent : Colors.grey[600],
                                  ),
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
            )
          else
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: _tracks.map((track) {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6.0),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 50,
                        height: 60,
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _getIconForTrack(track.name),
                            Padding(
                              padding: const EdgeInsets.only(top: 4.0),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Container(
                                    margin: const EdgeInsets.only(right: 2),
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: track.isSoloed ? Colors.tealAccent.withOpacity(0.2) : Colors.transparent,
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: track.isSoloed ? Colors.tealAccent : Colors.grey[800]!),
                                    ),
                                    child: Text("S", style: TextStyle(
                                      color: track.isSoloed ? Colors.tealAccent : Colors.grey[600], 
                                      fontSize: 10, 
                                      fontWeight: FontWeight.bold
                                    )),
                                  ),
                                  Container(
                                    margin: const EdgeInsets.only(left: 2),
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    decoration: BoxDecoration(
                                      color: track.isMuted ? Colors.redAccent.withOpacity(0.2) : Colors.transparent,
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: track.isMuted ? Colors.redAccent : Colors.grey[800]!),
                                    ),
                                    child: Text("M", style: TextStyle(
                                      color: track.isMuted ? Colors.redAccent : Colors.grey[600], 
                                      fontSize: 10, 
                                      fontWeight: FontWeight.bold
                                    )),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                          child: StatefulBuilder(
                            builder: (context, setSliderState) {
                              return LayoutBuilder(
                                builder: (context, constraints) {
                                  // Standard Flutter Slider padding is usually 24px on left and right.
                                  double trackWidth = constraints.maxWidth - 48.0;
                                  if (trackWidth < 0) trackWidth = 0;
                                  
                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      // 70% Baseline Marker
                                      Positioned(
                                        left: 24.0 + (trackWidth * 0.7),
                                        child: Container(
                                          width: 2,
                                          height: 12,
                                          color: Colors.white54,
                                        ),
                                      ),
                                      // Smooth Local Slider
                                      SliderTheme(
  data: SliderTheme.of(context).copyWith(
    trackHeight: 2.0,
    thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
    overlayShape: const RoundSliderOverlayShape(overlayRadius: 14.0),
  ),
  child: Slider(
                                        value: track.volume,
                                        min: 0.0,
                                        max: 1.0,
                                        onChanged: (val) {
                                          // Magnetic snap to the 70% baseline
                                          if ((val - 0.7).abs() < 0.03) {
                                            if (track.volume != 0.7) {
                                              HapticFeedback.selectionClick();
                                            }
                                            val = 0.7;
                                          }
                                          setSliderState(() { track.volume = val; });
                                          _updateTrackVolumes();
                                        },
                                      )
),
                                    ],
                                  );
                                }
                              );
                            }
                          )
                        ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.more_vert, color: Colors.grey),
                        onPressed: () => _showTrackOptions(track),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),

          const SizedBox(height: 48),
          if (_showSections)
            ValueListenableBuilder<int>(
              valueListenable: _activeSectionNotifier,
              builder: (context, activeSection, child) {
                return SingleChildScrollView(
                  controller: _sectionScrollController,
                  scrollDirection: Axis.horizontal,
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: _sections.asMap().entries.map((entry) {
                      var section = entry.value;
                      bool active = entry.key == activeSection;
                      return _buildSectionPill(section, active);
                    }).toList(),
                  ),
                );
              }
            ),
          if (_showSections)
            const SizedBox(height: 16),

          ValueListenableBuilder<double>(
            valueListenable: _currentPositionNotifier,
            builder: (context, val, child) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Slider(
                    value: max(0.0, min(val, _songLength)),
                    max: _songLength,
                    onChangeStart: (v){
                      _cancelCountIn();
                      setState(() => _isScrubbing = true);
                    },
                    onChanged: (v){
                      _updateActiveChord(v);
                      _updateActiveSection(v);
                      _currentPositionNotifier.value = v;
                        if (_showChords && _chordScrollController.hasClients) {
                          _chordScrollController.jumpTo(v * 160.0);
                        }
                    },
                    onChangeEnd: (v){
                      for (var t in _tracks) {
                        SoLoud.instance.seek(t.handle, Duration(milliseconds: (v * 1000).toInt()));
                      }
                      for (var t in _metronomeTracks.values) {
                        SoLoud.instance.seek(t.handle, Duration(milliseconds: (v * 1000).toInt()));
                      }
                      _isScrubbing = false;
                    },
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(_formatTime(max(0.0, val)), style: const TextStyle(color: Colors.grey)),
                        Text("-${_formatTime(max(0.0, _songLength - val))}", style: const TextStyle(color: Colors.grey)),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(Icons.timer_outlined, color: _isMetronomeOn ? Colors.tealAccent : Colors.white, size: 28), 
                onPressed: _showMetronomeMenu,
              ),
              
              Container(
                decoration: const BoxDecoration(color: Colors.white12, shape: BoxShape.circle),
                child: IconButton(
                  icon: const Icon(Icons.replay_10, color: Colors.white, size: 28),
                  onPressed: () => _seekBy(-10),
                ),
              ),
              
              GestureDetector(
                onTap: _togglePlayPause,
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(color: (_countInTimer?.isActive ?? false) ? Colors.tealAccent : Colors.white, shape: BoxShape.circle),
                  child: Center(
                    child: (_countInTimer?.isActive ?? false) 
                      ? Text("${_countInClicks - _currentCountInTick}", style: const TextStyle(color: Colors.black, fontSize: 32, fontWeight: FontWeight.bold))
                      : Icon(
                          isPlaying ? Icons.pause : Icons.play_arrow,
                          color: Colors.black,
                          size: 40,
                        ),
                  ),
                ),
              ),
              
              Container(
                decoration: const BoxDecoration(color: Colors.white12, shape: BoxShape.circle),
                child: IconButton(
                  icon: const Icon(Icons.forward_10, color: Colors.white, size: 28),
                  onPressed: () => _seekBy(10),
                ),
              ),
              
              IconButton(
                icon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Transform.translate(
                      offset: const Offset(2, 4),
                      child: const Text("\u266D", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                    Transform.translate(
                      offset: const Offset(-2, -4),
                      child: const Text("\u266F", style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    ),
                  ],
                ),
                onPressed: _showPitchMenu
              ), 
            ],
          ),
          const SizedBox(height: 32),
          
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildBottomToggleBtn(Icons.format_quote, _showLyrics, () {
                final wasOff = !_showLyrics;
                setState(() => _showLyrics = !_showLyrics);
                if (wasOff) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    final newIdx = _activeLyricNotifier.value;
                    if (newIdx >= 0 && _lyricScrollController.hasClients) {
                      double offset = max(0.0, (newIdx * 75.0) - 100.0);
                      _lyricScrollController.jumpTo(offset);
                    }
                  });
                }
              }),
              const SizedBox(width: 32),
              _buildBottomToggleBtn(Icons.queue_music, _showChords, () {
                setState(() => _showChords = !_showChords);
              }),
              const SizedBox(width: 32),
              _buildBottomToggleBtn(Icons.view_carousel, _showSections, () {
                final wasOff = !_showSections;
                setState(() => _showSections = !_showSections);
                if (wasOff) {
                  // Panel just opened — scroll to current section after layout.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    final idx = _activeSectionNotifier.value;
                    if (idx >= 0 && _sectionScrollController.hasClients) {
                      const double pillWidth = 120.0;
                      final double target = (idx * pillWidth) - 80.0;
                      _sectionScrollController.jumpTo(
                        target.clamp(0.0, _sectionScrollController.position.maxScrollExtent),
                      );
                    }
                  });
                }
              }),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildBottomToggleBtn(IconData icon, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: active ? Colors.tealAccent.withOpacity(0.1) : Colors.grey[900],
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? Colors.tealAccent : Colors.transparent),
        ),
        child: Icon(icon, color: active ? Colors.tealAccent : Colors.white, size: 24),
      ),
    );
  }

  Widget _buildSectionPill(Map<String, dynamic> section, bool active) {
    return GestureDetector(
      onTap: () {
        double start = (section['start_time'] as num).toDouble();
        for (var t in _tracks) {
          SoLoud.instance.seek(t.handle, Duration(milliseconds: (start * 1000).toInt()));
        }
        for (var t in _metronomeTracks.values) {
          SoLoud.instance.seek(t.handle, Duration(milliseconds: (start * 1000).toInt()));
        }
        _cancelCountIn();
        _updateActiveChord(start);
        _updateActiveSection(start);
        setState(() => _currentPositionNotifier.value = start);
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: active ? Colors.tealAccent.withValues(alpha: 0.2) : Colors.transparent,
          border: Border.all(color: active ? Colors.tealAccent : Colors.grey[800]!),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(section['name'] as String, style: TextStyle(fontWeight: FontWeight.bold, color: active ? Colors.tealAccent : Colors.white)),
      ),
    );
  }
}
