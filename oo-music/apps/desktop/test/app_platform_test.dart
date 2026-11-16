import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/api/music_api.dart';
import 'package:oo_music/platform/app_platform.dart';

void main() {
  test('Flutter 平台映射到应用平台并区分桌面与移动端', () {
    expect(
      AppPlatform.platformKindFor(TargetPlatform.macOS),
      AppPlatformKind.macOS,
    );
    expect(
      AppPlatform.platformKindFor(TargetPlatform.windows),
      AppPlatformKind.windows,
    );
    expect(
      AppPlatform.platformKindFor(TargetPlatform.android),
      AppPlatformKind.android,
    );

    expect(AppPlatform.isDesktopKind(AppPlatformKind.macOS), isTrue);
    expect(AppPlatform.isDesktopKind(AppPlatformKind.windows), isTrue);
    expect(AppPlatform.isMobileKind(AppPlatformKind.android), isTrue);
    expect(AppPlatform.isMobileKind(AppPlatformKind.windows), isFalse);
  });

  test('平台文案、快捷键和网络 User-Agent 按平台切换', () {
    expect(AppPlatform.displayNameFor(AppPlatformKind.windows), 'Windows');
    expect(AppPlatform.primaryModifierLabelFor(AppPlatformKind.macOS), '⌘');
    expect(
      AppPlatform.primaryModifierLabelFor(AppPlatformKind.windows),
      'Ctrl',
    );
    expect(
      AppPlatform.desktopLyricsShortcutLabelFor(AppPlatformKind.macOS),
      '⌘⇧L',
    );
    expect(
      AppPlatform.desktopLyricsShortcutLabelFor(AppPlatformKind.windows),
      'Ctrl⇧L',
    );
    expect(
      AppPlatform.desktopLyricsShortcutLabelFor(AppPlatformKind.android),
      isEmpty,
    );
    expect(
      AppPlatform.networkUserAgentFor(AppPlatformKind.windows),
      contains('Windows NT'),
    );
    expect(
      AppPlatform.networkUserAgentFor(AppPlatformKind.android),
      contains('Android'),
    );
  });

  test('Android 模拟器默认通过宿主机映射地址访问后端', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final api = MusicApi();
    addTearDown(api.close);

    expect(api.baseUrl, 'http://10.0.2.2:8787');
  });
}
