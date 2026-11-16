import 'dart:async';

import 'package:flutter/services.dart';

import 'desktop_lyrics_platform.dart';
import 'desktop_lyrics_platform_factory.dart';

/// 控制当前平台的置顶桌面歌词窗口。
class DesktopLyricsController {
  /// 创建控制器；原生菜单和关闭事件会通过回调通知调用方。
  ///
  /// [platform] 主要用于测试和后续平台扩展；生产环境默认由平台工厂选择。
  DesktopLyricsController({
    this.onClosed,
    this.onToggle,
    this.onPrevious,
    this.onTogglePlayback,
    this.onNext,
    DesktopLyricsPlatform? platform,
  }) : _platform = platform ?? createDesktopLyricsPlatform() {
    _eventSubscription = _platform.events.listen(_handlePlatformEvent);
  }

  /// 原生窗口被关闭时的回调。
  final VoidCallback? onClosed;

  /// 原生菜单触发显示/关闭切换时的回调。
  final VoidCallback? onToggle;

  /// 桌面歌词窗口点击上一首时的回调。
  final VoidCallback? onPrevious;

  /// 桌面歌词窗口点击播放/暂停时的回调。
  final VoidCallback? onTogglePlayback;

  /// 桌面歌词窗口点击下一首时的回调。
  final VoidCallback? onNext;

  final DesktopLyricsPlatform _platform;
  late final StreamSubscription<DesktopLyricsEvent> _eventSubscription;
  bool _visible = false;

  /// 当前平台是否支持桌面歌词窗口。
  bool get isSupported => _platform.isSupported;

  /// 当前是否正在展示桌面歌词。
  bool get visible => _visible;

  /// 展示桌面歌词窗口并写入当前歌词。
  Future<bool> show({
    required String lyric,
    required String translation,
    required bool isPlaying,
  }) async {
    if (!_platform.isSupported) {
      return false;
    }
    try {
      _visible = await _platform.show(
        lyric: lyric,
        translation: translation,
        isPlaying: isPlaying,
      );
      return _visible;
    } on Object {
      _visible = false;
      return false;
    }
  }

  /// 更新桌面歌词窗口中的两行文本。
  Future<void> update({
    required String lyric,
    required String translation,
    required bool isPlaying,
  }) async {
    if (!_visible) {
      return;
    }
    try {
      await _platform.update(
        lyric: lyric,
        translation: translation,
        isPlaying: isPlaying,
      );
    } on Object {
      // 原生窗口偶尔不可用时不影响主播放器。
      _visible = false;
    }
  }

  /// 隐藏桌面歌词窗口。
  Future<void> hide() async {
    if (!_visible) {
      return;
    }
    _visible = false;
    try {
      await _platform.hide();
    } on Object {
      // 隐藏失败会在下次展示时重新创建窗口。
    }
  }

  void _handlePlatformEvent(DesktopLyricsEvent event) {
    switch (event) {
      case DesktopLyricsEvent.closed:
        _visible = false;
        onClosed?.call();
        return;
      case DesktopLyricsEvent.toggle:
        onToggle?.call();
        return;
      case DesktopLyricsEvent.previous:
        onPrevious?.call();
        return;
      case DesktopLyricsEvent.togglePlayback:
        onTogglePlayback?.call();
        return;
      case DesktopLyricsEvent.next:
        onNext?.call();
        return;
    }
  }

  /// 释放平台事件订阅并隐藏窗口。
  Future<void> dispose() async {
    await hide();
    await _eventSubscription.cancel();
    await _platform.dispose();
  }
}
