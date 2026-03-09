// ignore_for_file: avoid_print
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;

// ═══════════════════════════════════════════════════════════════════
//  FOREGROUND TASK HANDLER
//  Runs in a SEPARATE ISOLATE — survives screen off + app background.
//  Owns the camera + WebSocket connections.
//  UI communicates via FlutterForegroundTask.sendDataToTask/sendDataToMain
// ═══════════════════════════════════════════════════════════════════
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_WatchdogTaskHandler());
}

class _WatchdogTaskHandler extends TaskHandler {
  CameraController? _cam;
  WebSocket? _frameWs;
  WebSocket? _cmdWs;
  bool _active = false;
  bool _sending = false;
  int  _fpsCount = 0;
  Timer? _fpsTimer;
  Timer? _reconnectFrameTimer;
  Timer? _reconnectCmdTimer;
  String _serverUrl = '';
  String _roomId    = '';
  String _token     = '';

  @override
  Future<void> onStart(DateTime timestamp, SendPort? sendPort) async {
    FlutterForegroundTask.addTaskDataCallback(_onData);
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp, SendPort? sendPort) async {
    if (_active) {
      FlutterForegroundTask.updateService(
        notificationTitle: 'Watchdog — стрим активен',
        notificationText: 'Комната: $_roomId',
      );
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, SendPort? sendPort) async {
    await _stop();
  }

  void _onData(Object data) {
    if (data is! Map) return;
    final msg = Map<String, dynamic>.from(data as Map);
    switch (msg['cmd']) {
      case 'start':
        _serverUrl = msg['server'] as String;
        _roomId    = msg['roomId'] as String;
        _token     = msg['token']  as String;
        _startStream();
        break;
      case 'stop':
        _stop();
        break;
      case 'torch':
        _setTorch(msg['on'] as bool);
        break;
      case 'audio':
        // Forward mic audio from UI to donor command WS
        _cmdWs?.add(jsonEncode({'type': 'audio', 'data': msg['data']}));
        break;
    }
  }

  Future<void> _startStream() async {
    if (_active) return;
    _active = true;
    await _initCamera();
    _connectCmdWs();
    _connectFrameWs();
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) => _fpsCount = 0);
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _cam = CameraController(
      back,
      ResolutionPreset.medium,
      imageFormatGroup: ImageFormatGroup.jpeg,
      enableAudio: false,
    );
    await _cam!.initialize();
    try { await _cam!.setFocusMode(FocusMode.locked); } catch (_) {}
    try { await _cam!.setExposureMode(ExposureMode.locked); } catch (_) {}
    // startImageStream runs on camera's own thread — works when screen is off
    await _cam!.startImageStream(_onFrame);
  }

  void _onFrame(CameraImage image) {
    if (!_active || _sending) return;
    if (_frameWs == null || _frameWs!.readyState != WebSocket.open) return;
    if (image.format.group != ImageFormatGroup.jpeg) return;
    final jpeg = image.planes[0].bytes;
    if (jpeg.isEmpty) return;
    _sending = true;
    try {
      _frameWs!.add(jpeg);
      _fpsCount++;
    } catch (_) {}
    _sending = false;
  }

  void _connectFrameWs() async {
    if (!_active) return;
    final wsUrl = _wsUrl(_serverUrl);
    try {
      _frameWs = await WebSocket.connect(
        '$wsUrl/stream/frames?token=${Uri.encodeComponent(_token)}',
      );
      _frameWs!.listen(
        (_) {},
        onDone: () {
          _frameWs = null;
          if (_active) _reconnectFrameTimer = Timer(const Duration(seconds: 2), _connectFrameWs);
        },
        onError: (_) {
          _frameWs = null;
          if (_active) _reconnectFrameTimer = Timer(const Duration(seconds: 2), _connectFrameWs);
        },
        cancelOnError: true,
      );
    } catch (_) {
      if (_active) _reconnectFrameTimer = Timer(const Duration(seconds: 3), _connectFrameWs);
    }
  }

  void _connectCmdWs() async {
    if (!_active) return;
    final wsUrl = _wsUrl(_serverUrl);
    try {
      _cmdWs = await WebSocket.connect(
        '$wsUrl/donor?token=${Uri.encodeComponent(_token)}',
      );
      FlutterForegroundTask.sendDataToMain({'event': 'wsStatus', 'ok': true});
      _cmdWs!.listen(
        (data) {
          try {
            final msg = jsonDecode(data as String) as Map<String, dynamic>;
            if (msg['cmd'] == 'torch') _setTorch(msg['state'] == 'on');
            if (msg['cmd'] == 'stopStream') _stop();
            if (msg['type'] == 'audio_from_observer') {
              FlutterForegroundTask.sendDataToMain({'event': 'audio', 'data': msg['data']});
            }
          } catch (_) {}
        },
        onDone: () {
          _cmdWs = null;
          FlutterForegroundTask.sendDataToMain({'event': 'wsStatus', 'ok': false});
          if (_active) _reconnectCmdTimer = Timer(const Duration(seconds: 3), _connectCmdWs);
        },
        onError: (_) {
          _cmdWs = null;
          FlutterForegroundTask.sendDataToMain({'event': 'wsStatus', 'ok': false});
          if (_active) _reconnectCmdTimer = Timer(const Duration(seconds: 3), _connectCmdWs);
        },
        cancelOnError: true,
      );
    } catch (_) {
      FlutterForegroundTask.sendDataToMain({'event': 'wsStatus', 'ok': false});
      if (_active) _reconnectCmdTimer = Timer(const Duration(seconds: 3), _connectCmdWs);
    }
  }

  void _setTorch(bool on) {
    try { _cam?.setFlashMode(on ? FlashMode.torch : FlashMode.off); } catch (_) {}
    FlutterForegroundTask.sendDataToMain({'event': 'torch', 'on': on});
  }

  Future<void> _stop() async {
    _active = false;
    _fpsTimer?.cancel();
    _reconnectFrameTimer?.cancel();
    _reconnectCmdTimer?.cancel();
    _sending = false;
    try { await _cam?.stopImageStream(); } catch (_) {}
    try { await _cam?.dispose(); }         catch (_) {}
    _cam = null;
    try { await _frameWs?.close(); } catch (_) {}
    try { await _cmdWs?.close(); }   catch (_) {}
    _frameWs = null; _cmdWs = null;
    FlutterForegroundTask.sendDataToMain({'event': 'stopped'});
  }

  String _wsUrl(String url) =>
    url.replaceAll('https://', 'wss://').replaceAll('http://', 'ws://');
}

