import 'package:flutter/widgets.dart';

/// MV 播放器向共享弹窗暴露的状态快照。
@immutable
class MvPlaybackSnapshot {
  /// 创建不可变的 MV 播放状态。
  const MvPlaybackSnapshot({
    this.initialized = false,
    this.playing = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.aspectRatio = 16 / 9,
    this.error,
  });

  /// 视频是否已经初始化。
  final bool initialized;

  /// 视频是否正在播放。
  final bool playing;

  /// 当前播放位置。
  final Duration position;

  /// 视频总时长。
  final Duration duration;

  /// 视频宽高比。
  final double aspectRatio;

  /// 运行时播放错误；不包含媒体地址或凭据。
  final String? error;
}

/// MV 播放器平台驱动。
///
/// macOS、iOS 和 Android 使用 `video_player`；Windows 使用 `media_kit`。
/// 共享弹窗只依赖本接口。
abstract class MvPlaybackDriver extends ChangeNotifier {
  /// 当前播放状态。
  MvPlaybackSnapshot get snapshot;

  /// 构建平台自己的视频画面组件。
  Widget buildView();

  /// 初始化网络视频。
  Future<void> initialize({
    required Uri uri,
    required Map<String, String> httpHeaders,
  });

  /// 开始播放。
  Future<void> play();

  /// 暂停播放。
  Future<void> pause();

  /// 跳转到指定位置。
  Future<void> seek(Duration position);
}

/// 当前平台没有可用 MV 驱动时抛出的稳定异常。
class MvPlaybackUnavailableException implements Exception {
  /// 创建 MV 播放不可用异常。
  const MvPlaybackUnavailableException(this.message);

  /// 可展示的错误文本。
  final String message;

  @override
  String toString() => message;
}

/// 未实现 MV 驱动的平台使用的占位实现。
class UnsupportedMvPlaybackDriver extends MvPlaybackDriver {
  @override
  MvPlaybackSnapshot get snapshot => const MvPlaybackSnapshot();

  @override
  Widget buildView() => const SizedBox.shrink();

  @override
  Future<void> initialize({
    required Uri uri,
    required Map<String, String> httpHeaders,
  }) async {
    throw const MvPlaybackUnavailableException('当前平台暂不支持 MV 播放');
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> play() async {}

  @override
  Future<void> seek(Duration position) async {}
}
