import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:video_player/video_player.dart';

import 'mv_playback_driver.dart';

/// 基于 `video_player` 的 MV 播放驱动。
///
/// 当前用于 macOS、iOS 和 Android。Windows 端没有 `video_player` 实现，
/// 因此不会由平台工厂创建该驱动。
class VideoPlayerMvPlaybackDriver extends MvPlaybackDriver {
  VideoPlayerController? _controller;
  bool _disposed = false;

  @override
  MvPlaybackSnapshot get snapshot {
    final controller = _controller;
    if (controller == null) {
      return const MvPlaybackSnapshot();
    }
    final value = controller.value;
    return MvPlaybackSnapshot(
      initialized: value.isInitialized,
      playing: value.isPlaying,
      position: value.position,
      duration: value.duration,
      aspectRatio: value.aspectRatio > 0 ? value.aspectRatio : 16 / 9,
      error: value.hasError ? 'MV 播放失败，请重试或检查网络连接' : null,
    );
  }

  @override
  Widget buildView() {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      return const SizedBox.shrink();
    }
    return VideoPlayer(controller);
  }

  @override
  Future<void> initialize({
    required Uri uri,
    required Map<String, String> httpHeaders,
  }) async {
    final controller = VideoPlayerController.networkUrl(
      uri,
      httpHeaders: httpHeaders,
    );
    _controller = controller;
    controller.addListener(_handleControllerChanged);
    await controller.initialize();
    if (_disposed) {
      return;
    }
    notifyListeners();
  }

  @override
  Future<void> play() async {
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seekTo(position);
  }

  void _handleControllerChanged() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    if (_disposed) {
      return;
    }
    _disposed = true;
    final controller = _controller;
    _controller = null;
    controller?.removeListener(_handleControllerChanged);
    if (controller != null) {
      unawaited(controller.dispose());
    }
    super.dispose();
  }
}
