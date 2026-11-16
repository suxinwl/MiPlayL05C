import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';

import '../models/client_account.dart';
import '../models/music_source.dart';
import '../models/playlist.dart';
import 'sqlite_database.dart';

const int _localLibrarySchemaVersion = 4;

/// SQLite 支持的本地歌单与播放偏好存储。
///
/// `playlists` 表保存歌单元数据，`playlist_songs` 表保存平台、歌曲 ID 与排序，
/// 不持久化歌曲标题、封面等可能过期的元数据。旧版本数据库不做数据迁移，
/// 结构不匹配时直接清空并重建。
class LocalLibraryStore {
  LocalLibraryStore._(this._database);

  final SqliteDatabase _database;
  bool _closed = false;

  /// 打开默认应用数据目录中的 SQLite 数据库。
  static Future<LocalLibraryStore> openDefault() async {
    final baseDirectory = await getApplicationSupportDirectory();
    final dataDirectory = Directory('${baseDirectory.path}/oo_music');
    await dataDirectory.create(recursive: true);
    return open('${dataDirectory.path}/library.sqlite3');
  }

  /// 打开指定路径的 SQLite 数据库；测试可传 `:memory:`。
  static LocalLibraryStore open(String databasePath) {
    if (databasePath != ':memory:') {
      final parent = Directory(File(databasePath).parent.path);
      parent.createSync(recursive: true);
    }
    final database = SqliteDatabase.open(databasePath);
    final store = LocalLibraryStore._(database);
    try {
      store._initializeSchema();
      return store;
    } on Object {
      database.dispose();
      rethrow;
    }
  }

  /// 创建一个独立的内存数据库，主要用于测试。
  static LocalLibraryStore inMemory() => open(':memory:');

  void _initializeSchema() {
    final versionRows = _database.select('PRAGMA user_version;');
    final currentVersion = versionRows.isEmpty
        ? 0
        : _asInt(versionRows.first['user_version']);
    if (currentVersion > _localLibrarySchemaVersion) {
      throw StateError(
        '本地数据库版本 $currentVersion 高于当前客户端支持的 $_localLibrarySchemaVersion',
      );
    }

    final rebuild =
        currentVersion != _localLibrarySchemaVersion || !_hasCurrentSchema();
    _database.execute('PRAGMA foreign_keys = OFF;');
    try {
      _database.transaction(() {
        if (rebuild) {
          _dropLibraryTables();
        }
        _createCurrentSchema();
        _seedDefaults();
        final foreignKeyViolations = _database.select(
          'PRAGMA foreign_key_check;',
        );
        if (foreignKeyViolations.isNotEmpty) {
          throw StateError('本地音乐库存在无效歌单歌曲引用');
        }
        _database.execute('PRAGMA user_version = $_localLibrarySchemaVersion;');
      });
    } finally {
      _database.execute('PRAGMA foreign_keys = ON;');
    }
  }

  bool _hasCurrentSchema() {
    return _tableExists('settings') &&
        _hasExactColumns('settings', const <String>{'key', 'value'}) &&
        _hasExactColumns('playlists', const <String>{
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
        }) &&
        _hasExactColumns('playlist_songs', const <String>{
          'playlist_id',
          'source',
          'song_id',
          'sort_order',
        }) &&
        _hasExactColumns('client_accounts', const <String>{
          'account_type',
          'account_id',
          'access_key',
          'nickname',
          'avatar_url',
          'updated_at',
        });
  }

  void _dropLibraryTables() {
    _database.execute('''
      DROP TABLE IF EXISTS playlist_songs;
      DROP TABLE IF EXISTS playlists;
      DROP TABLE IF EXISTS playlist_songs_v4;
      DROP TABLE IF EXISTS playlists_v4;
      DROP TABLE IF EXISTS client_accounts;
      DROP TABLE IF EXISTS client_accounts_v4;
      DROP TABLE IF EXISTS settings;
    ''');
  }

