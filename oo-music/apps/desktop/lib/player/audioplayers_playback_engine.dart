import 'package:audioplayers/audioplayers.dart';

import 'playback_engine.dart';

/// 基于 `audioplayers` 的跨平台播放引擎实现。
///
/// Mac 和移动平台保留这一实现；Windows 工厂改用异步 media_kit 驱动。
class AudioplayersPlaybackEngine implements PlaybackEngine {
  /// 创建播放引擎；测试可以注入已有的 [AudioPlayer]。
  AudioplayersPlaybackEngine({AudioPlayer? player})
    : _player = player ?? AudioPlayer();

  final AudioPlayer _player;

  @override
  Stream<Duration> get onPositionChanged => _player.onPositionChanged;

  @override
  Stream<Duration> get onDurationChanged => _player.onDurationChanged;

  @override
  Stream<PlaybackEngineState> get onStateChanged =>
      _player.onPlayerStateChanged.map(_mapState);

  @override
  Stream<void> get onComplete => _player.onPlayerComplete;

  @override
  Future<void> setSourceUrl(String url) => _player.setSource(UrlSource(url));

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> resume() => _player.resume();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> dispose() => _player.dispose();

  PlaybackEngineState _mapState(PlayerState state) {
    return switch (state) {
      PlayerState.stopped => PlaybackEngineState.stopped,
      PlayerState.playing => PlaybackEngineState.playing,
      PlayerState.paused => PlaybackEngineState.paused,
      PlayerState.completed => PlaybackEngineState.completed,
      PlayerState.disposed => PlaybackEngineState.disposed,
    };
  }
}
