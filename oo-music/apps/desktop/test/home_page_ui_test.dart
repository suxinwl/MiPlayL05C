import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oo_music/api/music_api.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/models/song.dart';
import 'package:oo_music/platform/mv_playback_driver.dart';
import 'package:oo_music/player/playback_engine.dart';
import 'package:oo_music/screens/home_page.dart';
import 'package:oo_music/storage/local_library_store.dart';
import 'package:oo_music/theme/app_theme.dart';
import 'package:oo_music/widgets/app_dialog.dart';
import 'package:oo_music/widgets/mv_player_dialog.dart';

void main() {
  desktopTestWidgets('歌曲行固定展示 MV，并可从当前歌单添加到其他本地歌单', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1440, 980));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    final source = store.createPlaylist('源歌单');
    final target = store.createPlaylist('目标歌单');
    store.addSongToPlaylist(source.id, MusicSource.qq, 101);

    final client = MockClient((request) async {
      if (request.url.path == '/api/search') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Map<String, Object?>>[_songJson()],
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      if (request.url.path == '/api/tracks') {
        return http.Response(
          jsonEncode(<String, Object?>{
            'items': <Map<String, Object?>>[_songJson()],
          }),
          200,
          headers: const <String, String>{
            'content-type': 'application/json; charset=utf-8',
          },
        );
      }
      return http.Response('not found', 404);
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          api: api,
          libraryStore: store,
          playbackEngine: _NoopPlaybackEngine(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('search-field')),
      '测试歌曲',
    );
    await tester.tap(find.byKey(const ValueKey<String>('search-button')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('mv-song-qq:101')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('download-song-qq:101')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('add-song-qq:101')),
      findsOneWidget,
    );

    await tester.tap(find.text('源歌单'));
    await tester.pumpAndSettle();
    final addToOther = find.byKey(
      const ValueKey<String>('add-local-song-qq:101'),
    );
    expect(addToOther, findsOneWidget);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(addToOther));
    await tester.pumpAndSettle();
    await tester.tap(addToOther);
    await tester.pumpAndSettle();

    final sourceChoice = tester.widget<AppChoiceTile>(
      find.byKey(ValueKey<String>('target-playlist-${source.id}')),
    );
    expect(sourceChoice.enabled, isFalse);

    await tester.tap(
      find.byKey(ValueKey<String>('target-playlist-${target.id}')),
    );
    await tester.pumpAndSettle();
    expect(
      store
          .snapshot()
          .playlistById(target.id)
          ?.songs
          .map((song) => song.songId),
      contains(101),
    );
  });

  desktopTestWidgets('搜索等待期间展示骨架屏，完成后恢复歌曲列表', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final response = Completer<http.Response>();
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient((request) {
        if (request.url.path == '/api/search') {
          return response.future;
        }
        return Future<http.Response>.value(http.Response('not found', 404));
      }),
    );
    addTearDown(api.close);

    await _pumpHome(tester, api: api, store: store);
    await tester.enterText(
      find.byKey(const ValueKey<String>('search-field')),
      '测试延迟',
    );
    await tester.tap(find.byKey(const ValueKey<String>('search-button')));
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('search-skeleton')),
      findsOneWidget,
    );

    response.complete(
      _jsonResponse(<String, Object?>{
        'items': <Map<String, Object?>>[_songJson()],
      }),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('search-skeleton')), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('search-song-qq:101')),
      findsOneWidget,
    );
  });

  desktopTestWidgets('Cmd+K 聚焦并全选搜索框，Escape 可关闭完整播放页', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1200, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_musicApiResponse),
    );
    addTearDown(api.close);

    await _pumpHome(tester, api: api, store: store);

    final searchField = find.byKey(const ValueKey<String>('search-field'));
    await tester.enterText(searchField, '晴天');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    final editable = tester.widget<EditableText>(
      find.descendant(of: searchField, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isFalse);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();

    expect(editable.focusNode.hasFocus, isTrue);
    expect(
      editable.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 2),
    );

    await tester.tap(find.byKey(const ValueKey<String>('search-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('search-song-qq:101')));
    await tester.pumpAndSettle();

    final artwork = find.byKey(const ValueKey<String>('player-artwork'));
    final artworkOverlay = find.byKey(
      const ValueKey<String>('player-artwork-expand-overlay'),
    );
    expect(tester.widget<AnimatedOpacity>(artworkOverlay).opacity, 0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer();
    await mouse.moveTo(tester.getCenter(artwork));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(artworkOverlay).opacity, 1);

    await tester.tap(artwork);
    await tester.pumpAndSettle();

    final nowPlaying = find.byKey(const ValueKey<String>('now-playing-page'));
    expect(nowPlaying, findsOneWidget);
    expect(
      find.descendant(of: nowPlaying, matching: find.byType(Scrollbar)),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('now-playing-title')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('now-playing-artist')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('now-playing-album')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey<String>('player-toggle')), findsOneWidget);
    expect(
      find.descendant(
        of: nowPlaying,
        matching: find.byKey(const ValueKey<String>('player-download')),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: nowPlaying,
        matching: find.byKey(const ValueKey<String>('player-desktop-lyrics')),
      ),
      findsNothing,
    );

    expect(
      find.byKey(const ValueKey<String>('close-now-playing')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('now-playing-close-overlay')),
      findsNothing,
    );

    final collapseOverlay = find.byKey(
      const ValueKey<String>('player-artwork-collapse-overlay'),
    );
    await mouse.moveTo(tester.getCenter(nowPlaying));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(collapseOverlay).opacity, 0);
    await mouse.moveTo(tester.getCenter(artwork));
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedOpacity>(collapseOverlay).opacity, 1);

    await tester.tap(artwork);
    await tester.pumpAndSettle();
    expect(nowPlaying, findsNothing);

    await tester.tap(artwork);
    await tester.pumpAndSettle();
    expect(nowPlaying, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(nowPlaying, findsNothing);

    debugDefaultTargetPlatformOverride = null;
  });

  desktopTestWidgets('Windows Ctrl+K 搜索与 Ctrl+Shift+L 桌面歌词复用共享主页', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1200, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const channel = MethodChannel('oo_music/desktop_lyrics');
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return call.method == 'show' ? true : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_musicApiResponse),
    );
    addTearDown(api.close);
    await _pumpHome(tester, api: api, store: store);

    final searchField = find.byKey(const ValueKey<String>('search-field'));
    await tester.enterText(searchField, 'Windows');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    final editable = tester.widget<EditableText>(
      find.descendant(of: searchField, matching: find.byType(EditableText)),
    );
    expect(editable.focusNode.hasFocus, isTrue);
    expect(
      editable.controller.selection,
      const TextSelection(baseOffset: 0, extentOffset: 7),
    );
    await tester.tap(find.byKey(const ValueKey<String>('search-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('search-song-qq:101')));
    await tester.pumpAndSettle();

    Future<void> toggleLyrics() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
    }

    await toggleLyrics();
    expect(calls.where((call) => call.method == 'show'), hasLength(1));
    final payload =
        calls.firstWhere((call) => call.method == 'show').arguments as Map;
    expect(payload['lyric'], isNotEmpty);
    expect(payload['isPlaying'], isFalse);
    await toggleLyrics();
    expect(calls.where((call) => call.method == 'hide'), hasLength(1));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  desktopTestWidgets('切换网易云后搜索请求和结果使用网易云平台', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    String? requestedSource;
    final client = MockClient((request) async {
      if (request.url.path == '/api/search') {
        requestedSource = request.url.queryParameters['source'];
        return _jsonResponse(<String, Object?>{
          'source': 'netease',
          'items': <Map<String, Object?>>[
            <String, Object?>{..._songJson(), 'source': 'netease'},
          ],
        });
      }
      return _musicApiResponse(request);
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    addTearDown(api.close);

    await _pumpHome(tester, api: api, store: store);
    await tester.tap(
      find.byKey(const ValueKey<String>('music-source-netease')),
    );
    await tester.pumpAndSettle();
    await _submitSearch(tester, '晴天');

    expect(requestedSource, 'netease');
    expect(
      find.byKey(const ValueKey<String>('source-badge-netease')),
      findsWidgets,
    );
  });

  desktopTestWidgets('音质切换使用请求返回时的当前进度并从该位置继续', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    final flacGate = Completer<void>();
    final songJson = <String, Object?>{
      ..._songJson(),
      'availableQualities': <String>['320mp3', 'flac'],
    };
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient((request) async {
        final path = request.url.path;
        if (path == '/api/search' || path == '/api/tracks') {
          return _jsonResponse({
            'items': <Map<String, Object?>>[songJson],
          });
        }
        if (path == '/api/lyrics') {
          return _jsonResponse({
            'source': 'qq',
            'lyric': '[00:00.00]第一句\n[01:10.00]第二句',
            'translation': '',
            'romanization': '',
          });
        }
        if (path == '/api/playback') {
          final quality = request.url.queryParameters['quality'] ?? '320mp3';
          if (quality == 'flac') await flacGate.future;
          return _jsonResponse({
            'source': 'qq',
            'songId': 101,
            'available': true,
            'url':
                'https://music.test/${quality == 'flac' ? 'hq' : 'std'}.flac',
            'quality': quality,
            'reason': '',
            'attempts': <Object?>[],
          });
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(api.close);
    final engine = _SourceAwareTestEngine();
    addTearDown(engine.dispose);

    await _pumpHome(tester, api: api, store: store, engine: engine);
    await tester.enterText(
      find.byKey(const ValueKey<String>('search-field')),
      '测试歌曲',
    );
    await tester.tap(find.byKey(const ValueKey<String>('search-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('search-song-qq:101')));
    await tester.pumpAndSettle();

    engine.emitPosition(const Duration(seconds: 20));
    await tester.pump();
    final qualityMenu = tester.widget<PopupMenuButton<String>>(
      find.byKey(const ValueKey<String>('player-quality')),
    );
    qualityMenu.onSelected?.call('flac');
    await tester.pump();

    // 新音质地址请求期间旧音频继续播放，进度又前进了 3 秒。
    engine.emitPosition(const Duration(seconds: 23));
    await tester.pump();
    flacGate.complete();
    await tester.pumpAndSettle();

    expect(engine.initialPositions.last, const Duration(seconds: 23));
    expect(engine.seekCalls, 0);
    expect(find.text('FLAC 无损'), findsOneWidget);
  });

  desktopTestWidgets('快速切歌时旧音源迟到不停止新歌曲或清除新歌 loading', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    final engine = _DelayedSourceEngine();
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_twoSongResponse),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomePage(api: api, libraryStore: store, playbackEngine: engine),
      ),
    );
    await tester.pumpAndSettle();
    await _submitSearch(tester, '轻松一下');
    await tester.tap(find.byKey(const ValueKey<String>('search-song-qq:101')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(engine.sources, hasLength(1));
    await tester.tap(find.byKey(const ValueKey<String>('search-song-qq:102')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(engine.stops, 2);
    expect(engine.sources, hasLength(1));
    engine.firstReady.complete();
    await tester.pumpAndSettle();
    expect(engine.sources, hasLength(2));
    expect(engine.sources.last, endsWith('/102.mp3'));
    expect(engine.resumeCalls, 1);
    expect(engine.stops, 2, reason: '旧请求完成后不再额外 stop，不能停止刚加载的新歌');
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('player-toggle')),
    );
    expect(button.onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  desktopTestWidgets('音频加载超时从 loading 恢复为可重试状态', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    final engine = _DelayedSourceEngine(failFirst: true);
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_twoSongResponse),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: HomePage(api: api, libraryStore: store, playbackEngine: engine),
      ),
    );
    await tester.pumpAndSettle();
    await _submitSearch(tester, '惬意的事');
    await tester.tap(find.byKey(const ValueKey<String>('search-song-qq:101')));
    await tester.pumpAndSettle();
    expect(engine.resumeCalls, 0);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey<String>('player-toggle')),
    );
    expect(button.onPressed, isNotNull, reason: '失败后不能无限显示 loading');
    await tester.tap(find.byKey(const ValueKey<String>('player-toggle')));
    await tester.pumpAndSettle();
    expect(
      engine.sources,
      hasLength(2),
      reason: '错误后的播放按钮应重新加载而不是 resume 失效实例',
    );
    expect(engine.resumeCalls, 1);
    await tester.tap(find.byKey(const ValueKey<String>('search-song-qq:102')));
    await tester.pumpAndSettle();
    expect(engine.resumeCalls, 2);
    expect(tester.takeException(), isNull);
  });

  desktopTestWidgets('MV 加载失败展示明确错误并可通过关闭按钮退出', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient((request) async {
        if (request.url.path == '/api/mv') {
          return _jsonResponse(<String, Object?>{
            'error': <String, Object?>{'message': 'MV 服务暂不可用'},
          }, statusCode: 503);
        }
        return http.Response('not found', 404);
      }),
    );
    addTearDown(api.close);
    final song = Song.fromJson(_songJson());

    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => MvPlayerDialog(
                    api: api,
                    song: song,
                    driverFactory: UnsupportedMvPlaybackDriver.new,
                  ),
                ),
                child: const Text('打开 MV'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开 MV'));
    await tester.pumpAndSettle();

    expect(find.text('MV 加载失败'), findsOneWidget);
    expect(find.text('MV 服务暂不可用'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('close-mv-dialog')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('close-mv-dialog')), findsNothing);
  });

  desktopTestWidgets('窄屏从音乐库抽屉选择搜索后会关闭抽屉', (tester) async {
    await tester.binding.setSurfaceSize(const Size(600, 860));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_musicApiResponse),
    );
    addTearDown(api.close);

    await _pumpHome(tester, api: api, store: store);
    final scaffoldState = tester.state<ScaffoldState>(find.byType(Scaffold));

    await tester.tap(find.byKey(const ValueKey<String>('open-library')));
    await tester.pumpAndSettle();
    expect(scaffoldState.isDrawerOpen, isTrue);
    final drawerSearch = find.descendant(
      of: find.byType(Drawer),
      matching: find.text('搜索音乐'),
    );
    expect(drawerSearch, findsOneWidget);

    await tester.tap(drawerSearch);
    await tester.pumpAndSettle();
    expect(scaffoldState.isDrawerOpen, isFalse);
    expect(find.text('输入歌曲名、歌手或专辑名开始搜索'), findsOneWidget);
  });

  desktopTestWidgets('480 到 1440 宽的核心搜索与播放布局均无 overflow', (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    final api = MusicApi(
      baseUrl: 'http://music.test',
      client: MockClient(_musicApiResponse),
    );
    addTearDown(api.close);

    for (final width in <double>[480, 600, 820, 1100, 1440]) {
      await tester.binding.setSurfaceSize(Size(width, 900));
      await tester.pumpWidget(
        MaterialApp(
          key: ValueKey<double>(width),
          theme: buildAppTheme(),
          home: HomePage(
            api: api,
            libraryStore: store,
            playbackEngine: _NoopPlaybackEngine(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _submitSearch(tester, '宽度 $width');
      await tester.tap(
        find.byKey(const ValueKey<String>('search-song-qq:101')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('player-toggle')),
        findsOneWidget,
        reason: '$width px 下播放器应可见',
      );
      expect(
        find.byKey(const ValueKey<String>('player-play-mode')),
        findsOneWidget,
        reason: '$width px 下应可切换播放模式',
      );
      expect(
        find.byKey(const ValueKey<String>('player-volume')),
        findsOneWidget,
        reason: '$width px 下应可调整音量',
      );
      if (width < 760) {
        expect(
          find.byKey(const ValueKey<String>('player-more')),
          findsOneWidget,
          reason: '$width px 紧凑播放器应保留更多播放设置',
        );
      } else {
        expect(
          find.byKey(const ValueKey<String>('player-download')),
          findsOneWidget,
          reason: '$width px 宽屏播放器应保留下载入口',
        );
      }
      expect(
        tester.takeException(),
        isNull,
        reason: '$width px 宽度下出现布局 overflow 或其他渲染异常',
      );
    }
  });
}

Future<void> _pumpHome(
  WidgetTester tester, {
  required MusicApi api,
  required LocalLibraryStore store,
  PlaybackEngine? engine,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: HomePage(
        api: api,
        libraryStore: store,
        playbackEngine: engine ?? _NoopPlaybackEngine(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _submitSearch(WidgetTester tester, String query) async {
  await tester.enterText(
    find.byKey(const ValueKey<String>('search-field')),
    query,
  );
  await tester.tap(find.byKey(const ValueKey<String>('search-button')));
  await tester.pumpAndSettle();
}

Future<http.Response> _musicApiResponse(http.Request request) async {
  final body = switch (request.url.path) {
    '/api/search' => <String, Object?>{
      'items': <Map<String, Object?>>[_songJson()],
    },
    '/api/tracks' => <String, Object?>{
      'items': <Map<String, Object?>>[_songJson()],
    },
    '/api/lyrics' => <String, Object?>{
      'source': 'qq',
      'songId': 101,
      'songMid': 'song-mid-101',
      'title': '测试歌曲',
      'artist': '测试歌手',
      'lyric': '[00:00.00]第一句\n[00:10.00]第二句',
      'translation': '',
      'romanization': '',
    },
    '/api/playback' => <String, Object?>{
      'source': 'qq',
      'songId': 101,
      'available': true,
      'url': 'https://music.test/audio.mp3',
      'quality': '320mp3',
      'reason': '',
      'attempts': <Object?>[],
    },
    _ => null,
  };
  if (body == null) {
    return http.Response('not found', 404);
  }
  return _jsonResponse(body);
}

http.Response _jsonResponse(Object body, {int statusCode = 200}) {
  return http.Response(
    jsonEncode(body),
    statusCode,
    headers: const <String, String>{
      'content-type': 'application/json; charset=utf-8',
    },
  );
}

Map<String, Object?> _songJson() {
  return <String, Object?>{
    'source': 'qq',
    'id': 101,
    'mid': 'song-mid-101',
    'name': '测试歌曲',
    'artists': <String>['测试歌手'],
    'album': '测试专辑',
    'albumMid': 'album-mid-101',
    'coverUrl': '',
    'durationSeconds': 245,
    'hasMv': true,
    'mvVid': 'mv-101',
    'availableQualities': <String>['320mp3'],
  };
}

class _NoopPlaybackEngine implements PlaybackEngine {
  @override
  Stream<void> get onComplete => const Stream<void>.empty();

  @override
  Stream<Duration> get onDurationChanged => const Stream<Duration>.empty();

  @override
  Stream<Duration> get onPositionChanged => const Stream<Duration>.empty();

  @override
  Stream<PlaybackEngineState> get onStateChanged =>
      const Stream<PlaybackEngineState>.empty();

  @override
  Future<void> dispose() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setSourceUrl(String url) async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {}
}

Future<http.Response> _twoSongResponse(http.Request request) async {
  if (request.url.path == '/api/search') {
    return _jsonResponse({
      'items': [
        _songJson(),
        {..._songJson(), 'id': 102, 'name': '惬意的事'},
      ],
    });
  }
  final id = int.tryParse(request.url.queryParameters['song_id'] ?? '') ?? 101;
  if (request.url.path == '/api/playback') {
    return _jsonResponse({
      'source': 'qq',
      'songId': id,
      'available': true,
      'url': 'https://music.test/$id.mp3',
      'quality': '320mp3',
      'reason': '',
      'attempts': [],
    });
  }
  if (request.url.path == '/api/tracks') return _jsonResponse({'items': []});
  return _musicApiResponse(request);
}

class _SourceAwareTestEngine
    implements PlaybackEngine, SourceAwarePlaybackEngine {
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _durations = StreamController<Duration>.broadcast(sync: true);
  final _states = StreamController<PlaybackEngineState>.broadcast(sync: true);
  final _completed = StreamController<void>.broadcast(sync: true);
  final initialPositions = <Duration>[];
  int seekCalls = 0;

  void emitPosition(Duration position) => _positions.add(position);

  @override
  Stream<void> get onComplete => _completed.stream;

  @override
  Stream<Duration> get onDurationChanged => _durations.stream;

  @override
  Stream<Duration> get onPositionChanged => _positions.stream;

  @override
  Stream<PlaybackEngineState> get onStateChanged => _states.stream;

  @override
  Future<void> dispose() async {
    await Future.wait([
      _positions.close(),
      _durations.close(),
      _states.close(),
      _completed.close(),
    ]);
  }

  @override
  Future<void> pause() async {
    _states.add(PlaybackEngineState.paused);
  }

  @override
  Future<void> resume() async {
    _states.add(PlaybackEngineState.playing);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCalls++;
    _positions.add(position);
  }

  @override
  Future<void> setSource(
    String url, {
    required MusicSource source,
    Duration? initialPosition,
  }) async {
    initialPositions.add(initialPosition ?? Duration.zero);
  }

  @override
  Future<void> setSourceUrl(String url) =>
      setSource(url, source: MusicSource.qq);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> stop() async {
    _states.add(PlaybackEngineState.stopped);
  }
}

class _DelayedSourceEngine extends _NoopPlaybackEngine {
  _DelayedSourceEngine({this.failFirst = false});
  final bool failFirst;
  final firstReady = Completer<void>();
  final sources = <String>[];
  int stops = 0;
  int resumeCalls = 0;

  @override
  Future<void> setSourceUrl(String url) async {
    sources.add(url);
    if (sources.length == 1) {
      if (failFirst) throw const PlaybackEngineException('音源加载超时，请重试或切换歌曲');
      await firstReady.future;
    }
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> resume() async {
    resumeCalls++;
  }
}

// Desktop assertions use an explicit variant, restored before binding checks.
void desktopTestWidgets(
  String description,
  Future<void> Function(WidgetTester) callback,
) {
  testWidgets(
    description,
    callback,
    variant: TargetPlatformVariant.only(TargetPlatform.windows),
  );
}
