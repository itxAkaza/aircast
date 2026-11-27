import 'dart:io';
import 'package:jnigen/jnigen.dart';

Future<void> main() async {
  final packageRoot = Platform.script.resolve('../');

  // Locate compiled Kotlin debug bytecode (build first with: flutter build apk --debug)
  final candidates = [
    Directory.fromUri(packageRoot.resolve('build/app/tmp/kotlin-classes/debug')),
    Directory.fromUri(packageRoot.resolve('android/app/build/tmp/kotlin-classes/debug')),
  ];

  final classesDir = candidates.firstWhere(
        (d) => d.existsSync(),
    orElse: () {
      stderr.writeln(
        'Compiled Kotlin classes not found. Run "flutter build apk --debug" first!',
      );
      exit(1);
    },
  );

  // Strip trailing backslash on Windows so JNIgen CLI arguments parse cleanly
  final cleanClassPath = classesDir.path.replaceFirst(RegExp(r'[\\/]+$'), '');

  final generator = JniGenerator(
    input: Input(
      classPath: [Uri.file(cleanClassPath)],
      classes: const ['com.pixelplot.aircast.camera.AirCastCameraBridge'],
      androidSdk: AndroidSdk(
        addGradleDeps: true,
        androidExample: packageRoot,
      ),
    ),
    output: Output(
      dart: DartOutput(
        path: packageRoot.resolve('lib/native/camera_bridge.g.dart'),
        structure: OutputStructure.singleFile,
      ),
    ),
  );

  await generator.generate();
  stdout.writeln('Generated lib/native/camera_bridge.g.dart successfully!');
}