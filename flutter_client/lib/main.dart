import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';

// ─── ENTRY POINT ────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(WatchdogApp(cameras: cameras));
}

// ─── FOREGROUND TASK HANDLER ─────────────────────────────────────────────────
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(StreamTaskHandler());
}

class StreamTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {}

  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {}

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {}
}

// ─── APP ─────────────────────────────────────────────────────────────────────
class WatchdogApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const WatchdogApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Watchdog Donor',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00FF9D), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF030608),
        useMaterial3: true,
      ),
      home: DonorScreen(cameras: cameras),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ─── DONOR SCREEN ─────────────────────────────────────────────────────────────
class DonorScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const DonorScreen({super.key, required this.cameras});

  @override
  State<DonorScreen> createState() => _DonorScreenState();
}

class _DonorScreenState extends State<DonorScreen> with WidgetsBindingObserver {
  // Settings
  final _serverController = TextEditingController(text: 'https://your-server.onrender.com');
  final _donorIdController = TextEditingController(text: 'donor-1');

  // Camera
  CameraController? _cam;
  bool _streaming = false;
  bool _torchOn = false;
  int _framesPerSecond = 0;
  int _frameCount = 0;
  Timer? _fpsTimer;
  Timer? _frameTimer;

  // WebSocket (command channel)
  IOWebSocketChannel? _ws;
  bool _wsConnected = false;

  // Audio
  final _recorder = AudioRecorder();
  final _player = AudioPlayer();
  bool _audioEnabled = false;
  IOWebSocketChannel? _audioWs;

