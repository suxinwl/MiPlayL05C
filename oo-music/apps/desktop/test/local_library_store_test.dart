import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/models/client_account.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/models/playlist.dart';
import 'package:oo_music/storage/local_library_store.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late LocalLibraryStore store;

  setUp(() {
    store = LocalLibraryStore.inMemory();
  });

  tearDown(() {
    store.close();
  });

  test('初始化内置最近播放与默认播放偏好', () {
    final snapshot = store.snapshot();

    expect(snapshot.recentlyPlayed.name, '最近播放');
    expect(snapshot.recentlyPlayed.builtIn, isTrue);
    expect(snapshot.recentlyPlayed.songs, isEmpty);
    expect(snapshot.customPlaylists, isEmpty);
    expect(snapshot.playMode, PlayMode.sequentialLoop);
    expect(snapshot.volume, 0.8);
    expect(snapshot.preferredQualityFor(MusicSource.qq), '320mp3');
    expect(snapshot.accountFor(MusicSource.qq), isNull);
  });

  test('远程歌单存储 ID 包含平台和账号，避免跨平台冲突', () {
    expect(
      remotePlaylistStorageId('12345', 'playlist-1', source: MusicSource.qq),
      'remote:qq:12345:playlist-1',
    );
    expect(
      remotePlaylistStorageId(
        '12345',
        'playlist-1',
        source: MusicSource.netease,
      ),
      'remote:netease:12345:playlist-1',
    );
  });

  test('创建、重命名并删除用户歌单', () {
    final playlist = store.createPlaylist(' 我的歌单 ');
    expect(playlist.name, '我的歌单');
    expect(store.snapshot().customPlaylists.single.id, playlist.id);

    store.renamePlaylist(playlist.id, '通勤');
    expect(store.snapshot().playlistById(playlist.id)?.name, '通勤');

    store.deletePlaylist(playlist.id);
    expect(store.snapshot().playlistById(playlist.id), isNull);
  });

  test('歌曲添加去重、移除并保留指定顺序', () {
    final playlist = store.createPlaylist('测试');
    final firstAdd = store.addSongToPlaylist(playlist.id, MusicSource.qq, 101);
    final duplicateAdd = store.addSongToPlaylist(
      playlist.id,
      MusicSource.qq,
      101,
    );
    store.addSongToPlaylist(playlist.id, MusicSource.qq, 202);
    store.addSongToPlaylist(playlist.id, MusicSource.netease, 303);

    expect(firstAdd, isTrue);
    expect(duplicateAdd, isFalse);
    expect(
      store
          .snapshot()
          .playlistById(playlist.id)
          ?.songs
          .map((song) => song.mediaKey),
      <String>['qq:101', 'qq:202', 'netease:303'],
    );

    store.reorderSongs(playlist.id, const <PlaylistSongRef>[
      PlaylistSongRef(source: MusicSource.netease, songId: 303),
      PlaylistSongRef(source: MusicSource.qq, songId: 101),
      PlaylistSongRef(source: MusicSource.qq, songId: 202),
    ]);
    expect(
      store
          .snapshot()
          .playlistById(playlist.id)
          ?.songs
          .map((song) => song.mediaKey),
      <String>['netease:303', 'qq:101', 'qq:202'],
    );

    expect(
      store.removeSongFromPlaylist(playlist.id, MusicSource.qq, 101),
      isTrue,
    );
    expect(
      store
          .snapshot()
          .playlistById(playlist.id)
          ?.songs
          .map((song) => song.mediaKey),
      <String>['netease:303', 'qq:202'],
    );
  });

  test('最近播放会去重并按播放顺序追加到末尾', () {
    store.touchRecentlyPlayed(MusicSource.qq, 11);
    store.touchRecentlyPlayed(MusicSource.netease, 22);
    store.touchRecentlyPlayed(MusicSource.qq, 33);
    expect(
      store.snapshot().recentlyPlayed.songs.map((song) => song.mediaKey),
      <String>['qq:11', 'netease:22', 'qq:33'],
    );

    store.touchRecentlyPlayed(MusicSource.netease, 22);
    expect(
      store.snapshot().recentlyPlayed.songs.map((song) => song.mediaKey),
      <String>['qq:11', 'qq:33', 'netease:22'],
    );

    expect(
      store.removeSongFromPlaylist(
        recentlyPlayedPlaylistId,
        MusicSource.qq,
        11,
      ),
      isTrue,
    );
    expect(
      store.snapshot().recentlyPlayed.songs.map((song) => song.mediaKey),
      <String>['qq:33', 'netease:22'],
    );
  });

  test('内置最近播放不能被手动添加、重命名、排序或删除', () {
    expect(
      () => store.addSongToPlaylist(
        recentlyPlayedPlaylistId,
        MusicSource.qq,
        101,
      ),
      throwsStateError,
    );
    expect(
      () => store.renamePlaylist(recentlyPlayedPlaylistId, '新名称'),
      throwsStateError,
    );
    expect(
      () => store.reorderSongs(
        recentlyPlayedPlaylistId,
        const <PlaylistSongRef>[],
      ),
      throwsStateError,
    );
    expect(
      () => store.deletePlaylist(recentlyPlayedPlaylistId),
      throwsStateError,
    );
  });

  test('远程歌单按账号隔离刷新，不影响本地和其他账号缓存', () {
    final local = store.createPlaylist('我的本地歌单');
    store.addSongToPlaylist(local.id, MusicSource.qq, 97773);
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '209192670',
        accessKey: 'account-a',
      ),
    );

    store.replaceRemotePlaylists(
      MusicSource.qq,
      '209192670',
      <RemotePlaylistSnapshot>[
        RemotePlaylistSnapshot(
          source: MusicSource.qq,
          id: 'remote-a',
          name: '账号 A 的远程歌单',
          coverUrl: 'https://example.com/a.png',
          songCount: 3,
          trackIds: const <int>[101, 101, 202],
        ),
        RemotePlaylistSnapshot(
          source: MusicSource.qq,
          id: 'remote-a',
          name: '重复远程歌单',
          coverUrl: '',
          songCount: 1,
          trackIds: const <int>[303],
        ),
      ],
    );

    var snapshot = store.snapshot();
    expect(snapshot.localPlaylists.map((playlist) => playlist.id), <String>[
      recentlyPlayedPlaylistId,
      local.id,
    ]);
    expect(snapshot.customPlaylists.map((playlist) => playlist.id), <String>[
      local.id,
    ]);
    final remote = snapshot.remotePlaylistsFor(MusicSource.qq, '209192670');
    expect(remote, hasLength(1));
    expect(remote.single.accountId, '209192670');
    expect(remote.single.remoteId, 'remote-a');
    expect(remote.single.songs.map((song) => song.mediaKey), <String>[
      'qq:101',
      'qq:202',
    ]);

    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '10001',
        accessKey: 'account-b',
      ),
    );
    store.replaceRemotePlaylists(
      MusicSource.qq,
      '10001',
      <RemotePlaylistSnapshot>[
        RemotePlaylistSnapshot(
          source: MusicSource.qq,
          id: 'remote-b',
          name: '账号 B 的远程歌单',
          coverUrl: '',
          songCount: 1,
          trackIds: const <int>[404],
        ),
      ],
    );
    expect(
      store
          .snapshot()
          .remotePlaylistsFor(MusicSource.qq, '10001')
          .map((playlist) => playlist.name),
      <String>['账号 B 的远程歌单'],
    );

    store.activateClientAccount(MusicSource.qq, '209192670');
    store.replaceRemotePlaylists(
      MusicSource.qq,
      '209192670',
      <RemotePlaylistSnapshot>[
        RemotePlaylistSnapshot(
          source: MusicSource.qq,
          id: 'remote-a2',
          name: '刷新后的远程歌单',
          coverUrl: '',
          songCount: 1,
          trackIds: const <int>[505],
        ),
      ],
    );
    snapshot = store.snapshot();
    expect(
      snapshot
          .remotePlaylistsFor(MusicSource.qq, '209192670')
          .map((playlist) => playlist.remoteId),
      <String>['remote-a2'],
    );
    expect(snapshot.playlistById(local.id)?.songs.single.mediaKey, 'qq:97773');

    store.activateClientAccount(MusicSource.qq, '10001');
    expect(
      snapshot.playlistById(
        remotePlaylistStorageId(source: MusicSource.qq, '10001', 'remote-b'),
      ),
      isNotNull,
    );
    expect(
      store
          .snapshot()
          .remotePlaylistsFor(MusicSource.qq, '10001')
          .map((playlist) => playlist.remoteId),
      <String>['remote-b'],
    );
  });

  test('相同账号 ID 的远程歌单按平台隔离', () {
    store.replaceRemotePlaylists(
      MusicSource.qq,
      '12345678',
      <RemotePlaylistSnapshot>[
        RemotePlaylistSnapshot(
          source: MusicSource.qq,
          id: 'same-id',
          name: 'QQ 歌单',
          coverUrl: '',
          songCount: 1,
          trackIds: const <int>[11],
        ),
      ],
    );
    store.replaceRemotePlaylists(
      MusicSource.netease,
      '12345678',
      <RemotePlaylistSnapshot>[
        RemotePlaylistSnapshot(
          source: MusicSource.netease,
          id: 'same-id',
          name: '网易云歌单',
          coverUrl: '',
          songCount: 1,
          trackIds: const <int>[11],
        ),
      ],
    );

    final snapshot = store.snapshot();
    final qq = snapshot.remotePlaylistsFor(MusicSource.qq, '12345678');
    final netease = snapshot.remotePlaylistsFor(
      MusicSource.netease,
      '12345678',
    );
    expect(qq.single.name, 'QQ 歌单');
    expect(netease.single.name, '网易云歌单');
    expect(qq.single.id, isNot(netease.single.id));
  });

  test('远程歌单导入本地时保持顺序、追加到末尾并跳过重复歌曲', () {
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '209192670',
        accessKey: 'account-a',
      ),
    );
    store.replaceRemotePlaylists(
      MusicSource.qq,
      '209192670',
      <RemotePlaylistSnapshot>[
        RemotePlaylistSnapshot(
          source: MusicSource.qq,
          id: 'remote-import',
          name: '待导入歌单',
          coverUrl: '',
          songCount: 4,
          trackIds: const <int>[101, 202, 303, 101],
        ),
      ],
    );
    final target = store.createPlaylist('导入目标');
    store.addSongToPlaylist(target.id, MusicSource.qq, 202);
    store.addSongToPlaylist(target.id, MusicSource.qq, 999);
    store.addSongToPlaylist(target.id, MusicSource.netease, 101);

    final added = store.importPlaylistSongs(
      sourcePlaylistId: remotePlaylistStorageId(
        source: MusicSource.qq,
        '209192670',
        'remote-import',
      ),
      targetPlaylistId: target.id,
    );

    expect(added, 2);
    expect(
      store
          .snapshot()
          .playlistById(target.id)
          ?.songs
          .map((song) => song.mediaKey),
      <String>['qq:202', 'qq:999', 'netease:101', 'qq:101', 'qq:303'],
    );
  });

  test('远程歌单禁止本地管理，只能作为导入源或添加到本地歌单', () {
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '209192670',
        accessKey: 'account-a',
      ),
    );
    store.replaceRemotePlaylists(
      MusicSource.qq,
      '209192670',
      <RemotePlaylistSnapshot>[
        RemotePlaylistSnapshot(
          source: MusicSource.qq,
          id: 'readonly',
          name: '只读远程歌单',
          coverUrl: '',
          songCount: 1,
          trackIds: const <int>[101],
        ),
      ],
    );
    final remoteId = remotePlaylistStorageId(
      source: MusicSource.qq,
      '209192670',
      'readonly',
    );
    expect(store.snapshot().customPlaylists, isEmpty);

    expect(() => store.renamePlaylist(remoteId, '不能改名'), throwsStateError);
    expect(() => store.deletePlaylist(remoteId), throwsStateError);
    expect(
      () => store.addSongToPlaylist(remoteId, MusicSource.qq, 202),
      throwsStateError,
    );
    expect(
      () => store.removeSongFromPlaylist(remoteId, MusicSource.qq, 101),
      throwsStateError,
    );
    expect(
      () => store.reorderSongs(remoteId, const <PlaylistSongRef>[]),
      throwsStateError,
    );
  });

  test('旧版数据库会清空账号和歌单并重建为 v4', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'oo_music_legacy_reset_',
    );
    final databasePath = '${tempDirectory.path}/legacy.sqlite3';
    _createLegacyDatabase(databasePath);
    try {
      final rebuilt = LocalLibraryStore.open(databasePath);
      try {
        final snapshot = rebuilt.snapshot();
        expect(snapshot.customPlaylists, isEmpty);
        expect(snapshot.clientAccounts, isEmpty);
        expect(snapshot.recentlyPlayed.builtIn, isTrue);
        expect(snapshot.playMode, PlayMode.sequentialLoop);
        expect(snapshot.preferredQualityFor(MusicSource.qq), '320mp3');
      } finally {
        rebuilt.close();
      }

      final verification = sqlite3.open(databasePath);
      try {
        expect(
          verification.select('PRAGMA user_version;').first['user_version'],
          4,
        );
        expect(_tableColumns(verification, 'playlists'), <String>{
          'id',
          'name',
          'built_in',
          'sort_order',
          'playlist_type',
          'source',
          'account_id',
          'remote_id',
          'cover_url',
          'updated_at',
        });
        expect(
          verification
              .select(
                "SELECT COUNT(*) AS count FROM playlists WHERE id = 'legacy-local';",
              )
              .first['count'],
          0,
        );
        expect(
          verification
              .select('SELECT COUNT(*) AS count FROM client_accounts;')
              .first['count'],
          0,
        );
        expect(
          verification
              .select(
                "SELECT COUNT(*) AS count FROM settings WHERE key = 'active_client_uin';",
              )
              .first['count'],
          0,
        );
      } finally {
        verification.close();
      }
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('播放模式和音量设置可持久读取', () {
    store.setPlayMode(PlayMode.shuffle);
    store.setVolume(0.35);
    store.setPreferredQuality('flac', MusicSource.qq);

    final snapshot = store.snapshot();
    expect(snapshot.playMode, PlayMode.shuffle);
    expect(snapshot.volume, 0.35);
    expect(snapshot.preferredQualityFor(MusicSource.qq), 'flac');
  });

  test('客户端扫码授权身份可持久化并清除', () {
    const session = ClientAccountSession(
      source: MusicSource.qq,
      accountId: '209192670',
      accessKey: 'client-access-key',
    );

    store.saveClientAccountSession(session);
    final saved = store.snapshot().accountFor(MusicSource.qq);
    expect(saved?.accountId, session.accountId);
    expect(saved?.accessKey, session.accessKey);

    store.clearClientAccountSession(MusicSource.qq);
    expect(store.snapshot().accountFor(MusicSource.qq), isNull);
  });

  test('多账号可保存、切换，失效后保留资料并切换到后备账号', () {
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '209192670',
        accessKey: 'primary-key',
        nickname: '主账号',
        avatarUrl: 'https://example.com/primary.png',
      ),
    );
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '10001',
        accessKey: 'backup-key',
        nickname: '备用账号',
        avatarUrl: 'https://example.com/backup.png',
      ),
    );

    expect(store.snapshot().accountFor(MusicSource.qq)?.accountId, '10001');
    final activated = store.activateClientAccount(MusicSource.qq, '209192670');
    expect(activated.nickname, '主账号');
    expect(store.snapshot().accountFor(MusicSource.qq)?.accountId, '209192670');

    store.clearClientAccountAccessKey(MusicSource.qq, '209192670');
    final snapshot = store.snapshot();
    final expired = snapshot.clientAccounts.firstWhere(
      (account) => account.accountId == '209192670',
    );
    expect(expired.accessKey, isNull);
    expect(expired.nickname, '主账号');
    expect(expired.avatarUrl, 'https://example.com/primary.png');
    expect(snapshot.accountFor(MusicSource.qq)?.accountId, '10001');
    expect(
      () => store.activateClientAccount(MusicSource.qq, '209192670'),
      throwsStateError,
    );
  });

  test('QQ 与网易云可使用相同账号 ID，并各自保留当前账号', () {
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '12345678',
        accessKey: 'qq-key',
        nickname: 'QQ 用户',
      ),
    );
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.netease,
        accountId: '12345678',
        accessKey: 'netease-key',
        nickname: '网易云用户',
      ),
    );

    var snapshot = store.snapshot();
    expect(snapshot.selectedSource, MusicSource.netease);
    expect(snapshot.accountFor(MusicSource.qq)?.nickname, 'QQ 用户');
    expect(snapshot.accountFor(MusicSource.netease)?.nickname, '网易云用户');
    expect(snapshot.accountsFor(MusicSource.qq), hasLength(1));
    expect(snapshot.accountsFor(MusicSource.netease), hasLength(1));

    store.activateClientAccount(MusicSource.qq, '12345678');
    snapshot = store.snapshot();
    expect(snapshot.selectedSource, MusicSource.qq);
    expect(snapshot.accountFor(MusicSource.qq)?.accessKey, 'qq-key');
    expect(snapshot.accountFor(MusicSource.netease)?.accessKey, 'netease-key');

    store.clearClientAccountAccessKey(MusicSource.qq, '12345678');
    snapshot = store.snapshot();
    expect(snapshot.accountFor(MusicSource.qq)?.accessKey, isNull);
    expect(snapshot.accountFor(MusicSource.netease)?.accessKey, 'netease-key');
  });

  test('删除当前账号后切换到其他有效账号，且本地删除不影响其他记录', () {
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '209192670',
        accessKey: 'primary-key',
        nickname: '主账号',
      ),
    );
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '10001',
        accessKey: 'backup-key',
        nickname: '备用账号',
      ),
    );
    store.activateClientAccount(MusicSource.qq, '209192670');

    expect(store.deleteClientAccount(MusicSource.qq, '209192670'), isTrue);
    final snapshot = store.snapshot();
    expect(
      snapshot.clientAccounts.map((account) => account.accountId),
      <String>['10001'],
    );
    expect(snapshot.accountFor(MusicSource.qq)?.accountId, '10001');
    expect(store.deleteClientAccount(MusicSource.qq, 'missing'), isFalse);
  });

  test('全新数据库直接创建完整 v4 表结构', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'oo_music_fresh_v4_',
    );
    final databasePath = '${tempDirectory.path}/fresh.sqlite3';
    try {
      LocalLibraryStore.open(databasePath).close();
      final database = sqlite3.open(databasePath);
      try {
        expect(
          database.select('PRAGMA user_version;').first['user_version'],
          4,
        );
        expect(_tableColumns(database, 'playlists'), <String>{
          'id',
          'name',
          'built_in',
          'sort_order',
          'playlist_type',
          'source',
          'account_id',
          'remote_id',
          'cover_url',
          'updated_at',
        });
        expect(_tableColumns(database, 'playlist_songs'), <String>{
          'playlist_id',
          'source',
          'song_id',
          'sort_order',
        });
        expect(_tableColumns(database, 'client_accounts'), <String>{
          'account_type',
          'account_id',
          'access_key',
          'nickname',
          'avatar_url',
          'updated_at',
        });
      } finally {
        database.close();
      }
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('v4 字段结构不匹配时清空旧数据并重建', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'oo_music_partial_v4_',
    );
    final databasePath = '${tempDirectory.path}/partial.sqlite3';
    final database = sqlite3.open(databasePath);
    try {
      database.execute('''
        PRAGMA user_version = 4;
        CREATE TABLE settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        INSERT INTO settings(key, value) VALUES ('play_mode', 'shuffle');
        CREATE TABLE playlists (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          built_in INTEGER NOT NULL DEFAULT 0,
          sort_order INTEGER NOT NULL,
          playlist_type TEXT NOT NULL
        );
        INSERT INTO playlists(id, name, sort_order, playlist_type)
        VALUES ('partial', '不完整歌单', 1, 'local');
      ''');
    } finally {
      database.close();
    }

    try {
      final rebuilt = LocalLibraryStore.open(databasePath);
      try {
        final snapshot = rebuilt.snapshot();
        expect(snapshot.customPlaylists, isEmpty);
        expect(snapshot.playMode, PlayMode.sequentialLoop);
      } finally {
        rebuilt.close();
      }
      final verification = sqlite3.open(databasePath);
      try {
        expect(
          verification.select('PRAGMA user_version;').first['user_version'],
          4,
        );
        expect(
          verification
              .select(
                "SELECT COUNT(*) AS count FROM playlists WHERE id = 'partial';",
              )
              .first['count'],
          0,
        );
      } finally {
        verification.close();
      }
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('拒绝打开高于当前客户端支持版本的数据库', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'oo_music_future_version_',
    );
    final databasePath = '${tempDirectory.path}/library.sqlite3';
    final database = sqlite3.open(databasePath);
    try {
      database.execute('PRAGMA user_version = 5;');
    } finally {
      database.close();
    }
    try {
      expect(() => LocalLibraryStore.open(databasePath), throwsStateError);
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  });

  test('SQLite 文件关闭重开后仍保留歌单和播放偏好', () async {
    final tempDirectory = await Directory.systemTemp.createTemp(
      'oo_music_library_',
    );
    final databasePath = '${tempDirectory.path}/library.sqlite3';

    try {
      var diskStore = LocalLibraryStore.open(databasePath);
      final playlist = diskStore.createPlaylist('磁盘持久化');
      diskStore.addSongToPlaylist(playlist.id, MusicSource.qq, 97773);
      diskStore.touchRecentlyPlayed(MusicSource.qq, 97773);
      diskStore.setPlayMode(PlayMode.shuffle);
      diskStore.setVolume(0.42);
      diskStore.setPreferredQuality('flac', MusicSource.qq);
      diskStore.saveClientAccountSession(
        const ClientAccountSession(
          source: MusicSource.qq,
          accountId: '209192670',
          accessKey: 'persisted-access-key',
        ),
      );
      diskStore.close();

      diskStore = LocalLibraryStore.open(databasePath);
      try {
        final snapshot = diskStore.snapshot();
        expect(snapshot.playlistById(playlist.id)?.name, '磁盘持久化');
        expect(
          snapshot
              .playlistById(playlist.id)
              ?.songs
              .map((song) => song.mediaKey),
          <String>['qq:97773'],
        );
        expect(
          snapshot.recentlyPlayed.songs.map((song) => song.mediaKey),
          <String>['qq:97773'],
        );
        expect(snapshot.playMode, PlayMode.shuffle);
        expect(snapshot.volume, closeTo(0.42, 0.0001));
        expect(snapshot.preferredQualityFor(MusicSource.qq), 'flac');
        expect(snapshot.accountFor(MusicSource.qq)?.accountId, '209192670');
        expect(
          snapshot.accountFor(MusicSource.qq)?.accessKey,
          'persisted-access-key',
        );
      } finally {
        diskStore.close();
      }
    } finally {
      await tempDirectory.delete(recursive: true);
    }
  });
}

