import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:get/get.dart';
import 'package:shared_protocol/shared_protocol.dart';

class ServerController extends GetxController {
  final RxList<String> availableIps = <String>[].obs;
  final RxString selectedIp = ''.obs;
  final RxInt port = AirCastConstants.defaultPort.obs;
  final RxString pairingToken = ''.obs;

  final RxBool isServerRunning = false.obs;
  final RxBool isClientConnected = false.obs;
  final RxString connectedDevice = ''.obs;
  final RxList<String> logs = <String>[].obs;

  /// Synced live from the connected phone.
  final Rx<AudioConfig> remoteAudioConfig = const AudioConfig().obs;
  final RxBool remoteAudioStreaming = false.obs;

  /// Hook for MicMonitorController (and Phase 2B C++ audio router).
  void Function(Uint8List pcmBytes)? onAudioPacket;
  void Function()? onAudioReconfig;

  ServerSocket? _server;
  Socket? _client;
  final PacketDecoder _decoder = PacketDecoder();

  String get qrData => PairingPayload(
    host: selectedIp.value,
    port: port.value,
    token: pairingToken.value,
  ).toJsonString();

  final RxString activeSessionToken = ''.obs;
  int _failedPinAttempts = 0;
  DateTime? _pinLockedUntil;

  String _generateSessionToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void onInit() {
    super.onInit();
    _initServer();
  }

  Future<void> _initServer() async {
    pairingToken.value = _generatePin();
    await refreshNetworkInterfaces();
    await startServer();
  }

  String _generatePin() {
    final rng = Random.secure();
    return (100000 + rng.nextInt(900000)).toString();
  }

  Future<void> refreshNetworkInterfaces() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );

    final ips = <String>[];
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        if (!addr.address.startsWith('169.254.')) {
          ips.add(addr.address);
        }
      }
    }

    ips.sort((a, b) {
      final aLan = a.startsWith('192.168.') || a.startsWith('10.') ? 0 : 1;
      final bLan = b.startsWith('192.168.') || b.startsWith('10.') ? 0 : 1;
      return aLan.compareTo(bLan);
    });

    availableIps.assignAll(ips);
    if (ips.isNotEmpty && !ips.contains(selectedIp.value)) {
      selectedIp.value = ips.first;
    }
  }

  Future<void> startServer() async {
    try {
      await _server?.close();
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, port.value);
      isServerRunning.value = true;
      log('TCP Server listening on port ${port.value}');

      _server!.listen(_handleClientConnection);
    } catch (e) {
      log('Server start failed: $e');
    }
  }

  void _handleClientConnection(Socket socket) {
    final remote = '${socket.remoteAddress.address}:${socket.remotePort}';
    log('Incoming connection from $remote');

    _client?.destroy();
    _decoder.reset();
    _client = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);

    socket.listen(
          (Uint8List data) {
        for (final packet in _decoder.addChunk(data)) {
          _handlePacket(packet, socket);
        }
      },
      onError: (e) {
        log('Socket error: $e');
        _resetClient();
      },
      onDone: () {
        log('Client disconnected ($remote)');
        _resetClient();
      },
    );
  }

  void _handlePacket(AirCastPacket packet, Socket socket) {
    if (packet.type == PacketType.audio) {
      onAudioPacket?.call(packet.payload);
      return;
    }

    if (packet.type != PacketType.control) return;

    final msg = packet.toJson();
    final cmd = msg['cmd'] as String?;

    if (cmd == 'handshake') {
      final token = msg['token'] as String? ?? '';
      final device = msg['device'] as String? ?? 'Android Device';

      final now = DateTime.now();
      if (_pinLockedUntil != null && now.isBefore(_pinLockedUntil!)) {
        final secs = _pinLockedUntil!.difference(now).inSeconds + 1;
        log('Blocked handshake during cooldown (${secs}s remaining)');
        socket.add(PacketFramer.encodeControl({
          'cmd': 'handshake_ack',
          'ok': false,
          'error': 'Too many failed PIN attempts. Wait ${secs}s.',
        }));
        socket.flush();
        socket.close();
        return;
      }

      if (token != pairingToken.value) {
        _failedPinAttempts++;
        if (_failedPinAttempts >= 5) {
          _pinLockedUntil = now.add(const Duration(seconds: 15));
          _failedPinAttempts = 0;
          log('5 invalid PIN attempts — locked pairing for 15s');
        } else {
          log('Rejected $device: invalid PIN ($_failedPinAttempts/5)');
        }
        socket.add(PacketFramer.encodeControl({
          'cmd': 'handshake_ack',
          'ok': false,
          'error': 'Invalid pairing PIN',
        }));
        socket.flush();
        socket.close();
        return;
      }

      _failedPinAttempts = 0;
      _pinLockedUntil = null;
      activeSessionToken.value = _generateSessionToken();
      isClientConnected.value = true;
      connectedDevice.value = device;
      log('Paired with $device (session token issued)');

      socket.add(PacketFramer.encodeControl({
        'cmd': 'handshake_ack',
        'ok': true,
        'server': Platform.localHostname,
        'sessionToken': activeSessionToken.value,
        'videoPort': AirCastConstants.defaultVideoPort,
      }));
    }

    else if (cmd == 'ping') {
      final ts = msg['ts'];
      log('Ping received -> sending Pong');
      socket.add(PacketFramer.encodeControl({'cmd': 'pong', 'ts': ts}));
    } else if (cmd == 'audio_config') {
      final cfgMap = msg['config'] as Map<String, dynamic>?;
      if (cfgMap != null) {
        remoteAudioConfig.value = AudioConfig.fromJson(cfgMap);
        log('Audio config: ${remoteAudioConfig.value.sampleRate}Hz, '
            'gain=${remoteAudioConfig.value.gain}x, '
            'muted=${remoteAudioConfig.value.isMuted}, '
            'NC=${remoteAudioConfig.value.noiseSuppression}');
      }
    } else if (cmd == 'audio_state') {
      final streaming = (msg['streaming'] as bool?) ?? false;
      remoteAudioStreaming.value = streaming;
      log(streaming ? 'Phone started mic stream' : 'Phone stopped mic stream');
    } else if (cmd == 'audio_reconfig') {
      onAudioReconfig?.call();
      log('Phone reconfiguring mic filters');
    }
  }

  void disconnectClient() {
    _client?.destroy();
    _resetClient();
    log('Disconnected client manually');
  }

  void _resetClient() {
    _client = null;
    _decoder.reset();
    isClientConnected.value = false;
    activeSessionToken.value = '';
    connectedDevice.value = '';
    remoteAudioStreaming.value = false;
    remoteAudioConfig.value = const AudioConfig();
  }

  void log(String text) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    logs.insert(0, '[$time] $text');
    if (logs.length > 60) logs.removeLast();
  }

  @override
  void onClose() {
    _client?.destroy();
    _server?.close();
    super.onClose();
  }
}