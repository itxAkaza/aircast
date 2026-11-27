import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:get/get.dart';
import 'package:shared_protocol/shared_protocol.dart';

class ClientController extends GetxController {
  static const _kLastHostKey = 'aircast_last_host';
  static const _kLastPortKey = 'aircast_last_port';
  static const _kLastTokenKey = 'aircast_last_token';

  static const int _maxReconnectAttempts = 20;

  final RxBool isConnecting = false.obs;
  final RxBool isConnected = false.obs;
  final RxBool isReconnecting = false.obs;
  final RxInt reconnectAttempt = 0.obs;
  final RxString serverName = ''.obs;
  final RxnInt lastPingMs = RxnInt();
  final RxList<String> logs = <String>[].obs;

  /// Persisted last-known PC credentials so you don't need to re-scan QR.
  final RxString lastHost = ''.obs;
  final RxInt lastPort = AirCastConstants.defaultPort.obs;
  final RxString lastToken = ''.obs;

  bool get hasSavedServer =>
      lastHost.value.isNotEmpty && lastToken.value.isNotEmpty;

  Socket? _socket;
  final PacketDecoder _decoder = PacketDecoder();

  Timer? _heartbeatTimer;
  Timer? _reconnectTimer;
  DateTime _lastServerActivity = DateTime.now();
  bool _manualDisconnect = false;

  @override
  void onInit() {
    super.onInit();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    try {
      final h = await FlutterForegroundTask.getData<String>(key: _kLastHostKey);
      final p = await FlutterForegroundTask.getData<int>(key: _kLastPortKey);
      final t = await FlutterForegroundTask.getData<String>(key: _kLastTokenKey);
      if (h != null && h.isNotEmpty) lastHost.value = h;
      if (p != null && p > 0) lastPort.value = p;
      if (t != null && t.isNotEmpty) lastToken.value = t;
    } catch (_) {}
  }

  Future<void> _saveCredentials(String host, int port, String token) async {
    lastHost.value = host;
    lastPort.value = port;
    lastToken.value = token;
    try {
      await FlutterForegroundTask.saveData(key: _kLastHostKey, value: host);
      await FlutterForegroundTask.saveData(key: _kLastPortKey, value: port);
      await FlutterForegroundTask.saveData(key: _kLastTokenKey, value: token);
    } catch (_) {}
  }