  void _createCurrentSchema() {
    _database.execute('''
      CREATE TABLE IF NOT EXISTS playlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        built_in INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL,
        playlist_type TEXT NOT NULL,
        source TEXT NOT NULL,
        account_id TEXT NOT NULL DEFAULT '',
        remote_id TEXT NOT NULL DEFAULT '',
        cover_url TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS playlist_songs (
        playlist_id TEXT NOT NULL,
        source TEXT NOT NULL,
        song_id TEXT NOT NULL,
        sort_order INTEGER NOT NULL,
        PRIMARY KEY (playlist_id, source, song_id),
        FOREIGN KEY (playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
      );
      CREATE INDEX IF NOT EXISTS idx_playlist_songs_order
      ON playlist_songs(playlist_id, sort_order);
      CREATE TABLE IF NOT EXISTS client_accounts (
        account_type TEXT NOT NULL,
        account_id TEXT NOT NULL,
        access_key TEXT,
        nickname TEXT NOT NULL DEFAULT '',
        avatar_url TEXT NOT NULL DEFAULT '',
        updated_at INTEGER NOT NULL,
        PRIMARY KEY(account_type, account_id)
      );
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      );
    ''');
  }

  void _seedDefaults() {
    _database.run(
      '''
      INSERT OR IGNORE INTO playlists(
        id, name, built_in, sort_order, playlist_type, source, account_id,
        remote_id, cover_url, updated_at
      ) VALUES (?, ?, 1, 0, 'local', 'mixed', '', '', '', 0);
    ''',
      <Object?>[recentlyPlayedPlaylistId, '最近播放'],
    );
    _database.execute('''
      INSERT OR IGNORE INTO settings(key, value) VALUES
        ('play_mode', 'sequential_loop'),
        ('volume', '0.8'),
        ('selected_source', 'qq'),
        ('active_account_qq', ''),
        ('active_account_netease', ''),
        ('preferred_quality_qq', '320mp3'),
        ('preferred_quality_netease', '320mp3');
    ''');
  }

  bool _tableExists(String table) {
    final rows = _database.select(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;",
      <Object?>[table],
    );
    return rows.isNotEmpty;
  }

  bool _hasExactColumns(String table, Set<String> expected) {
    final actual = _tableColumns(table);
    return actual.length == expected.length && actual.containsAll(expected);
  }

  Set<String> _tableColumns(String table) {
    return _database
        .select('PRAGMA table_info($table);')
        .map((row) => row['name']?.toString() ?? '')
        .toSet();
  }

  /// 读取完整的歌单和播放偏好快照。
  LibrarySnapshot snapshot() {
    _ensureOpen();
    final playlistRows = _database.select('''
      SELECT id, name, built_in, playlist_type, source, account_id, remote_id,
             cover_url, updated_at
      FROM playlists
      ORDER BY sort_order ASC, id ASC;
    ''');
    final songRows = _database.select('''
      SELECT playlist_id, source, song_id
      FROM playlist_songs
      ORDER BY playlist_id ASC, sort_order ASC;
    ''');
    final songsByPlaylist = <String, List<PlaylistSongRef>>{};
    for (final row in songRows) {
      final playlistId = row['playlist_id']?.toString() ?? '';
      final songId = _asInt(row['song_id']);
      if (songId <= 0) {
        continue;
      }
      songsByPlaylist
          .putIfAbsent(playlistId, () => <PlaylistSongRef>[])
          .add(
            PlaylistSongRef(
              source: MusicSourceDetails.fromStorage(row['source']?.toString()),
              songId: songId,
            ),
          );
    }
    final playlists = <Playlist>[
      for (final row in playlistRows)
        Playlist(
          id: row['id']?.toString() ?? '',
          name: row['name']?.toString() ?? '',
          songs:
              songsByPlaylist[row['id']?.toString()] ??
              const <PlaylistSongRef>[],
          builtIn: _asInt(row['built_in']) == 1,
          source: PlaylistSourceDetails.fromStorage(
            row['playlist_type']?.toString(),
          ),
          musicSource: _playlistMusicSource(row['source']?.toString()),
          accountId: row['account_id']?.toString() ?? '',
          remoteId: row['remote_id']?.toString() ?? '',
          coverUrl: row['cover_url']?.toString() ?? '',
          updatedAt: _asInt(row['updated_at']) <= 0
              ? null
              : DateTime.fromMillisecondsSinceEpoch(_asInt(row['updated_at'])),
        ),
    ];
    final settings = <String, String>{
      for (final row in _database.select('SELECT key, value FROM settings;'))
        row['key']?.toString() ?? '': row['value']?.toString() ?? '',
    };
    final clientAccounts = _database
        .select('''
          SELECT account_type, account_id, access_key, nickname, avatar_url, updated_at
          FROM client_accounts
          ORDER BY account_type ASC, updated_at DESC, account_id ASC;
        ''')
        .map(_clientAccountFromRow)
        .toList(growable: false);
    final selectedSource = MusicSourceDetails.fromStorage(
      settings['selected_source'],
    );
    final qqAccount = _activeAccountFor(
      clientAccounts,
      MusicSource.qq,
      settings['active_account_qq'] ?? '',
    );
    final neteaseAccount = _activeAccountFor(
      clientAccounts,
      MusicSource.netease,
      settings['active_account_netease'] ?? '',
    );
    return LibrarySnapshot(
      playlists: playlists,
      playMode: PlayModeDetails.fromStorage(settings['play_mode']),
      volume: _asDouble(settings['volume'], fallback: 0.8).clamp(0, 1),
      selectedSource: selectedSource,
      preferredQualityQq: settings['preferred_quality_qq'] ?? '320mp3',
      preferredQualityNetease:
          settings['preferred_quality_netease'] ?? '320mp3',
      clientAccounts: clientAccounts,
      qqAccount: qqAccount,
      neteaseAccount: neteaseAccount,
    );
  }

