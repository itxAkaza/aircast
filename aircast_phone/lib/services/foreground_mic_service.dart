import 'dart:io';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

@pragma('vm:entry-point')
void airCastForegroundCallback() {
  FlutterForegroundTask.setTaskHandler(_AirCastTaskHandler());
}

class _AirCastTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}

  @override
  void onReceiveData(Object data) {}

  @override
  void onNotificationButtonPressed(String id) {
    FlutterForegroundTask.sendDataToMain({'action': id});
  }

  @override
  void onNotificationPressed() {
    // Tapping the notification brings the app to the foreground automatically.
  }
}

class ForegroundMicService {
  static const int _serviceId = 4820;
  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'aircast_mic_stream',
        channelName: 'AirCast Live Microphone',
        channelDescription:
        'Keeps your phone microphone streaming while the screen is locked.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(10000),
        autoRunOnBoot: false,
        autoRunOnMyPackageReplaced: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    _initialized = true;
  }

  static Future<void> ensureNotificationPermission() async {
    if (!Platform.isAndroid) return;
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (!Platform.isAndroid) return true;
    return FlutterForegroundTask.isIgnoringBatteryOptimizations;
  }

  static Future<bool> requestIgnoreBatteryOptimization() async {
    if (!Platform.isAndroid) return true;
    return FlutterForegroundTask.requestIgnoreBatteryOptimization();
  }

  /// IMPORTANT: Call only AFTER RECORD_AUDIO runtime permission is granted
  /// (Android 14+ throws SecurityException otherwise).
  static Future<bool> start({
    required String serverName,
    required bool isMuted,
  }) async {
    if (!Platform.isAndroid) return true;
    init();
    await ensureNotificationPermission();

    final title = isMuted ? 'AirCast Mic (Muted)' : 'AirCast Mic Active';
    final text = 'Streaming 48 kHz PCM to $serverName';
    final buttons = _buildButtons(isMuted: isMuted);

    if (await FlutterForegroundTask.isRunningService) {
      final res = await FlutterForegroundTask.updateService(
        notificationTitle: title,
        notificationText: text,
        notificationButtons: buttons,
      );
      return res is ServiceRequestSuccess;
    }

    final res = await FlutterForegroundTask.startService(
      serviceId: _serviceId,
      serviceTypes: [ForegroundServiceTypes.microphone],
      notificationTitle: title,
      notificationText: text,
      notificationButtons: buttons,
      callback: airCastForegroundCallback,
    );
    return res is ServiceRequestSuccess;
  }

  static Future<void> updateStatus({
    required String title,
    required String text,
    required bool isMuted,
  }) async {
    if (!Platform.isAndroid) return;
    if (!await FlutterForegroundTask.isRunningService) return;

    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
      notificationButtons: _buildButtons(isMuted: isMuted),
    );
  }

  static Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }

  static List<NotificationButton> _buildButtons({required bool isMuted}) {
    return [
      NotificationButton(
        id: 'toggle_mute',
        text: isMuted ? 'Unmute' : 'Mute',
      ),
      const NotificationButton(
        id: 'stop_mic',
        text: 'Stop Mic',
      ),
    ];
  }
}