void _createLegacyDatabase(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute('''
      PRAGMA user_version = 3;
      CREATE TABLE playlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        built_in INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL,
        playlist_type TEXT NOT NULL DEFAULT 'local',
        account_uin TEXT NOT NULL DEFAULT '',
        remote_id TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE playlist_songs (
        playlist_id TEXT NOT NULL,
        song_id INTEGER NOT NULL,
        sort_order INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, song_id)
      );
      CREATE TABLE settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
      CREATE TABLE client_accounts (
        uin TEXT PRIMARY KEY,
        access_key TEXT,
        nickname TEXT NOT NULL DEFAULT '',
        avatar_url TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL
      );
      INSERT INTO playlists(id, name, sort_order, playlist_type)
      VALUES ('legacy-local', '旧版本地歌单', 0, 'local');
      INSERT INTO playlist_songs(playlist_id, song_id, sort_order)
      VALUES ('legacy-local', 97773, 0);
      INSERT INTO settings(key, value) VALUES
        ('play_mode', 'shuffle'),
        ('volume', '0.5'),
        ('preferred_quality', 'flac'),
        ('active_client_uin', '209192670');
      INSERT INTO client_accounts(
        uin, access_key, nickname, avatar_url, updated_at
      ) VALUES (
        '209192670', 'legacy-access-key', '旧 QQ 账号',
        'https://example.com/avatar.png', 123
      );
    ''');
  } finally {
    database.close();
  }
}

Set<String> _tableColumns(Database database, String table) {
  return database
      .select('PRAGMA table_info($table);')
      .map((row) => row['name']?.toString() ?? '')
      .toSet();
}
