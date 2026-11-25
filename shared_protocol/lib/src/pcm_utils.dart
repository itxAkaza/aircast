import 'dart:math' as math;
import 'dart:typed_data';

class PcmMeterStats {
  /// Normalized perceptual volume level from 0.0 (silence) to 1.0 (0 dBFS).
  final double level;

  /// True if any sample hit near the 16-bit ceiling.
  final bool isClipping;

  const PcmMeterStats({required this.level, required this.isClipping});
}

class PcmUtils {
  static const int minInt16 = -32768;
  static const int maxInt16 = 32767;

  /// Applies digital gain in-place on signed 16-bit little-endian PCM bytes.
  /// Avoids per-chunk buffer allocations while clamping safely against wrap-around.
  static void applyGainInPlace(Uint8List pcmBytes, double gain) {
    if ((gain - 1.0).abs() < 0.005) return;
    if (gain <= 0.0) {
      pcmBytes.fillRange(0, pcmBytes.length, 0);
      return;
    }

    final data = ByteData.sublistView(pcmBytes);
    final limit = pcmBytes.length - 1;

    for (var offset = 0; offset < limit; offset += 2) {
      final sample = data.getInt16(offset, Endian.little);
      final amplified = (sample * gain).round();
      final clamped = amplified.clamp(minInt16, maxInt16);
      data.setInt16(offset, clamped, Endian.little);
    }
  }

  /// Calculates perceptual RMS meter level (mapped from -55 dBFS..0 dBFS -> 0.0..1.0)
  /// so normal speech produces natural VU meter movement.
  static PcmMeterStats analyze(Uint8List pcmBytes) {
    final sampleCount = pcmBytes.length ~/ 2;
    if (sampleCount == 0) {
      return const PcmMeterStats(level: 0.0, isClipping: false);
    }

    final data = ByteData.sublistView(pcmBytes);
    double sumSquares = 0.0;
    bool clipping = false;

    for (var offset = 0; offset + 1 < pcmBytes.length; offset += 2) {
      final sample = data.getInt16(offset, Endian.little);
      if (sample >= 32760 || sample <= -32760) {
        clipping = true;
      }
      final normalized = sample / 32768.0;
      sumSquares += normalized * normalized;
    }

    final rms = math.sqrt(sumSquares / sampleCount);
    if (rms <= 1e-6) {
      return PcmMeterStats(level: 0.0, isClipping: clipping);
    }

    // Map -55 dB .. 0 dB into 0.0 .. 1.0
    final db = 20.0 * (math.log(rms) / math.ln10);
    final level = ((db + 55.0) / 55.0).clamp(0.0, 1.0);

    return PcmMeterStats(level: level, isClipping: clipping);
  }
}
