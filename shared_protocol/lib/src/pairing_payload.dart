import 'dart:convert';

import 'constants.dart';

class PairingPayload {
  final String host;
  final int port;
  final String token;
  final int version;

  const PairingPayload({
    required this.host,
    required this.port,
    required this.token,
    this.version = AirCastConstants.protocolVersion,
  });

  String toJsonString() => jsonEncode({
    'app': 'aircast',
    'v': version,
    'host': host,
    'port': port,
    'token': token,
  });

  static PairingPayload? tryParse(String raw) {
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (map['app'] != 'aircast') return null;
      return PairingPayload(
        host: map['host'] as String,
        port: map['port'] as int,
        token: map['token'] as String,
        version: (map['v'] as int?) ?? 1,
      );
    } catch (_) {
      return null;
    }
  }
}
