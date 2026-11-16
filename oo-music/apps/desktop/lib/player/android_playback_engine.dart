import 'dart:async';
import 'dart:ui' show Color;

import 'package:audio_service/audio_service.dart' as service;
import 'package:audio_session/audio_session.dart';
import 'package:just_audio/just_audio.dart';

import '../models/music_source.dart';
import '../platform/app_platform.dart';
import 'playback_engine.dart';

AndroidPlaybackEngine? _androidEngine;

/// Android-only initialization. Mac and Windows do not start a media service.
Future<void> initializeAndroidPlaybackService() async {
  final engine = await service.AudioService.init<AndroidPlaybackEngine>(
    builder: () => _androidEngine ??= AndroidPlaybackEngine(),
    config: const service.AudioServiceConfig(
      androidNotificationChannelId: 'com.yskj0864.oo_music.playback',
      androidNotificationChannelName: '音乐播放',
      androidNotificationChannelDescription: '后台音乐播放与媒体控制',
      notificationColor: Color(0xFF69DFA0),
      androidNotificationIcon: 'drawable/ic_stat_music',
      androidNotificationClickStartsActivity: true,
      // Keep transport controls available when the app is backgrounded.
      // Android 12 may reject restarting a foreground service from a lockscreen
      // pause. Keep it foreground during pause; an explicit stop still ends it.
      androidStopForegroundOnPause: false,
    ),
  );
  _androidEngine = engine;
  final session = await AudioSession.instance;
  await session.configure(const AudioSessionConfiguration.music());
}

/// The activity and notification use exactly one engine and one application queue.
AndroidPlaybackEngine androidPlaybackEngine() =>
    _androidEngine ??= AndroidPlaybackEngine();

