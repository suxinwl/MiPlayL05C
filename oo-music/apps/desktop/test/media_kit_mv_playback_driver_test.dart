import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:oo_music/platform/media_kit_mv_playback_driver.dart';
import 'package:oo_music/platform/mv_playback_driver.dart';

void main() {
  const headers = {
    'Referer': 'https://y.qq.com/',
    'User-Agent': 'test-windows',
  };
  final uri = Uri.parse('https://example.com/video.mp4');

  MediaKitMvPlaybackDriver createDriver(
    _FakePlayer platform, {
    Duration? timeout,
  }) {
    return MediaKitMvPlaybackDriver(
      playerFactory: () => Player(platformPlayer: platform),
      viewFactory: (_) => const SizedBox(key: ValueKey('fake-video')),
      initializationTimeout: timeout ?? const Duration(seconds: 1),
    );
  }

  test('Windows MV 保留请求头，初始化不自动播放，状态与进度同步', () async {
    final platform = _FakePlayer();
    final driver = createDriver(platform);
    addTearDown(driver.dispose);
    var notifications = 0;
    driver.addListener(() => notifications++);
    await driver.initialize(uri: uri, httpHeaders: headers);
    expect(platform.openedMedia?.uri, uri.toString());
    expect(platform.openedMedia?.httpHeaders, headers);
    expect(platform.autoPlay, isFalse);
    expect(driver.snapshot.initialized, isTrue);
    expect(driver.snapshot.duration, const Duration(seconds: 42));
    expect(driver.snapshot.aspectRatio, closeTo(16 / 9, 0.001));
    expect(driver.buildView().key, const ValueKey('fake-video'));

    await driver.play();
    await driver.seek(const Duration(seconds: 8));
    await Future<void>.delayed(Duration.zero);
    expect(driver.snapshot.playing, isTrue);
    expect(driver.snapshot.position, const Duration(seconds: 8));
    await driver.pause();
    await Future<void>.delayed(Duration.zero);
    expect(driver.snapshot.playing, isFalse);
    expect(notifications, greaterThan(0));

    driver.dispose();
    driver.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(platform.disposeCount, 1);
    expect(driver.snapshot.initialized, isFalse);
    await driver.play();
    expect(platform.playCount, 1);
  });

  test('原生加载失败不展示包含签名或令牌的异常，并释放播放器', () async {
    final platform = _FakePlayer(failOpen: true);
    final driver = createDriver(platform);
    addTearDown(driver.dispose);
    await expectLater(
      driver.initialize(uri: uri, httpHeaders: headers),
      throwsA(
        isA<MvPlaybackUnavailableException>().having(
          (error) => error.message,
          '安全文案',
          isNot(contains('secret-token')),
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(platform.disposeCount, 1);
    expect(driver.snapshot.error, isNotNull);
    expect(driver.snapshot.error, isNot(contains('https://')));
  });

  test('初始化超时包含 open 阶段，不会一直停留在加载界面', () async {
    final platform = _FakePlayer(blockOpen: true);
    final driver = createDriver(
      platform,
      timeout: const Duration(milliseconds: 10),
    );
    addTearDown(driver.dispose);
    await expectLater(
      driver.initialize(uri: uri, httpHeaders: headers),
      throwsA(
        isA<MvPlaybackUnavailableException>().having(
          (error) => error.message,
          '超时文案',
          contains('超时'),
        ),
      ),
    );
    platform.openGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(platform.disposeCount, 1);
  });

  test('等待视频元数据时关闭弹窗会结束初始化且不再通知监听者', () async {
    final platform = _FakePlayer(loadMetadata: false);
    final driver = createDriver(platform);
    final pending = driver.initialize(uri: uri, httpHeaders: headers);
    await Future<void>.delayed(Duration.zero);
    driver.dispose();
    await pending;
    await Future<void>.delayed(Duration.zero);
    expect(platform.disposeCount, 1);
    expect(driver.snapshot.initialized, isFalse);
  });

  test('运行时原生错误和播放控制失败转为安全的状态错误', () async {
    final platform = _FakePlayer();
    final driver = createDriver(platform);
    addTearDown(driver.dispose);
    await driver.initialize(uri: uri, httpHeaders: headers);
    platform.emitError('https://signed.example?token=secret-token');
    await Future<void>.delayed(Duration.zero);
    expect(driver.snapshot.error, 'MV 播放失败，请重试或检查网络连接');
    platform.failPlay = true;
    await driver.play();
    expect(driver.snapshot.error, isNot(contains('secret-token')));
    driver.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(platform.disposeCount, 1);
  });

  test('关闭弹窗可立即取消仍在等待的原生 open', () async {
    final platform = _FakePlayer(blockOpen: true);
    final driver = createDriver(platform);
    final pending = driver.initialize(uri: uri, httpHeaders: headers);
    await Future<void>.delayed(Duration.zero);
    driver.dispose();
    await pending.timeout(const Duration(milliseconds: 100));
    platform.openGate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(platform.disposeCount, 1);
  });

  test('原生 DLL 初始化失败提供明确错误，可重复关闭', () async {
    final driver = MediaKitMvPlaybackDriver(
      playerFactory: () => throw StateError('native DLL unavailable'),
    );
    await expectLater(
      driver.initialize(uri: uri, httpHeaders: headers),
      throwsA(isA<MvPlaybackUnavailableException>()),
    );
    expect(driver.snapshot.error, isNotNull);
    driver.dispose();
    driver.dispose();
  });
}

class _FakePlayer extends PlatformPlayer {
  _FakePlayer({
    this.failOpen = false,
    this.blockOpen = false,
    this.loadMetadata = true,
  }) : super(configuration: const PlayerConfiguration());

  final bool failOpen;
  final bool blockOpen;
  final bool loadMetadata;
  final openGate = Completer<void>();
  Media? openedMedia;
  bool? autoPlay;
  bool failPlay = false;
  int disposeCount = 0;
  int playCount = 0;

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    openedMedia = playable as Media;
    autoPlay = play;
    if (failOpen) throw StateError('https://signed.example?token=secret-token');
    if (blockOpen) await openGate.future;
    if (disposeCount != 0) return;
    if (loadMetadata) {
      state = state.copyWith(
        duration: const Duration(seconds: 42),
        width: 1920,
        height: 1080,
      );
      durationController.add(state.duration);
    }
  }

  @override
  Future<void> play() async {
    playCount++;
    if (failPlay) throw StateError('secret-token');
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
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  void emitError(String error) => errorController.add(error);

  @override
  Future<void> dispose() async {
    disposeCount++;
    await super.dispose();
  }
}