// ═══════════════════════════════════════════════════════════════════
//  MAIN
// ═══════════════════════════════════════════════════════════════════
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  runApp(const WatchdogApp());
}

class WatchdogApp extends StatelessWidget {
  const WatchdogApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Watchdog',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF030608),
      colorScheme: const ColorScheme.dark(primary: Color(0xFF00FF9D)),
      useMaterial3: true,
    ),
    home: const DonorScreen(),
  );
}

// ═══════════════════════════════════════════════════════════════════
//  UI — thin layer, just controls + status display
// ═══════════════════════════════════════════════════════════════════
class DonorScreen extends StatefulWidget {
  const DonorScreen({super.key});
  @override State<DonorScreen> createState() => _DonorScreenState();
}

class _DonorScreenState extends State<DonorScreen> with WidgetsBindingObserver {
  final _serverCtrl = TextEditingController(text: 'https://watchdog-server.onrender.com');
  final _roomCtrl   = TextEditingController(text: 'room-1');
  final _pinCtrl    = TextEditingController(text: '1234');

  bool   _streaming   = false;
  bool   _wsOk        = false;
  bool   _torchOn     = false;
  bool   _audioOn     = false;
  String _status      = 'Остановлен';
  Color  _statusColor = const Color(0xFF3A5060);
  String _token       = '';

