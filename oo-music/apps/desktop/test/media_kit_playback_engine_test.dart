import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/player/media_kit_playback_engine.dart';
import 'package:oo_music/player/playback_engine.dart';
import 'package:oo_music/player/playback_engine_factory.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  MediaKitPlaybackEngine engineFor(
    _FakeAudioPlayer player, {
    Duration timeout = const Duration(seconds: 1),
  }) => MediaKitPlaybackEngine(
    playerFactory: () => Player(platformPlayer: player),
    loadTimeout: timeout,
    commandTimeout: timeout,
  );

  test('Windows 音频工厂不启动 Media Foundation 或预先创建原生播放器', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final engine = createPlaybackEngine();
    expect(engine, isA<MediaKitPlaybackEngine>());
    await engine.stop();
    await engine.dispose();
  });

  test('异步打开音频保留 CDN 头，不自动播放，音量从 0..1 转为 0..100', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final player = _FakeAudioPlayer();
    final engine = engineFor(player);
    addTearDown(engine.dispose);
    final states = <PlaybackEngineState>[];
    final sub = engine.onStateChanged.listen(states.add);
    addTearDown(sub.cancel);
    await engine.setVolume(0.35);
    await engine.setSourceUrl('https://example.com/song.mp3');
    expect(player.autoPlay, isFalse);
    expect(player.medias.single.httpHeaders!['Referer'], 'https://y.qq.com/');
    expect(
      player.medias.single.httpHeaders!['User-Agent'],
      contains('Windows'),
    );
    await engine.setSource(
      'https://example.com/netease.m4a',
      source: MusicSource.netease,
    );
    expect(
      player.medias.last.httpHeaders!['Referer'],
      'https://music.163.com/',
    );
    expect(player.volume, 35);
    await engine.resume();
    await Future<void>.delayed(Duration.zero);
    expect(states.last, PlaybackEngineState.playing);
    await engine.pause();
    await Future<void>.delayed(Duration.zero);
    expect(states.last, PlaybackEngineState.paused);
    await engine.seek(const Duration(seconds: 9));
    expect(player.state.position, const Duration(seconds: 9));
  });

  test('Windows 音质切换在加载完成前定位到原进度', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final player = _FakeAudioPlayer();
    final engine = engineFor(player);
    addTearDown(engine.dispose);
    final positions = <Duration>[];
    final subscription = engine.onPositionChanged.listen(positions.add);
    addTearDown(subscription.cancel);

    await engine.setSource(
      'https://example.com/hq.flac',
      source: MusicSource.qq,
      initialPosition: const Duration(minutes: 1, seconds: 23),
    );
    expect(player.seekCalls, 1);
    expect(player.state.position, const Duration(minutes: 1, seconds: 23));
    expect(positions.last, const Duration(minutes: 1, seconds: 23));
  });

  test('连续加载只执行最后的请求，不重叠原生命令', () async {
    final player = _FakeAudioPlayer();
    final engine = engineFor(player);
    addTearDown(engine.dispose);
    await Future.wait(
      List.generate(
        60,
        (i) => engine.setSourceUrl('https://example.com/$i.mp3'),
      ),
    );
    expect(player.medias, hasLength(1));
    expect(player.medias.single.uri, endsWith('/59.mp3'));
    expect(player.maximumConcurrentOpens, 1);
  });

  test('新歌取消旧歌元数据等待，旧歌完成不会停止或播放新歌', () async {
    final player = _FakeAudioPlayer(missingMetadata: true);
    final engine = engineFor(player);
    addTearDown(engine.dispose);
    final first = engine.setSourceUrl('https://example.com/first.mp3');
    await Future<void>.delayed(Duration.zero);
    player.missingMetadata = false;
    final latest = engine.setSourceUrl('https://example.com/latest.mp3');
    await Future.wait([first, latest]);
    await engine.resume();
    expect(player.medias.last.uri, endsWith('/latest.mp3'));
    expect(player.maximumConcurrentOpens, 1);
    expect(player.playCalls, 1);
  });

  test('stop 立即取消元数据等待，后续曲目仍可播放', () async {
    final player = _FakeAudioPlayer(missingMetadata: true);
    final engine = engineFor(player);
    addTearDown(engine.dispose);
    final pending = engine.setSourceUrl('https://example.com/pending.mp3');
    await Future<void>.delayed(Duration.zero);
    await engine.stop();
    await pending;
    player.missingMetadata = false;
    await engine.setSourceUrl('https://example.com/recovered.mp3');
    await engine.resume();
    expect(player.stopCalls, 1);
    expect(player.playCalls, 1);
  });

  test('排队的新曲不接收旧曲取消期间的原生错误', () async {
    final player = _FakeAudioPlayer(missingMetadata: true);
    final engine = engineFor(player);
    addTearDown(engine.dispose);
    final first = engine.setSourceUrl('https://example.com/first.mp3');
    await Future<void>.delayed(Duration.zero);
    player.missingMetadata = false;
    final latest = engine.setSourceUrl('https://example.com/latest.mp3');
    player.emitError('old cancelled source error');
    await Future.wait([first, latest]);
    await engine.resume();
    expect(player.playCalls, 1);
    expect(player.disposeCalls, 0);
  });

  test('音源加载超时释放失去响应的实例，下一首使用新实例', () async {
    final failed = _FakeAudioPlayer(missingMetadata: true);
    final recovered = _FakeAudioPlayer();
    var count = 0;
    final engine = MediaKitPlaybackEngine(
      playerFactory: () =>
          Player(platformPlayer: count++ == 0 ? failed : recovered),
      commandTimeout: const Duration(milliseconds: 80),
      loadTimeout: const Duration(milliseconds: 15),
    );
    addTearDown(engine.dispose);
    await expectLater(
      engine.setSourceUrl('https://example.com/stall.mp3'),
      throwsA(
        isA<PlaybackEngineException>().having(
          (e) => e.message,
          '超时',
          contains('超时'),
        ),
      ),
    );
    await engine.setSourceUrl('https://example.com/recovered.mp3');
    await engine.resume();
    expect(failed.disposeCalls, 1);
    expect(recovered.playCalls, 1);
  });

  test('原生 open 超时隔离旧实例，迟到的完成不会作用于新播放器', () async {
    final failed = _FakeAudioPlayer(blockOpen: true);
    final recovered = _FakeAudioPlayer();
    var count = 0;
    final engine = MediaKitPlaybackEngine(
      playerFactory: () =>
          Player(platformPlayer: count++ == 0 ? failed : recovered),
      commandTimeout: const Duration(milliseconds: 15),
    );
    addTearDown(engine.dispose);
    await expectLater(
      engine.setSourceUrl('https://example.com/stall.mp3'),
      throwsA(isA<PlaybackEngineException>()),
    );
    await engine.setSourceUrl('https://example.com/recovered.mp3');
    failed.openGate.complete();
    await engine.resume();
    expect(failed.disposeCalls, 1);
    expect(recovered.playCalls, 1);
  });

  test('原生错误不泄露签名 URL，失败队列不影响下首歌', () async {
    final failed = _FakeAudioPlayer(failOpen: true);
    final recovered = _FakeAudioPlayer();
    var count = 0;
    final engine = MediaKitPlaybackEngine(
      playerFactory: () =>
          Player(platformPlayer: count++ == 0 ? failed : recovered),
    );
    addTearDown(engine.dispose);
    await expectLater(
      engine.setSourceUrl('https://example.com/failed.mp3'),
      throwsA(
        isA<PlaybackEngineException>().having(
          (e) => e.message,
          'safe error',
          isNot(contains('secret-token')),
        ),
      ),
    );
    await engine.setSourceUrl('https://example.com/recovered.mp3');
    expect(failed.disposeCalls, 1);
    expect(recovered.medias, hasLength(1));
  });

  test('原生错误事件结束 loading 等待而不是等到超时', () async {
    final player = _FakeAudioPlayer(missingMetadata: true);
    final engine = engineFor(player);
    addTearDown(engine.dispose);
    final pending = engine.setSourceUrl('https://example.com/error.mp3');
    final expectation = expectLater(
      pending,
      throwsA(isA<PlaybackEngineException>()),
    );
    await Future<void>.delayed(Duration.zero);
    player.emitError('https://signed.example?token=secret-token');
    await expectation;
    expect(player.disposeCalls, 1);
  });

  test('重复 dispose 只释放一次且不会回传已过期事件', () async {
    final player = _FakeAudioPlayer(missingMetadata: true);
    final engine = engineFor(player);
    final pending = engine.setSourceUrl('https://example.com/pending.mp3');
    await Future<void>.delayed(Duration.zero);
    await engine.dispose();
    await engine.dispose();
    await pending;
    expect(player.disposeCalls, 1);
    await engine.stop();
  });

  test('整首播放完成只回传完成事件，不把停止时的重置当作完成', () async {
    final player = _FakeAudioPlayer();
    final engine = engineFor(player);
    addTearDown(engine.dispose);
    var completions = 0;
    final sub = engine.onComplete.listen((_) => completions++);
    addTearDown(sub.cancel);
    await engine.setSourceUrl('https://example.com/song.mp3');
    player.emitComplete();
    await Future<void>.delayed(Duration.zero);
    expect(completions, 1);
    await engine.stop();
    player.emitComplete();
    await Future<void>.delayed(Duration.zero);
    expect(completions, 1);
  });
}

