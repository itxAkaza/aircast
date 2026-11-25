import 'dart:convert';
import 'dart:typed_data';
import 'constants.dart';

class AirCastPacket {
  final int type;
  final Uint8List payload;

  const AirCastPacket(this.type, this.payload);

  Map<String, dynamic> toJson() =>
      jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
}

class PacketFramer {
  /// Header: [1 byte type][4 bytes uint32 payload length][payload bytes]
  static Uint8List encode(int type, Uint8List payload) {
    final buffer = Uint8List(5 + payload.length);
    final header = ByteData.sublistView(buffer, 0, 5);
    header.setUint8(0, type);
    header.setUint32(1, payload.length, Endian.big);
    buffer.setRange(5, buffer.length, payload);
    return buffer;
  }

  static Uint8List encodeControl(Map<String, dynamic> json) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(json)));
    return encode(PacketType.control, bytes);
  }
}

/// Reassembles fragmented TCP chunks into complete AirCastPacket objects.
class PacketDecoder {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Clears leftover partial bytes when a socket reconnects.
  void reset() => _buffer.clear();

  List<AirCastPacket> addChunk(Uint8List chunk) {
    _buffer.add(chunk);
    final packets = <AirCastPacket>[];
    var bytes = _buffer.toBytes();
    var offset = 0;

    while (bytes.length - offset >= 5) {
      final header = ByteData.sublistView(bytes, offset, offset + 5);
      final type = header.getUint8(0);
      final length = header.getUint32(1, Endian.big);

      if (bytes.length - offset < 5 + length) break;

      final payload = Uint8List.sublistView(
        bytes,
        offset + 5,
        offset + 5 + length,
      );
      packets.add(AirCastPacket(type, Uint8List.fromList(payload)));
      offset += 5 + length;
    }

    _buffer.clear();
    if (offset < bytes.length) {
      _buffer.add(Uint8List.sublistView(bytes, offset));
    }
    return packets;
  }
}