enum StreamMode {
  mic,
  camera,
  both;

  static StreamMode fromName(String? value) {
    return StreamMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => StreamMode.mic,
    );
  }
}

class AudioConfig {
  /// 48 kHz mono 16-bit PCM = 96,000 bytes/sec (~96 KB/s).
  /// 20 ms chunk = 960 samples = 1,920 bytes.
  static const int defaultSampleRate = 48000;
  static const int defaultChannels = 1;
  static const int frameBytes20ms = 1920;

  final int sampleRate;
  final int numChannels;
  final double gain; // 0.0 to 2.0
  final bool isMuted;
  final bool noiseSuppression;
  final bool echoCancellation;
  final StreamMode mode;

  const AudioConfig({
    this.sampleRate = defaultSampleRate,
    this.numChannels = defaultChannels,
    this.gain = 1.0,
    this.isMuted = false,
    this.noiseSuppression = true,
    this.echoCancellation = true,
    this.mode = StreamMode.mic,
  });

  AudioConfig copyWith({
    int? sampleRate,
    int? numChannels,
    double? gain,
    bool? isMuted,
    bool? noiseSuppression,
    bool? echoCancellation,
    StreamMode? mode,
  }) {
    return AudioConfig(
      sampleRate: sampleRate ?? this.sampleRate,
      numChannels: numChannels ?? this.numChannels,
      gain: gain ?? this.gain,
      isMuted: isMuted ?? this.isMuted,
      noiseSuppression: noiseSuppression ?? this.noiseSuppression,
      echoCancellation: echoCancellation ?? this.echoCancellation,
      mode: mode ?? this.mode,
    );
  }

  Map<String, dynamic> toJson() => {
        'sampleRate': sampleRate,
        'numChannels': numChannels,
        'gain': double.parse(gain.toStringAsFixed(2)),
        'isMuted': isMuted,
        'noiseSuppression': noiseSuppression,
        'echoCancellation': echoCancellation,
        'mode': mode.name,
      };

  factory AudioConfig.fromJson(Map<String, dynamic> json) {
    return AudioConfig(
      sampleRate: (json['sampleRate'] as num?)?.toInt() ?? defaultSampleRate,
      numChannels: (json['numChannels'] as num?)?.toInt() ?? defaultChannels,
      gain: ((json['gain'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 2.0),
      isMuted: (json['isMuted'] as bool?) ?? false,
      noiseSuppression: (json['noiseSuppression'] as bool?) ?? true,
      echoCancellation: (json['echoCancellation'] as bool?) ?? true,
      mode: StreamMode.fromName(json['mode'] as String?),
    );
  }
}