  Future<void> connect({
    required String host,
    required int port,
    required String token,
    bool fromReconnect = false,
  }) async {
    if (isConnecting.value) return;

    final cleanHost = host.trim();
    final cleanToken = token.trim();
    if (cleanHost.isEmpty || cleanToken.isEmpty) {
      log('Enter IP and PIN or scan QR code');
      return;
    }

    _manualDisconnect = false;
    _reconnectTimer?.cancel();
    isConnecting.value = true;

    if (!fromReconnect) {
      isReconnecting.value = false;
      reconnectAttempt.value = 0;
      await _saveCredentials(cleanHost, port, cleanToken);
      log('Connecting to $cleanHost:$port...');
    }

    try {
      _closeCurrentSocket();
      _decoder.reset();

      final socket = await Socket.connect(
        cleanHost,
        port,
        timeout: const Duration(seconds: 4),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;
      _lastServerActivity = DateTime.now();

      socket.listen(
            (Uint8List data) {
          if (_socket != socket) return; // Ignore stale socket events
          _lastServerActivity = DateTime.now();
          for (final packet in _decoder.addChunk(data)) {
            _handlePacket(packet);
          }
        },
        onError: (e) {
          if (_socket != socket) return;
          log('Connection error: $e');
          _handleUnexpectedDrop();
        },
        onDone: () {
          if (_socket != socket) return;
          if (!_manualDisconnect) {
            log('Connection dropped by network/PC');
            _handleUnexpectedDrop();
          }
        },
      );

      sendControl({
        'cmd': 'handshake',
        'token': cleanToken,
        'device': Platform.localHostname,
      });
    } catch (e) {
      log(fromReconnect
          ? 'Reconnect #${reconnectAttempt.value} failed'
          : 'Failed to connect: $e');
      if (fromReconnect) {
        _scheduleNextReconnect();
      } else {
        _resetDisconnectedState();
      }
    } finally {
      isConnecting.value = false;
    }
  }

  Future<void> reconnectLast() async {
    if (!hasSavedServer) return;
    await connect(
      host: lastHost.value,
      port: lastPort.value,
      token: lastToken.value,
    );
  }

  bool sendControl(Map<String, dynamic> json) {
    final socket = _socket;
    if (socket == null) return false;
    try {
      socket.add(PacketFramer.encodeControl(json));
      return true;
    } catch (e) {
      log('Control send error: $e');
      _handleUnexpectedDrop();
      return false;
    }
  }

  bool sendAudioFrame(Uint8List pcmBytes) {
    final socket = _socket;
    if (!isConnected.value || socket == null) return false;
    try {
      socket.add(PacketFramer.encode(PacketType.audio, pcmBytes));
      return true;
    } catch (e) {
      log('Audio send error: $e');
      _handleUnexpectedDrop();
      return false;
    }
  }

  void _handlePacket(AirCastPacket packet) {
    if (packet.type != PacketType.control) return;
    final msg = packet.toJson();
    final cmd = msg['cmd'] as String?;

    if (cmd == 'handshake_ack') {
      if (msg['ok'] == true) {
        final wasReconnecting = isReconnecting.value;
        isConnected.value = true;
        isReconnecting.value = false;
        reconnectAttempt.value = 0;
        _reconnectTimer?.cancel();
        serverName.value = (msg['server'] as String?) ?? 'Windows PC';
        _lastServerActivity = DateTime.now();
        _startHeartbeat();

        log(wasReconnecting
            ? 'Auto-reconnected to ${serverName.value}!'
            : 'Connected to ${serverName.value}');
        sendPing(manual: !wasReconnecting);
      } else {
        // Wrong PIN (e.g. Desktop restarted with a new PIN) — stop retrying
        log('Handshake rejected: ${msg['error']} — scan new QR code');
        disconnect();
      }
    } else if (cmd == 'pong') {
      final sentTs = msg['ts'] as int?;
      final manual = msg['manual'] == true;
      if (sentTs != null) {
        final rtt = DateTime.now().millisecondsSinceEpoch - sentTs;
        lastPingMs.value = rtt;
        if (manual) {
          log('Pong received — Latency: $rtt ms');
        }
      }
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!isConnected.value) return;
      final silentSecs =
          DateTime.now().difference(_lastServerActivity).inSeconds;
      if (silentSecs >= 10) {
        log('PC unresponsive for ${silentSecs}s — reconnecting...');
        _handleUnexpectedDrop();
        return;
      }
      sendPing(manual: false);
    });
  }

  void _handleUnexpectedDrop() {
    _heartbeatTimer?.cancel();
    _closeCurrentSocket();
    _decoder.reset();
    isConnected.value = false;
    lastPingMs.value = null;

    if (_manualDisconnect || !hasSavedServer) {
      isReconnecting.value = false;
      serverName.value = '';
      return;
    }

    isReconnecting.value = true;
    _scheduleNextReconnect();
  }

  void _scheduleNextReconnect() {
    if (_manualDisconnect || isConnected.value) return;

    if (reconnectAttempt.value >= _maxReconnectAttempts) {
      log('Auto-reconnect timed out. Tap Reconnect or scan QR.');
      isReconnecting.value = false;
      serverName.value = '';
      return;
    }

    reconnectAttempt.value++;
    final delaySec = reconnectAttempt.value <= 4 ? 2 : 4;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: delaySec), () {
      if (_manualDisconnect || isConnected.value) return;
      connect(
        host: lastHost.value,
        port: lastPort.value,
        token: lastToken.value,
        fromReconnect: true,
      );
    });
  }

  void sendPing({bool manual = true}) {
    if (!isConnected.value) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    sendControl({'cmd': 'ping', 'ts': now, 'manual': manual});
  }

  void disconnect() {
    _manualDisconnect = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _closeCurrentSocket();
    _resetDisconnectedState();
    log('Disconnected manually');
  }

  void _closeCurrentSocket() {
    final old = _socket;
    _socket = null;
    try {
      old?.destroy();
    } catch (_) {}
  }

  void _resetDisconnectedState() {
    _decoder.reset();
    isConnected.value = false;
    isReconnecting.value = false;
    reconnectAttempt.value = 0;
    serverName.value = '';
    lastPingMs.value = null;
  }

  void log(String text) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    logs.insert(0, '[$time] $text');
    if (logs.length > 60) logs.removeLast();
  }

  @override
  void onClose() {
    _manualDisconnect = true;
    _heartbeatTimer?.cancel();
    _reconnectTimer?.cancel();
    _closeCurrentSocket();
    super.onClose();
  }
}