  // Status
  String _status = 'Остановлен';
  Color _statusColor = Colors.grey;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initForegroundTask();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    super.dispose();
  }

  // ── FOREGROUND TASK SETUP ───────────────────────────────────────────────
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'watchdog_stream',
        channelName: 'Watchdog Stream',
        channelDescription: 'Стрим видео на сервер активен',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  // ── PERMISSIONS ─────────────────────────────────────────────────────────
  Future<bool> _requestPermissions() async {
    final permissions = [
      Permission.camera,
      Permission.microphone,
      Permission.notification,
    ];

    for (final perm in permissions) {
      final status = await perm.request();
      if (status.isDenied) return false;
    }

    // Battery optimization
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }

    return true;
  }

  // ── CAMERA INIT ─────────────────────────────────────────────────────────
  Future<void> _initCamera() async {
    if (widget.cameras.isEmpty) return;
    _cam = CameraController(
      widget.cameras.first,
      ResolutionPreset.medium,
      imageFormatGroup: ImageFormatGroup.jpeg,
      enableAudio: false,
    );
    await _cam!.initialize();
    setState(() {});
  }

  // ── START STREAM ────────────────────────────────────────────────────────
  Future<void> _startStream() async {
    final ok = await _requestPermissions();
    if (!ok) {
      _showSnack('Нет разрешений!');
      return;
    }

    setState(() {
      _status = 'Запуск...';
      _statusColor = Colors.yellow;
    });

    // WakeLock
    await WakelockPlus.enable();

    // Foreground service
    await FlutterForegroundTask.startService(
      notificationTitle: 'Watchdog — стрим активен',
      notificationText: 'Видео передаётся на сервер',
      callback: startCallback,
    );

    // Camera
    await _initCamera();

    // WebSocket command channel
    _connectWebSocket();

    // Frame sending loop
    _streaming = true;
    _frameCount = 0;

    // FPS counter
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() { _framesPerSecond = _frameCount; _frameCount = 0; });
    });

    // Frame capture loop (~15 fps)
    _frameTimer = Timer.periodic(const Duration(milliseconds: 67), (_) {
      if (_streaming) _captureAndSend();
    });

    // Audio if enabled
    if (_audioEnabled) _startAudio();

    setState(() {
      _status = 'Стримит...';
      _statusColor = const Color(0xFF00FF9D);
      _streaming = true;
    });
  }

  // ── STOP STREAM ─────────────────────────────────────────────────────────
  Future<void> _stopStream() async {
    _streaming = false;
    _frameTimer?.cancel();
    _fpsTimer?.cancel();
    _ws?.sink.close();
    _audioWs?.sink.close();
    await _cam?.dispose();
    _cam = null;
    await WakelockPlus.disable();
    await FlutterForegroundTask.stopService();
    await _recorder.stop();

    setState(() {
      _status = 'Остановлен';
      _statusColor = Colors.grey;
      _wsConnected = false;
      _framesPerSecond = 0;
    });
  }

  // ── WEBSOCKET ────────────────────────────────────────────────────────────
  void _connectWebSocket() {
    final server = _serverController.text.trim();
    final donorId = _donorIdController.text.trim();
    final wsUrl = server.replaceAll('https://', 'wss://').replaceAll('http://', 'ws://');

    try {
      _ws = IOWebSocketChannel.connect('$wsUrl/donor?donorId=${Uri.encodeComponent(donorId)}');
      setState(() => _wsConnected = true);

      _ws!.stream.listen(
        (data) {
          try {
            final msg = jsonDecode(data as String) as Map<String, dynamic>;
            _handleServerCommand(msg);
          } catch (_) {}
        },
        onDone: () {
          setState(() => _wsConnected = false);
          // Reconnect after 3s if still streaming
          if (_streaming) {
            Future.delayed(const Duration(seconds: 3), _connectWebSocket);
          }
        },
        onError: (_) {
          setState(() => _wsConnected = false);
          if (_streaming) {
            Future.delayed(const Duration(seconds: 3), _connectWebSocket);
          }
        },
      );
    } catch (e) {
      setState(() => _wsConnected = false);
    }
  }

  void _handleServerCommand(Map<String, dynamic> msg) {
    final cmd = msg['cmd'] as String?;
    switch (cmd) {
      case 'torch':
        final state = msg['state'] as String?;
        _setTorch(state == 'on');
        break;
      case 'stopStream':
        _stopStream();
        break;
      case 'startStream':
        if (!_streaming) _startStream();
        break;
      case 'audio_from_observer':
        // Play audio from observer
        final audioData = msg['data'] as String?;
        if (audioData != null) _playObserverAudio(audioData);
        break;
    }
  }

  // ── FRAME CAPTURE ────────────────────────────────────────────────────────
  Future<void> _captureAndSend() async {
    if (_cam == null || !_cam!.value.isInitialized) return;
    try {
      final xFile = await _cam!.takePicture();
      final bytes = await xFile.readAsBytes();
      await _sendFrame(bytes);
      _frameCount++;
    } catch (_) {}
  }

  Future<void> _sendFrame(Uint8List jpeg) async {
    final server = _serverController.text.trim();
    final donorId = _donorIdController.text.trim();
    try {
      await http.post(
        Uri.parse('$server/stream/frame?donorId=${Uri.encodeComponent(donorId)}'),
        headers: {'Content-Type': 'image/jpeg'},
        body: jpeg,
      ).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  // ── TORCH ────────────────────────────────────────────────────────────────
  Future<void> _setTorch(bool on) async {
    try {
      await _cam?.setFlashMode(on ? FlashMode.torch : FlashMode.off);
      setState(() => _torchOn = on);
    } catch (_) {}
  }

  // ── AUDIO ────────────────────────────────────────────────────────────────
  void _startAudio() {
    final server = _serverController.text.trim();
    final donorId = _donorIdController.text.trim();
    final wsUrl = server.replaceAll('https://', 'wss://').replaceAll('http://', 'ws://');

    _audioWs = IOWebSocketChannel.connect('$wsUrl/observer/audio?donorId=${Uri.encodeComponent(donorId)}');

    // Start recording and stream audio
    _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
    )).then((stream) {
      stream.listen((chunk) {
        if (_audioWs != null) {
          final b64 = base64Encode(chunk);
          _audioWs!.sink.add(jsonEncode({'type': 'audio', 'data': b64}));
        }
      });
    }).catchError((_) {});
  }

  void _playObserverAudio(String base64Data) {
    try {
      final bytes = base64Decode(base64Data);
      _player.play(BytesSource(bytes));
    } catch (_) {}
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: Scaffold(
        backgroundColor: const Color(0xFF030608),
        appBar: AppBar(
          backgroundColor: const Color(0xFF080D10),
          title: const Text(
            'WATCHDOG DONOR',
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 16,
              letterSpacing: 4,
              color: Color(0xFF00FF9D),
            ),
          ),
          actions: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                border: Border.all(color: _wsConnected ? const Color(0xFF00FF9D) : Colors.grey),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _wsConnected ? 'ОНЛАЙН' : 'ОФФЛАЙН',
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11,
                  color: _wsConnected ? const Color(0xFF00FF9D) : Colors.grey,
                ),
              ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Camera preview
              if (_cam != null && _cam!.value.isInitialized)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(
                    children: [
                      AspectRatio(
                        aspectRatio: 4 / 3,
                        child: CameraPreview(_cam!),
                      ),
                      // REC overlay
                      if (_streaming)
                        Positioned(
                          top: 8, left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.red.withOpacity(0.85),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.fiber_manual_record, color: Colors.white, size: 10),
                                SizedBox(width: 4),
                                Text('REC', style: TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 11, letterSpacing: 2)),
                              ],
                            ),
                          ),
                        ),
                      Positioned(
                        top: 8, right: 8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          color: Colors.black54,
                          child: Text(
                            '$_framesPerSecond FPS',
                            style: const TextStyle(color: Color(0xFF00FF9D), fontFamily: 'monospace', fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Container(
                  height: 200,
                  decoration: BoxDecoration(
                    color: const Color(0xFF080D10),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF1A2830)),
                  ),
                  child: const Center(
                    child: Text('КАМЕРА НЕ АКТИВНА', style: TextStyle(fontFamily: 'monospace', color: Color(0xFF4A6070), letterSpacing: 2)),
                  ),
                ),

              const SizedBox(height: 16),

              // Status
              _StatusChip(label: _status, color: _statusColor),
              const SizedBox(height: 16),

              // Server settings
              _SectionTitle('НАСТРОЙКИ СЕРВЕРА'),
              const SizedBox(height: 8),
              _DarkTextField(controller: _serverController, hint: 'URL сервера', icon: Icons.cloud),
              const SizedBox(height: 8),
              _DarkTextField(controller: _donorIdController, hint: 'ID донора', icon: Icons.devices),
              const SizedBox(height: 16),

              // Audio toggle
              _SectionTitle('ДВУСТОРОННИЙ ЗВУК'),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Передавать аудио', style: TextStyle(color: Color(0xFFB8CDD4))),
                  const Spacer(),
                  Switch(
                    value: _audioEnabled,
                    activeColor: const Color(0xFF00FF9D),
                    onChanged: (v) => setState(() => _audioEnabled = v),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Main controls
              _SectionTitle('УПРАВЛЕНИЕ'),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _BigButton(
                      label: _streaming ? 'СТОП' : 'СТАРТ',
                      color: _streaming ? Colors.red : const Color(0xFF00FF9D),
                      icon: _streaming ? Icons.stop : Icons.play_arrow,
                      onTap: _streaming ? _stopStream : _startStream,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _BigButton(
                      label: _torchOn ? 'ФОНАРЬ ВЫКЛ' : 'ФОНАРЬ ВКЛ',
                      color: const Color(0xFFFFCC00),
                      icon: _torchOn ? Icons.flashlight_off : Icons.flashlight_on,
                      onTap: () => _setTorch(!_torchOn),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 24),
              _InfoBox(
                items: {
                  'WakeLock': _streaming ? 'АКТИВЕН' : 'ВЫКЛ',
                  'Foreground': _streaming ? 'АКТИВЕН' : 'ВЫКЛ',
                  'WebSocket': _wsConnected ? 'ПОДКЛЮЧЁН' : 'ОТКЛ',
                  'Звук': _audioEnabled ? 'ВКЛ' : 'ВЫКЛ',
                  'FPS': '$_framesPerSecond',
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── WIDGETS ──────────────────────────────────────────────────────────────────
class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);
  @override
  Widget build(BuildContext context) {
    return Text(text, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Color(0xFF4A6070), letterSpacing: 3));
  }
}

class _StatusChip extends StatelessWidget {
  final String label; final Color color;
  const _StatusChip({required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
        color: color.withOpacity(0.08),
      ),
      child: Text(label, style: TextStyle(fontFamily: 'monospace', color: color, fontSize: 13, letterSpacing: 2)),
    );
  }
}

class _DarkTextField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final IconData icon;
  const _DarkTextField({required this.controller, required this.hint, required this.icon});
  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13, color: Color(0xFFB8CDD4)),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: const Color(0xFF4A6070), size: 18),
        hintText: hint,
        hintStyle: const TextStyle(color: Color(0xFF2A3840)),
        filled: true,
        fillColor: const Color(0xFF080D10),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFF1A2830))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: Color(0xFF00FF9D))),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      ),
    );
  }
}

class _BigButton extends StatelessWidget {
  final String label; final Color color; final IconData icon; final VoidCallback onTap;
  const _BigButton({required this.label, required this.color, required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: color),
          borderRadius: BorderRadius.circular(6),
          color: color.withOpacity(0.1),
        ),
        child: Column(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(height: 6),
            Text(label, style: TextStyle(fontFamily: 'monospace', color: color, fontSize: 12, letterSpacing: 2)),
          ],
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final Map<String, String> items;
  const _InfoBox({required this.items});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF080D10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1A2830)),
      ),
      child: Column(
        children: items.entries.map((e) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Text(e.key, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF4A6070))),
              const Spacer(),
              Text(e.value, style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFFB8CDD4))),
            ],
          ),
        )).toList(),
      ),
    );
  }
}
