import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 客户端当前运行的平台类型。
///
/// 业务层与共享 UI 应使用该抽象，而不是直接判断 `dart:io Platform`，以便
/// 同一份代码可以同时编译到 macOS、Windows 和 Android。
enum AppPlatformKind { macOS, windows, linux, android, iOS, fuchsia }

/// 跨平台能力与文案的统一入口。
class AppPlatform {
  const AppPlatform._();

  /// 当前运行平台。
  static AppPlatformKind get current => platformKindFor(defaultTargetPlatform);

  /// 将 Flutter 的平台枚举转换为应用自己的平台枚举。
  static AppPlatformKind platformKindFor(TargetPlatform platform) {
    return switch (platform) {
      TargetPlatform.macOS => AppPlatformKind.macOS,
      TargetPlatform.windows => AppPlatformKind.windows,
      TargetPlatform.linux => AppPlatformKind.linux,
      TargetPlatform.android => AppPlatformKind.android,
      TargetPlatform.iOS => AppPlatformKind.iOS,
      TargetPlatform.fuchsia => AppPlatformKind.fuchsia,
    };
  }

  /// 当前是否为桌面平台。
  static bool get isDesktop => isDesktopKind(current);

  /// 当前是否为移动平台。
  static bool get isMobile => isMobileKind(current);

  /// 指定平台是否为桌面平台。
  static bool isDesktopKind(AppPlatformKind kind) {
    return kind == AppPlatformKind.macOS ||
        kind == AppPlatformKind.windows ||
        kind == AppPlatformKind.linux;
  }

  /// 指定平台是否为移动平台。
  static bool isMobileKind(AppPlatformKind kind) {
    return kind == AppPlatformKind.android ||
        kind == AppPlatformKind.iOS ||
        kind == AppPlatformKind.fuchsia;
  }

  /// 面向用户展示的平台名称。
  static String get displayName => displayNameFor(current);

  /// 返回指定平台的面板文案名称。
  static String displayNameFor(AppPlatformKind kind) {
    return switch (kind) {
      AppPlatformKind.macOS => 'macOS',
      AppPlatformKind.windows => 'Windows',
      AppPlatformKind.linux => 'Linux',
      AppPlatformKind.android => 'Android',
      AppPlatformKind.iOS => 'iOS',
      AppPlatformKind.fuchsia => 'Fuchsia',
    };
  }

  /// QQ 音乐 CDN 请求使用的平台 User-Agent。
  static String get networkUserAgent => networkUserAgentFor(current);

  /// 返回适合指定平台的浏览器 User-Agent。
  static String networkUserAgentFor(AppPlatformKind kind) {
    return switch (kind) {
      AppPlatformKind.macOS =>
        'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/131.0.0.0 Safari/537.36',
      AppPlatformKind.windows =>
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/131.0.0.0 Safari/537.36',
      AppPlatformKind.linux =>
        'Mozilla/5.0 (X11; Linux x86_64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/131.0.0.0 Safari/537.36',
      AppPlatformKind.android =>
        'Mozilla/5.0 (Linux; Android 14) '
            'AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/131.0.0.0 Mobile Safari/537.36',
      AppPlatformKind.iOS =>
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) '
            'AppleWebKit/605.1.15 (KHTML, like Gecko) '
            'Version/17.0 Mobile/15E148 Safari/604.1',
      AppPlatformKind.fuchsia =>
        'Mozilla/5.0 (X11; Fuchsia) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    };
  }

  /// 当前桌面平台的主修饰键显示文本。
  static String get primaryModifierLabel => primaryModifierLabelFor(current);

  /// 返回指定平台的主修饰键显示文本。
  static String primaryModifierLabelFor(AppPlatformKind kind) {
    return kind == AppPlatformKind.macOS ? '⌘' : 'Ctrl';
  }

  /// 桌面歌词快捷键的面板提示文本；移动平台没有键盘快捷键。
  static String get desktopLyricsShortcutLabel {
    return desktopLyricsShortcutLabelFor(current);
  }

  /// 返回指定平台的桌面歌词快捷键提示文本。
  static String desktopLyricsShortcutLabelFor(AppPlatformKind kind) {
    if (!isDesktopKind(kind)) {
      return '';
    }
    return '${primaryModifierLabelFor(kind)}⇧L';
  }

  /// 判断当前按键事件是否触发桌面歌词显示/隐藏。
  static bool matchesDesktopLyricsShortcut(KeyEvent event) {
    final kind = current;
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyL ||
        !isDesktopKind(kind)) {
      return false;
    }
    final primaryPressed = kind == AppPlatformKind.macOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
    return primaryPressed && HardwareKeyboard.instance.isShiftPressed;
  }

  /// 搜索框聚焦快捷键的面板提示文本。
  static String get searchShortcutLabel => '${primaryModifierLabel}K';

  /// 判断当前按键事件是否触发搜索框聚焦。
  static bool matchesSearchShortcut(KeyEvent event) {
    final kind = current;
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyK ||
        !isDesktopKind(kind) ||
        HardwareKeyboard.instance.isShiftPressed) {
      return false;
    }
    return kind == AppPlatformKind.macOS
        ? HardwareKeyboard.instance.isMetaPressed
        : HardwareKeyboard.instance.isControlPressed;
  }

  /// 判断当前按键事件是否为 Escape。
  static bool matchesEscape(KeyEvent event) {
    return event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape;
  }
}
