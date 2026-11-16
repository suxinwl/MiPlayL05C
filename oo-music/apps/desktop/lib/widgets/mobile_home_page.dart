import 'dart:async';

import 'package:flutter/material.dart';

import '../models/client_account.dart';
import '../models/music_source.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';
import 'music_source_badge.dart';

/// 搜索结果页；移动端只展示歌曲结果。
class MobileSearchPage extends StatelessWidget {
  const MobileSearchPage({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.searching,
    required this.account,
    required this.source,
    required this.accountAvatarUrl,
    required this.openingAccountLogin,
    required this.songs,
    required this.selectedSong,
    required this.playing,
    required this.error,
    required this.searched,
    required this.lastQuery,
    required this.downloadingSongKeys,
    required this.downloadProgress,
    required this.onSearch,
    required this.onAccountPressed,
    required this.onSelect,
    required this.onTogglePlayback,
    required this.onDownload,
    required this.onPlayMv,
    required this.onAddToPlaylist,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool searching;
  final ClientAccountSession? account;
  final MusicSource source;
  final String accountAvatarUrl;
  final bool openingAccountLogin;
  final List<Song> songs;
  final Song? selectedSong;
  final bool playing;
  final String? error;
  final bool searched;
  final String lastQuery;
  final Set<String> downloadingSongKeys;
  final Map<String, double?> downloadProgress;
  final VoidCallback onSearch;
  final VoidCallback onAccountPressed;
  final ValueChanged<Song> onSelect;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Song> onDownload;
  final ValueChanged<Song> onPlayMv;
  final ValueChanged<Song> onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey<String>('mobile-search-page'),
      children: <Widget>[
        _MobileHeader(
          title: 'oo music',
          subtitle: '${source.label} · 搜索歌曲、歌手或专辑',
          trailing: _MobileAccountButton(
            account: account,
            avatarUrl: accountAvatarUrl,
            loading: openingAccountLogin,
            onPressed: onAccountPressed,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: TextField(
            key: const ValueKey<String>('mobile-search-field'),
            controller: controller,
            focusNode: focusNode,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => onSearch(),
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
            decoration: InputDecoration(
              hintText: '搜索歌曲、歌手或专辑',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              suffixIcon: IconButton(
                key: const ValueKey<String>('mobile-search-button'),
                tooltip: '搜索歌曲',
                onPressed: searching ? null : onSearch,
                icon: searching
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward_rounded, size: 20),
                color: AppColors.accent,
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
        Expanded(
          child: _MobileSearchResults(
            songs: songs,
            selectedSong: selectedSong,
            playing: playing,
            searching: searching,
            error: error,
            searched: searched,
            lastQuery: lastQuery,
            downloadingSongKeys: downloadingSongKeys,
            downloadProgress: downloadProgress,
            onSelect: onSelect,
            onTogglePlayback: onTogglePlayback,
            onDownload: onDownload,
            onPlayMv: onPlayMv,
            onAddToPlaylist: onAddToPlaylist,
          ),
        ),
      ],
    );
  }
}

class _MobileSearchResults extends StatelessWidget {
  const _MobileSearchResults({
    required this.songs,
    required this.selectedSong,
    required this.playing,
    required this.searching,
    required this.error,
    required this.searched,
    required this.lastQuery,
    required this.downloadingSongKeys,
    required this.downloadProgress,
    required this.onSelect,
    required this.onTogglePlayback,
    required this.onDownload,
    required this.onPlayMv,
    required this.onAddToPlaylist,
  });

  final List<Song> songs;
  final Song? selectedSong;
  final bool playing;
  final bool searching;
  final String? error;
  final bool searched;
  final String lastQuery;
  final Set<String> downloadingSongKeys;
  final Map<String, double?> downloadProgress;
  final ValueChanged<Song> onSelect;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Song> onDownload;
  final ValueChanged<Song> onPlayMv;
  final ValueChanged<Song> onAddToPlaylist;

  @override
  Widget build(BuildContext context) {
    if (searching && songs.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (error != null) {
      return _MobileEmptyState(
        icon: Icons.cloud_off_rounded,
        title: '搜索失败',
        description: error!,
      );
    }
    if (songs.isEmpty) {
      return _MobileEmptyState(
        icon: searched ? Icons.search_off_rounded : Icons.search_rounded,
        title: searched ? '没有找到“$lastQuery”' : '搜索音乐',
        description: searched ? '试试更短的关键词，或换用歌手名、专辑名搜索' : '输入歌曲名、歌手或专辑名开始搜索',
      );
    }
    return ListView.separated(
      key: const ValueKey<String>('mobile-search-results'),
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
      itemCount: songs.length + 1,
      separatorBuilder: (_, index) => index == 0
          ? const SizedBox.shrink()
          : const Divider(height: 1, indent: 66, color: AppColors.border),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 4),
            child: Row(
              children: <Widget>[
                const Text(
                  '歌曲结果',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                Text(
                  '${songs.length} 首',
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          );
        }
        final song = songs[index - 1];
        return MobileSongRow(
          song: song,
          selected: selectedSong?.mediaKey == song.mediaKey,
          playing: playing,
          downloading: downloadingSongKeys.contains(song.mediaKey),
          downloadProgress: downloadProgress[song.mediaKey],
          onTap: () => onSelect(song),
          onTogglePlayback: onTogglePlayback,
          onDownload: () => onDownload(song),
          onPlayMv: song.hasMv ? () => onPlayMv(song) : null,
          onAddToPlaylist: () => onAddToPlaylist(song),
        );
      },
    );
  }
}

/// 音乐库首页：只展示本地歌单和远程歌单两个分组。
class MobileLibraryPage extends StatelessWidget {
  const MobileLibraryPage({
    super.key,
    required this.snapshot,
    required this.error,
    required this.refreshingRemotePlaylists,
    required this.onCreatePlaylist,
    required this.onImportPlaylist,
    required this.onRefreshRemotePlaylists,
    required this.onOpenPlaylist,
    required this.onRenamePlaylist,
    required this.onDeletePlaylist,
    required this.onOpenAccount,
  });

  final LibrarySnapshot? snapshot;
  final String? error;
  final bool refreshingRemotePlaylists;
  final VoidCallback onCreatePlaylist;
  final VoidCallback onImportPlaylist;
  final Future<void> Function() onRefreshRemotePlaylists;
  final ValueChanged<Playlist> onOpenPlaylist;
  final ValueChanged<Playlist> onRenamePlaylist;
  final ValueChanged<Playlist> onDeletePlaylist;
  final VoidCallback onOpenAccount;

  @override
  Widget build(BuildContext context) {
    final library = snapshot;
    final localPlaylists = library?.localPlaylists ?? const <Playlist>[];
    final account = library?.accountFor(library.selectedSource);
    final remotePlaylists =
        library?.remotePlaylistsFor(
          library.selectedSource,
          account?.accountId ?? '',
        ) ??
        const <Playlist>[];
    return Column(
      key: const ValueKey<String>('mobile-library-page'),
      children: <Widget>[
        _MobileHeader(
          title: '音乐库',
          subtitle: library == null ? '正在读取本地数据' : '最近播放已归入本地歌单',
          trailing: IconButton(
            key: const ValueKey<String>('mobile-create-playlist'),
            tooltip: '新建本地歌单',
            onPressed: library == null ? null : onCreatePlaylist,
            color: AppColors.accent,
            icon: const Icon(Icons.add_rounded),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
            children: <Widget>[
              if (error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
                  child: Text(
                    error!,
                    style: const TextStyle(
                      color: AppColors.warning,
                      fontSize: 12,
                    ),
                  ),
                ),
              _MobileGroupCard(
                title: '本地歌单',
                subtitle: '${localPlaylists.length} 个',
                action: IconButton(
                  key: const ValueKey<String>('mobile-import-playlist'),
                  tooltip: '导入远程歌单',
                  onPressed: library == null ? null : onImportPlaylist,
                  icon: const Icon(Icons.playlist_add_rounded, size: 20),
                ),
                children: localPlaylists.isEmpty
                    ? const <Widget>[
                        _MobileGroupEmpty(
                          icon: Icons.queue_music_rounded,
                          text: '还没有本地歌单',
                        ),
                      ]
                    : <Widget>[
                        for (final playlist in localPlaylists)
                          _MobilePlaylistTile(
                            playlist: playlist,
                            onOpen: () => onOpenPlaylist(playlist),
                            onRename: playlist.allowsLocalManagement
                                ? () => onRenamePlaylist(playlist)
                                : null,
                            onDelete: playlist.allowsLocalManagement
                                ? () => onDeletePlaylist(playlist)
                                : null,
                          ),
                      ],
              ),
              const SizedBox(height: 10),
              _MobileGroupCard(
                title: '远程歌单',
                subtitle: account?.canSwitch == true
                    ? '已连接 ${library?.selectedSource.label ?? ''}'
                    : '未连接 ${library?.selectedSource.label ?? ''}',
                action: IconButton(
                  key: const ValueKey<String>('mobile-refresh-remote'),
                  tooltip: '刷新远程歌单',
                  onPressed:
                      account?.canSwitch != true || refreshingRemotePlaylists
                      ? null
                      : () => unawaited(onRefreshRemotePlaylists()),
                  icon: refreshingRemotePlaylists
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 20),
                ),
                children: account?.canSwitch != true
                    ? <Widget>[
                        _MobileRemoteLogin(
                          onPressed: onOpenAccount,
                          loading: false,
                        ),
                      ]
                    : remotePlaylists.isEmpty
                    ? const <Widget>[
                        _MobileGroupEmpty(
                          icon: Icons.cloud_queue_rounded,
                          text: '点击刷新读取远程歌单',
                        ),
                      ]
                    : <Widget>[
                        for (final playlist in remotePlaylists)
                          _MobilePlaylistTile(
                            playlist: playlist,
                            remote: true,
                            onOpen: () => onOpenPlaylist(playlist),
                          ),
                      ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 单个歌单的移动端详情页。
class MobilePlaylistPage extends StatelessWidget {
  const MobilePlaylistPage({
    super.key,
    required this.playlist,
    required this.songs,
    required this.selectedSong,
    required this.playing,
    required this.loading,
    required this.error,
    required this.downloadingSongKeys,
    required this.downloadProgress,
    required this.onBack,
    required this.onSelect,
    required this.onTogglePlayback,
    required this.onDownload,
    required this.onPlayMv,
    required this.onAddToPlaylist,
    required this.onRemoveSong,
    required this.onRename,
    required this.onDelete,
  });

  final Playlist playlist;
  final List<Song> songs;
  final Song? selectedSong;
  final bool playing;
  final bool loading;
  final String? error;
  final Set<String> downloadingSongKeys;
  final Map<String, double?> downloadProgress;
  final VoidCallback onBack;
  final ValueChanged<Song> onSelect;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Song> onDownload;
  final ValueChanged<Song> onPlayMv;
  final ValueChanged<Song> onAddToPlaylist;
  final ValueChanged<Song> onRemoveSong;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey<String>('mobile-playlist-page'),
      children: <Widget>[
        SizedBox(
          height: 58,
          child: Row(
            children: <Widget>[
              IconButton(
                key: const ValueKey<String>('mobile-playlist-back'),
                tooltip: '返回音乐库',
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back_rounded),
              ),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${playlist.songs.length} 首歌曲',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              if (playlist.allowsLocalManagement)
                PopupMenuButton<String>(
                  key: const ValueKey<String>('mobile-playlist-actions'),
                  tooltip: '歌单操作',
                  onSelected: (value) {
                    if (value == 'rename') onRename();
                    if (value == 'delete') onDelete();
                  },
                  itemBuilder: (_) => const <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
                    PopupMenuItem<String>(value: 'delete', child: Text('删除')),
                  ],
                ),
            ],
          ),
        ),
        Expanded(child: _buildSongs()),
      ],
    );
  }

  Widget _buildSongs() {
    if (loading && songs.isEmpty) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (error != null) {
      return _MobileEmptyState(
        icon: Icons.cloud_off_rounded,
        title: '歌单读取失败',
        description: error!,
      );
    }
    if (songs.isEmpty) {
      return _MobileEmptyState(
        icon: playlist.isRemote
            ? Icons.cloud_queue_rounded
            : Icons.queue_music_rounded,
        title: playlist.isRecentlyPlayed ? '还没有播放记录' : '歌单还是空的',
        description: playlist.isRemote ? '刷新远程歌单后再试' : '从搜索结果点击“更多”即可加入歌单',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
      itemCount: songs.length,
      separatorBuilder: (_, _) =>
          const Divider(height: 1, indent: 66, color: AppColors.border),
      itemBuilder: (context, index) {
        final song = songs[index];
        return MobileSongRow(
          song: song,
          selected: selectedSong?.mediaKey == song.mediaKey,
          playing: playing,
          downloading: downloadingSongKeys.contains(song.mediaKey),
          downloadProgress: downloadProgress[song.mediaKey],
          onTap: () => onSelect(song),
          onTogglePlayback: onTogglePlayback,
          onDownload: () => onDownload(song),
          onPlayMv: song.hasMv ? () => onPlayMv(song) : null,
          onAddToPlaylist: () => onAddToPlaylist(song),
          onRemove: playlist.isLocal ? () => onRemoveSong(song) : null,
        );
      },
    );
  }
}

/// 我的页面：账号与基础播放信息。
class MobileAccountPage extends StatelessWidget {
  const MobileAccountPage({
    super.key,
    required this.account,
    required this.source,
    required this.avatarUrl,
    required this.openingAccountLogin,
    required this.localPlaylistCount,
    required this.remotePlaylistCount,
    required this.onOpenAccount,
    required this.onOpenNotificationSettings,
  });

  final ClientAccountSession? account;
  final MusicSource source;
  final String avatarUrl;
  final bool openingAccountLogin;
  final int localPlaylistCount;
  final int remotePlaylistCount;
  final VoidCallback onOpenAccount;
  final VoidCallback onOpenNotificationSettings;

  @override
  Widget build(BuildContext context) {
    return Column(
      key: const ValueKey<String>('mobile-account-page'),
      children: <Widget>[
        const _MobileHeader(title: '我的', subtitle: '账号与播放设置'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 20),
            children: <Widget>[
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadii.tile),
                  border: Border.all(color: AppColors.border),
                ),
                child: Row(
                  children: <Widget>[
                    _MobileAccountButton(
                      account: account,
                      avatarUrl: avatarUrl,
                      loading: openingAccountLogin,
                      onPressed: onOpenAccount,
                      large: true,
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            account?.displayName ?? '未登录',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            account?.canSwitch == true
                                ? '${source.label}账号已连接'
                                : '登录后可同步远程歌单',
                            style: const TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: openingAccountLogin ? null : onOpenAccount,
                      child: Text(account == null ? '扫码登录' : '切换'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadii.tile),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  children: <Widget>[
                    _MobileInfoRow(
                      icon: Icons.queue_music_rounded,
                      title: '本地歌单',
                      value: '$localPlaylistCount 个',
                    ),
                    const Divider(height: 1, color: AppColors.border),
                    _MobileInfoRow(
                      icon: Icons.cloud_queue_rounded,
                      title: '远程歌单',
                      value: '$remotePlaylistCount 个',
                    ),
                    const Divider(height: 1, color: AppColors.border),
                    _MobileInfoRow(
                      key: const ValueKey('mobile-notification-settings'),
                      icon: Icons.headphones_rounded,
                      title: '后台播放通知',
                      value: '系统设置',
                      onTap: onOpenNotificationSettings,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 主页面底部的单行迷你播放器。
class MobileMiniPlayer extends StatelessWidget {
  const MobileMiniPlayer({
    super.key,
    required this.song,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.loading,
    required this.error,
    required this.onOpen,
    required this.onTogglePlayback,
  });

  final Song song;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool loading;
  final String? error;
  final VoidCallback onOpen;
  final VoidCallback onTogglePlayback;

  @override
  Widget build(BuildContext context) {
    final total = duration.inMilliseconds;
    final value = total <= 0
        ? 0.0
        : (position.inMilliseconds / total).clamp(0.0, 1.0);
    return Container(
      key: const ValueKey<String>('mobile-mini-player'),
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          ClipRRect(
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(AppRadii.tile),
            ),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 2,
              backgroundColor: AppColors.border,
              color: AppColors.accent,
            ),
          ),
          SizedBox(
            height: 62,
            child: Row(
              children: <Widget>[
                Expanded(
                  child: InkWell(
                    key: const ValueKey<String>('mobile-open-now-playing'),
                    onTap: onOpen,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
                      child: Row(
                        children: <Widget>[
                          _MobileCover(
                            url: song.coverUrl,
                            size: 42,
                            fallbackText: _firstCharacter(song.name),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    MusicSourceBadge(
                                      source: song.source,
                                      compact: true,
                                    ),
                                    const SizedBox(width: 5),
                                    Expanded(
                                      child: Text(
                                        song.name,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: AppColors.textPrimary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  error ?? song.artistText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: error == null
                                        ? AppColors.textMuted
                                        : AppColors.warning,
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                IconButton.filled(
                  key: const ValueKey<String>('mobile-mini-toggle'),
                  tooltip: loading
                      ? '正在加载歌曲'
                      : isPlaying
                      ? '暂停'
                      : '播放',
                  onPressed: loading ? null : onTogglePlayback,
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.accentOn,
                    disabledBackgroundColor: AppColors.surfaceHigh,
                  ),
                  icon: loading
                      ? const SizedBox.square(
                          dimension: 17,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                        ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MobileBottomNavigation extends StatelessWidget {
  const MobileBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onSelected,
  });

  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('mobile-bottom-navigation'),
      height: 58,
      decoration: const BoxDecoration(
        color: Color(0xFF10141A),
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Row(
        children: <Widget>[
          _MobileNavItem(
            key: const ValueKey<String>('mobile-tab-search'),
            icon: Icons.search_rounded,
            label: '搜索',
            selected: selectedIndex == 0,
            onTap: () => onSelected(0),
          ),
          _MobileNavItem(
            key: const ValueKey<String>('mobile-tab-library'),
            icon: Icons.library_music_rounded,
            label: '音乐库',
            selected: selectedIndex == 1,
            onTap: () => onSelected(1),
          ),
          _MobileNavItem(
            key: const ValueKey<String>('mobile-tab-account'),
            icon: Icons.person_outline_rounded,
            label: '我的',
            selected: selectedIndex == 2,
            onTap: () => onSelected(2),
          ),
        ],
      ),
    );
  }
}

class MobileSongRow extends StatelessWidget {
  const MobileSongRow({
    super.key,
    required this.song,
    required this.selected,
    required this.playing,
    required this.downloading,
    required this.downloadProgress,
    required this.onTap,
    required this.onTogglePlayback,
    required this.onDownload,
    this.onPlayMv,
    this.onAddToPlaylist,
    this.onRemove,
  });

  final Song song;
  final bool selected;
  final bool playing;
  final bool downloading;
  final double? downloadProgress;
  final VoidCallback onTap;
  final VoidCallback onTogglePlayback;
  final VoidCallback onDownload;
  final VoidCallback? onPlayMv;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? AppColors.accentSoft.withValues(alpha: 0.54)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(AppRadii.tile),
      child: InkWell(
        key: ValueKey<String>('mobile-song-${song.mediaKey}'),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        child: SizedBox(
          height: 68,
          child: Row(
            children: <Widget>[
              const SizedBox(width: 6),
              Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  _MobileCover(
                    url: song.coverUrl,
                    size: 50,
                    fallbackText: _firstCharacter(song.name),
                  ),
                  if (selected)
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.34),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: IconButton(
                        key: const ValueKey<String>('mobile-song-toggle'),
                        tooltip: playing ? '暂停' : '播放',
                        onPressed: onTogglePlayback,
                        padding: EdgeInsets.zero,
                        icon: Icon(
                          playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          color: AppColors.accent,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            song.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: selected
                                  ? AppColors.accentStrong
                                  : AppColors.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        MusicSourceBadge(source: song.source, compact: true),
                        if (song.hasMv) ...<Widget>[
                          const SizedBox(width: 6),
                          const _MobileMvBadge(),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${song.artistText} · ${song.album}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                _formatDuration(Duration(seconds: song.durationSeconds)),
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 9,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              if (downloading)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 13),
                  child: SizedBox.square(
                    dimension: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else
                PopupMenuButton<String>(
                  key: ValueKey<String>('mobile-song-more-${song.mediaKey}'),
                  tooltip: '更多操作',
                  icon: const Icon(Icons.more_horiz_rounded, size: 20),
                  onSelected: (value) {
                    switch (value) {
                      case 'download':
                        onDownload();
                      case 'mv':
                        onPlayMv?.call();
                      case 'playlist':
                        onAddToPlaylist?.call();
                      case 'remove':
                        onRemove?.call();
                    }
                  },
                  itemBuilder: (_) => <PopupMenuEntry<String>>[
                    const PopupMenuItem<String>(
                      value: 'download',
                      child: Text('下载歌曲'),
                    ),
                    if (onPlayMv != null)
                      const PopupMenuItem<String>(
                        value: 'mv',
                        child: Text('播放 MV'),
                      ),
                    if (onAddToPlaylist != null)
                      const PopupMenuItem<String>(
                        value: 'playlist',
                        child: Text('添加到歌单'),
                      ),
                    if (onRemove != null) ...<PopupMenuEntry<String>>[
                      const PopupMenuDivider(),
                      const PopupMenuItem<String>(
                        value: 'remove',
                        child: Text('从歌单移除'),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileHeader extends StatelessWidget {
  const _MobileHeader({
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 58,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: <Widget>[
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

class _MobileAccountButton extends StatelessWidget {
  const _MobileAccountButton({
    required this.account,
    required this.avatarUrl,
    required this.loading,
    required this.onPressed,
    this.large = false,
  });

  final ClientAccountSession? account;
  final String avatarUrl;
  final bool loading;
  final VoidCallback onPressed;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final size = large ? 52.0 : 34.0;
    return InkWell(
      key: const ValueKey<String>('mobile-account-button'),
      onTap: loading ? null : onPressed,
      borderRadius: BorderRadius.circular(size / 2),
      child: Container(
        width: size,
        height: size,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: AppColors.surfaceHigh,
          border: Border.all(color: AppColors.border),
        ),
        alignment: Alignment.center,
        child: loading
            ? SizedBox.square(
                dimension: large ? 20 : 15,
                child: const CircularProgressIndicator(strokeWidth: 2),
              )
            : avatarUrl.trim().isEmpty
            ? Text(
                account?.avatarFallbackText ?? 'Q',
                style: TextStyle(
                  color: AppColors.accentStrong,
                  fontSize: large ? 18 : 12,
                  fontWeight: FontWeight.w700,
                ),
              )
            : Image.network(
                avatarUrl,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Text(
                  account?.avatarFallbackText ?? 'Q',
                  style: TextStyle(
                    color: AppColors.accentStrong,
                    fontSize: large ? 18 : 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
      ),
    );
  }
}

class _MobileGroupCard extends StatelessWidget {
  const _MobileGroupCard({
    required this.title,
    required this.subtitle,
    required this.action,
    required this.children,
  });

  final String title;
  final String subtitle;
  final Widget action;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        border: Border.all(color: AppColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          SizedBox(
            height: 50,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 4, 0),
              child: Row(
                children: <Widget>[
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 10,
                    ),
                  ),
                  action,
                ],
              ),
            ),
          ),
          for (final child in children) child,
        ],
      ),
    );
  }
}

class _MobilePlaylistTile extends StatelessWidget {
  const _MobilePlaylistTile({
    required this.playlist,
    required this.onOpen,
    this.remote = false,
    this.onRename,
    this.onDelete,
  });

  final Playlist playlist;
  final VoidCallback onOpen;
  final bool remote;
  final VoidCallback? onRename;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        key: ValueKey<String>('mobile-playlist-${playlist.id}'),
        onTap: onOpen,
        child: Container(
          constraints: const BoxConstraints(minHeight: 58),
          padding: const EdgeInsets.fromLTRB(12, 7, 4, 7),
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: AppColors.border)),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: remote ? AppColors.accentSoft : AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(9),
                ),
                alignment: Alignment.center,
                child: Icon(
                  remote
                      ? Icons.cloud_queue_rounded
                      : playlist.isRecentlyPlayed
                      ? Icons.history_rounded
                      : Icons.queue_music_rounded,
                  color: remote || playlist.isRecentlyPlayed
                      ? AppColors.accentStrong
                      : AppColors.textSecondary,
                  size: 20,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      playlist.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      playlist.isRecentlyPlayed
                          ? '本地歌单 · ${playlist.songs.length} 首'
                          : '${remote ? '远程歌单' : '本地歌单'} · ${playlist.songs.length} 首',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
              if (onRename != null || onDelete != null)
                PopupMenuButton<String>(
                  tooltip: '歌单操作',
                  onSelected: (value) {
                    if (value == 'rename') onRename?.call();
                    if (value == 'delete') onDelete?.call();
                  },
                  itemBuilder: (_) => const <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(value: 'rename', child: Text('重命名')),
                    PopupMenuItem<String>(value: 'delete', child: Text('删除')),
                  ],
                )
              else
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14),
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 18,
                    color: AppColors.textMuted,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileRemoteLogin extends StatelessWidget {
  const _MobileRemoteLogin({required this.onPressed, required this.loading});

  final VoidCallback onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        children: <Widget>[
          const Expanded(
            child: Text(
              '登录后可读取收藏歌单',
              style: TextStyle(color: AppColors.textMuted, fontSize: 10),
            ),
          ),
          TextButton(
            onPressed: loading ? null : onPressed,
            child: Text(loading ? '登录中' : '去登录'),
          ),
        ],
      ),
    );
  }
}

class _MobileInfoRow extends StatelessWidget {
  const _MobileInfoRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final row = Row(
      children: <Widget>[
        Icon(icon, size: 19, color: AppColors.accentStrong),
        const SizedBox(width: 11),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ),
        Text(
          value,
          style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
        ),
        if (onTap != null) ...<Widget>[
          const SizedBox(width: 5),
          const Icon(
            Icons.chevron_right_rounded,
            size: 16,
            color: AppColors.textMuted,
          ),
        ],
      ],
    );
    if (onTap == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: row,
      );
    }
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: row,
      ),
    );
  }
}

class _MobileNavItem extends StatelessWidget {
  const _MobileNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: 56,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(
                icon,
                size: 20,
                color: selected ? AppColors.accent : AppColors.textMuted,
              ),
              const SizedBox(height: 2),
              Text(
                label,
                style: TextStyle(
                  color: selected ? AppColors.accent : AppColors.textMuted,
                  fontSize: 9,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileEmptyState extends StatelessWidget {
  const _MobileEmptyState({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final minimumHeight = (constraints.maxHeight - 48).clamp(
          0.0,
          double.infinity,
        );
        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minimumHeight),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(17),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Icon(icon, color: AppColors.textMuted, size: 25),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    description,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MobileGroupEmpty extends StatelessWidget {
  const _MobileGroupEmpty({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 15, color: AppColors.textDisabled),
          const SizedBox(width: 6),
          Text(
            text,
            style: const TextStyle(color: AppColors.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _MobileCover extends StatelessWidget {
  const _MobileCover({
    required this.url,
    required this.size,
    required this.fallbackText,
  });

  final String url;
  final double size;
  final String fallbackText;

  @override
  Widget build(BuildContext context) {
    final fallback = Text(
      fallbackText,
      style: TextStyle(
        color: AppColors.textSecondary,
        fontSize: size * 0.32,
        fontWeight: FontWeight.w700,
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Container(
        width: size,
        height: size,
        color: AppColors.surfaceHigh,
        alignment: Alignment.center,
        child: url.trim().isEmpty
            ? fallback
            : Image.network(
                url,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _MobileMvBadge extends StatelessWidget {
  const _MobileMvBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        color: const Color(0xFF382A20),
        borderRadius: BorderRadius.circular(4),
      ),
      child: const Text(
        'MV',
        style: TextStyle(
          color: AppColors.warning,
          fontSize: 7,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _firstCharacter(String value) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? '♪' : String.fromCharCode(trimmed.runes.first);
}

String _formatDuration(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 359999);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}
