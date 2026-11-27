enum VideoPreset {
  batterySaver(
    width: 640,
    height: 480,
    fps: 24,
    quality: 65,
    label: '480p 24fps',
  ),
  balanced(width: 1280, height: 720, fps: 30, quality: 75, label: '720p 30fps'),
  highQuality(
    width: 1920,
    height: 1080,
    fps: 30,
    quality: 80,
    label: '1080p 30fps',
  );

  final int width;
  final int height;
  final int fps;
  final int quality;
  final String label;

  const VideoPreset({
    required this.width,
    required this.height,
    required this.fps,
    required this.quality,
    required this.label,
  });

  static VideoPreset fromName(String? name) {
    return VideoPreset.values.firstWhere(
      (e) => e.name == name,
      orElse: () => VideoPreset.balanced,
    );
  }
}

enum VideoFitMode {
  fill, // Crop to fill 1280x720 cleanly (default webcam look)
  fit; // Letterbox full sensor frame

  static VideoFitMode fromName(String? name) {
    return VideoFitMode.values.firstWhere(
      (e) => e.name == name,
      orElse: () => VideoFitMode.fill,
    );
  }
}

class VideoConfig {
  final int width;
  final int height;
  final int targetFps;
  final int jpegQuality;
  final bool isFrontCamera;
  final bool mirrorHorizontal;
  final bool torchEnabled;
  final VideoFitMode fitMode;

  const VideoConfig({
    this.width = 1280,
    this.height = 720,
    this.targetFps = 30,
    this.jpegQuality = 75,
    this.isFrontCamera = false,
    this.mirrorHorizontal = false,
    this.torchEnabled = false,
    this.fitMode = VideoFitMode.fill,
  });

  Map<String, dynamic> toJson() => {
    'width': width,
    'height': height,
    'targetFps': targetFps,
    'jpegQuality': jpegQuality,
    'isFrontCamera': isFrontCamera,
    'mirrorHorizontal': mirrorHorizontal,
    'torchEnabled': torchEnabled,
    'fitMode': fitMode.name,
  };

  factory VideoConfig.fromJson(Map<String, dynamic> json) => VideoConfig(
    width: (json['width'] as num?)?.toInt() ?? 1280,
    height: (json['height'] as num?)?.toInt() ?? 720,
    targetFps: (json['targetFps'] as num?)?.toInt() ?? 30,
    jpegQuality: (json['jpegQuality'] as num?)?.toInt() ?? 75,
    isFrontCamera: (json['isFrontCamera'] as bool?) ?? false,
    mirrorHorizontal: (json['mirrorHorizontal'] as bool?) ?? false,
    torchEnabled: (json['torchEnabled'] as bool?) ?? false,
    fitMode: VideoFitMode.fromName(json['fitMode'] as String?),
  );
}
