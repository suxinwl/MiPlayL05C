import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/platform/desktop_lyrics_platform.dart';
import 'package:oo_music/platform/desktop_lyrics_platform_factory.dart';
import 'package:oo_music/platform/media_kit_mv_playback_driver.dart';
import 'package:oo_music/platform/mv_playback_driver.dart';
import 'package:oo_music/platform/mv_playback_driver_factory.dart';
import 'package:oo_music/platform/video_player_mv_playback_driver.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Windows 工厂按需创建 media_kit 并复用桌面歌词方法通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final driver = createMvPlaybackDriver();
    final lyrics = createDesktopLyricsPlatform();
    expect(driver, isA<MediaKitMvPlaybackDriver>());
    expect(driver.snapshot.initialized, isFalse);
    expect(lyrics, isA<MethodChannelDesktopLyricsPlatform>());
    expect(lyrics.isSupported, isTrue);
    driver.dispose();
    await lyrics.dispose();
  });

  test('macOS 继续使用 video_player，Android 启用悬浮歌词方法通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final macDriver = createMvPlaybackDriver();
    final macLyrics = createDesktopLyricsPlatform();
    expect(macDriver, isA<VideoPlayerMvPlaybackDriver>());
    expect(macLyrics.isSupported, isTrue);
    macDriver.dispose();
    await macLyrics.dispose();

    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final androidDriver = createMvPlaybackDriver();
    final androidLyrics = createDesktopLyricsPlatform();
    expect(androidDriver, isA<VideoPlayerMvPlaybackDriver>());
    expect(androidLyrics, isA<MethodChannelDesktopLyricsPlatform>());
    expect(androidLyrics.isSupported, isTrue);
    await androidLyrics.dispose();
    androidDriver.dispose();

    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final linuxDriver = createMvPlaybackDriver();
    expect(linuxDriver, isA<UnsupportedMvPlaybackDriver>());
    linuxDriver.dispose();
  });

  test('缺失 Windows 原生通道时安全返回，不在关闭后调用通道', () async {
    const channel = MethodChannel('oo_music/test_missing_windows_lyrics');
    final lyrics = MethodChannelDesktopLyricsPlatform(channel: channel);
    expect(
      await lyrics.show(lyric: '歌词', translation: '', isPlaying: false),
      isFalse,
    );
    await lyrics.dispose();
    expect(
      await lyrics.show(lyric: '歌词', translation: '', isPlaying: true),
      isFalse,
    );
    await lyrics.update(lyric: '新歌词', translation: '', isPlaying: true);
    await lyrics.hide();
    await lyrics.dispose();
  });
}
