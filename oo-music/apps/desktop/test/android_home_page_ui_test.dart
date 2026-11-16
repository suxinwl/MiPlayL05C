import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oo_music/api/music_api.dart';
import 'package:oo_music/models/playlist.dart';
import 'package:oo_music/player/playback_engine.dart';
import 'package:oo_music/screens/home_page.dart';
import 'package:oo_music/storage/local_library_store.dart';
import 'package:oo_music/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const volumeChannel = MethodChannel('oo_music/system_volume');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    WidgetController.hitTestWarningShouldBeFatal = true;
    messenger.setMockMethodCallHandler(volumeChannel, (call) async {
      return call.method == 'get' ? 0.5 : true;
    });
  });
  tearDown(() {
    WidgetController.hitTestWarningShouldBeFatal = false;
    messenger.setMockMethodCallHandler(volumeChannel, null);
  });

  testWidgets('Android 主导航、播放页、完整歌词和底部操作卡片', (tester) async {
    await _setTestSize(tester, const Size(360, 720));
    final store = LocalLibraryStore.inMemory();
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_response),
    );
    addTearDown(store.close);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomePage(
          api: api,
          libraryStore: store,
          playbackEngine: _NoopEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('music-source-qq')), findsOneWidget);
    expect(find.byKey(const ValueKey('music-source-netease')), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('mobile-search-field')),
      '测试歌曲',
    );
    await tester.tap(find.byKey(const ValueKey('mobile-search-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-song-qq:101')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-song-qq:101')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-mini-player')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-open-now-playing')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-now-playing-page')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('mobile-now-playing-disc')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mobile-play-mode')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-previous')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile-toggle-playback')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('mobile-next')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-desktop-lyrics')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-now-playing-more')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-more-sheet')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-download')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-quality')), findsOneWidget);
    expect(find.byKey(const ValueKey('mobile-volume')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-more-close')));
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const ValueKey('mobile-now-playing-pages')),
      const Offset(-320, 0),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-full-lyrics-page')),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('mobile-now-playing-disc')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('mobile-now-playing-back')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-now-playing-page')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('mobile-tab-library')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-library-page')), findsOneWidget);
    expect(find.text('本地歌单'), findsOneWidget);
    expect(find.text('远程歌单'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('mobile-playlist-$recentlyPlayedPlaylistId')),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-playlist-page')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-tab-search')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-song-qq:101')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-tab-library')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-playlist-page')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('mobile-tab-library')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-library-page')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('mobile-tab-account')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('mobile-account-page')), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android 手机宽度和横屏下的三页布局不溢出', (tester) async {
    final store = LocalLibraryStore.inMemory();
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_response),
    );
    addTearDown(store.close);
    addTearDown(api.close);
    for (final size in const <Size>[
      Size(320, 640),
      Size(360, 720),
      Size(393, 800),
      Size(600, 900),
      Size(740, 360),
    ]) {
      await _setTestSize(tester, size);
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey<Size>(size),
          theme: buildAppTheme(),
          home: HomePage(
            api: api,
            libraryStore: store,
            playbackEngine: _NoopEngine(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-bottom-navigation')),
        findsOneWidget,
        reason: '主导航 $size',
      );
      await tester.tap(find.byKey(const ValueKey('mobile-tab-library')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-library-page')),
        findsOneWidget,
        reason: '音乐库 $size',
      );
      await tester.tap(find.byKey(const ValueKey('mobile-tab-account')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile-account-page')),
        findsOneWidget,
        reason: '我的 $size',
      );
      expect(tester.takeException(), isNull, reason: '布局 $size');
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    }
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android 输入法弹起时隐藏底部导航，搜索区域仍可输入', (tester) async {
    await _setTestSize(tester, const Size(360, 720));
    addTearDown(tester.view.resetViewInsets);
    final store = LocalLibraryStore.inMemory();
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_response),
    );
    addTearDown(store.close);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomePage(
          api: api,
          libraryStore: store,
          playbackEngine: _NoopEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fieldFinder = find.byKey(const ValueKey('mobile-search-field'));
    final focusNode = tester.widget<TextField>(fieldFinder).focusNode!;
    await tester.tap(fieldFinder);
    await tester.enterText(fieldFinder, '输入测试');
    expect(focusNode.hasFocus, isTrue);
    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsOneWidget,
    );

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    expect(focusNode.hasFocus, isTrue);
    await tester.enterText(fieldFinder, '输入测试仍可继续');
    expect(find.text('输入测试仍可继续'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('mobile-bottom-navigation')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('mobile-mini-player')), findsNothing);
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android 新建歌单时输入法收起和弹窗退场不产生异常', (tester) async {
    await _setTestSize(tester, const Size(360, 720));
    final store = LocalLibraryStore.inMemory();
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_response),
    );
    addTearDown(store.close);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomePage(
          api: api,
          libraryStore: store,
          playbackEngine: _NoopEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-tab-library')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('mobile-create-playlist')));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('playlist-name-field')),
      'Mobile QA',
    );
    await tester.tap(find.byKey(const ValueKey('save-playlist-name')));
    await tester.pump();
    tester.view.resetViewInsets();
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      store.snapshot().customPlaylists.where((p) => p.name == 'Mobile QA'),
      hasLength(1),
    );
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}

Future<void> _setTestSize(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(tester.view.resetPhysicalSize);
}

Future<http.Response> _response(http.Request request) async {
  final body = switch (request.url.path) {
    '/api/search' || '/api/tracks' => {
      'items': [_song],
    },
    '/api/lyrics' => {
      'source': 'qq',
      'lyric': '[00:00.00]第一句\n[00:10.00]第二句',
      'translation': '',
      'romanization': '',
    },
    '/api/playback' => {
      'source': 'qq',
      'songId': 101,
      'available': true,
      'url': 'https://music.test/song.mp3',
      'quality': '320mp3',
      'reason': '',
      'attempts': [],
    },
    _ => {},
  };
  return http.Response(
    jsonEncode(body),
    200,
    headers: {'content-type': 'application/json; charset=utf-8'},
  );
}

const _song = {
  'source': 'qq',
  'id': 101,
  'mid': 'song-101',
  'name': '一首名称很长的手机布局测试歌曲',
  'artists': ['测试歌手'],
  'album': '测试专辑',
  'coverUrl': '',
  'durationSeconds': 180,
  'hasMv': true,
  'mvVid': 'mv-101',
  'availableQualities': ['320mp3', 'flac'],
};

class _NoopEngine implements PlaybackEngine {
  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();
  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();
  @override
  Stream<PlaybackEngineState> get onStateChanged => const Stream.empty();
  @override
  Stream<void> get onComplete => const Stream.empty();
  @override
  Future<void> dispose() async {}
  @override
  Future<void> setSourceUrl(String url) async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> setVolume(double volume) async {}
}
