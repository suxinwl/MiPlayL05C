import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'mv_playback_driver.dart';

/// Windows MV 驱动。原生播放器按需创建，音频仍由 audioplayers 负责。
class MediaKitMvPlaybackDriver extends MvPlaybackDriver {
  /// 可注入播放器和画面工厂，测试无需加载原生 DLL 或访问网络。
  MediaKitMvPlaybackDriver({
    Player Function()? playerFactory,
    Widget Function(Player)? viewFactory,
    this.initializationTimeout = const Duration(seconds: 30),
  }) : _playerFactory = playerFactory ?? _createPlayer,
       _viewFactory = viewFactory ?? _createView;

  final Player Function() _playerFactory;
  final Widget Function(Player) _viewFactory;

  /// 覆盖原生 open 和视频元数据等待的总超时时间。
  final Duration initializationTimeout;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Completer<void> _cancelled = Completer<void>();
  Player? _player;
  Widget? _view;
  Completer<void>? _ready;
  Future<void>? _release;
  MvPlaybackSnapshot _snapshot = const MvPlaybackSnapshot();
  bool _disposed = false;
  bool _initializationStarted = false;
  String? _error;

  static Player _createPlayer() {
    MediaKit.ensureInitialized();
    return Player(
      configuration: const PlayerConfiguration(title: 'oo music · MV'),
    );
  }

  static Widget _createView(Player player) {
    // VideoController 由 Player 管理释放；不显示第二套英文播放控制栏。
    return Video(
      controller: VideoController(player),
      controls: NoVideoControls,
    );
  }

  @override
  MvPlaybackSnapshot get snapshot => _snapshot;

  @override
  Widget buildView() =>
      _disposed ? const SizedBox.shrink() : _view ?? const SizedBox.shrink();

  @override
  Future<void> initialize({
    required Uri uri,
    required Map<String, String> httpHeaders,
  }) async {
    if (_disposed || _initializationStarted) {
      throw const MvPlaybackUnavailableException('MV 播放器已关闭或已初始化');
    }
    _initializationStarted = true;
    final ready = Completer<void>();
    _ready = ready;
    try {
      final player = _playerFactory();
      _player = player;
      _view = _viewFactory(player);
      _subscriptions.addAll([
        player.stream.playing.listen(_handleChanged),
        player.stream.position.listen(_handleChanged),
        player.stream.duration.listen(_handleChanged),
        player.stream.width.listen(_handleChanged),
        player.stream.height.listen(_handleChanged),
        player.stream.error.listen((_) {
          // 原生错误可能包含带签名的 URL，不直接展示或记录。
          _setError('MV 播放失败，请重试或检查网络连接');
        }),
      ]);
      // 超时覆盖 open 和元数据等待，而不只是 open 之后的阶段。
      await Future.any<void>([
        _open(player, ready, uri, httpHeaders),
        _cancelled.future,
      ]).timeout(
        initializationTimeout,
        onTimeout: () =>
            throw const MvPlaybackUnavailableException('MV 加载超时，请重试'),
      );
      if (_disposed) return;
      if (_error != null) throw MvPlaybackUnavailableException(_error!);
    } on Object catch (error) {
      if (_disposed) return;
      final message = error is MvPlaybackUnavailableException
          ? error.message
          : 'MV 加载失败，请重试或检查网络连接';
      _setError(message);
      // 某些原生初始化失败会阻塞 dispose，不能因此阻塞错误界面。
      unawaited(_releasePlayer());
      throw MvPlaybackUnavailableException(message);
    }
  }

  Future<void> _open(
    Player player,
    Completer<void> ready,
    Uri uri,
    Map<String, String> headers,
  ) async {
    await player.open(Media(uri.toString(), httpHeaders: headers), play: false);
    if (_disposed || _player != player) return;
    _handleChanged(null);
    await ready.future;
  }

  void _handleChanged(dynamic _) {
    final player = _player;
    if (_disposed || player == null) return;
    final state = player.state;
    final width = state.width ?? 0;
    final height = state.height ?? 0;
    final initialized =
        state.duration > Duration.zero || (width > 0 && height > 0);
    _snapshot = MvPlaybackSnapshot(
      initialized: initialized,
      playing: state.playing,
      position: state.position,
      duration: state.duration,
      aspectRatio: width > 0 && height > 0 ? width / height : 16 / 9,
      error: _error,
    );
    final ready = _ready;
    if (ready != null &&
        !ready.isCompleted &&
        (initialized || _error != null)) {
      ready.complete();
    }
    notifyListeners();
  }

  void _setError(String message) {
    if (_disposed) return;
    _error = message;
    _handleChanged(null);
    // DLL/画面初始化失败时尚未创建 Player，也要保留安全错误文本。
    if (_player == null) {
      _snapshot = MvPlaybackSnapshot(error: message);
      notifyListeners();
    }
    // 错误页不可见的视频不应继续播放声音。
    unawaited(_releasePlayer());
  }

  Future<void> _perform(Future<void> Function(Player) action) async {
    final player = _player;
    if (_disposed || player == null) return;
    try {
      await action(player);
    } on Object {
      _setError('MV 播放失败，请重试或检查网络连接');
    }
  }

  @override
  Future<void> play() => _perform((player) => player.play());

  @override
  Future<void> pause() => _perform((player) => player.pause());

  @override
  Future<void> seek(Duration position) =>
      _perform((player) => player.seek(position));

  Future<void> _releasePlayer() => _release ??= _releasePlayerOnce();

  Future<void> _releasePlayerOnce() async {
    final player = _player;
    _player = null;
    _view = null;
    final subscriptions = List<StreamSubscription<dynamic>>.of(_subscriptions);
    _subscriptions.clear();
    await Future.wait(
      subscriptions.map((subscription) => subscription.cancel()),
    );
    try {
      await player?.dispose();
    } on Object {
      // 清理失败不覆盖原始错误，也不输出可能含媒体 URL 的原生异常。
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (!_cancelled.isCompleted) _cancelled.complete();
    final ready = _ready;
    if (ready != null && !ready.isCompleted) ready.complete();
    _snapshot = const MvPlaybackSnapshot();
    unawaited(_releasePlayer());
    super.dispose();
  }
}
