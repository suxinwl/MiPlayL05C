import 'app_platform.dart';
import 'desktop_lyrics_platform.dart';

/// 创建当前平台的桌面歌词窗口实现。
///
/// macOS、Windows 和 Android 使用同一方法通道协议，分别连接 AppKit、
/// Win32 和 Android 悬浮窗。共享控制器和播放器界面不需要感知平台细节。
DesktopLyricsPlatform createDesktopLyricsPlatform() {
  return switch (AppPlatform.current) {
    AppPlatformKind.macOS ||
    AppPlatformKind.windows ||
    AppPlatformKind.android => MethodChannelDesktopLyricsPlatform(),
    _ => const UnsupportedDesktopLyricsPlatform(),
  };
}
