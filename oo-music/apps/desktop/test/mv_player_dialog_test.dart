import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oo_music/api/music_api.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/models/song.dart';
import 'package:oo_music/platform/mv_playback_driver.dart';
import 'package:oo_music/widgets/mv_player_dialog.dart';

void main() {
  const song = Song(
    source: MusicSource.qq,
    id: 101,
    mid: 'test-mid',
    name: '测试 MV',
    artists: ['测试歌手'],
    album: '',
    albumMid: '',
    coverUrl: '',
    durationSeconds: 42,
    hasMv: true,
  );

  Future<void> showMv(
    WidgetTester tester,
    MusicApi api,
    _FakeDriver driver,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => MvPlayerDialog(
                  api: api,
                  song: song,
                  driverFactory: () => driver,
                ),
              ),
              child: const Text('打开 MV'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开 MV'));
    await tester.pump();
  }

  MusicApi createApi(Future<http.Response> Function(http.Request) handler) {
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(handler),
    );
    addTearDown(api.close);
    return api;
  }

  testWidgets('关闭等待 API 的 MV 弹窗不再初始化或播放已释放的驱动', (tester) async {
    final response = Completer<http.Response>();
    final api = createApi((_) => response.future);
    final driver = _FakeDriver();
    await showMv(tester, api, driver);
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byKey(const ValueKey('close-mv-dialog')));
    await tester.pumpAndSettle();
    response.complete(_mvResponse());
    await tester.pump();
    expect(driver.initializeCount, 0);
    expect(driver.playCount, 0);
    expect(driver.disposeCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关闭等待原生初始化的 MV 弹窗后不继续播放', (tester) async {
    final api = createApi((_) async => _mvResponse());
    final driver = _FakeDriver(waitForInitialization: true);
    await showMv(tester, api, driver);
    await tester.pump(const Duration(milliseconds: 250));
    expect(driver.initializeCount, 1);
    await tester.tap(find.byKey(const ValueKey('close-mv-dialog')));
    await tester.pumpAndSettle();
    driver.ready.complete();
    await tester.pump();
    expect(driver.playCount, 0);
    expect(driver.disposeCount, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('原生初始化异常不泄露媒体地址且立即释放驱动', (tester) async {
    final api = createApi((_) async => _mvResponse());
    final driver = _FakeDriver(failInitialization: true);
    await showMv(tester, api, driver);
    await tester.pumpAndSettle();
    expect(find.text('MV 加载失败，请重试或检查网络连接'), findsOneWidget);
    expect(find.textContaining('secret-token'), findsNothing);
    expect(driver.disposeCount, 1);
    expect(driver.playCount, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('MV 播放期间错误可以展示并重试，不继续显示错误画面', (tester) async {
    final api = createApi((_) async => _mvResponse());
    final driver = _FakeDriver();
    await showMv(tester, api, driver);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('fake-mv-view')), findsOneWidget);
    expect(driver.playCount, 1);
    driver.reportError();
    await tester.pump();
    expect(find.text('MV 播放失败，请重试'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.byKey(const ValueKey('fake-mv-view')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

http.Response _mvResponse() => http.Response(
  jsonEncode({
    'source': 'qq',
    'songId': 101,
    'vid': 'test-vid',
    'available': true,
    'url': 'https://example.com/video.mp4',
    'name': '测试 MV',
    'durationSeconds': 42,
  }),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class _FakeDriver extends MvPlaybackDriver {
  _FakeDriver({
    this.waitForInitialization = false,
    this.failInitialization = false,
  });
  final bool waitForInitialization;
  final bool failInitialization;
  final ready = Completer<void>();
  int initializeCount = 0;
  int playCount = 0;
  int disposeCount = 0;
  MvPlaybackSnapshot _snapshot = const MvPlaybackSnapshot();

  @override
  MvPlaybackSnapshot get snapshot => _snapshot;

  @override
  Widget buildView() => const SizedBox(key: ValueKey('fake-mv-view'));

  @override
  Future<void> initialize({
    required Uri uri,
    required Map<String, String> httpHeaders,
  }) async {
    initializeCount++;
    if (failInitialization) {
      throw StateError('https://signed.example?token=secret-token');
    }
    if (waitForInitialization) await ready.future;
    _snapshot = const MvPlaybackSnapshot(
      initialized: true,
      duration: Duration(seconds: 42),
    );
  }

  @override
  Future<void> play() async => playCount++;
  @override
  Future<void> pause() async {}
  @override
  Future<void> seek(Duration position) async {}

  void reportError() {
    _snapshot = const MvPlaybackSnapshot(
      initialized: true,
      error: 'MV 播放失败，请重试',
    );
    notifyListeners();
  }

  @override
  void dispose() {
    disposeCount++;
    super.dispose();
  }
}