class _FakeAudioPlayer extends PlatformPlayer {
  _FakeAudioPlayer({
    this.missingMetadata = false,
    this.blockOpen = false,
    this.failOpen = false,
  }) : super(configuration: const PlayerConfiguration());
  bool missingMetadata;
  final bool blockOpen;
  final bool failOpen;
  final openGate = Completer<void>();
  final medias = <Media>[];
  bool? autoPlay;
  double volume = 0;
  int playCalls = 0;
  int stopCalls = 0;
  int disposeCalls = 0;
  int seekCalls = 0;
  int concurrentOpens = 0;
  int maximumConcurrentOpens = 0;
  void emitError(String value) => errorController.add(value);
  void emitComplete() => completedController.add(true);

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    medias.add(playable as Media);
    autoPlay = play;
    concurrentOpens++;
    if (concurrentOpens > maximumConcurrentOpens) {
      maximumConcurrentOpens = concurrentOpens;
    }
    try {
      if (failOpen) {
        throw StateError('https://signed.example?token=secret-token');
      }
      if (blockOpen) await openGate.future;
      if (disposeCalls > 0) return;
      state = const PlayerState();
      if (!missingMetadata) {
        state = state.copyWith(duration: const Duration(minutes: 3));
        durationController.add(state.duration);
      }
    } finally {
      concurrentOpens--;
    }
  }

  @override
  Future<void> play() async {
    playCalls++;
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> pause() async {
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  @override
  Future<void> setVolume(double value) async {
    volume = value;
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    state = const PlayerState();
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    await super.dispose();
  }
}
