class AirCastConstants {
  static const int protocolVersion = 1;
  static const int defaultPort = 4820;
  static const int defaultVideoPort = 4821;
  static const int videoProtocolVersion = 1;
  static const int maxVideoFrameBytes = 4 * 1024 * 1024; // 4 MB hard cap
}

class PacketType {
  static const int control = 0x01; // JSON handshake, ping/pong, config
  static const int audio = 0x02; // Phase 2: 16-bit PCM audio chunks
  static const int video = 0x03; // Phase 3: M-JPEG / H.264 video frames
}