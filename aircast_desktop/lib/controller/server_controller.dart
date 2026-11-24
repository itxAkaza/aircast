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

  ServerSocket? _server;
  Socket? _client;
  final PacketDecoder _decoder = PacketDecoder();

  String get qrData => PairingPayload(
    host: selectedIp.value,
    port: port.value,
    token: pairingToken.value,
  ).toJsonString();

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

    // Prioritize standard LAN subnets (192.168.x.x, 10.x.x.x) first
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
      _log('TCP Server listening on port ${port.value}');

      _server!.listen(_handleClientConnection);
    } catch (e) {
      _log('Server start failed: $e');
    }
  }

  void _handleClientConnection(Socket socket) {
    final remote = '${socket.remoteAddress.address}:${socket.remotePort}';
    _log('Incoming connection from $remote');

    // Replace any stale connection
    _client?.destroy();
    _client = socket;
    socket.setOption(SocketOption.tcpNoDelay, true);

    socket.listen(
          (Uint8List data) {
        for (final packet in _decoder.addChunk(data)) {
          _handlePacket(packet, socket);
        }
      },
      onError: (e) {
        _log('Socket error: $e');
        _resetClient();
      },
      onDone: () {
        _log('Client disconnected ($remote)');
        _resetClient();
      },
    );
  }

  void _handlePacket(AirCastPacket packet, Socket socket) {
    if (packet.type != PacketType.control) return;

    final msg = packet.toJson();
    final cmd = msg['cmd'] as String?;

    if (cmd == 'handshake') {
      final token = msg['token'] as String? ?? '';
      final device = msg['device'] as String? ?? 'Android Device';

      if (token != pairingToken.value) {
        _log('Rejected $device: invalid PIN');
        socket.add(PacketFramer.encodeControl({
          'cmd': 'handshake_ack',
          'ok': false,
          'error': 'Invalid pairing PIN',
        }));
        socket.flush();
        socket.close();
        return;
      }

      isClientConnected.value = true;
      connectedDevice.value = device;
      _log('Paired with $device');

      socket.add(PacketFramer.encodeControl({
        'cmd': 'handshake_ack',
        'ok': true,
        'server': Platform.localHostname,
      }));
    } else if (cmd == 'ping') {
      final ts = msg['ts'];
      _log('Ping received -> sending Pong');
      socket.add(PacketFramer.encodeControl({'cmd': 'pong', 'ts': ts}));
    }
  }

  void disconnectClient() {
    _client?.destroy();
    _resetClient();
    _log('Disconnected client manually');
  }

  void _resetClient() {
    _client = null;
    isClientConnected.value = false;
    connectedDevice.value = '';
  }

  void _log(String text) {
    final time = DateTime.now().toIso8601String().substring(11, 19);
    logs.insert(0, '[$time] $text');
    if (logs.length > 50) logs.removeLast();
  }

  @override
  void onClose() {
    _client?.destroy();
    _server?.close();
    super.onClose();
  }
}