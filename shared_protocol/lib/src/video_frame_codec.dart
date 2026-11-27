import 'dart:typed_data';
import 'constants.dart';

class VideoFrameFlags {
  static const int frontCamera = 1 << 0;
  static const int mirrorHorizontal = 1 << 1;
}

class VideoFramePacket {
  static const int headerSize = 26;
  static const int typeAuth = 0x01;
  static const int typeJpegFrame = 0x02;

  final int version;
  final int type;
  final int sequence;
  final int timestampMs;
  final int width;
  final int height;
  final int rotation;
  final int flags;
  final Uint8List payload;

  const VideoFramePacket({
    this.version = AirCastConstants.videoProtocolVersion,
    required this.type,
    required this.sequence,
    required this.timestampMs,
    required this.width,
    required this.height,
    required this.rotation,
    required this.flags,
    required this.payload,
  });

  bool get isFrontCamera => (flags & VideoFrameFlags.frontCamera) != 0;
  bool get isMirrored => (flags & VideoFrameFlags.mirrorHorizontal) != 0;

  Uint8List encode() {
    if (payload.length > AirCastConstants.maxVideoFrameBytes) {
      throw StateError('Video frame exceeds 4 MB safety limit');
    }
    final out = Uint8List(headerSize + payload.length);
    final bd = ByteData.sublistView(out);
    bd.setUint8(0, version);
    bd.setUint8(1, type);
    bd.setUint32(2, sequence, Endian.big);
    bd.setUint64(6, timestampMs, Endian.big);
    bd.setUint16(14, width, Endian.big);
    bd.setUint16(16, height, Endian.big);
    bd.setUint16(18, rotation, Endian.big);
    bd.setUint16(20, flags, Endian.big);
    bd.setUint32(22, payload.length, Endian.big);
    out.setRange(headerSize, out.length, payload);
    return out;
  }
}

class VideoStreamDecoder {
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  /// Throws [FormatException] if a corrupted or >4 MB frame header arrives.
  List<VideoFramePacket> addChunk(Uint8List chunk) {
    if (chunk.isNotEmpty) _buffer.add(chunk);
    final results = <VideoFramePacket>[];

    while (_buffer.length >= VideoFramePacket.headerSize) {
      final bytes = _buffer.toBytes();
      final bd = ByteData.sublistView(bytes);

      final version = bd.getUint8(0);
      if (version != AirCastConstants.videoProtocolVersion) {
        _buffer.clear();
        throw FormatException('Unsupported video protocol version: $version');
      }

      final payloadLen = bd.getUint32(22, Endian.big);
      if (payloadLen > AirCastConstants.maxVideoFrameBytes) {
        _buffer.clear();
        throw FormatException('Video payload too large: $payloadLen bytes');
      }

      final totalLen = VideoFramePacket.headerSize + payloadLen;
      if (bytes.length < totalLen) {
        // Put unconsumed bytes back and wait for the rest of the frame
        _buffer.clear();
        _buffer.add(bytes);
        break;
      }

      results.add(VideoFramePacket(
        version: version,
        type: bd.getUint8(1),
        sequence: bd.getUint32(2, Endian.big),
        timestampMs: bd.getUint64(6, Endian.big),
        width: bd.getUint16(14, Endian.big),
        height: bd.getUint16(16, Endian.big),
        rotation: bd.getUint16(18, Endian.big),
        flags: bd.getUint16(20, Endian.big),
        payload: Uint8List.fromList(
          Uint8List.sublistView(bytes, VideoFramePacket.headerSize, totalLen),
        ),
      ));

      _buffer.clear();
      if (bytes.length > totalLen) {
        _buffer.add(Uint8List.sublistView(bytes, totalLen));
      }
    }

    return results;
  }

  void reset() => _buffer.clear();
}