  /// 创建用户歌单并返回新歌单。
  Playlist createPlaylist(String name) {
    _ensureOpen();
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw const FormatException('歌单名称不能为空');
    }
    if (normalizedName.length > 60) {
      throw const FormatException('歌单名称不能超过 60 个字符');
    }
    final existing = _database.select(
      '''
      SELECT 1 FROM playlists
      WHERE playlist_type = 'local' AND built_in = 0 AND lower(name) = lower(?)
      LIMIT 1;
      ''',
      <Object?>[normalizedName],
    );
    if (existing.isNotEmpty) {
      throw const FormatException('已经存在同名歌单');
    }
    final id =
        'playlist_${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(1 << 31)}';
    final nextOrder = _database
        .select(
          'SELECT COALESCE(MAX(sort_order), 0) + 1 AS value FROM playlists;',
        )
        .first['value'];
    _database.run(
      '''
      INSERT INTO playlists(
        id, name, built_in, sort_order, playlist_type, source, account_id,
        remote_id, cover_url, updated_at
      ) VALUES (?, ?, 0, ?, 'local', 'mixed', '', '', '', ?);
      ''',
      <Object?>[
        id,
        normalizedName,
        _asInt(nextOrder),
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    return Playlist(
      id: id,
      name: normalizedName,
      songs: const <PlaylistSongRef>[],
      builtIn: false,
    );
  }

  /// 重命名用户歌单。
  void renamePlaylist(String playlistId, String name) {
    _ensureOpen();
    _requireCustomPlaylist(playlistId);
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw const FormatException('歌单名称不能为空');
    }
    if (normalizedName.length > 60) {
      throw const FormatException('歌单名称不能超过 60 个字符');
    }
    final duplicate = _database.select(
      '''
      SELECT 1 FROM playlists
      WHERE playlist_type = 'local' AND built_in = 0 AND id <> ?
        AND lower(name) = lower(?)
      LIMIT 1;
      ''',
      <Object?>[playlistId, normalizedName],
    );
    if (duplicate.isNotEmpty) {
      throw const FormatException('已经存在同名歌单');
    }
    _database.run('UPDATE playlists SET name = ? WHERE id = ?;', <Object?>[
      normalizedName,
      playlistId,
    ]);
  }

  /// 删除用户歌单；内置歌单不可删除。
  void deletePlaylist(String playlistId) {
    _ensureOpen();
    _requireCustomPlaylist(playlistId);
    _database.run('DELETE FROM playlists WHERE id = ?;', <Object?>[playlistId]);
  }

