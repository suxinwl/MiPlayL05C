import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/lyrics/lrc_parser.dart';
import 'package:oo_music/api/music_api.dart';
import 'package:oo_music/models/client_account.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/models/playback.dart';
import 'package:oo_music/models/playlist.dart';
import 'package:oo_music/models/song.dart';
import 'package:oo_music/storage/local_library_store.dart';
import 'package:oo_music/widgets/account_dialog.dart';
import 'package:oo_music/widgets/library_sidebar.dart';
import 'package:oo_music/widgets/player_bar.dart';

void main() {
  test('解析多时间标签、小数秒和 offset', () {
    final lines = LrcParser.parse(
      '[offset:100]\n'
      '[00:01.50][00:03.250]第一句\n'
      '[00:05.0]第二句\n',
    );

    expect(lines, hasLength(3));
    expect(lines[0].timestamp, const Duration(milliseconds: 1600));
    expect(lines[0].text, '第一句');
    expect(lines[1].timestamp, const Duration(milliseconds: 3350));
    expect(lines[2].timestamp, const Duration(milliseconds: 5100));
  });

  test('根据播放位置定位当前歌词', () {
    final lines = LrcParser.parse('[00:00.00]开始\n[00:10.00]副歌\n');

    expect(LrcParser.activeIndex(lines, const Duration(seconds: 9)), 0);
    expect(LrcParser.activeIndex(lines, const Duration(seconds: 10)), 1);
  });

  test('无时间标签的歌词按普通文本保留', () {
    final lines = LrcParser.parse('第一行\n第二行');

    expect(lines.map((line) => line.text), <String>['第一行', '第二行']);
    expect(lines.every((line) => line.timestamp == null), isTrue);
    expect(LrcParser.activeIndex(lines, const Duration(seconds: 3)), -1);
  });

  desktopTestWidgets('音质菜单只展示当前歌曲支持的音质并可选择新音质', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    String? selectedQuality;
    const song = Song(
      source: MusicSource.qq,
      id: 97773,
      mid: '0039MnYb0qxYhV',
      name: '晴天',
      artists: <String>['周杰伦'],
      album: '叶惠美',
      albumMid: '000MkMni19ClKG',
      coverUrl: '',
      durationSeconds: 269,
      hasMv: true,
      availableQualities: <String>['flac', '320mp3'],
    );
    const playback = PlaybackResult(
      source: MusicSource.qq,
      songId: 97773,
      available: true,
      url: 'https://example.com/audio.mp3',
      quality: '320mp3',
      reason: '',
      attempts: <PlaybackAttempt>[],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerBar(
            song: song,
            playback: playback,
            position: const Duration(seconds: 1),
            duration: const Duration(seconds: 269),
            isPlaying: true,
            loading: false,
            switchingQuality: false,
            error: null,
            playMode: PlayMode.sequentialLoop,
            volume: 0.8,
            availableQualities: song.availableQualities,
            canSkip: true,
            onTogglePlayback: _noop,
            onSeek: _ignoreDuration,
            onPrevious: _noop,
            onNext: _noop,
            onPlayModeChanged: _ignorePlayMode,
            onVolumeChanged: _ignoreVolume,
            onQualityChanged: (quality) => selectedQuality = quality,
          ),
        ),
      ),
    );

    await tester.tap(find.text('320 kbps'));
    await tester.pumpAndSettle();

    expect(find.text('FLAC 无损'), findsOneWidget);
    expect(find.text('128 kbps'), findsNothing);
    expect(find.text('AAC 96 kbps'), findsNothing);

    await tester.tap(find.byType(CheckedPopupMenuItem<String>).first);
    await tester.pumpAndSettle();
    expect(selectedQuality, 'flac');
  });

  desktopTestWidgets('账号切换列表中的失效账号可提示并可独立删除', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '209192670',
        accessKey: 'active-key',
        nickname: '当前账号',
        avatarUrl: 'https://example.com/current.png',
      ),
    );
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '10001',
        accessKey: 'expired-key',
        nickname: '过期账号',
        avatarUrl: 'https://example.com/expired.png',
      ),
    );
    store.clearClientAccountAccessKey(MusicSource.qq, '10001');
    store.activateClientAccount(MusicSource.qq, '209192670');
    final api = MusicApi(baseUrl: 'http://music.test');
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountDialog(
            api: api,
            store: store,
            activeAccount: store.snapshot().accountFor(MusicSource.qq),
            source: MusicSource.qq,
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('show-account-switcher')),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const ValueKey<String>('local-account-qq-10001')),
    );
    await tester.pump();
    expect(find.text('该账号授权已过期，无法切换'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('delete-local-account-qq-10001')),
    );
    await tester.pumpAndSettle();
    expect(
      store.snapshot().clientAccounts.map((account) => account.accountId),
      <String>['209192670'],
    );
  });

  desktopTestWidgets('本地歌单默认展开、远程歌单默认折叠并可独立刷新', (tester) async {
    await tester.binding.setSurfaceSize(const Size(700, 760));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    store.createPlaylist('本地收藏');
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '209192670',
        accessKey: 'access-key',
      ),
    );
    store.replaceRemotePlaylists(
      MusicSource.qq,
      '209192670',
      <RemotePlaylistSnapshot>[
        RemotePlaylistSnapshot(
          source: MusicSource.qq,
          id: 'remote-1',
          name: '远程收藏',
          coverUrl: '',
          songCount: 1,
          trackIds: const <int>[101],
        ),
      ],
    );
    var refreshed = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LibrarySidebar(
            snapshot: store.snapshot(),
            searchSelected: true,
            selectedPlaylistId: null,
            onSelectSearch: _noop,
            onSelectPlaylist: _ignoreString,
            onCreatePlaylist: _noop,
            onImportPlaylist: _noop,
            onRefreshRemotePlaylists: () async => refreshed = true,
            onRenamePlaylist: _ignorePlaylist,
            onDeletePlaylist: _ignorePlaylist,
          ),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('local-playlist-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote-playlist-list')),
      findsNothing,
    );
    expect(find.text('新建歌单'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('import-playlist')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('refresh-remote-playlists')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const ValueKey<String>('toggle-远程歌单')));
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('local-playlist-list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('remote-playlist-list')),
      findsOneWidget,
    );
    expect(find.text('远程收藏'), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey<String>('refresh-remote-playlists')),
    );
    await tester.pump();
    expect(refreshed, isTrue);
  });
}

void _noop() {}

void _ignoreDuration(Duration _) {}

void _ignorePlayMode(PlayMode _) {}

void _ignoreVolume(double _) {}

void _ignoreString(String _) {}

void _ignorePlaylist(Playlist _) {}

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
