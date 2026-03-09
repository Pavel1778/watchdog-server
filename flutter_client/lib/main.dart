import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/io.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;

// ─── FOREGROUND TASK ──────────────────────────────────────────────
@pragma('vm:entry-point')
void startCallback() => FlutterForegroundTask.setTaskHandler(_StreamHandler());

class _StreamHandler extends TaskHandler {
  @override Future<void> onStart(DateTime t, SendPort? p) async {}
  @override Future<void> onRepeatEvent(DateTime t, SendPort? p) async {}
  @override Future<void> onDestroy(DateTime t, SendPort? p) async {}
}

// ─── JPEG ENCODE ISOLATE ──────────────────────────────────────────
// Encodes CameraImage (YUV420/BGRA) → JPEG bytes in a separate isolate
Future<Uint8List?> encodeJpeg(CameraImage image) async {
  return await Isolate.run(() => _encodeJpegSync(image));
}

Uint8List? _encodeJpegSync(CameraImage image) {
  try {
    // For Android YUV_420_888 / iOS BGRA8888
    // We use the fact that camera plugin provides a JPEG plane on some devices,
    // otherwise we pass raw bytes and let the server handle it (fallback).
    // Best approach: use the first plane as-is if format is JPEG-compatible.
    if (image.format.group == ImageFormatGroup.jpeg) {
      return Uint8List.fromList(image.planes[0].bytes);
    }
    // For YUV420: return raw Y plane (greyscale fast fallback)
    // Full YUV→JPEG requires native code; we use http multipart instead
    return null;
  } catch (_) {
    return null;
  }
}

// ─── MAIN ─────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep portrait, prevent auto-rotate stutters
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  final cameras = await availableCameras();
  runApp(WatchdogApp(cameras: cameras));
}

class WatchdogApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const WatchdogApp({super.key, required this.cameras});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Watchdog Donor',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF030608),
      colorScheme: ColorScheme.dark(primary: const Color(0xFF00FF9D)),
      useMaterial3: true,
    ),
    home: DonorScreen(cameras: cameras),
  );
}

// ─── DONOR SCREEN ─────────────────────────────────────────────────
class DonorScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const DonorScreen({super.key, required this.cameras});
  @override State<DonorScreen> createState() => _DonorScreenState();
}

class _DonorScreenState extends State<DonorScreen> with WidgetsBindingObserver {
  // Controllers
  final _serverCtrl = TextEditingController(text: 'https://watchdog-server.onrender.com');
  final _roomCtrl   = TextEditingController(text: 'room-1');
  final _pinCtrl    = TextEditingController(text: '1234');

  // Camera
  CameraController? _cam;
  bool _camStreaming = false; // imageStream active

  // Streaming
  bool _streaming = false;
  bool _torchOn   = false;
  bool _audioOn   = false;
  bool _wsOk      = false;

  // WebSocket for frames (binary)
  IOWebSocketChannel? _frameWs;

  // WebSocket for commands
  IOWebSocketChannel? _cmdWs;

  // Audio
  IOWebSocketChannel? _audioWs;
  final _recorder = AudioRecorder();
  final _player   = AudioPlayer();

  // Stats
  int _fps = 0;
  int _fpsCount = 0;
  Timer? _fpsTimer;
  String _status = 'Остановлен';
  Color  _statusColor = Colors.grey;

  // Frame queue — only keep latest, drop stale ones
  Uint8List? _pendingFrame;
  bool _sendingFrame = false;
  Timer? _sendTimer;

