import 'dart:async';

import 'package:flutter/services.dart';

/// 原生桌面歌词窗口回传给 Flutter 的事件。
enum DesktopLyricsEvent { closed, toggle, previous, togglePlayback, next }

/// 桌面歌词窗口的平台实现接口。
///
/// macOS 使用方法通道连接 AppKit，Windows 连接 Win32，Android 连接系统悬浮窗。
abstract interface class DesktopLyricsPlatform {
  /// 当前平台是否真正支持桌面歌词窗口。
  bool get isSupported;

  /// 原生窗口触发的事件。
  Stream<DesktopLyricsEvent> get events;

  /// 显示桌面歌词窗口。
  Future<bool> show({
    required String lyric,
    required String translation,
    required bool isPlaying,
  });

  /// 更新桌面歌词文本和播放状态。
  Future<void> update({
    required String lyric,
    required String translation,
    required bool isPlaying,
  });

  /// 隐藏桌面歌词窗口。
  Future<void> hide();

  /// 释放方法通道和事件资源。
  Future<void> dispose();
}

/// 使用 Flutter MethodChannel 操作原生桌面歌词窗口。
///
/// 该类不判断操作系统；由平台工厂决定是否为当前平台创建实例。这样
/// Android 也复用同一套 Dart 控制器，由原生窗口负责悬浮窗权限和视图。
class MethodChannelDesktopLyricsPlatform implements DesktopLyricsPlatform {
  /// 创建方法通道实现。
  MethodChannelDesktopLyricsPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(_channelName) {
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const String _channelName = 'oo_music/desktop_lyrics';

  final MethodChannel _channel;
  final StreamController<DesktopLyricsEvent> _events =
      StreamController<DesktopLyricsEvent>.broadcast(sync: true);
  bool _disposed = false;

  @override
  bool get isSupported => true;

  @override
  Stream<DesktopLyricsEvent> get events => _events.stream;

  @override
  Future<bool> show({
    required String lyric,
    required String translation,
    required bool isPlaying,
  }) async {
    if (_disposed) {
      return false;
    }
    try {
      final result = await _channel.invokeMethod<bool>('show', <String, Object>{
        'lyric': lyric,
        'translation': translation,
        'isPlaying': isPlaying,
      });
      return result ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> update({
    required String lyric,
    required String translation,
    required bool isPlaying,
  }) async {
    if (_disposed) {
      return;
    }
    await _channel.invokeMethod<void>('update', <String, Object>{
      'lyric': lyric,
      'translation': translation,
      'isPlaying': isPlaying,
    });
  }

  @override
  Future<void> hide() async {
    if (_disposed) {
      return;
    }
    await _channel.invokeMethod<void>('hide');
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'closed':
        _events.add(DesktopLyricsEvent.closed);
        return;
      case 'toggle':
        _events.add(DesktopLyricsEvent.toggle);
        return;
      case 'previous':
        _events.add(DesktopLyricsEvent.previous);
        return;
      case 'togglePlayback':
        _events.add(DesktopLyricsEvent.togglePlayback);
        return;
      case 'next':
        _events.add(DesktopLyricsEvent.next);
        return;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}

/// 当前平台尚未实现原生桌面歌词窗口时使用的空实现。
class UnsupportedDesktopLyricsPlatform implements DesktopLyricsPlatform {
  /// 创建不受支持的平台实现。
  const UnsupportedDesktopLyricsPlatform();

  @override
  bool get isSupported => false;

  @override
  Stream<DesktopLyricsEvent> get events =>
      const Stream<DesktopLyricsEvent>.empty();

  @override
  Future<bool> show({
    required String lyric,
    required String translation,
    required bool isPlaying,
  }) async => false;

  @override
  Future<void> update({
    required String lyric,
    required String translation,
    required bool isPlaying,
  }) async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> dispose() async {}
}
