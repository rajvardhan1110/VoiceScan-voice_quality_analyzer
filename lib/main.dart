import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:audio_streamer/audio_streamer.dart';
import 'package:record/record.dart'; 
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path_provider/path_provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:share_plus/share_plus.dart';
import 'package:intl/intl.dart';

void main() => runApp(const MaterialApp(home: VoiceHomePage(), debugShowCheckedModeBanner: false));

class VoiceHomePage extends StatefulWidget {
  const VoiceHomePage({super.key});
  @override
  State<VoiceHomePage> createState() => _VoiceHomePageState();
}


class _VoiceHomePageState extends State<VoiceHomePage> {
  Interpreter? _interpreter;
  StreamSubscription<List<double>>? _audioSub;
  final List<double> _aiBuffer = [];
  final AudioRecorder _originalRecorder = AudioRecorder();
  final AudioPlayer _audioPlayer = AudioPlayer();
  
  bool _isRecording = false;
  bool _isOverallSafe = true; 
  String _statusText = "Ready";
  String _currentClassName = "Silence";
  double _currentAmplitude = 0.0;
  List<bool> _safeHistory = []; 
  List<Map<String, dynamic>> _recordings = [];
  String? _playingPath;

  final Set<int> _safeClasses = {0,1,2,3,4,5,12,13,14,62,63,104,132};

  @override
  void initState() {
    super.initState();
    _initAI();
    _audioPlayer.onPlayerStateChanged.listen((s) {
      if (s == PlayerState.completed) setState(() => _playingPath = null);
    });
  }

  Future<void> _initAI() async {
    await Permission.microphone.request();
    _interpreter = await Interpreter.fromAsset('assets/models/yamnet.tflite');
  }

  Future<void> _startDualRecording() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = "${dir.path}/rec_${DateTime.now().millisecondsSinceEpoch}.m4a";

    setState(() {
      _isRecording = true;
      _isOverallSafe = true;
      _safeHistory.clear();
      _aiBuffer.clear();
      _statusText = "Monitoring...";
    });

    await _originalRecorder.start(const RecordConfig(), path: path);

    _audioSub = AudioStreamer().audioStream.listen((samples) {
      double maxAmp = samples.fold(0.0, (prev, e) => max(prev, e.abs()));
      setState(() => _currentAmplitude = maxAmp);

      _aiBuffer.addAll(samples);

      if (_aiBuffer.length >= 15600) {
        _runAI(Float32List.fromList(_aiBuffer.sublist(0, 15600)));
        _aiBuffer.removeRange(0, 15600);
      }
    });
  }

  Future<void> _stopDualRecording() async {
    _audioSub?.cancel();
    final path = await _originalRecorder.stop();

    int safeCount = _safeHistory.where((val) => val).length;
    double safePercent = _safeHistory.isEmpty ? 0 : (safeCount / _safeHistory.length) * 100;

    bool sessionSafe = safePercent > 75;

    setState(() {
      _isRecording = false;
      _isOverallSafe = sessionSafe;
      _statusText = sessionSafe ? "✅ Good Quality" : "❌ Poor Quality";

      if (path != null) {
        _recordings.insert(0, {
          "path": path,
          "time": DateFormat('hh:mm a').format(DateTime.now()),
          "safePercent": safePercent.toInt(),
          "isSafe": sessionSafe
        });
      }
    });
  }

  void _runAI(Float32List input) {
    if (_interpreter == null) return;

    var output = [List.filled(521, 0.0)];
    _interpreter!.run(input, output);

    double prob = output[0].reduce(max);
    int idx = output[0].indexOf(prob);

    bool isSilence = _currentAmplitude < 0.10;
    bool isTooLoud = _currentAmplitude > 0.55;
    bool isClassSafe = _safeClasses.contains(idx);

    bool isSafeNow;
    if (isSilence) {
      isSafeNow = true;
    } else if (isTooLoud) {
      isSafeNow = false;
    } else {
      isSafeNow = isClassSafe;
    }

    _safeHistory.add(isSafeNow);

    setState(() {
      _currentClassName = _getName(idx);

      if (_isRecording) {
        if (isTooLoud) {
          _statusText = "⚠️ TOO LOUD";
        } else if (isSilence) {
          _statusText = "🔇 SILENT";
        } else {
          _statusText = isSafeNow ? "✅ Good Quality" : "❌ Poor Quality";
        }
      }
    });
  }

  String _getName(int i) {
    Map<int, String> names = {
      0: "Speech",
      6: "SHOUTING",
      7: "YELLING",
      13: "Laughter",
      62: "Crowded Noise",
      137: "Music"
    };
    return names[i] ?? "Sound ($i)";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _isRecording
                    ? [Color(0xFF232526), Color(0xFF414345)]
                    : (_isOverallSafe
                        ? [Color(0xFF0B3D2E), Color(0xFF1F7A5C)]
                        : [Color(0xFF8E0E00), Color(0xFF1F1C18)]),
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          Center(
            child: Opacity(
              opacity: 0.12,
              child: Image.asset(
                "assets/ic_launcher.png",
                scale: 0.4
                // fit: BoxFit.cover,
              ),
            ),
          ),

          Column(
            children: [
              const SizedBox(height: 60),

              Container(
                margin: const EdgeInsets.symmetric(horizontal: 20),
                padding: const EdgeInsets.all(25),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(25),
                  border: Border.all(color: Colors.white24),
                ),
                child: Column(
                  children: [
                    Text(_statusText,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),

                    Text("Detected: $_currentClassName",
                        style: const TextStyle(color: Colors.white70)),

                    const SizedBox(height: 20),

                    LinearProgressIndicator(
                      value: _currentAmplitude * 1.5,
                      minHeight: 12,
                      backgroundColor: Colors.white12,
                      color: _currentAmplitude > 0.55
                          ? Colors.red
                          : Colors.greenAccent,
                    ),

                    const SizedBox(height: 10),
                    Text("VOL: ${(_currentAmplitude * 100).toInt()}%",
                        style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),

              const SizedBox(height: 40),

              GestureDetector(
                onTap: _isRecording ? _stopDualRecording : _startDualRecording,
                child: Container(
                  padding: const EdgeInsets.all(25),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isRecording ? Colors.redAccent : Colors.blueAccent,
                  ),
                  child: Icon(
                    _isRecording ? Icons.stop : Icons.mic,
                    size: 50,
                    color: Colors.white,
                  ),
                ),
              ),

              const SizedBox(height: 20),

              const Text("SESSION HISTORY",
                  style: TextStyle(color: Colors.white54)),

              Expanded(
                child: ListView.builder(
                  itemCount: _recordings.length,
                  itemBuilder: (context, i) {
                    final rec = _recordings[i];
                    bool isPlaying = _playingPath == rec['path'];

                    return ListTile(
                      title: Text("${rec['safePercent']}% Clarity",
                          style: const TextStyle(color: Colors.white)),
                      subtitle: Text(rec['time'],
                          style: const TextStyle(color: Colors.white38)),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(isPlaying ? Icons.stop : Icons.play_arrow, color: Colors.blueAccent),
                            onPressed: () async {
                              if (isPlaying) {
                                await _audioPlayer.stop();
                                setState(() => _playingPath = null);
                              } else {
                                await _audioPlayer.play(DeviceFileSource(rec['path']));
                                setState(() => _playingPath = rec['path']);
                              }
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.share, color: Colors.white70),
                            onPressed: () => Share.shareXFiles([XFile(rec['path'])]),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}