import '../models/music_source.dart';

/// 播放引擎对共享业务层暴露的播放状态。
enum PlaybackEngineState { stopped, playing, paused, completed, disposed }

/// 音频播放引擎接口。
///
/// Windows 使用 `media_kit`，Android 使用 `just_audio`/系统媒体服务；
/// macOS 和其他已支持平台保留 `audioplayers`。
abstract interface class SourceAwarePlaybackEngine {
  /// 设置网络音源，并使用歌曲所属平台的 CDN 请求来源。
  ///
  /// [initialPosition] 用于音质切换：播放器应在对外宣告加载完成前定位到该
  /// 位置，避免旧音源停止后被短暂重置为 0 秒，导致进度和歌词错位。
  Future<void> setSource(
    String url, {
    required MusicSource source,
    Duration? initialPosition,
  });
}

/// 基础播放引擎接口，供尚未接入来源请求头的平台实现。
abstract interface class PlaybackEngine {
  /// 播放进度流。
  Stream<Duration> get onPositionChanged;

  /// 音频总时长流。
  Stream<Duration> get onDurationChanged;

  /// 播放状态流。
  Stream<PlaybackEngineState> get onStateChanged;

  /// 当前音源播放完成事件。
  Stream<void> get onComplete;

  /// 设置网络音源，但不会自动开始播放。
  Future<void> setSourceUrl(String url);

  /// 暂停播放。
  Future<void> pause();

  /// 继续播放。
  Future<void> resume();

  /// 停止播放。
  Future<void> stop();

  /// 跳转到指定位置。
  Future<void> seek(Duration position);

  /// 设置音量，范围为 0 到 1。
  Future<void> setVolume(double volume);

  /// 释放播放器资源。
  Future<void> dispose();
}

/// Optional mobile system-media integration; desktop engines need not implement it.
abstract interface class SystemMediaPlaybackEngine {
  /// Cancel the old audio source without ending the foreground media service.
  /// A lock-screen skip must not stop/restart that service on Android 12+.
  Future<void> prepareForSourceSwitch();

  /// Update safe track metadata and whether system skip controls are available.
  void updateSystemMedia(PlaybackMetadata metadata, {required bool canSkip});

  /// Bind system controls to the same queue/retry logic used by the application.
  void bindSystemControls({
    required Future<void> Function() previous,
    required Future<void> Function() next,
    required Future<void> Function() retry,
  });
}

/// Track information exposed to the phone's media session, never the signed audio URL.
class PlaybackMetadata {
  const PlaybackMetadata({
    required this.id,
    required this.title,
    required this.artist,
    required this.album,
    required this.duration,
    this.artUri,
  });
  final String id;
  final String title;
  final String artist;
  final String album;
  final Duration duration;
  final Uri? artUri;
}

/// 不包含媒体 URL 或原生异常细节的播放错误。
class PlaybackEngineException implements Exception {
  /// 创建可直接展示的播放错误。
  const PlaybackEngineException(this.message);

  /// 安全的用户提示。
  final String message;
  @override
  String toString() => message;
}
