import 'audioplayers_playback_engine.dart';
import 'android_playback_engine.dart';
import '../platform/app_platform.dart';
import 'media_kit_playback_engine.dart';
import 'playback_engine.dart';

/// 创建当前平台默认的音频播放引擎。
///
/// Windows 使用串行、可取消的 media_kit 音频适配器；不改变 Mac 的播放实现。
PlaybackEngine createPlaybackEngine() => switch (AppPlatform.current) {
  AppPlatformKind.windows => MediaKitPlaybackEngine(),
  AppPlatformKind.android => androidPlaybackEngine(),
  _ => AudioplayersPlaybackEngine(),
};
