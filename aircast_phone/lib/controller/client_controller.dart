import 'dart:io';
import 'dart:typed_data';
import 'package:get/get.dart';
import 'package:shared_protocol/shared_protocol.dart';

class ClientController extends GetxController {
  final RxBool isConnecting = false.obs;
  final RxBool isConnected = false.obs;
  final RxString serverName = ''.obs;
  final RxnInt lastPingMs = RxnInt();
  final RxList<String> logs = <String>[].obs;

  Socket? _socket;
  final PacketDecoder _decoder = PacketDecoder();

  Future<void> connect({
    required String host,
    required int port,
    required String token,
  }) async {
    if (isConnecting.value) return;
    isConnecting.value = true;
    log('Connecting to $host:$port...');

    try {
      await _socket?.close();
      _decoder.reset();

      final socket = await Socket.connect(
        host,
        port,
        timeout: const Duration(seconds: 5),
      );
      socket.setOption(SocketOption.tcpNoDelay, true);
      _socket = socket;

      socket.listen(
            (Uint8List data) {
          for (final packet in _decoder.addChunk(data)) {
            _handlePacket(packet);
          }
        },
        onError: (e) {
          log('Connection error: $e');
          _resetState();
        },
        onDone: () {
          log('Disconnected from server');
          _resetState();
        },
      );

      sendControl({
        'cmd': 'handshake',
        'token': token.trim(),
        'device': Platform.localHostname,
      });
    } catch (e) {
      log('Failed to connect: $e');
      _resetState();
    } finally {
      isConnecting.value = false;
    }
  }

  /// Sends a control JSON packet safely.
  bool sendControl(Map<String, dynamic> json) {
    final socket = _socket;
    if (socket == null) return false;
    try {
      socket.add(PacketFramer.encodeControl(json));
      return true;
    } catch (e) {
      log('Control send error: $e');
      _resetState();
      return false;
    }
  }

  /// Sends a raw 16-bit PCM audio frame over the active TCP socket.
  bool sendAudioFrame(Uint8List pcmBytes) {
    final socket = _socket;
    if (!isConnected.value || socket == null) return false;
    try {
      socket.add(PacketFramer.encode(PacketType.audio, pcmBytes));
      return true;
    } catch (e) {
      log('Audio send error: $e');
      _resetState();
      return false;
    }
  }

  void _handlePacket(AirCastPacket packet) {
    if (packet.type != PacketType.control) return;
    final msg = packet.toJson();
    final cmd = msg['cmd'] as String?;

    if (cmd == 'handshake_ack') {
      if (msg['ok'] == true) {
        isConnected.value = true;
        serverName.value = (msg['server'] as String?) ?? 'Windows PC';
        log('Connected to ${serverName.value}');
        sendPing();
      } else {
        log('Handshake rejected: ${msg['error']}');
        disconnect();
      }
    } else if (cmd == 'pong') {
      final sentTs = msg['ts'] as int?;
      if (sentTs != null) {
        final rtt = DateTime.now().millisecondsSinceEpoch - sentTs;
        lastPingMs.value = rtt;
        log('Pong received — Latency: $rtt ms');
      }
    }
  }

  void sendPing() {
    if (!isConnected.value) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    sendControl({'cmd': 'ping', 'ts': now});
  }

  void disconnect() {
    _socket?.destroy();
    _resetState();
  }

  void _resetState() {
    _socket = null;
    _decoder.reset();
    isConnected.value = false;
    serverName.value = '';
    lastPingMs.value = null;
  }

  void log(String text) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    logs.insert(0, '[$time] $text');
    if (logs.length > 50) logs.removeLast();
  }

  @override
  void onClose() {
    _socket?.destroy();
    super.onClose();
  }
}