import 'package:flutter/material.dart';

import 'client_account.dart';
import 'music_source.dart';

/// 内置“最近播放”歌单的固定 ID。
const String recentlyPlayedPlaylistId = 'recently-played';

/// 生成远程歌单在本地 SQLite 中的稳定 ID。
String remotePlaylistStorageId(
  String accountId,
  String remoteId, {
  required MusicSource source,
}) {
  return 'remote:${source.storageValue}:${accountId.trim()}:${remoteId.trim()}';
}

/// 歌单内的一首平台歌曲引用。
class PlaylistSongRef {
  /// 创建歌曲引用。
  const PlaylistSongRef({required this.source, required this.songId});

  /// 歌曲所属平台。
  final MusicSource source;

  /// 平台内歌曲 ID。
  final int songId;

  /// 跨平台唯一键。
  String get mediaKey => '${source.storageValue}:$songId';
}

/// 歌单数据来源。
enum PlaylistSource {
  /// 用户在本机创建和维护的歌单。
  local,

  /// 从平台账号读取并缓存到本机的歌单。
  remote,
}

/// 歌单来源的数据库取值与界面辅助方法。
extension PlaylistSourceDetails on PlaylistSource {
  /// 写入 SQLite 的稳定值。
  String get storageValue => switch (this) {
    PlaylistSource.local => 'local',
    PlaylistSource.remote => 'remote',
  };

  /// 展示给用户的名称。
  String get label => switch (this) {
    PlaylistSource.local => '本地歌单',
    PlaylistSource.remote => '远程歌单',
  };

  /// 从数据库值恢复歌单来源。
  static PlaylistSource fromStorage(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'local' => PlaylistSource.local,
      'remote' => PlaylistSource.remote,
      _ => throw FormatException('无效的歌单来源: ${value ?? ''}'),
    };
  }
}

/// 当前队列的播放模式。
enum PlayMode {
  /// 顺序播放，播放到末尾后回到第一首。
  sequentialLoop,

  /// 单曲循环，播放完成后重新播放当前歌曲。
  repeatOne,

  /// 随机播放，尽量避开与当前歌曲相同的下一首。
  shuffle,
}

/// 播放模式的持久化值与界面文案。
extension PlayModeDetails on PlayMode {
  /// 写入 SQLite 的稳定值。
  String get storageValue => switch (this) {
    PlayMode.sequentialLoop => 'sequential_loop',
    PlayMode.repeatOne => 'repeat_one',
    PlayMode.shuffle => 'shuffle',
  };

  /// 展示给用户的名称。
  String get label => switch (this) {
    PlayMode.sequentialLoop => '顺序循环',
    PlayMode.repeatOne => '单曲循环',
    PlayMode.shuffle => '随机播放',
  };

  /// 播放模式图标。
  IconData get icon => switch (this) {
    PlayMode.sequentialLoop => Icons.repeat_rounded,
    PlayMode.repeatOne => Icons.repeat_one_rounded,
    PlayMode.shuffle => Icons.shuffle_rounded,
  };

  /// 从数据库值恢复播放模式。
  static PlayMode fromStorage(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'sequential_loop' => PlayMode.sequentialLoop,
      'repeat_one' => PlayMode.repeatOne,
      'shuffle' => PlayMode.shuffle,
      _ => throw FormatException('无效的播放模式: ${value ?? ''}'),
    };
  }
}

/// 歌单及其跨平台歌曲顺序。
class Playlist {
  /// 创建不可变歌单模型。
  Playlist({
    required this.id,
    required this.name,
    required List<PlaylistSongRef> songs,
    required this.builtIn,
    this.source = PlaylistSource.local,
    this.musicSource,
    this.accountId = '',
    this.remoteId = '',
    this.coverUrl = '',
    this.updatedAt,
  }) : songs = List<PlaylistSongRef>.unmodifiable(songs);

  /// 歌单 ID。
  final String id;

  /// 歌单名称。
  final String name;

  /// 按展示顺序保存的跨平台歌曲引用。
  final List<PlaylistSongRef> songs;

  /// 是否由应用内置维护。
  final bool builtIn;

  /// 歌单来源。
  final PlaylistSource source;

  /// 远程歌单所属平台；本地混合歌单为空。
  final MusicSource? musicSource;

  /// 远程歌单所属账号 ID；本地歌单为空。
  final String accountId;

  /// 平台侧的远程歌单 ID；本地歌单为空。
  final String remoteId;

  /// 平台返回的歌单封面地址。
  final String coverUrl;

  /// 最近一次从平台刷新或写入本地数据库的时间。
  final DateTime? updatedAt;

  /// 是否为远程歌单。
  bool get isRemote => source == PlaylistSource.remote;