  // JWT token
  String _token = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFgTask();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopAll();
    super.dispose();
  }

  // ── App lifecycle: keep streaming when screen off ───────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Do NOT stop streaming on pause/inactive — foreground service handles it
    if (state == AppLifecycleState.detached) _stopAll();
  }

  // ── Foreground task init ────────────────────────────────────────
  void _initFgTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'wd_stream',
        channelName: 'Watchdog Stream',
        channelDescription: 'Видеострим активен',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: false),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  // ── Permissions ─────────────────────────────────────────────────
  Future<bool> _requestPermissions() async {
    final perms = [Permission.camera, Permission.microphone, Permission.notification];
    for (final p in perms) {
      if (!(await p.request()).isGranted) return false;
    }
    await Permission.ignoreBatteryOptimizations.request();
    return true;
  }

  // ── Auth: create room ────────────────────────────────────────────
  Future<bool> _createRoom() async {
    try {
      final r = await http.post(
        Uri.parse('${_serverCtrl.text.trim()}/room/create'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'roomId': _roomCtrl.text.trim(), 'pin': _pinCtrl.text.trim()}),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        _token = jsonDecode(r.body)['token'] as String;
        return true;
      }
      _snack('Ошибка: ${jsonDecode(r.body)['error']}');
      return false;
    } catch (e) {
      _snack('Не удалось подключиться к серверу');
      return false;
    }
  }

  // ── START ────────────────────────────────────────────────────────
  Future<void> _start() async {
    if (_streaming) return;
    if (!await _requestPermissions()) { _snack('Нет разрешений'); return; }

    setState(() { _status = 'Подключение...'; _statusColor = Colors.yellow; });

    if (!await _createRoom()) {
      setState(() { _status = 'Ошибка'; _statusColor = Colors.red; });
      return;
    }

    // Foreground service + wakelock
    await WakelockPlus.enable();
    await FlutterForegroundTask.startService(
      notificationTitle: 'Watchdog — стрим активен',
      notificationText: 'Комната: ${_roomCtrl.text.trim()}',
      callback: startCallback,
    );

    // Init camera
    await _initCamera();

    // Connect command WebSocket
    _connectCmdWs();

    // Start frame streaming via WebSocket
    _startFrameWs();

    // FPS counter
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() { _fps = _fpsCount; _fpsCount = 0; });
    });

    _streaming = true;
    setState(() { _status = 'Стримит'; _statusColor = const Color(0xFF00FF9D); });

    if (_audioOn) _startAudio();
  }

  // ── STOP ─────────────────────────────────────────────────────────
  Future<void> _stopAll() async {
    _streaming = false;
    _camStreaming = false;

    _sendTimer?.cancel();
    _fpsTimer?.cancel();

    try { await _cam?.stopImageStream(); } catch (_) {}
    await _cam?.dispose();
    _cam = null;

    _frameWs?.sink.close();
    _cmdWs?.sink.close();
    _audioWs?.sink.close();
    _frameWs = null; _cmdWs = null; _audioWs = null;

    await _recorder.stop();
    await WakelockPlus.disable();
    await FlutterForegroundTask.stopService();

    if (mounted) setState(() {
      _status = 'Остановлен'; _statusColor = Colors.grey;
      _wsOk = false; _fps = 0; _camStreaming = false;
    });
  }

  // ── Camera init with imageStream ─────────────────────────────────
  Future<void> _initCamera() async {
    if (widget.cameras.isEmpty) return;

    // Back camera, try to get JPEG format directly for zero-copy
    _cam = CameraController(
      widget.cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => widget.cameras.first,
      ),
      ResolutionPreset.medium, // 720p — balance of quality/speed
      imageFormatGroup: ImageFormatGroup.jpeg, // Request JPEG directly on Android
      enableAudio: false,
    );

    await _cam!.initialize();
    // Disable auto-focus continuous scanning (reduces latency)
    await _cam!.setFocusMode(FocusMode.locked);
    // Set exposure to fixed to avoid sudden brightness changes
    try { await _cam!.setExposureMode(ExposureMode.locked); } catch (_) {}

    if (mounted) setState(() {});
  }

  // ── Frame WebSocket ───────────────────────────────────────────────
  void _startFrameWs() {
    final srv = _serverCtrl.text.trim();
    final wsUrl = srv.replaceAll('https://', 'wss://').replaceAll('http://', 'ws://');
    final roomId = _roomCtrl.text.trim();

    try {
      // Separate WebSocket just for binary frame data
      _frameWs = IOWebSocketChannel.connect(
        '$wsUrl/stream/frames?roomId=${Uri.encodeComponent(roomId)}&token=${Uri.encodeComponent(_token)}',
        pingInterval: const Duration(seconds: 15),
      );
      _frameWs!.stream.listen(
        (_) {}, // server sends nothing back on frame WS
        onDone: () { if (_streaming) Future.delayed(const Duration(seconds: 2), _startFrameWs); },
        onError: (_) { if (_streaming) Future.delayed(const Duration(seconds: 2), _startFrameWs); },
      );
    } catch (_) {
      if (_streaming) Future.delayed(const Duration(seconds: 2), _startFrameWs);
      return;
    }

    // Start image stream from camera
    if (_cam == null || !_cam!.value.isInitialized) return;
    if (_camStreaming) return;
    _camStreaming = true;

    _cam!.startImageStream((CameraImage image) {
      if (!_streaming) return;
      // Drop frame if still sending previous one (back-pressure)
      if (_sendingFrame) return;

      _sendingFrame = true;
      _sendFrame(image).then((_) {
        _sendingFrame = false;
      });
    });
  }

  Future<void> _sendFrame(CameraImage image) async {
    Uint8List? jpeg;

    // Fast path: camera gives us JPEG directly
    if (image.format.group == ImageFormatGroup.jpeg) {
      jpeg = Uint8List.fromList(image.planes[0].bytes);
    }

    if (jpeg == null || jpeg.isEmpty) return;

    try {
      // Send as binary WebSocket message — much faster than HTTP POST
      if (_frameWs != null) {
        _frameWs!.sink.add(jpeg);
        _fpsCount++;
      }
    } catch (_) {}
  }

  // ── Command WebSocket ─────────────────────────────────────────────
  void _connectCmdWs() {
    final srv = _serverCtrl.text.trim();
    final wsUrl = srv.replaceAll('https://', 'wss://').replaceAll('http://', 'ws://');
    final roomId = _roomCtrl.text.trim();

    try {
      _cmdWs = IOWebSocketChannel.connect(
        '$wsUrl/donor?roomId=${Uri.encodeComponent(roomId)}&token=${Uri.encodeComponent(_token)}',
        pingInterval: const Duration(seconds: 20),
      );
      if (mounted) setState(() => _wsOk = true);

      _cmdWs!.stream.listen(
        (data) {
          try {
            final msg = jsonDecode(data as String) as Map<String, dynamic>;
            switch (msg['cmd']) {
              case 'torch': _setTorch(msg['state'] == 'on'); break;
              case 'stopStream': _stopAll(); break;
              case 'startStream': if (!_streaming) _start(); break;
            }
            if (msg['type'] == 'audio_from_observer') {
              final d = msg['data'] as String?;
              if (d != null) _playPCM(d);
            }
          } catch (_) {}
        },
        onDone: () {
          if (mounted) setState(() => _wsOk = false);
          if (_streaming) Future.delayed(const Duration(seconds: 3), _connectCmdWs);
        },
        onError: (_) {
          if (mounted) setState(() => _wsOk = false);
          if (_streaming) Future.delayed(const Duration(seconds: 3), _connectCmdWs);
        },
      );
    } catch (_) {
      if (mounted) setState(() => _wsOk = false);
      if (_streaming) Future.delayed(const Duration(seconds: 3), _connectCmdWs);
    }
  }

  // ── Torch ────────────────────────────────────────────────────────
  Future<void> _setTorch(bool on) async {
    try {
      await _cam?.setFlashMode(on ? FlashMode.torch : FlashMode.off);
      if (mounted) setState(() => _torchOn = on);
    } catch (_) {}
  }

  // ── Audio ─────────────────────────────────────────────────────────
  void _startAudio() async {
    final srv = _serverCtrl.text.trim();
    final wsUrl = srv.replaceAll('https://', 'wss://').replaceAll('http://', 'ws://');
    final roomId = _roomCtrl.text.trim();

    _audioWs = IOWebSocketChannel.connect(
      '$wsUrl/observer/audio?roomId=${Uri.encodeComponent(roomId)}&token=${Uri.encodeComponent(_token)}',
    );

    // Incoming audio from observer → play
    _audioWs!.stream.listen((data) {
      try {
        final msg = jsonDecode(data as String);
        if (msg['type'] == 'audio') _playPCM(msg['data'] as String);
      } catch (_) {}
    });

    // Outgoing mic audio → send to observer
    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 128000,
      ));
      stream.listen((chunk) {
        if (_cmdWs != null) {
          _cmdWs!.sink.add(jsonEncode({
            'type': 'audio',
            'data': base64Encode(chunk),
          }));
        }
      });
    } catch (_) {}
  }

  void _playPCM(String b64) async {
    try {
      final bytes = base64Decode(b64);
      await _player.play(BytesSource(bytes));
    } catch (_) {}
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontFamily: 'monospace')),
      backgroundColor: const Color(0xFF0A1218),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── UI ────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    const green  = Color(0xFF00FF9D);
    const dim    = Color(0xFF3A5060);
    const bg2    = Color(0xFF080D10);
    const border = Color(0xFF1A2830);
    const yellow = Color(0xFFFFCC00);
    const blue   = Color(0xFF00AAFF);

    return WithForegroundTask(
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: bg2,
          elevation: 0,
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: border),
          ),
          title: Row(children: [
            Container(
              width: 24, height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: green, width: 1.5),
              ),
              child: Center(child: Container(
                width: 6, height: 6,
                decoration: const BoxDecoration(color: green, shape: BoxShape.circle),
              )),
            ),
            const SizedBox(width: 8),
            const Text('WATCHDOG DONOR',
              style: TextStyle(fontFamily: 'monospace', fontSize: 13,
                letterSpacing: 3, color: green)),
          ]),
          actions: [
            Container(
              margin: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                border: Border.all(color: _wsOk ? green : dim),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(_wsOk ? 'ONLINE' : 'OFFLINE',
                style: TextStyle(fontFamily: 'monospace', fontSize: 9,
                  color: _wsOk ? green : dim, letterSpacing: 1)),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            // Camera preview
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: _cam != null && _cam!.value.isInitialized
                  ? Stack(fit: StackFit.expand, children: [
                      CameraPreview(_cam!),
                      // Corner brackets
                      Positioned(top:6,left:6,child:_corner(green,top:true,left:true)),
                      Positioned(top:6,right:6,child:_corner(green,top:true,left:false)),
                      Positioned(bottom:6,left:6,child:_corner(green,top:false,left:true)),
                      Positioned(bottom:6,right:6,child:_corner(green,top:false,left:false)),
                      if (_streaming) Positioned(top:8,left:8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal:7,vertical:3),
                          decoration: BoxDecoration(color:Colors.black54,borderRadius:BorderRadius.circular(2)),
                          child: Row(mainAxisSize:MainAxisSize.min,children:[
                            Container(width:5,height:5,decoration:const BoxDecoration(color:Colors.red,shape:BoxShape.circle)),
                            const SizedBox(width:4),
                            const Text('REC',style:TextStyle(color:Colors.red,fontFamily:'monospace',fontSize:9,letterSpacing:1)),
                          ]),
                        ),
                      ),
                      Positioned(top:8,right:8,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal:7,vertical:3),
                          decoration: BoxDecoration(color:Colors.black54,borderRadius:BorderRadius.circular(2)),
                          child: Text('$_fps FPS',style:const TextStyle(color:green,fontFamily:'monospace',fontSize:10)),
                        ),
                      ),
                    ])
                  : Container(
                      color: bg2,
                      child: const Center(child: Text('КАМЕРА НЕАКТИВНА',
                        style: TextStyle(fontFamily:'monospace',color:dim,fontSize:11,letterSpacing:2))),
                    ),
              ),
            ),

            const SizedBox(height: 10),

            // Status
            Container(
              padding: const EdgeInsets.symmetric(horizontal:12, vertical:8),
              decoration: BoxDecoration(
                border: Border.all(color: _statusColor.withOpacity(.5)),
                borderRadius: BorderRadius.circular(4),
                color: _statusColor.withOpacity(.06),
              ),
              child: Row(children: [
                Container(width:6,height:6,decoration:BoxDecoration(color:_statusColor,shape:BoxShape.circle)),
                const SizedBox(width:8),
                Text(_status, style: TextStyle(fontFamily:'monospace',color:_statusColor,fontSize:11,letterSpacing:2)),
                const Spacer(),
                Text('WS: ${_wsOk?"OK":"—"}  FPS: $_fps',
                  style: TextStyle(fontFamily:'monospace',fontSize:10,color:dim)),
              ]),
            ),

            const SizedBox(height: 12),

            // Server config
            _label('СЕРВЕР'),
            const SizedBox(height: 6),
            _field(_serverCtrl, 'URL сервера', Icons.cloud_outlined),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _field(_roomCtrl, 'ID комнаты', Icons.meeting_room_outlined)),
              const SizedBox(width: 8),
              Expanded(child: _field(_pinCtrl, 'Пинкод', Icons.lock_outline, obscure: true)),
            ]),

            const SizedBox(height: 14),
            _label('УПРАВЛЕНИЕ'),
            const SizedBox(height: 8),

            // Main controls grid
            Row(children: [
              Expanded(child: _actionBtn(
                _streaming ? 'СТОП' : 'СТАРТ',
                _streaming ? Colors.red : green,
                _streaming ? Icons.stop_rounded : Icons.play_arrow_rounded,
                _streaming ? _stopAll : _start,
              )),
              const SizedBox(width: 8),
              Expanded(child: _actionBtn(
                _torchOn ? 'ВЫКЛ' : 'ФОНАРЬ',
                yellow, _torchOn ? Icons.flashlight_off : Icons.flashlight_on,
                () => _setTorch(!_torchOn),
              )),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _actionBtn(
                _audioOn ? 'МИК ВКЛ' : 'МИК',
                blue, _audioOn ? Icons.mic : Icons.mic_off,
                () { setState(() => _audioOn = !_audioOn); if (_streaming) { if (_audioOn) _startAudio(); else _recorder.stop(); } },
              )),
              const SizedBox(width: 8),
              // Info box
              Expanded(child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(border:Border.all(color:border),borderRadius:BorderRadius.circular(4),color:bg2),
                child: Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
                  _infoRow('WakeLock', _streaming ? 'ВКЛ' : 'ВЫКЛ', green, dim),
                  _infoRow('FG Task', _streaming ? 'ВКЛ' : 'ВЫКЛ', green, dim),
                  _infoRow('Аудио', _audioOn ? 'ВКЛ' : 'ВЫКЛ', blue, dim),
                ]),
              )),
            ]),

            const SizedBox(height: 16),
            _label('ПОДСКАЗКА'),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(border:Border.all(color:border),borderRadius:BorderRadius.circular(4)),
              child: const Text(
                'Стрим продолжается при выключённом экране.\n'
                'Не убивайте приложение из диспетчера задач.\n'
                'Для лучшего качества используйте Wi-Fi.',
                style: TextStyle(fontFamily:'monospace',fontSize:10,color:dim,height:1.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _corner(Color c, {required bool top, required bool left}) =>
    SizedBox(width:14,height:14,child:CustomPaint(painter:_CornerPainter(c,top,left)));

  Widget _label(String t) => Text(t, style: const TextStyle(
    fontFamily:'monospace',fontSize:9,color:Color(0xFF3A5060),letterSpacing:3));

  Widget _field(TextEditingController c, String hint, IconData icon, {bool obscure=false}) =>
    TextField(
      controller: c, obscureText: obscure,
      style: const TextStyle(fontFamily:'monospace',fontSize:12,color:Color(0xFFB8CDD4)),
      decoration: InputDecoration(
        prefixIcon: Icon(icon,color:const Color(0xFF3A5060),size:16),
        hintText: hint,
        hintStyle: const TextStyle(color:Color(0xFF1A2830)),
        filled: true, fillColor: const Color(0xFF080D10),
        enabledBorder: OutlineInputBorder(borderRadius:BorderRadius.circular(4),borderSide:const BorderSide(color:Color(0xFF1A2830))),
        focusedBorder: OutlineInputBorder(borderRadius:BorderRadius.circular(4),borderSide:const BorderSide(color:Color(0xFF00FF9D))),
        contentPadding: const EdgeInsets.symmetric(horizontal:10,vertical:10),
      ),
    );

  Widget _actionBtn(String label, Color color, IconData icon, VoidCallback onTap) =>
    GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical:14),
        decoration: BoxDecoration(
          border: Border.all(color:color),
          borderRadius: BorderRadius.circular(4),
          color: color.withOpacity(.08),
        ),
        child: Column(mainAxisSize:MainAxisSize.min,children:[
          Icon(icon, color:color, size:22),
          const SizedBox(height:4),
          Text(label,style:TextStyle(fontFamily:'monospace',color:color,fontSize:10,letterSpacing:1)),
        ]),
      ),
    );

  Widget _infoRow(String label, String val, Color valColor, Color labelColor) =>
    Padding(padding:const EdgeInsets.symmetric(vertical:1),child:Row(children:[
      Text(label,style:TextStyle(fontFamily:'monospace',fontSize:9,color:labelColor)),
      const Spacer(),
      Text(val,style:TextStyle(fontFamily:'monospace',fontSize:9,color:valColor)),
    ]));
}

// ── Corner bracket painter ────────────────────────────────────────
class _CornerPainter extends CustomPainter {
  final Color color;
  final bool top, left;
  _CornerPainter(this.color, this.top, this.left);
  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color..strokeWidth = 1.5..style = PaintingStyle.stroke;
    final x = left ? 0.0 : size.width;
    final y = top ? 0.0 : size.height;
    final dx = left ? size.width : -size.width;
    final dy = top ? size.height : -size.height;
    canvas.drawLine(Offset(x, y), Offset(x + dx, y), p);
    canvas.drawLine(Offset(x, y), Offset(x, y + dy), p);
  }
  @override bool shouldRepaint(_) => false;
}
