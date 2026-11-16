import 'package:flutter/services.dart';

const MethodChannel _channel = MethodChannel('oo_music/android_permissions');

/// Requests notification permission on Android 13 and newer.
///
/// Older Android versions and unsupported hosts return without changing app
/// startup. Foreground playback notifications still require the user to keep
/// notifications enabled in system settings.
Future<void> requestAndroidNotificationPermission() async {
  try {
    await _channel.invokeMethod<bool>('requestNotificationPermission');
  } on MissingPluginException {
    // Desktop and test hosts do not register the Android channel.
  } on PlatformException {
    // Permission denial must not block audio service initialization.
  }
}

/// 返回系统是否允许当前应用展示通知。
Future<bool> androidNotificationsEnabled() async {
  try {
    return await _channel.invokeMethod<bool>('notificationsEnabled') ?? true;
  } on MissingPluginException {
    return true;
  } on PlatformException {
    return false;
  }
}

/// 打开当前应用的通知设置；ColorOS 等系统可在此开启通知和媒体控制。
Future<void> openAndroidNotificationSettings() async {
  try {
    await _channel.invokeMethod<void>('openNotificationSettings');
  } on MissingPluginException {
    return;
  } on PlatformException {
    return;
  }
}