  /// 将歌曲添加到用户歌单末尾；重复添加不会产生第二条记录。
  ///
  /// 返回是否真的新增了记录。最近播放等内置歌单必须使用
  /// [touchRecentlyPlayed]，不能由用户手动添加。
  /// 将指定平台歌曲添加到用户歌单末尾；重复添加不会产生第二条记录。
  bool addSongToPlaylist(String playlistId, MusicSource source, int songId) {
    _ensureOpen();
    _requireCustomPlaylist(playlistId);
    if (songId <= 0) {
      throw const FormatException('歌曲 ID 必须为正整数');
    }
    return _database.transaction(() {
      final existing = _database.select(
        'SELECT 1 FROM playlist_songs WHERE playlist_id = ? AND source = ? AND song_id = ? LIMIT 1;',
        <Object?>[playlistId, source.storageValue, songId.toString()],
      );
      if (existing.isNotEmpty) {
        return false;
      }
      final nextOrder = _database
          .select(
            '''
        SELECT COALESCE(MAX(sort_order), -1) + 1 AS value
        FROM playlist_songs WHERE playlist_id = ?;
        ''',
            <Object?>[playlistId],
          )
          .first['value'];
      _database.run(
        '''
        INSERT INTO playlist_songs(playlist_id, source, song_id, sort_order)
        VALUES (?, ?, ?, ?);
        ''',
        <Object?>[
          playlistId,
          source.storageValue,
          songId.toString(),
          _asInt(nextOrder),
        ],
      );
      return true;
    });
  }

  /// 从歌单中移除歌曲，并重新整理剩余歌曲顺序。
  ///
  /// 最近播放允许移除歌曲，但用户歌单和最近播放都不允许在歌单记录上
  /// 使用添加按钮，调用方应遵守各自入口约束。
  /// 从歌单中移除指定平台歌曲，并重新整理剩余歌曲顺序。
  bool removeSongFromPlaylist(
    String playlistId,
    MusicSource source,
    int songId,
  ) {
    _ensureOpen();
    _requireLocalPlaylist(playlistId);
    return _database.transaction(() {
      final row = _database.select(
        'SELECT sort_order FROM playlist_songs WHERE playlist_id = ? AND source = ? AND song_id = ? LIMIT 1;',
        <Object?>[playlistId, source.storageValue, songId.toString()],
      );
      if (row.isEmpty) {
        return false;
      }
      final removedOrder = _asInt(row.first['sort_order']);
      _database.run(
        'DELETE FROM playlist_songs WHERE playlist_id = ? AND source = ? AND song_id = ?;',
        <Object?>[playlistId, source.storageValue, songId.toString()],
      );
      _database.run(
        '''
        UPDATE playlist_songs SET sort_order = sort_order - 1
        WHERE playlist_id = ? AND sort_order > ?;
        ''',
        <Object?>[playlistId, removedOrder],
      );
      return true;
    });
  }

  /// 用新的歌曲 ID 顺序替换用户歌单顺序。
  /// 用新的跨平台歌曲顺序替换用户歌单顺序。
  void reorderSongs(String playlistId, List<PlaylistSongRef> orderedSongs) {
    _ensureOpen();
    _requireCustomPlaylist(playlistId);
    final orderedKeys = orderedSongs.map((song) => song.mediaKey).toList();
    if (orderedKeys.toSet().length != orderedKeys.length) {
      throw const FormatException('歌单顺序中存在重复歌曲');
    }
    _database.transaction(() {
      final currentKeys = _database
          .select(
            'SELECT source, song_id FROM playlist_songs WHERE playlist_id = ? ORDER BY sort_order ASC;',
            <Object?>[playlistId],
          )
          .map(_playlistSongRefFromRow)
          .map((song) => song.mediaKey)
          .toSet();
      if (currentKeys.length != orderedKeys.length ||
          !currentKeys.containsAll(orderedKeys)) {
        throw const FormatException('歌单内容已经变化，请刷新后重试');
      }
      _database.run(
        'DELETE FROM playlist_songs WHERE playlist_id = ?;',
        <Object?>[playlistId],
      );
      for (var index = 0; index < orderedSongs.length; index++) {
        final song = orderedSongs[index];
        _database.run(
          '''
          INSERT INTO playlist_songs(playlist_id, source, song_id, sort_order)
          VALUES (?, ?, ?, ?);
          ''',
          <Object?>[
            playlistId,
            song.source.storageValue,
            song.songId.toString(),
            index,
          ],
        );
      }
    });
  }

