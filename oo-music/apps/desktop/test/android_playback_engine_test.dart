import 'dart:async';

import 'package:audio_service/audio_service.dart' as service;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/player/android_playback_engine.dart';
import 'package:oo_music/player/playback_engine.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('Android 加载保持 CDN 头，不自动播放，系统和界面状态一致', () async {
    final player = _FakePlayer();
    final engine = AndroidPlaybackEngine(playerFactory: () => player);
    addTearDown(engine.dispose);
    engine.updateSystemMedia(_metadata, canSkip: true);
    await engine.setVolume(0.35);
    await engine.setSourceUrl('https://example.test/song.mp3');
    expect(player.headers?['Referer'], 'https://y.qq.com/');
    expect(player.headers?['User-Agent'], contains('Android'));
    expect(player.playCalls, 0);
    expect(player.volume, 0.35);
    await engine.resume().timeout(const Duration(milliseconds: 100));
    expect(player.playCalls, 1);
    // play() remains pending until pause. The engine must not await it or
    // subsequent volume/seek commands would stall behind the song's duration.
    await engine.seek(const Duration(seconds: 10));
    await engine.pause();
    expect(player.position, const Duration(seconds: 10));
    expect(engine.playbackState.value.playing, isFalse);
    expect(engine.mediaItem.value?.title, _metadata.title);
    expect(engine.mediaItem.value?.id, '101');
    expect(engine.mediaItem.value?.id, isNot(contains('https')));
    expect(
      engine.playbackState.value.controls,
      contains(service.MediaControl.skipToNext),
    );
  });

  test('Android 音质切换在加载完成前定位到原进度', () async {
    final player = _FakePlayer();
    final engine = AndroidPlaybackEngine(playerFactory: () => player);
    addTearDown(engine.dispose);
    final positions = <Duration>[];
    final subscription = engine.onPositionChanged.listen(positions.add);
    addTearDown(subscription.cancel);

    await engine.setSource(
      'https://example.test/hq.flac',
      source: MusicSource.qq,
      initialPosition: const Duration(minutes: 1, seconds: 23),
    );
    expect(
      player.requestedInitialPosition,
      const Duration(minutes: 1, seconds: 23),
    );
    expect(positions.last, const Duration(minutes: 1, seconds: 23));
    expect(engine.playbackState.value.playing, isFalse);
  });

  test('Android 网易云音源使用网易云来源请求头', () async {
    final player = _FakePlayer();
    final engine = AndroidPlaybackEngine(playerFactory: () => player);
    addTearDown(engine.dispose);
    await engine.setSource(
      'https://example.test/netease.m4a',
      source: MusicSource.netease,
    );
    expect(player.headers?['Referer'], 'https://music.163.com/');
    expect(player.headers?['User-Agent'], contains('Android'));
  });

  test('快速连续 Android 加载仅处理最后请求', () async {
    final players = <_FakePlayer>[];
    final engine = AndroidPlaybackEngine(
      playerFactory: () {
        final player = _FakePlayer();
        players.add(player);
        return player;
      },
    );
    addTearDown(engine.dispose);
    await Future.wait(
      List.generate(
        60,
        (i) => engine.setSourceUrl('https://example.test/$i.mp3'),
      ),
    );
    expect(players, hasLength(1));
    expect(players.single.url, endsWith('/59.mp3'));
  });

  test('取消旧加载立即释放旧实例，迟到的结果不污染新歌', () async {
    final old = _FakePlayer(blockLoad: true);
    final latest = _FakePlayer();
    var index = 0;
    final engine = AndroidPlaybackEngine(
      playerFactory: () => index++ == 0 ? old : latest,
    );
    addTearDown(engine.dispose);
    final pending = engine.setSourceUrl('https://example.test/old.mp3');
    await Future<void>.delayed(Duration.zero);
    final next = engine.setSourceUrl('https://example.test/new.mp3');
    await Future.wait([pending, next]);
    old.loadGate.complete(const Duration(seconds: 999));
    await engine.resume();
    expect(old.disposeCalls, 1);
    expect(latest.playCalls, 1);
    expect(engine.playbackState.value.playing, isTrue);
  });

  test('加载超时隔离播放器，下一首仍可播放；错误不泄露 URL', () async {
    final old = _FakePlayer(blockLoad: true);
    final latest = _FakePlayer();
    var index = 0;
    final engine = AndroidPlaybackEngine(
      playerFactory: () => index++ == 0 ? old : latest,
      loadTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(engine.dispose);
    await expectLater(
      engine.setSourceUrl('https://example.test/stall?token=secret'),
      throwsA(
        isA<PlaybackEngineException>().having(
          (e) => e.message,
          'safe timeout',
          allOf(contains('超时'), isNot(contains('secret'))),
        ),
      ),
    );
    expect(old.disposeCalls, 1);
    expect(
      engine.playbackState.value.processingState,
      service.AudioProcessingState.idle,
    );
    await engine.setSourceUrl('https://example.test/recovered.mp3');
    await engine.resume();
    expect(latest.playCalls, 1);
  });

  test('锁屏切歌保持 loading 而不是停止前台服务，标准 stop 才变 idle', () async {
    final player = _FakePlayer();
    final engine = AndroidPlaybackEngine(playerFactory: () => player);
    addTearDown(engine.dispose);
    await engine.setSourceUrl('https://example.test/song.mp3');
    await engine.resume();
    await engine.prepareForSourceSwitch();
    engine.updateSystemMedia(_metadata, canSkip: true);
    expect(
      engine.playbackState.value.processingState,
      service.AudioProcessingState.loading,
    );
    expect(player.disposeCalls, 1);
    await engine.stop();
    expect(
      engine.playbackState.value.processingState,
      service.AudioProcessingState.idle,
    );
  });

  test('系统前后曲和停止后播放调用同一业务回调', () async {
    var previous = 0, next = 0, retry = 0;
    final engine = AndroidPlaybackEngine();
    addTearDown(engine.dispose);
    engine.bindSystemControls(
      previous: () async => previous++,
      next: () async => next++,
      retry: () async => retry++,
    );
    engine.updateSystemMedia(_metadata, canSkip: false);
    await engine.skipToNext();
    expect(next, 0);
    engine.updateSystemMedia(_metadata, canSkip: true);
    await engine.skipToPrevious();
    await engine.skipToNext();
    await engine.play();
    expect([previous, next, retry], [1, 1, 1]);
  });

  test('单曲完成去重，重复 dispose 不产生旧事件', () async {
    final player = _FakePlayer();
    final engine = AndroidPlaybackEngine(playerFactory: () => player);
    var completions = 0;
    final subscription = engine.onComplete.listen((_) => completions++);
    await engine.setSourceUrl('https://example.test/song.mp3');
    player.finish();
    player.finish();
    expect(completions, 1);
    await subscription.cancel();
    await engine.dispose();
    await engine.dispose();
    expect(player.disposeCalls, 1);
  });
}