  /// 是否为本地歌单。
  bool get isLocal => source == PlaylistSource.local;

  /// 是否为“最近播放”歌单。
  bool get isRecentlyPlayed => id == recentlyPlayedPlaylistId;

  /// 是否允许手动添加歌曲。
  bool get allowsManualAdd => isLocal && !builtIn;

  /// 是否允许修改歌曲顺序。
  bool get allowsReorder => isLocal && !builtIn;

  /// 是否允许在客户端重命名或删除。
  bool get allowsLocalManagement => isLocal && !builtIn;
}

/// 后端返回的单次远程歌单快照。
class RemotePlaylistSnapshot {
  /// 创建不可变远程歌单快照。
  RemotePlaylistSnapshot({
    required this.id,
    required this.source,
    required this.name,
    required this.coverUrl,
    required this.songCount,
    required List<int> trackIds,
  }) : trackIds = List<int>.unmodifiable(trackIds);

  /// 平台侧的稳定歌单 ID。
  final String id;

  /// 远程歌单所属平台。
  final MusicSource source;

  /// 歌单名称。
  final String name;

  /// 歌单封面地址。
  final String coverUrl;

  /// 平台声明的歌曲数量。
  final int songCount;

  /// 按平台歌单顺序返回的歌曲 ID。
  final List<int> trackIds;
}

/// 一次读取得到的歌单与播放偏好快照。
class LibrarySnapshot {
  /// 创建不可变快照。
  LibrarySnapshot({
    required List<Playlist> playlists,
    required this.playMode,
    required this.volume,
    required this.selectedSource,
    required this.preferredQualityQq,
    required this.preferredQualityNetease,
    required List<ClientAccountSession> clientAccounts,
    required this.qqAccount,
    required this.neteaseAccount,
  }) : playlists = List<Playlist>.unmodifiable(playlists),
       clientAccounts = List<ClientAccountSession>.unmodifiable(clientAccounts);

  /// 按侧栏顺序保存的歌单。
  final List<Playlist> playlists;

  /// 当前播放模式。
  final PlayMode playMode;

  /// 当前音量，范围 0 到 1。
  final double volume;

  /// 当前选中的平台。
  final MusicSource selectedSource;

  /// QQ 音乐首选音质。
  final String preferredQualityQq;

  /// 网易云音乐首选音质。
  final String preferredQualityNetease;

  /// 本机保存过的全部平台授权账号，包括授权已失效的禁用账号。
  final List<ClientAccountSession> clientAccounts;

  /// 当前选中的 QQ 音乐账号。
  final ClientAccountSession? qqAccount;

  /// 当前选中的网易云音乐账号。
  final ClientAccountSession? neteaseAccount;

  /// 指定平台当前账号。
  ClientAccountSession? accountFor(MusicSource source) {
    return source == MusicSource.qq ? qqAccount : neteaseAccount;
  }

  /// 指定平台保存的账号列表。
  List<ClientAccountSession> accountsFor(MusicSource source) => clientAccounts
      .where((account) => account.source == source)
      .toList(growable: false);

  /// 指定平台的首选音质。
  String preferredQualityFor(MusicSource source) {
    return source == MusicSource.qq
        ? preferredQualityQq
        : preferredQualityNetease;
  }

  /// 内置的最近播放歌单。
  Playlist get recentlyPlayed => playlists.firstWhere(
    (playlist) => playlist.isLocal && playlist.isRecentlyPlayed,
    orElse: () => Playlist(
      id: recentlyPlayedPlaylistId,
      name: '最近播放',
      songs: const <PlaylistSongRef>[],
      builtIn: true,
    ),
  );

  /// 全部本地歌单，包括最近播放。
  List<Playlist> get localPlaylists =>
      playlists.where((playlist) => playlist.isLocal).toList(growable: false);

  /// 指定平台和账号的远程歌单缓存。
  List<Playlist> remotePlaylistsFor(MusicSource source, String accountId) {
    final normalized = accountId.trim();
    if (normalized.isEmpty) {
      return const <Playlist>[];
    }
    return playlists
        .where(
          (playlist) =>
              playlist.isRemote &&
              playlist.musicSource == source &&
              playlist.accountId == normalized,
        )
        .toList(growable: false);
  }

  /// 用户创建的可编辑本地歌单；不包含远程歌单和内置歌单。
  List<Playlist> get customPlaylists => playlists
      .where((playlist) => playlist.isLocal && !playlist.builtIn)
      .toList(growable: false);

  /// 按 ID 查找歌单。
  Playlist? playlistById(String id) {
    for (final playlist in playlists) {
      if (playlist.id == id) {
        return playlist;
      }
    }
    return null;
  }
}