  /// 使用一次成功刷新结果替换指定账号的全部远程歌单缓存。
  ///
  /// 该方法只删除同一账号、同一平台下的远程歌单，不影响本地歌单或其他账号
  /// 的远程缓存。调用方应先完成网络请求，失败时不要调用该方法。
  void replaceRemotePlaylists(
    MusicSource source,
    String accountId,
    List<RemotePlaylistSnapshot> playlists,
  ) {
    _ensureOpen();
    final normalizedAccountID = accountId.trim();
    if (normalizedAccountID.isEmpty) {
      throw const FormatException('远程歌单账号 ID 不能为空');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final seenRemoteIds = <String>{};
    _database.transaction(() {
      _database.run(
        "DELETE FROM playlists WHERE playlist_type = 'remote' AND source = ? AND account_id = ?;",
        <Object?>[source.storageValue, normalizedAccountID],
      );
      for (var index = 0; index < playlists.length; index++) {
        final playlist = playlists[index];
        final remoteId = playlist.id.trim();
        if (remoteId.isEmpty) {
          throw const FormatException('远程歌单 ID 不能为空');
        }
        if (!seenRemoteIds.add(remoteId)) {
          continue;
        }
        final name = playlist.name.trim().isEmpty
            ? '未命名歌单'
            : playlist.name.trim();
        final playlistId = remotePlaylistStorageId(
          normalizedAccountID,
          remoteId,
          source: source,
        );
        _database.run(
          '''
          INSERT INTO playlists(
            id, name, built_in, sort_order, playlist_type, source, account_id,
            remote_id, cover_url, updated_at
          ) VALUES (?, ?, 0, ?, 'remote', ?, ?, ?, ?, ?);
          ''',
          <Object?>[
            playlistId,
            name,
            index,
            source.storageValue,
            normalizedAccountID,
            remoteId,
            playlist.coverUrl.trim(),
            now,
          ],
        );
        final seenSongIds = <int>{};
        var songOrder = 0;
        for (final songId in playlist.trackIds) {
          if (songId <= 0 || !seenSongIds.add(songId)) {
            continue;
          }
          _database.run(
            '''
            INSERT INTO playlist_songs(playlist_id, source, song_id, sort_order)
            VALUES (?, ?, ?, ?);
            ''',
            <Object?>[
              playlistId,
              source.storageValue,
              songId.toString(),
              songOrder++,
            ],
          );
        }
      }
    });
  }

  /// 将远程歌单按原顺序追加到本地歌单，已存在的歌曲跳过。
  ///
  /// 返回实际新增的歌曲数量。源必须是远程歌单，目标必须是用户创建的本地
  /// 歌单；内置“最近播放”和远程歌单不能作为目标。
  int importPlaylistSongs({
    required String sourcePlaylistId,
    required String targetPlaylistId,
  }) {
    _ensureOpen();
    _requireRemotePlaylist(sourcePlaylistId);
    _requireCustomPlaylist(targetPlaylistId);
    return _database.transaction(() {
      final sourceRows = _database.select(
        '''
        SELECT source, song_id FROM playlist_songs
        WHERE playlist_id = ? ORDER BY sort_order ASC;
        ''',
        <Object?>[sourcePlaylistId],
      );
      final existing = _database
          .select(
            'SELECT source, song_id FROM playlist_songs WHERE playlist_id = ?;',
            <Object?>[targetPlaylistId],
          )
          .map(_playlistSongRefFromRow)
          .map((song) => song.mediaKey)
          .toSet();
      var nextOrder = _asInt(
        _database
            .select(
              '''
              SELECT COALESCE(MAX(sort_order), -1) + 1 AS value
              FROM playlist_songs WHERE playlist_id = ?;
              ''',
              <Object?>[targetPlaylistId],
            )
            .first['value'],
      );
      var added = 0;
      for (final row in sourceRows) {
        final song = _playlistSongRefFromRow(row);
        if (song.songId <= 0 || !existing.add(song.mediaKey)) {
          continue;
        }
        _database.run(
          '''
          INSERT INTO playlist_songs(playlist_id, source, song_id, sort_order)
          VALUES (?, ?, ?, ?);
          ''',
          <Object?>[
            targetPlaylistId,
            song.source.storageValue,
            song.songId.toString(),
            nextOrder++,
          ],
        );
        added++;
      }
      return added;
    });
  }

  /// 把歌曲移到最近播放末尾；已存在时先删除旧记录，保证去重和最近顺序。
  /// 把指定平台歌曲移到最近播放末尾。
  void touchRecentlyPlayed(MusicSource source, int songId) {
    _ensureOpen();
    if (songId <= 0) {
      throw const FormatException('歌曲 ID 必须为正整数');
    }
    _database.transaction(() {
      _database.run(
        'DELETE FROM playlist_songs WHERE playlist_id = ? AND source = ? AND song_id = ?;',
        <Object?>[
          recentlyPlayedPlaylistId,
          source.storageValue,
          songId.toString(),
        ],
      );
      final nextOrder = _database
          .select(
            '''
        SELECT COALESCE(MAX(sort_order), -1) + 1 AS value
        FROM playlist_songs WHERE playlist_id = ?;
        ''',
            <Object?>[recentlyPlayedPlaylistId],
          )
          .first['value'];
      _database.run(
        '''
        INSERT INTO playlist_songs(playlist_id, source, song_id, sort_order)
        VALUES (?, ?, ?, ?);
        ''',
        <Object?>[
          recentlyPlayedPlaylistId,
          source.storageValue,
          songId.toString(),
          _asInt(nextOrder),
        ],
      );
    });
  }

  /// 保存播放模式。
  void setPlayMode(PlayMode mode) {
    _setSetting('play_mode', mode.storageValue);
  }

  /// 保存音量，范围会被限制在 0 到 1。
  void setVolume(double volume) {
    _setSetting('volume', volume.clamp(0, 1).toStringAsFixed(4));
  }

  /// 保存首选音质。
  void setPreferredQuality(String quality, MusicSource source) {
    final value = quality.trim();
    if (value.isEmpty) {
      throw const FormatException('音质标识不能为空');
    }
    _setSetting('preferred_quality_${source.storageValue}', value);
  }

  /// 保存当前选中的平台。
  void setSelectedSource(MusicSource source) {
    _setSetting('selected_source', source.storageValue);
  }

  /// 读取一个界面偏好字符串；键不存在时返回空字符串。
  String readSetting(String key) {
    _ensureOpen();
    final rows = _database.select(
      'SELECT value FROM settings WHERE key = ? LIMIT 1;',
      <Object?>[key],
    );
    return rows.isEmpty ? '' : rows.first['value']?.toString() ?? '';
  }

  /// 写入或覆盖一个界面偏好字符串。
  void saveSetting(String key, String value) {
    _ensureOpen();
    final normalizedKey = key.trim();
    if (normalizedKey.isEmpty) {
      throw const FormatException('设置键不能为空');
    }
    _setSetting(normalizedKey, value);
  }

  /// 保存并启用扫码登录得到的客户端授权账号。
  ///
  /// 同一平台账号再次扫码时会更新 accessKey 和资料，但不会创建重复记录。
  void saveClientAccountSession(ClientAccountSession session) {
    _ensureOpen();
    final accountID = session.accountId.trim();
    final accessKey = session.accessKey?.trim() ?? '';
    if (accountID.isEmpty || accessKey.isEmpty) {
      throw const FormatException('客户端授权身份不完整');
    }
    _database.transaction(() {
      _upsertClientAccount(
        session.copyWith(accountId: accountID, accessKey: accessKey),
      );
      _setSetting(_activeAccountSettingKey(session.source), accountID);
      _setSetting('selected_source', session.source.storageValue);
    });
  }

  /// 启用一个本机已保存且仍有 accessKey 的账号。
  ClientAccountSession activateClientAccount(
    MusicSource source,
    String accountId,
  ) {
    _ensureOpen();
    final normalized = accountId.trim();
    final rows = _database.select(
      '''
      SELECT account_type, account_id, access_key, nickname, avatar_url, updated_at
      FROM client_accounts
      WHERE account_type = ? AND account_id = ?
      LIMIT 1;
      ''',
      <Object?>[source.storageValue, normalized],
    );
    if (rows.isEmpty) {
      throw StateError('本地账号不存在');
    }
    final account = _clientAccountFromRow(rows.first);
    if (!account.canSwitch) {
      throw StateError('该账号授权已过期，无法切换');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _database.transaction(() {
      _database.run(
        'UPDATE client_accounts SET updated_at = ? WHERE account_type = ? AND account_id = ?;',
        <Object?>[now, source.storageValue, normalized],
      );
      _setSetting(_activeAccountSettingKey(source), normalized);
      _setSetting('selected_source', source.storageValue);
    });
    return account.copyWith(
      updatedAt: DateTime.fromMillisecondsSinceEpoch(now),
    );
  }

  /// 清除指定本地账号的 accessKey，同时保留昵称、头像和账号 ID。
  ///
  /// 若清除的是当前账号，会优先切换到另一个仍有 accessKey 的账号。
  void clearClientAccountAccessKey(MusicSource source, String accountId) {
    _ensureOpen();
    final normalized = accountId.trim();
    if (normalized.isEmpty) {
      return;
    }
    _database.transaction(() {
      _database.run(
        'UPDATE client_accounts SET access_key = NULL, updated_at = ? WHERE account_type = ? AND account_id = ?;',
        <Object?>[
          DateTime.now().millisecondsSinceEpoch,
          source.storageValue,
          normalized,
        ],
      );
      final active = _activeAccountID(source);
      if (active == normalized) {
        _selectFallbackActiveAccount(source, excludeAccountID: normalized);
      }
    });
  }

  /// 仅删除本机账号记录，不会删除后端绑定账号或使其他客户端退出。
  bool deleteClientAccount(MusicSource source, String accountId) {
    _ensureOpen();
    final normalized = accountId.trim();
    if (normalized.isEmpty) {
      return false;
    }
    return _database.transaction(() {
      final rows = _database.select(
        'SELECT 1 FROM client_accounts WHERE account_type = ? AND account_id = ? LIMIT 1;',
        <Object?>[source.storageValue, normalized],
      );
      if (rows.isEmpty) {
        return false;
      }
      _database.run(
        'DELETE FROM client_accounts WHERE account_type = ? AND account_id = ?;',
        <Object?>[source.storageValue, normalized],
      );
      if (_activeAccountID(source) == normalized) {
        _selectFallbackActiveAccount(source, excludeAccountID: normalized);
      }
      return true;
    });
  }

  /// 取消当前本地账号选择，但保留所有账号记录和 accessKey。
  void clearClientAccountSession(MusicSource source) {
    _ensureOpen();
    _database.run('DELETE FROM settings WHERE key = ?;', <Object?>[
      _activeAccountSettingKey(source),
    ]);
  }

  void _upsertClientAccount(ClientAccountSession account) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _database.run(
      '''
      INSERT INTO client_accounts(
        account_type, account_id, access_key, nickname, avatar_url, updated_at
      )
      VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(account_type, account_id) DO UPDATE SET
        access_key = CASE
          WHEN excluded.access_key IS NOT NULL AND trim(excluded.access_key) <> ''
            THEN excluded.access_key
          ELSE client_accounts.access_key
        END,
        nickname = CASE
          WHEN excluded.nickname <> '' THEN excluded.nickname
          ELSE client_accounts.nickname
        END,
        avatar_url = CASE
          WHEN excluded.avatar_url <> '' THEN excluded.avatar_url
          ELSE client_accounts.avatar_url
        END,
        updated_at = excluded.updated_at;
      ''',
      <Object?>[
        account.source.storageValue,
        account.accountId.trim(),
        account.accessKey?.trim(),
        account.nickname.trim(),
        account.avatarUrl.trim(),
        now,
      ],
    );
  }

  String _activeAccountID(MusicSource source) {
    final rows = _database.select(
      'SELECT value FROM settings WHERE key = ? LIMIT 1;',
      <Object?>[_activeAccountSettingKey(source)],
    );
    return rows.isEmpty ? '' : rows.first['value']?.toString().trim() ?? '';
  }

  void _selectFallbackActiveAccount(
    MusicSource source, {
    required String excludeAccountID,
  }) {
    final rows = _database.select(
      '''
      SELECT account_id FROM client_accounts
      WHERE account_type = ? AND account_id <> ?
        AND access_key IS NOT NULL AND trim(access_key) <> ''
      ORDER BY updated_at DESC, account_id ASC
      LIMIT 1;
      ''',
      <Object?>[source.storageValue, excludeAccountID],
    );
    if (rows.isEmpty) {
      _database.run('DELETE FROM settings WHERE key = ?;', <Object?>[
        _activeAccountSettingKey(source),
      ]);
      return;
    }
    _setSetting(
      _activeAccountSettingKey(source),
      rows.first['account_id']?.toString() ?? '',
    );
  }

  ClientAccountSession _clientAccountFromRow(Map<String, Object?> row) {
    final rawAccessKey = row['access_key']?.toString().trim() ?? '';
    final updatedAt = _asInt(row['updated_at']);
    return ClientAccountSession(
      accountId: row['account_id']?.toString() ?? '',
      source: MusicSourceDetails.fromStorage(row['account_type']?.toString()),
      accessKey: rawAccessKey.isEmpty ? null : rawAccessKey,
      nickname: row['nickname']?.toString() ?? '',
      avatarUrl: row['avatar_url']?.toString() ?? '',
      updatedAt: updatedAt <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(updatedAt),
    );
  }

  ClientAccountSession? _activeAccountFor(
    List<ClientAccountSession> accounts,
    MusicSource source,
    String activeAccountID,
  ) {
    final normalized = activeAccountID.trim();
    if (normalized.isEmpty) {
      return null;
    }
    for (final account in accounts) {
      if (account.source == source && account.accountId == normalized) {
        return account;
      }
    }
    return null;
  }

  MusicSource? _playlistMusicSource(String? raw) {
    return switch (raw?.trim().toLowerCase()) {
      'qq' => MusicSource.qq,
      'netease' => MusicSource.netease,
      _ => null,
    };
  }

  PlaylistSongRef _playlistSongRefFromRow(Map<String, Object?> row) {
    return PlaylistSongRef(
      source: MusicSourceDetails.fromStorage(row['source']?.toString()),
      songId: _asInt(row['song_id']),
    );
  }

  String _activeAccountSettingKey(MusicSource source) {
    return 'active_account_${source.storageValue}';
  }

  void _setSetting(String key, String value) {
    _ensureOpen();
    _database.run(
      '''
      INSERT INTO settings(key, value) VALUES (?, ?)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value;
      ''',
      <Object?>[key, value],
    );
  }

  void _requireCustomPlaylist(String playlistId) {
    final rows = _database.select(
      'SELECT built_in, playlist_type FROM playlists WHERE id = ? LIMIT 1;',
      <Object?>[playlistId],
    );
    if (rows.isEmpty) {
      throw StateError('歌单不存在');
    }
    if (_asInt(rows.first['built_in']) == 1) {
      throw StateError('内置歌单不支持该操作');
    }
    if (PlaylistSourceDetails.fromStorage(
          rows.first['playlist_type']?.toString(),
        ) !=
        PlaylistSource.local) {
      throw StateError('远程歌单不支持该操作');
    }
  }

  void _requireLocalPlaylist(String playlistId) {
    final rows = _database.select(
      'SELECT playlist_type FROM playlists WHERE id = ? LIMIT 1;',
      <Object?>[playlistId],
    );
    if (rows.isEmpty) {
      throw StateError('歌单不存在');
    }
    if (PlaylistSourceDetails.fromStorage(
          rows.first['playlist_type']?.toString(),
        ) !=
        PlaylistSource.local) {
      throw StateError('远程歌单只能添加到本地歌单');
    }
  }

  void _requireRemotePlaylist(String playlistId) {
    final rows = _database.select(
      'SELECT playlist_type FROM playlists WHERE id = ? LIMIT 1;',
      <Object?>[playlistId],
    );
    if (rows.isEmpty) {
      throw StateError('歌单不存在');
    }
    if (PlaylistSourceDetails.fromStorage(
          rows.first['playlist_type']?.toString(),
        ) !=
        PlaylistSource.remote) {
      throw StateError('源歌单必须是远程歌单');
    }
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('本地音乐库已经关闭');
    }
  }

  /// 关闭底层 SQLite 连接。
  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _database.dispose();
  }
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _asDouble(Object? value, {required double fallback}) {
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? fallback;
}