const _metadata = PlaybackMetadata(
  id: '101',
  title: '测试歌曲',
  artist: '测试歌手',
  album: '测试专辑',
  duration: Duration(minutes: 3),
);

class _FakePlayer implements AudioPlayer {
  _FakePlayer({this.blockLoad = false});
  final bool blockLoad;
  final loadGate = Completer<Duration?>();
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  final durations = StreamController<Duration?>.broadcast(sync: true);
  final errors = StreamController<PlayerException>.broadcast(sync: true);
  Completer<void>? _playGate;
  @override
  bool playing = false;
  @override
  ProcessingState processingState = ProcessingState.idle;
  @override
  Duration position = Duration.zero;
  @override
  Duration get bufferedPosition => position;
  @override
  double volume = 1;
  String? url;
  Map<String, String>? headers;
  Duration? requestedInitialPosition;
  int playCalls = 0, disposeCalls = 0;
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => durations.stream;
  @override
  Stream<PlayerException> get errorStream => errors.stream;

  @override
  Future<Duration?> setUrl(
    String url, {
    Map<String, String>? headers,
    Duration? initialPosition,
    bool preload = true,
    dynamic tag,
  }) async {
    this.url = url;
    this.headers = headers;
    requestedInitialPosition = initialPosition;
    processingState = ProcessingState.loading;
    if (blockLoad) return loadGate.future;
    processingState = ProcessingState.ready;
    return const Duration(minutes: 3);
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  Future<void> play() {
    playCalls++;
    playing = true;
    states.add(PlayerState(true, processingState));
    return (_playGate = Completer<void>()).future;
  }

  @override
  Future<void> pause() async {
    playing = false;
    states.add(PlayerState(false, processingState));
    _playGate?.complete();
    _playGate = null;
  }

  @override
  Future<void> seek(Duration? value, {int? index}) async {
    position = value ?? Duration.zero;
    processingState = ProcessingState.ready;
    positions.add(position);
  }

  void finish() {
    processingState = ProcessingState.completed;
    states.add(PlayerState(playing, processingState));
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    _playGate?.complete();
    _playGate = null;
    await Future.wait([
      states.close(),
      positions.close(),
      durations.close(),
      errors.close(),
    ]);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
