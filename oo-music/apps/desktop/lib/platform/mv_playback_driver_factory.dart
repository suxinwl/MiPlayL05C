import 'app_platform.dart';
import 'mv_playback_driver.dart';
import 'media_kit_mv_playback_driver.dart';
import 'video_player_mv_playback_driver.dart';

/// 创建当前平台的 MV 播放驱动。
///
/// Windows 使用 `media_kit` 驱动；Android 继续复用 macOS
/// 当前的 `video_player` 驱动。
MvPlaybackDriver createMvPlaybackDriver() {
  return switch (AppPlatform.current) {
    AppPlatformKind.windows => MediaKitMvPlaybackDriver(),
    AppPlatformKind.macOS ||
    AppPlatformKind.android ||
    AppPlatformKind.iOS => VideoPlayerMvPlaybackDriver(),
    _ => UnsupportedMvPlaybackDriver(),
  };
}
