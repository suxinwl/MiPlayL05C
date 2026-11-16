import 'package:flutter/services.dart';

import 'app_platform.dart';

/// Android 系统媒体音量桥接。其他平台返回空值并保持现有播放器音量逻辑。
abstract final class SystemVolume {
  static const MethodChannel _channel = MethodChannel('oo_music/system_volume');

  static Future<double?> read() async {
    if (AppPlatform.current != AppPlatformKind.android) return null;
    try {
      final value = await _channel.invokeMethod<num>('get');
      return value != null && value.isFinite
          ? value.toDouble().clamp(0.0, 1.0)
          : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<bool> write(double value) async {
    if (AppPlatform.current != AppPlatformKind.android || !value.isFinite) {
      return false;
    }
    try {
      return await _channel.invokeMethod<bool>('set', <String, Object?>{
            'value': value.clamp(0.0, 1.0),
          }) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}
