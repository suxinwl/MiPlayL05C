import 'dart:async';

import 'package:media_kit/media_kit.dart';

import '../models/music_source.dart';
import '../platform/app_platform.dart';
import 'playback_engine.dart';

/// Windows 音频引擎：异步 libmpv，不使用阻塞平台线程的 Media Foundation 加载路径。
///
/// 所有原生命令串行；新音源/stop 立即取消上一轮的元数据等待。超时的原生实例
/// 会隔离并释放，后续歌曲不会继续排在一个失去响应的实例后面。
class MediaKitPlaybackEngine
    implements PlaybackEngine, SourceAwarePlaybackEngine {
  /// 测试可注入播放器与超时，不需要加载原生库或访问 QQ 音乐。
  MediaKitPlaybackEngine({
    Player Function()? playerFactory,
    this.loadTimeout = const Duration(seconds: 20),
    this.commandTimeout = const Duration(seconds: 5),
  }) : _playerFactory = playerFactory ?? _createPlayer;

  final Player Function() _playerFactory;

  /// 元数据加载的最长等待时间。
  final Duration loadTimeout;

  /// 单个原生命令的最长等待时间。
  final Duration commandTimeout;
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _durations = StreamController<Duration>.broadcast(sync: true);
  final _states = StreamController<PlaybackEngineState>.broadcast(sync: true);
  final _completed = StreamController<void>.broadcast(sync: true);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Future<void> _commands = Future<void>.value();
  Future<void>? _disposal;
  Player? _player;
  _AudioLoad? _load;
  _AudioLoad? _activeLoad;
  int _generation = 0;
  double _volume = 0.8;
  bool _loaded = false;
  bool _disposed = false;

  static Player _createPlayer() {
    MediaKit.ensureInitialized();
    return Player(configuration: const PlayerConfiguration(title: 'oo music'));
  }

  @override
  Stream<Duration> get onPositionChanged => _positions.stream;
  @override
  Stream<Duration> get onDurationChanged => _durations.stream;
  @override
  Stream<PlaybackEngineState> get onStateChanged => _states.stream;
  @override
  Stream<void> get onComplete => _completed.stream;

  bool _current(_AudioLoad load) =>
      !_disposed && load.generation == _generation;
  bool _same(Player player) => !_disposed && identical(_player, player);

  Future<void> _enqueue(Future<void> Function() action) {
    final result = _commands.then((_) async {
      if (!_disposed) await action();
    });
    // One failed request must not poison the queue for the next song.
    _commands = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  int _invalidate() {
    final load = _load;
    if (load != null && !load.cancelled.isCompleted) load.cancelled.complete();
    _load = null;
    _loaded = false;
    // Cancel the old source's listeners before a new open is queued. A queued
    // old error/position must not be delivered to the next source's session.
    _cancelSourceSubscriptions();
    return ++_generation;
  }

  Player _ensurePlayer() {
    final existing = _player;
    final player = existing ?? _playerFactory();
    _player = player;
    final generation = _generation;
    bool currentSource() => _same(player) && generation == _generation;
    _subscriptions.addAll([
      player.stream.position.listen((position) {
        if (currentSource() && _loaded) _positions.add(position);
      }),
      player.stream.duration.listen((duration) {
        if (!currentSource()) return;
        _metadataReady(player);
        if (_loaded && duration > Duration.zero) _durations.add(duration);
      }),
      player.stream.playing.listen((playing) {
        if (currentSource() && _loaded) {
          _states.add(
            playing ? PlaybackEngineState.playing : PlaybackEngineState.paused,
          );
        }
      }),
      player.stream.completed.listen((completed) {
        if (currentSource() && _loaded && completed && _load == null) {
          _states.add(PlaybackEngineState.completed);
          _completed.add(null);
        }
      }),
      player.stream.error.listen((_) {
        // Never expose native errors containing signed CDN URLs or credentials.
        if (!currentSource()) return;
        final load = _activeLoad;
        if (load != null && _current(load)) {
          load.error = '音频加载失败，请重试或检查网络连接';
          if (!load.ready.isCompleted) load.ready.complete();
        } else if (_loaded) {
          _loaded = false;
          _states.addError(const PlaybackEngineException('音频播放失败，请重试或切换歌曲'));
          _states.add(PlaybackEngineState.stopped);
          _discard(player);
        }
      }),
    ]);
    return player;
  }

  void _metadataReady(Player player) {
    final load = _activeLoad;
    if (load != null &&
        _current(load) &&
        load.acceptMetadata &&
        player.state.duration > Duration.zero &&
        !load.ready.isCompleted) {
      load.ready.complete();
    }
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
    if (_disposed) return Future<void>.value();
    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        !{'http', 'https'}.contains(uri.scheme)) {
      return Future<void>.error(const PlaybackEngineException('音源地址无效'));
    }
    final load = _AudioLoad(_invalidate());
    _load = load;
    return _enqueue(() async {
      if (!_current(load)) return;
      _activeLoad = load;
      Player? player;
      try {
        player = _ensurePlayer();
        await player
            .open(
              Media(
                url,
                httpHeaders: {
                  'Referer': source.referer,
                  'User-Agent': AppPlatform.networkUserAgent,
                },
              ),
              play: false,
            )
            .timeout(commandTimeout);
        if (!_current(load)) return;
        load.acceptMetadata = true;
        _metadataReady(player);
        await Future.any<void>([load.ready.future, load.cancelled.future])
            .timeout(loadTimeout);
        if (!_current(load)) return;
        if (load.error != null) throw PlaybackEngineException(load.error!);
        final requestedPosition = initialPosition ?? Duration.zero;
        if (requestedPosition > Duration.zero) {
          await player.seek(requestedPosition).timeout(commandTimeout);
        }
        if (!_current(load)) return;
        await player.setVolume(_volume * 100).timeout(commandTimeout);
        if (!_current(load)) return;
        _loaded = true;
        _load = null;
        _positions.add(requestedPosition);
        _durations.add(player.state.duration);
        _states.add(PlaybackEngineState.paused);
      } on Object catch (error) {
        // Discard this exact native instance even if its timed-out load is old.
        // The next queued request creates a fresh instance instead of hanging.
        if (player != null) _discard(player);
        if (!_current(load)) return;
        _load = null;
        _loaded = false;
        throw PlaybackEngineException(
          error is TimeoutException
              ? '音源加载超时，请重试或切换歌曲'
              : error is PlaybackEngineException
              ? error.message
              : '音频加载失败，请重试或检查网络连接',
        );
      } finally {
        if (identical(_activeLoad, load)) _activeLoad = null;
      }
    });
  }

  Future<void> _control(Future<void> Function(Player) action) {
    final generation = _generation;
    return _enqueue(() async {
      if (generation != _generation || !_loaded) return;
      final player = _player;
      if (player == null) return;
      try {
        await action(player).timeout(commandTimeout);
      } on Object {
        _discard(player);
        if (generation != _generation) return;
        _loaded = false;
        throw const PlaybackEngineException('播放操作失败，请重试或切换歌曲');
      }
    });
  }

  @override
  Future<void> pause() => _control((player) => player.pause());
  @override
  Future<void> resume() => _control((player) => player.play());
  @override
  Future<void> seek(Duration position) =>
      _control((player) => player.seek(position));

  @override
  Future<void> setVolume(double volume) {
    _volume = volume.clamp(0, 1);
    return _control((player) => player.setVolume(_volume * 100));
  }

  @override
  Future<void> stop() {
    if (_disposed) return Future<void>.value();
    final generation = _invalidate();
    _states.add(PlaybackEngineState.stopped);
    return _enqueue(() async {
      if (generation != _generation) return;
      final player = _player;
      if (player == null) return;
      try {
        await player.stop().timeout(commandTimeout);
      } on Object {
        _discard(player);
        // A broken old source must not prevent loading the next one.
      }
    });
  }

  void _discard(Player player) {
    if (!identical(_player, player)) return;
    _player = null;
    _cancelSourceSubscriptions();
    unawaited(
      player.dispose().timeout(commandTimeout).catchError((Object _) {
        // Native cleanup is best-effort; no secret-bearing error logging.
      }),
    );
  }

  void _cancelSourceSubscriptions() {
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    for (final subscription in subscriptions) {
      unawaited(subscription.cancel());
    }
  }

  @override
  Future<void> dispose() => _disposal ??= _disposeOnce();

  Future<void> _disposeOnce() async {
    _disposed = true;
    _invalidate();
    final player = _player;
    if (player != null) _discard(player);
    await Future.wait([
      _positions.close(),
      _durations.close(),
      _states.close(),
      _completed.close(),
    ]);
  }
}

class _AudioLoad {
  _AudioLoad(this.generation);
  final int generation;
  final ready = Completer<void>();
  final cancelled = Completer<void>();
  bool acceptMetadata = false;
  String? error;
}