/// ExoPlayer-backed Android audio with cancellation, timeouts and safe errors.
/// just_audio handles audio focus, ducking/interruption and unplugged headphones.
class AndroidPlaybackEngine extends service.BaseAudioHandler
    implements
        PlaybackEngine,
        SourceAwarePlaybackEngine,
        SystemMediaPlaybackEngine {
  AndroidPlaybackEngine({
    AudioPlayer Function()? playerFactory,
    this.loadTimeout = const Duration(seconds: 20),
    this.commandTimeout = const Duration(seconds: 5),
  }) : _playerFactory = playerFactory ?? _createPlayer;

  static AudioPlayer _createPlayer() => AudioPlayer(
    // Android ExoPlayer accepts headers directly; no HTTP proxy is needed.
    useProxyForRequestHeaders: false,
  );

  final AudioPlayer Function() _playerFactory;
  final Duration loadTimeout;
  final Duration commandTimeout;
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _durations = StreamController<Duration>.broadcast(sync: true);
  final _states = StreamController<PlaybackEngineState>.broadcast(sync: true);
  final _completed = StreamController<void>.broadcast(sync: true);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _commands = Future<void>.value();
  Future<void>? _disposal;
  AudioPlayer? _player;
  Completer<void>? _cancelLoad;
  int _generation = 0;
  bool _loaded = false;
  bool _loading = false;
  bool _disposed = false;
  bool _completionSent = false;
  bool _canSkip = false;
  double _volume = 0.8;
  Future<void> Function()? _previous;
  Future<void> Function()? _next;
  Future<void> Function()? _retry;

  @override
  Stream<Duration> get onPositionChanged => _positions.stream;
  @override
  Stream<Duration> get onDurationChanged => _durations.stream;
  @override
  Stream<PlaybackEngineState> get onStateChanged => _states.stream;
  @override
  Stream<void> get onComplete => _completed.stream;

  @override
  void bindSystemControls({
    required Future<void> Function() previous,
    required Future<void> Function() next,
    required Future<void> Function() retry,
  }) {
    _previous = previous;
    _next = next;
    _retry = retry;
  }

  @override
  void updateSystemMedia(PlaybackMetadata metadata, {required bool canSkip}) {
    if (_disposed) return;
    _canSkip = canSkip;
    mediaItem.add(
      service.MediaItem(
        id: metadata.id,
        title: metadata.title,
        artist: metadata.artist,
        album: metadata.album,
        duration: metadata.duration,
        artUri: metadata.artUri,
      ),
    );
    _publish();
  }

  @override
  Future<void> prepareForSourceSwitch() async {
    if (_disposed) return;
    _invalidate();
    _loading = true;
    _states.add(PlaybackEngineState.stopped);
    _publish();
  }

  bool _current(int generation, AudioPlayer player) =>
      !_disposed && generation == _generation && identical(_player, player);

  Future<void> _enqueue(Future<void> Function() action) {
    final result = _commands.then((_) async {
      if (!_disposed) await action();
    });
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  int _invalidate() {
    final cancelled = _cancelLoad;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
    _cancelLoad = null;
    _loaded = false;
    _completionSent = false;
    final player = _player;
    if (player != null) _discard(player);
    return ++_generation;
  }

  AudioPlayer _createSourcePlayer(int generation) {
    final player = _playerFactory();
    _player = player;
    _subscriptions.addAll([
      player.positionStream.listen((position) {
        if (_current(generation, player) && _loaded) {
          _positions.add(position);
          _publish();
        }
      }),
      player.durationStream.listen((duration) {
        if (_current(generation, player) && _loaded && duration != null) {
          _durations.add(duration);
          final item = mediaItem.value;
          if (item != null) mediaItem.add(item.copyWith(duration: duration));
        }
      }),
      player.playerStateStream.listen((state) {
        if (!_current(generation, player) || !_loaded) return;
        if (state.processingState == ProcessingState.completed) {
          if (!_completionSent) {
            _completionSent = true;
            _states.add(PlaybackEngineState.completed);
            _completed.add(null);
          }
        } else {
          _states.add(
            state.playing
                ? PlaybackEngineState.playing
                : PlaybackEngineState.paused,
          );
        }
        _publish();
      }),
      player.errorStream.listen((_) {
        if (_current(generation, player) && _loaded) {
          _fail(player, '音频播放失败，请重试或切换歌曲');
        }
      }),
    ]);
    return player;
  }

  void _publish({service.AudioProcessingState? processingState}) {
    if (_disposed) return;
    final player = _player;
    final state =
        processingState ??
        (!_loaded || player == null
            ? _loading
                  ? service.AudioProcessingState.loading
                  : service.AudioProcessingState.idle
            : switch (player.processingState) {
                ProcessingState.idle => service.AudioProcessingState.idle,
                ProcessingState.loading => service.AudioProcessingState.loading,
                ProcessingState.buffering =>
                  service.AudioProcessingState.buffering,
                ProcessingState.ready => service.AudioProcessingState.ready,
                ProcessingState.completed =>
                  service.AudioProcessingState.completed,
              });
    final playing =
        _loaded &&
        player?.playing == true &&
        state != service.AudioProcessingState.completed;
    playbackState.add(
      service.PlaybackState(
        controls: [
          if (_canSkip) service.MediaControl.skipToPrevious,
          playing ? service.MediaControl.pause : service.MediaControl.play,
          if (_canSkip) service.MediaControl.skipToNext,
          service.MediaControl.stop,
        ],
        systemActions: const {service.MediaAction.seek},
        androidCompactActionIndices: _canSkip ? const [0, 1, 2] : const [0],
        processingState: state,
        playing: playing,
        updatePosition: player?.position ?? Duration.zero,
        bufferedPosition: player?.bufferedPosition ?? Duration.zero,
      ),
    );
  }

  @override
  Future<void> setSourceUrl(String url) =>
      setSource(url, source: MusicSource.qq);

  @override
  Future<void> setSource(
    String url, {
    required MusicSource source,
    Duration? initialPosition,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        !{'http', 'https'}.contains(uri.scheme)) {
      return Future<void>.error(const PlaybackEngineException('音源地址无效'));
    }
    if (_disposed) return Future<void>.value();
    final generation = _invalidate();
    _loading = true;
    final cancelled = Completer<void>();
    _cancelLoad = cancelled;
    _publish(processingState: service.AudioProcessingState.loading);
    return _enqueue(() async {
      if (generation != _generation) return;
      AudioPlayer? player;
      try {
        player = _createSourcePlayer(generation);
        final requestedPosition = initialPosition ?? Duration.zero;
        final duration = await Future.any<Duration?>([
          player.setUrl(
            url,
            headers: {
              'Referer': source.referer,
              'User-Agent': AppPlatform.networkUserAgent,
            },
            initialPosition: requestedPosition > Duration.zero
                ? requestedPosition
                : null,
          ),
          cancelled.future.then<Duration?>((_) => null),
        ]).timeout(loadTimeout);
        if (!_current(generation, player)) return;
        await player.setVolume(_volume).timeout(commandTimeout);
        if (!_current(generation, player)) return;
        _loaded = true;
        _loading = false;
        _cancelLoad = null;
        _positions.add(requestedPosition);
        if (duration != null) _durations.add(duration);
        _states.add(PlaybackEngineState.paused);
        _publish();
      } on Object catch (error) {
        if (_disposed || generation != _generation) return;
        if (player != null) _discard(player);
        _loaded = false;
        _loading = false;
        _cancelLoad = null;
        _publish();
        throw PlaybackEngineException(
          error is TimeoutException ? '音源加载超时，请重试或切换歌曲' : '音频加载失败，请重试或检查网络连接',
        );
      }
    });
  }

  void _fail(AudioPlayer player, String message) {
    _loaded = false;
    _loading = false;
    _states.addError(PlaybackEngineException(message));
    _states.add(PlaybackEngineState.stopped);
    _discard(player);
    _publish();
  }

  Future<void> _control(Future<void> Function(AudioPlayer) action) {
    final generation = _generation;
    return _enqueue(() async {
      final player = _player;
      if (player == null || !_loaded || generation != _generation) return;
      try {
        await action(player).timeout(commandTimeout);
        if (_current(generation, player)) _publish();
      } on Object {
        if (_current(generation, player)) {
          _fail(player, '播放操作失败，请重试或切换歌曲');
          throw const PlaybackEngineException('播放操作失败，请重试或切换歌曲');
        }
      }
    });
  }

  @override
  Future<void> play() async {
    if (_loading || _disposed) return;
    if (!_loaded && _retry != null) {
      await _retry!();
    } else {
      if (_player?.processingState == ProcessingState.completed) {
        await seek(Duration.zero);
      }
      await resume();
    }
  }

  @override
  Future<void> resume() => _control((player) async {
    final generation = _generation;
    // just_audio play() completes when playback finishes/pauses, not when it
    // begins; awaiting it would block every subsequent command in the queue.
    unawaited(
      player.play().catchError((Object _) {
        if (_current(generation, player)) _fail(player, '音频播放失败，请重试');
      }),
    );
  });
  @override
  Future<void> pause() => _control((player) => player.pause());
  @override
  Future<void> seek(Duration position) => _control((player) async {
    _completionSent = false;
    await player.seek(position);
  });
  @override
  Future<void> setVolume(double volume) {
    _volume = volume.clamp(0, 1);
    return _control((player) => player.setVolume(_volume));
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    _invalidate();
    _loading = false;
    _states.add(PlaybackEngineState.stopped);
    _publish();
    await super.stop();
  }

  @override
  Future<void> skipToPrevious() async {
    if (_canSkip) await _previous?.call();
  }

  @override
  Future<void> skipToNext() async {
    if (_canSkip) await _next?.call();
  }

  @override
  Future<void> onTaskRemoved() async {
    // Removing the task while a background skip is resolving a new source
    // must not terminate that request just because the old audio was paused.
    if (!_loading && _player?.playing != true) await stop();
  }

  void _discard(AudioPlayer player) {
    if (!identical(_player, player)) return;
    _player = null;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    unawaited(
      player.dispose().timeout(commandTimeout).catchError((Object _) {}),
    );
  }

  @override
  Future<void> dispose() => _disposal ??= _disposeOnce();
  Future<void> _disposeOnce() async {
    await stop();
    _disposed = true;
    _previous = null;
    _next = null;
    _retry = null;
    await Future.wait([
      _positions.close(),
      _durations.close(),
      _states.close(),
      _completed.close(),
    ]);
  }
}