  final _player   = AudioPlayer();
  final _recorder = AudioRecorder();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFgTask();
    FlutterForegroundTask.addTaskDataCallback(_onTaskData);
  }

  @override
  void dispose() {
    FlutterForegroundTask.removeTaskDataCallback(_onTaskData);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // ── Never stop on lifecycle changes — task handler is independent ─
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {}

  void _onTaskData(Object data) {
    if (!mounted || data is! Map) return;
    final msg = Map<String, dynamic>.from(data as Map);
    switch (msg['event']) {
      case 'wsStatus': setState(() => _wsOk = msg['ok'] as bool); break;
      case 'torch':    setState(() => _torchOn = msg['on'] as bool); break;
      case 'stopped':  _onStopped(); break;
      case 'audio':    _playPCM(msg['data'] as String); break;
    }
  }

  void _initFgTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'wd_stream',
        channelName: 'Watchdog Stream',
        channelDescription: 'Видеострим работает в фоне',
        channelImportance: NotificationChannelImportance.HIGH,
        priority: NotificationPriority.HIGH,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
        buttons: [const NotificationButton(id: 'stop', text: 'СТОП')],
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true, playSound: false),
      foregroundTaskOptions: const ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,  // ← CPU stays alive when screen off
        allowWifiLock: true,  // ← Wi-Fi stays alive
      ),
    );
  }

  Future<bool> _requestPermissions() async {
    for (final p in [Permission.camera, Permission.microphone]) {
      if (!(await p.request()).isGranted) {
        _snack('Нужно разрешение: $p'); return false;
      }
    }
    await Permission.notification.request();
    if (!await Permission.ignoreBatteryOptimizations.isGranted) {
      await Permission.ignoreBatteryOptimizations.request();
    }
    return true;
  }

  Future<void> _start() async {
    if (_streaming) return;
    if (!await _requestPermissions()) return;
    setState(() { _status = 'Подключение...'; _statusColor = Colors.yellow; });

    if (!await _createRoom()) {
      setState(() { _status = 'Ошибка'; _statusColor = Colors.red; });
      return;
    }
    await WakelockPlus.enable();

    final result = await FlutterForegroundTask.startService(
      notificationTitle: 'Watchdog — стрим активен',
      notificationText: 'Комната: ${_roomCtrl.text.trim()}',
      callback: startCallback,
    );
    if (result != ServiceRequestResult.success) {
      _snack('Не удалось запустить фоновой сервис'); return;
    }

    // Small delay so task handler initialises before we send data
    await Future.delayed(const Duration(milliseconds: 300));

    FlutterForegroundTask.sendDataToTask({
      'cmd':    'start',
      'server': _serverCtrl.text.trim(),
      'roomId': _roomCtrl.text.trim(),
      'token':  _token,
    });

    setState(() {
      _streaming = true;
      _status = 'Стримит';
      _statusColor = const Color(0xFF00FF9D);
    });
  }

  Future<bool> _createRoom() async {
    try {
      final r = await http.post(
        Uri.parse('${_serverCtrl.text.trim()}/room/create'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'roomId': _roomCtrl.text.trim(), 'pin': _pinCtrl.text.trim()}),
      ).timeout(const Duration(seconds: 10));
      if (r.statusCode == 200) {
        _token = (jsonDecode(r.body) as Map)['token'] as String;
        return true;
      }
      _snack('Сервер: ${(jsonDecode(r.body) as Map)['error']}');
      return false;
    } catch (_) { _snack('Нет связи с сервером'); return false; }
  }

  Future<void> _stop() async {
    FlutterForegroundTask.sendDataToTask({'cmd': 'stop'});
  }

  void _onStopped() async {
    await _recorder.stop();
    await WakelockPlus.disable();
    await FlutterForegroundTask.stopService();
    if (mounted) setState(() {
      _streaming = false; _wsOk = false; _torchOn = false; _audioOn = false;
      _status = 'Остановлен'; _statusColor = const Color(0xFF3A5060);
    });
  }

  void _toggleTorch() {
    if (!_streaming) return;
    FlutterForegroundTask.sendDataToTask({'cmd': 'torch', 'on': !_torchOn});
  }

  Future<void> _toggleAudio() async {
    if (!_streaming) return;
    setState(() => _audioOn = !_audioOn);
    if (_audioOn) {
      try {
        final stream = await _recorder.startStream(const RecordConfig(
          encoder: AudioEncoder.pcm16bits, sampleRate: 16000, numChannels: 1,
        ));
        stream.listen((chunk) {
          FlutterForegroundTask.sendDataToTask({
            'cmd': 'audio', 'data': base64Encode(chunk),
          });
        });
      } catch (e) {
        _snack('Ошибка микрофона');
        setState(() => _audioOn = false);
      }
    } else {
      await _recorder.stop();
    }
  }

  void _playPCM(String b64) async {
    try { await _player.play(BytesSource(base64Decode(b64))); } catch (_) {}
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
      backgroundColor: const Color(0xFF0A1218),
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── colours ──────────────────────────────────────────────────────
  static const _green  = Color(0xFF00FF9D);
  static const _dim    = Color(0xFF3A5060);
  static const _bg2    = Color(0xFF080D10);
  static const _panel  = Color(0xFF0A1218);
  static const _border = Color(0xFF1A2830);
  static const _yellow = Color(0xFFFFCC00);
  static const _blue   = Color(0xFF00AAFF);
  static const _red    = Color(0xFFFF3B3B);

  @override
  Widget build(BuildContext context) {
    return WithForegroundTask(
      child: Scaffold(
        appBar: AppBar(
          backgroundColor: _bg2,
          elevation: 0,
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: _border),
          ),
          title: Row(children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              width: 22, height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _streaming ? _green : _dim, width: 1.5),
              ),
              child: Center(child: Container(
                width: 5, height: 5,
                decoration: BoxDecoration(
                  color: _streaming ? _green : _dim, shape: BoxShape.circle),
              )),
            ),
            const SizedBox(width: 8),
            const Text('WATCHDOG', style: TextStyle(
              fontFamily: 'monospace', fontSize: 13, letterSpacing: 4, color: _green)),
          ]),
          actions: [
            _pill(_wsOk ? 'WS' : 'WS—', _wsOk ? _green : _dim),
            const SizedBox(width: 6),
            _pill(_streaming ? 'LIVE' : 'OFF', _streaming ? _red : _dim),
            const SizedBox(width: 12),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            // Status
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                border: Border.all(color: _statusColor.withOpacity(.5)),
                borderRadius: BorderRadius.circular(5),
                color: _statusColor.withOpacity(.05),
              ),
              child: Row(children: [
                Container(width: 7, height: 7,
                  decoration: BoxDecoration(color: _statusColor, shape: BoxShape.circle)),
                const SizedBox(width: 10),
                Text(_status, style: TextStyle(fontFamily: 'monospace',
                  color: _statusColor, fontSize: 12, letterSpacing: 2)),
                const Spacer(),
                Text(_wsOk ? 'WebSocket OK' : 'WebSocket —',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: _dim)),
              ]),
            ),
            const SizedBox(height: 14),

            // Config
            _label('СЕРВЕР'), const SizedBox(height: 6),
            _field(_serverCtrl, 'URL сервера', Icons.cloud_outlined),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _field(_roomCtrl, 'ID комнаты', Icons.meeting_room_outlined)),
              const SizedBox(width: 8),
              Expanded(child: _field(_pinCtrl, 'Пинкод', Icons.lock_outline, obscure: true)),
            ]),
            const SizedBox(height: 16),

            // Controls
            _label('УПРАВЛЕНИЕ'), const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _btn(
                label: _streaming ? 'СТОП' : 'СТАРТ',
                icon: _streaming ? Icons.stop_rounded : Icons.play_arrow_rounded,
                color: _streaming ? _red : _green,
                onTap: _streaming ? _stop : _start,
                active: true,
              )),
              const SizedBox(width: 10),
              Expanded(child: _btn(
                label: _torchOn ? 'ФОНАРЬ\nВЫКЛ' : 'ФОНАРЬ\nВКЛ',
                icon: _torchOn ? Icons.flashlight_off_rounded : Icons.flashlight_on_rounded,
                color: _yellow, onTap: _toggleTorch, active: _streaming,
              )),
            ]),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(child: _btn(
                label: _audioOn ? 'МИК\nВЫКЛ' : 'МИК\nВКЛ',
                icon: _audioOn ? Icons.mic_rounded : Icons.mic_off_rounded,
                color: _blue, onTap: _toggleAudio, active: _streaming,
              )),
              const SizedBox(width: 10),
              Expanded(child: _statusGrid()),
            ]),
            const SizedBox(height: 16),

            // Hint
            _label('ДЛЯ СТАБИЛЬНОЙ РАБОТЫ'), const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(border: Border.all(color: _border), borderRadius: BorderRadius.circular(5)),
              child: const Text(
                '• Стрим работает при выключённом экране\n'
                '• Не убивайте приложение в диспетчере задач\n'
                '• Разрешите работу в фоне в настройках батареи\n'
                '• Wi-Fi даёт меньшую задержку чем мобильный',
                style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: _dim, height: 1.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String t, Color c) => Container(
    margin: const EdgeInsets.symmetric(vertical: 15),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(border: Border.all(color: c), borderRadius: BorderRadius.circular(2)),
    child: Text(t, style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: c, letterSpacing: 1)),
  );

  Widget _label(String t) => Text(t,
    style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: _dim, letterSpacing: 3));

  Widget _field(TextEditingController c, String hint, IconData icon, {bool obscure = false}) =>
    TextField(
      controller: c, obscureText: obscure,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Color(0xFFB8CDD4)),
      decoration: InputDecoration(
        prefixIcon: Icon(icon, color: _dim, size: 16),
        hintText: hint, hintStyle: const TextStyle(color: _border),
        filled: true, fillColor: _bg2,
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: _border)),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(4), borderSide: const BorderSide(color: _green)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      ),
    );

  Widget _btn({required String label, required IconData icon,
      required Color color, required VoidCallback onTap, required bool active}) =>
    GestureDetector(
      onTap: active ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          border: Border.all(color: active ? color : _border),
          borderRadius: BorderRadius.circular(5),
          color: active ? color.withOpacity(.08) : Colors.transparent,
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: active ? color : _dim, size: 26),
          const SizedBox(height: 6),
          Text(label, textAlign: TextAlign.center,
            style: TextStyle(fontFamily: 'monospace', color: active ? color : _dim,
              fontSize: 10, letterSpacing: 1, height: 1.4)),
        ]),
      ),
    );

  Widget _statusGrid() => Container(
    padding: const EdgeInsets.all(11),
    decoration: BoxDecoration(border: Border.all(color: _border),
      borderRadius: BorderRadius.circular(5), color: _bg2),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sr('Сервис', _streaming, _green),
      _sr('WakeLock', _streaming, _green),
      _sr('Wi-Fi Lock', _streaming, _green),
      _sr('Аудио', _audioOn, _blue),
      _sr('Фонарик', _torchOn, _yellow),
    ]),
  );

  Widget _sr(String l, bool on, Color c) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1.5),
    child: Row(children: [
      Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 9, color: _dim)),
      const Spacer(),
      Text(on ? 'ВКЛ' : 'ВЫКЛ',
        style: TextStyle(fontFamily: 'monospace', fontSize: 9, color: on ? c : _dim)),
    ]),
  );
}
