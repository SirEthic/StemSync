import 'package:flutter/material.dart';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/scheduler.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_soloud/flutter_soloud.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

class LyricLine {
  final double time;
  final String text;
  LyricLine({required this.time, required this.text});
}



void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const StemSyncApp());
}

class TrackData {
  final String name;
  final SoundHandle handle;
  final AudioSource source;
  final File file;
  double volume;

  TrackData({required this.name, required this.handle, required this.source, required this.file, this.volume = 1.0});
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
        scaffoldBackgroundColor: const Color(0xFF000000),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF000000),
          elevation: 0,
        ),
        sliderTheme: SliderThemeData(
          activeTrackColor: Colors.tealAccent,
          inactiveTrackColor: Colors.grey[800],
          thumbColor: Colors.grey[400],
          overlayColor: Colors.tealAccent.withOpacity(0.2),
          trackHeight: 4.0,
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
  bool _isLoading = false;
  
  List<TrackData> _tracks = [];
  Map<double, TrackData> _metronomeTracks = {};
  Map<String, dynamic>? _songMetadata;

  // Smart Metronome & Tempo State
  bool _isMetronomeOn = false;
  
  // View States
  bool _showChords = true;
  bool _showSections = true;
  bool _showLyrics = false;
  
  double _baseTempo = 120.0;
  double _currentTempo = 120.0;
  double _firstBeat = 0.0;
  double _metronomeVolume = 0.7;
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

  // Library State
  List<Directory> _savedSongs = [];
  bool _isLibraryLoading = true;
  Directory? _activeSongDir; // Used for UI state (null = library view)
  Directory? _loadedSongDir; // Used to track what is currently loaded in memory

  final List<String> _chromaticScale = ['C', 'C#', 'D', 'D#', 'E', 'F', 'F#', 'G', 'G#', 'A', 'A#', 'B'];

  // Count In State
  int _countInClicks = 0;
  Timer? _countInTimer;
  int _currentCountInTick = 0;
  AudioSource? _beepSource;
  
  // Bouncing State
  bool _isBouncing = false;
  
  
  

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeApp();
    
    _ticker = createTicker((elapsed) {
      if (!_isScrubbing && !_isScrubbingChords && _tracks.isNotEmpty && !SoLoud.instance.getPause(_tracks.first.handle)) {
         final actualPos = SoLoud.instance.getPosition(_tracks.first.handle).inMilliseconds / 1000.0;
         
         double current = _currentPositionNotifier.value;
         double diff = actualPos - current;
         
         if (diff.abs() > 0.5) { 
             // Hard snap only on manual seeking jumps (> 500ms)
             _currentPositionNotifier.value = actualPos;
         } else {
             // Exponential moving average: lerps 20% toward true audio clock per frame.
             // At 60fps, this flawlessly smooths out AAudio buffer chunking jitter.
             _currentPositionNotifier.value = current + (diff * 0.2);
         }
         
         final pos = _currentPositionNotifier.value;
         _updateActiveChord(pos);
         _updateActiveSection(pos);
         _updateActiveLyric(pos);
         
         if (pos >= _songLength - 0.05) {
             for (var t in _tracks) SoLoud.instance.setPause(t.handle, true);
             for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, true);
             _currentPositionNotifier.value = 0.0;
             _updateActiveChord(0.0);
             _updateActiveSection(0.0);
             setState(() {});
         }
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
      double env = exp(-t * 80.0);
      double sample = sin(2 * pi * 1000.0 * t) * env;
      buffer.setInt16(44 + i * 2, (sample * 32767).toInt(), Endian.little);
    }
    
    final docDir = await getApplicationDocumentsDirectory();
    final beepFile = File('${docDir.path}/beep.wav');
    await beepFile.writeAsBytes(buffer.buffer.asUint8List());
    
    _beepSource = await SoLoud.instance.loadFile(beepFile.path);
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
    String pitchFilter = "";
    if (_pitchShiftSemitones != 0.0) {
       int newRate = (44100 * pitchRatio).toInt();
       pitchFilter = "asetrate=$newRate,atempo=${1/pitchRatio},";
    }

    for (var track in activeTracks) {
      inputs += "-i \"${track.file.path}\" "; 
      
      double amp = track.volume;
      if (!track.name.toLowerCase().contains("metronome")) {
         amp = _getAmplitudeFromSlider(track.volume);
      } else {
         amp = _getAmplitudeFromSlider(_metronomeVolume);
      }
      
      filter += "[$index:a]${pitchFilter}volume=$amp[a$index]; ";
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

  void _togglePlayPause() {
    if (_tracks.isEmpty) return;

    if (_countInTimer != null && _countInTimer!.isActive) {
      _countInTimer!.cancel();
      _countInTimer = null;
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
        int intervalMs = (interval * 1000).toInt();
        setState(() {});

        // Pre-fire first tick
        _playBeep();
        _countInTimer = Timer.periodic(Duration(milliseconds: intervalMs), (timer) {
          _currentCountInTick++;
          if (_currentCountInTick >= _countInClicks) {
            timer.cancel();
            _countInTimer = null;
            for (var t in _tracks) SoLoud.instance.setPause(t.handle, false);
            for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, false);
            setState(() {});
          } else {
            _playBeep();
            setState(() {});
          }
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
        content: const Text("Are you sure you want to permanently delete this song and all its separated stems?", style: TextStyle(color: Colors.white70)),
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
    setState(() {
      _savedSongs = songsDir.listSync().whereType<Directory>().toList();
      _isLibraryLoading = false;
    });
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
    final RegExp timeRegExp = RegExp(r'\[(\d{2}):(\d{2}\.\d{2})\]');
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
    
    if (parsed.isNotEmpty && mounted) {
      setState(() => _lyrics = parsed);
    }
  }

  Future<void> _fetchLyricsFromLRCLIB(Directory targetDir, String songName, String? artistName) async {
    try {
      String query = songName;
      if (artistName != null && artistName.isNotEmpty) query += " $artistName";
      
      final uri = Uri.parse("https://lrclib.net/api/search?q=${Uri.encodeComponent(query)}");
      final response = await http.get(uri);
      
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
    String root = chord;
    String quality = "";
    
    if (chord.contains(" ")) {
      List<String> parts = chord.split(" ");
      root = parts[0];
      quality = parts[1];
    } else {
      bool isMinor = chord.endsWith("m");
      root = isMinor ? chord.substring(0, chord.length - 1) : chord;
      quality = isMinor ? "Minor" : "Major";
    }
    
    int idx = _chromaticScale.indexOf(root);
    if (idx == -1) return chord;
    
    int newIdx = (idx + semitones) % 12;
    if (newIdx < 0) newIdx += 12;
    
    String suffix = quality == "Minor" ? "m" : "";
    return "${_chromaticScale[newIdx]}$suffix";
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
    if (_countInTimer != null && _countInTimer!.isActive) {
      _countInTimer!.cancel();
      _countInTimer = null;
    }
    _updateActiveChord(start);
    _updateActiveSection(start);
    _currentPositionNotifier.value = start;
    if (_chordScrollController.hasClients) {
      _chordScrollController.jumpTo(start * 160.0);
    }
  }

  Widget _getIconForTrack(String filename) {
    final lower = filename.toLowerCase();
    if (lower.contains('vocal')) return const FaIcon(FontAwesomeIcons.microphoneLines, color: Colors.white, size: 22);
    if (lower.contains('drum')) return const FaIcon(FontAwesomeIcons.drum, color: Colors.white, size: 22);
    if (lower.contains('bass')) return const Icon(Icons.speaker_group_outlined, color: Colors.white, size: 24);
    if (lower.contains('guitar')) return const FaIcon(FontAwesomeIcons.guitar, color: Colors.white, size: 22);
    if (lower.contains('piano')) return const Icon(Icons.piano, color: Colors.white, size: 24);
    return const FaIcon(FontAwesomeIcons.music, color: Colors.white, size: 22);
  }

  Future<void> _loadZipFile() async {
    try {
      setState(() { _isLibraryLoading = true; });
      List<PlatformFile>? result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
      );

      if (result.isNotEmpty) {
        final file = File(result.single.path!);
        final bytes = file.readAsBytesSync();
        
        final docDir = await getApplicationDocumentsDirectory();
        final targetDir = Directory('${docDir.path}/songs/song_${DateTime.now().millisecondsSinceEpoch}');
        targetDir.createSync(recursive: true);

        final archive = ZipDecoder().decodeBytes(bytes);
        for (final archiveFile in archive) {
          if (archiveFile.isFile) {
            final data = archiveFile.content as List<int>;
            File('${targetDir.path}/${archiveFile.name}')
              ..createSync(recursive: true)
              ..writeAsBytesSync(data);
          }
        }
        await _loadLibrary();
      } else {
        setState(() { _isLibraryLoading = false; });
      }
    } catch (e) {
      setState(() { _isLibraryLoading = false; });
      debugPrint("Error extracting zip: $e");
    }
  }

  Future<void> _openSong(Directory targetDir) async {
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

      for (var t in _tracks) {
        SoLoud.instance.stop(t.handle);
        SoLoud.instance.disposeSource(t.source);
      }
      for (var t in _metronomeTracks.values) {
        SoLoud.instance.stop(t.handle);
        SoLoud.instance.disposeSource(t.source);
      }
      _metronomeTracks.clear();
      _tracks.clear();
      _songMetadata = null;
      _chords.clear();
      _sections.clear();
      _songKey = "Unknown";
      _pitchShiftSemitones = 0.0;
      SoLoud.instance.filters.pitchShiftFilter.semitones.value = 0.0;
      _lyrics.clear();
      _activeLyricNotifier.value = -1;

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
      } else if (_songMetadata != null && _songMetadata!['song_name'] != null) {
        // Run asynchronously without blocking the song open
        _fetchLyricsFromLRCLIB(targetDir, _songMetadata!['song_name'], _songMetadata!['artist']);
      }

      Map<String, double> savedVolumes = {};
      final mixStateFile = File('${targetDir.path}/mix_state.json');
      if (mixStateFile.existsSync()) {
        try {
          final data = jsonDecode(mixStateFile.readAsStringSync());
          if (data['volumes'] != null) {
            savedVolumes = Map<String, double>.from(data['volumes']);
          }
          if (data['pitchShift'] != null) _pitchShiftSemitones = (data['pitchShift'] as num).toDouble();
          if (data['tempo'] != null) {
            _currentTempo = (data['tempo'] as num).toDouble();
            _playbackSpeed = _currentTempo / _baseTempo;
          }
          if (data['metronomeVolume'] != null) _metronomeVolume = (data['metronomeVolume'] as num).toDouble();
          if (data['subdivision'] != null) _subdivision = (data['subdivision'] as num).toDouble();
          if (data['isMetronomeOn'] != null) _isMetronomeOn = data['isMetronomeOn'] as bool;
        } catch (_) {}
      }

      final audioFiles = targetDir.listSync(recursive: true).whereType<File>().where((f) => 
        f.path.endsWith('.wav') || f.path.endsWith('.mp3')
      ).toList();

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

      for (var audioFile in audioFiles) {
        final filename = audioFile.path.split(Platform.pathSeparator).last;
        final source = await SoLoud.instance.loadFile(audioFile.path);
        
        final handle = SoLoud.instance.play(source, paused: true, looping: true);
        SoLoud.instance.setProtectVoice(handle, true);
        
        if (filename.toLowerCase().contains('metronome')) {
           double sub = 1.0;
           if (filename.contains('0_5x')) sub = 0.5;
           if (filename.contains('2x')) sub = 2.0;
           
           double raw = (_isMetronomeOn && _subdivision == sub) ? _getAmplitudeFromSlider(_metronomeVolume) : 0.0;
           SoLoud.instance.setVolume(handle, raw);
           _metronomeTracks[sub] = TrackData(name: filename, handle: handle, source: source, file: audioFile, volume: _metronomeVolume);
        } else {
            double initialVol = savedVolumes.containsKey(filename) ? savedVolumes[filename]! : 0.7;
            SoLoud.instance.setVolume(handle, _getAmplitudeFromSlider(initialVol)); 
            _tracks.add(TrackData(name: filename, handle: handle, source: source, file: audioFile, volume: initialVol));
        }
        
        _songLength = SoLoud.instance.getLength(source).inMilliseconds / 1000.0;
        if (_songLength <= 0.0) _songLength = 1.0;
      }
      
      try {
        if (SoLoud.instance.filters.pitchShiftFilter.index == -1) {
          SoLoud.instance.filters.pitchShiftFilter.activate();
        }
      } catch (e) {
        debugPrint("Filter activate note: $e");
      }
      SoLoud.instance.filters.pitchShiftFilter.shift.value = 1.0;

      setState(() { _isLoading = false; });

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
    
    // Total shift must counteract the tempo speed-up AND apply the user's requested key transposition
    double tempoShift = 1.0 / _playbackSpeed;
    double keyShift = pow(2.0, _pitchShiftSemitones / 12.0).toDouble();
    SoLoud.instance.filters.pitchShiftFilter.shift.value = tempoShift * keyShift;
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
                              Slider(value: 0.5, onChanged: (v){}),
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
                            value: _currentTempo.clamp(max(10.0, _baseTempo - 30.0), min(300.0, _baseTempo + 30.0)),
                            min: max(10.0, _baseTempo - 30.0),
                            max: min(300.0, _baseTempo + 30.0),
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
      await SoLoud.instance.init();
    } catch (e) {
      debugPrint("Initial SoLoud init failed: $e");
      try {
        SoLoud.instance.deinit();
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 500));
      try {
        await SoLoud.instance.init();
      } catch (e2) {
        debugPrint("SoLoud completely failed to init: $e2");
      }
    }
    
    if (mounted) {
      _loadLibrary();
      _initBeep();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.detached) {
      _saveMixState();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _countInTimer?.cancel();
    for (var t in _tracks) {
      SoLoud.instance.stop(t.handle);
      SoLoud.instance.disposeSource(t.source);
    }
    for (var t in _metronomeTracks.values) {
      SoLoud.instance.stop(t.handle);
      SoLoud.instance.disposeSource(t.source);
    }
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
      'subdivision': _subdivision,
      'isMetronomeOn': _isMetronomeOn,
      'volumes': <String, double>{}
    };
    
    for (var t in _tracks) {
      data['volumes'][t.name] = t.volume;
    }
    
    try {
      final file = File('${_loadedSongDir!.path}/mix_state.json');
      file.writeAsStringSync(jsonEncode(data));
    } catch (_) {}
  }

  void _closeMixer() {
    _saveMixState();
    if (_countInTimer != null && _countInTimer!.isActive) {
      _countInTimer!.cancel();
      _countInTimer = null;
    }
    for (var t in _tracks) SoLoud.instance.setPause(t.handle, true);
    for (var t in _metronomeTracks.values) SoLoud.instance.setPause(t.handle, true);
    setState(() => _activeSongDir = null);
  }

  @override
  Widget build(BuildContext context) {
    bool isPlaying = _tracks.isNotEmpty && !SoLoud.instance.getPause(_tracks.first.handle);
    String songName = _songMetadata?['song_name'] ?? 'Select a Song';

    if (_activeSongDir == null) {
      return Scaffold(
        appBar: AppBar(title: const Text("StemSync Library", style: TextStyle(fontWeight: FontWeight.bold))),
        body: _isLibraryLoading 
          ? const Center(child: CircularProgressIndicator(color: Colors.tealAccent))
          : _savedSongs.isEmpty 
            ? const Center(child: Text("No songs loaded.\nTap the button below to load a .zip!", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)))
            : ListView.builder(
                itemCount: _savedSongs.length,
                itemBuilder: (context, index) {
                  final dir = _savedSongs[index];
                  String name = dir.path.split(Platform.pathSeparator).last;
                  final metaFile = File('${dir.path}/song_metadata.json');
                  if (metaFile.existsSync()) {
                    try {
                      final meta = jsonDecode(metaFile.readAsStringSync());
                      name = meta['song_name'] ?? name;
                    } catch (_) {}
                  }
                  return ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                    leading: const CircleAvatar(backgroundColor: Colors.teal, child: Icon(Icons.music_note, color: Colors.white)),
                    title: Text(name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.delete, color: Colors.grey),
                          onPressed: () => _deleteSong(dir),
                        ),
                        const Icon(Icons.chevron_right, color: Colors.grey),
                      ],
                    ),
                    onTap: () => _openSong(dir),
                  );
                },
              ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _loadZipFile,
          icon: const Icon(Icons.folder_zip),
          label: const Text("Load New .zip"),
          backgroundColor: Colors.tealAccent,
          foregroundColor: Colors.black,
        ),
      );
    }

    if (_isLoading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: Colors.tealAccent)),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _closeMixer();
      },
      child: Scaffold(
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
      ),
        body: Column(
            children: [
              if (_isBouncing)
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  color: Colors.blueAccent.withValues(alpha: 0.2),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.blueAccent, strokeWidth: 2)),
                      SizedBox(width: 12),
                      Text("EXPORTING AUDIO...", style: TextStyle(color: Colors.blueAccent, fontWeight: FontWeight.bold, letterSpacing: 1.5)),
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
                        if (_countInTimer != null && _countInTimer!.isActive) {
                          _countInTimer!.cancel();
                          _countInTimer = null;
                        }
                        setState(() => _isScrubbingChords = true);
                      } else if (scrollInfo is ScrollUpdateNotification && _isScrubbingChords) {
                        double newPos = scrollInfo.metrics.pixels / 160.0;
                        newPos = max(0.0, min(newPos, _songLength));
                        _updateActiveChord(newPos);
                        _updateActiveSection(newPos);
                        _currentPositionNotifier.value = newPos;
                      } else if (scrollInfo is ScrollEndNotification && _isScrubbingChords) {
                        _isScrubbingChords = false;
                        double newPos = scrollInfo.metrics.pixels / 160.0;
                        newPos = max(0.0, min(newPos, _songLength));
                        for (var t in _tracks) SoLoud.instance.seek(t.handle, Duration(milliseconds: (newPos * 1000).toInt()));
                        for (var t in _metronomeTracks.values) SoLoud.instance.seek(t.handle, Duration(milliseconds: (newPos * 1000).toInt()));
                      }
                      return true;
                    },
                      child: SizedBox(
                        height: 60,
                        child: ListView.builder(
                          controller: _chordScrollController,
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.symmetric(horizontal: 24.0),
                          itemCount: _chords.length > 0 ? _chords.length + 1 : 0,
                          itemBuilder: (context, index) {
                             if (index == 0) {
                                double firstStart = (_chords[0]['time'] as num).toDouble();
                                return SizedBox(width: firstStart * 160.0);
                             }
                             
                             int chordIdx = index - 1;
                             double start = (_chords[chordIdx]['time'] as num).toDouble();
                             double end = chordIdx < _chords.length - 1 ? (_chords[chordIdx + 1]['time'] as num).toDouble() : _songLength;
                             if (end < start) end = start;
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
                                            
                                            return Text(
                                              _transposeChord(_chords[chordIdx]['chord'] as String, _pitchShiftSemitones.toInt()),
                                              style: TextStyle(
                                                color: isActive 
                                                  ? (isGrey ? Colors.black54 : Colors.black) 
                                                  : (isGrey ? Colors.grey[600] : Colors.white),
                                                fontSize: isActive ? 24 : 18,
                                                fontWeight: isActive ? FontWeight.bold : FontWeight.normal
                                              )
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
                                _currentPositionNotifier.value = start;
                              },
                              child: Container(
                                alignment: Alignment.center,
                                child: Text(
                                  _lyrics[index].text,
                                  style: TextStyle(
                                    fontSize: isActive ? 22 : 16,
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
                  padding: const EdgeInsets.symmetric(vertical: 12.0),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 50,
                        child: Center(child: _getIconForTrack(track.name)),
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
                                      Slider(
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

                                          double amp;
                                          if (val <= 0.7) {
                                            // Smooth exponential fade-in up to YT Music baseline (+6dB amplitude = 2.0)
                                            double normalized = val / 0.7;
                                            amp = (normalized * normalized) * 2.0; 
                                          } else {
                                            // The remaining 30% adds exactly +3dB (1.412x amplitude multiplier)
                                            // Baseline = 2.0. Max = 2.0 * 1.412 = 2.824.
                                            double normalized = (val - 0.7) / 0.3;
                                            amp = 2.0 + (normalized * 0.824);
                                          }
                                          SoLoud.instance.setVolume(track.handle, amp);
                                          setSliderState(() { track.volume = val; });
                                        },
                                      ),
                                    ],
                                  );
                                }
                              );
                            }
                          )
                        ),
                      const SizedBox(width: 8),
                      const Icon(Icons.more_vert, color: Colors.grey),
                    ],
                  ),
                );
              }).toList(),
            ),
          ),

          if (_showSections)
            ValueListenableBuilder<int>(
              valueListenable: _activeSectionNotifier,
              builder: (context, activeSection, child) {
                return SingleChildScrollView(
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
                      if (_countInTimer != null && _countInTimer!.isActive) {
                        _countInTimer!.cancel();
                        _countInTimer = null;
                      }
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
          const SizedBox(height: 16),

          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              IconButton(
                icon: Icon(Icons.timer_outlined, color: _isMetronomeOn ? Colors.tealAccent : Colors.white, size: 28), 
                onPressed: _showMetronomeMenu,
              ),
              IconButton(
                icon: Icon(Icons.onetwothree, color: _countInClicks > 0 ? Colors.tealAccent : Colors.white, size: 32), 
                onPressed: _showCountInMenu,
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
              
              IconButton(
                icon: Icon(Icons.ios_share, color: _isBouncing ? Colors.blueAccent : Colors.white, size: 28),
                onPressed: _isBouncing ? null : _exportMix,
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
          const SizedBox(height: 24),
          
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildBottomToggleBtn(Icons.format_quote, _showLyrics, () {
                setState(() => _showLyrics = !_showLyrics);
              }),
              const SizedBox(width: 32),
              _buildBottomToggleBtn(Icons.queue_music, _showChords, () {
                setState(() => _showChords = !_showChords);
              }),
              const SizedBox(width: 32),
              _buildBottomToggleBtn(Icons.view_carousel, _showSections, () {
                setState(() => _showSections = !_showSections);
              }),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    ));
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
        if (_countInTimer != null && _countInTimer!.isActive) {
          _countInTimer!.cancel();
          _countInTimer = null;
        }
        _updateActiveChord(start);
        _updateActiveSection(start);
        setState(() => _currentPositionNotifier.value = start);
      },
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
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
