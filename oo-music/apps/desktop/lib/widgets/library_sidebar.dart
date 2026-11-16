import 'dart:async';

import 'package:flutter/material.dart';

import '../models/playlist.dart';
import '../theme/app_theme.dart';

/// 主界面左侧的搜索、本地歌单与远程歌单导航。
class LibrarySidebar extends StatefulWidget {
  /// 创建歌单导航。
  const LibrarySidebar({
    super.key,
    required this.snapshot,
    required this.searchSelected,
    required this.selectedPlaylistId,
    required this.onSelectSearch,
    required this.onSelectPlaylist,
    required this.onCreatePlaylist,
    required this.onImportPlaylist,
    required this.onRefreshRemotePlaylists,
    required this.onRenamePlaylist,
    required this.onDeletePlaylist,
    this.refreshingRemotePlaylists = false,
    this.error,
  });

  /// 当前本地音乐库快照；尚未加载完成时为空。
  final LibrarySnapshot? snapshot;

  /// 本地音乐库加载错误。
  final String? error;

  /// 当前是否显示搜索结果。
  final bool searchSelected;

  /// 当前歌单 ID。
  final String? selectedPlaylistId;

  /// 切换到搜索页。
  final VoidCallback onSelectSearch;

  /// 切换到指定歌单。
  final ValueChanged<String> onSelectPlaylist;

  /// 新建本地歌单。
  final VoidCallback onCreatePlaylist;

  /// 打开远程歌单导入卡片。
  final VoidCallback onImportPlaylist;

  /// 刷新当前授权账号的远程歌单。
  final Future<void> Function() onRefreshRemotePlaylists;

  /// 重命名本地用户歌单。
  final ValueChanged<Playlist> onRenamePlaylist;

  /// 删除本地用户歌单。
  final ValueChanged<Playlist> onDeletePlaylist;

  /// 远程歌单是否正在刷新。
  final bool refreshingRemotePlaylists;

  @override
  State<LibrarySidebar> createState() => _LibrarySidebarState();
}

class _LibrarySidebarState extends State<LibrarySidebar> {
  final ScrollController _localScrollController = ScrollController();
  final ScrollController _remoteScrollController = ScrollController();
  bool _localExpanded = true;
  bool _remoteExpanded = false;

  @override
  void dispose() {
    _localScrollController.dispose();
    _remoteScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final library = widget.snapshot;
    final localPlaylists = library?.localPlaylists ?? const <Playlist>[];
    final account = library?.accountFor(library.selectedSource);
    final remotePlaylists =
        library?.remotePlaylistsFor(
          library.selectedSource,
          account?.accountId ?? '',
        ) ??
        const <Playlist>[];

    return SizedBox(
      width: 220,
      child: DecoratedBox(
        decoration: appPanelDecoration(color: AppColors.surface),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 17, 16, 10),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.library_music_rounded,
                    color: AppColors.accentStrong,
                    size: 17,
                  ),
                  SizedBox(width: AppSpacing.sm),
                  Text(
                    '音乐库',
                    style: TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            _SidebarTile(
              icon: Icons.search_rounded,
              label: '搜索音乐',
              selected: widget.searchSelected,
              onTap: widget.onSelectSearch,
            ),
            const SizedBox(height: 8),
            _sectionHeader(
              label: '本地歌单',
              expanded: _localExpanded,
              onToggle: () => setState(() => _localExpanded = !_localExpanded),
              actions: <Widget>[
                _headerIconButton(
                  key: const ValueKey<String>('create-playlist'),
                  tooltip: '新建歌单',
                  onPressed: library == null ? null : widget.onCreatePlaylist,
                  icon: Icons.add_rounded,
                ),
                _headerIconButton(
                  key: const ValueKey<String>('import-playlist'),
                  tooltip: '导入远程歌单',
                  onPressed: library == null ? null : widget.onImportPlaylist,
                  icon: Icons.playlist_add_rounded,
                ),
              ],
            ),
            if (_localExpanded)
              Expanded(
                child: _buildLocalPlaylistList(
                  localPlaylists,
                  libraryLoaded: library != null,
                ),
              ),
            _sectionHeader(
              label: '远程歌单',
              expanded: _remoteExpanded,
              onToggle: () =>
                  setState(() => _remoteExpanded = !_remoteExpanded),
              actions: <Widget>[
                _headerIconButton(
                  key: const ValueKey<String>('refresh-remote-playlists'),
                  tooltip: '刷新远程歌单',
                  onPressed: library == null || widget.refreshingRemotePlaylists
                      ? null
                      : () => unawaited(widget.onRefreshRemotePlaylists()),
                  icon: widget.refreshingRemotePlaylists
                      ? Icons.sync_rounded
                      : Icons.refresh_rounded,
                  spinning: widget.refreshingRemotePlaylists,
                ),
              ],
            ),
            if (_remoteExpanded)
              Expanded(
                child: _buildRemotePlaylistList(
                  remotePlaylists,
                  loggedIn: account?.canSwitch == true,
                ),
              ),
            if (!_localExpanded && !_remoteExpanded) const Spacer(),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _sectionHeader({
    required String label,
    required bool expanded,
    required VoidCallback onToggle,
    required List<Widget> actions,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
      child: Row(
        children: <Widget>[
          Expanded(
            child: InkWell(
              key: ValueKey<String>('toggle-$label'),
              onTap: onToggle,
              borderRadius: BorderRadius.circular(8),
              hoverColor: AppColors.surfaceHover,
              focusColor: AppColors.accent.withValues(alpha: 0.12),
              mouseCursor: SystemMouseCursors.click,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                child: Row(
                  children: <Widget>[
                    AnimatedRotation(
                      turns: expanded ? 0 : -0.25,
                      duration: AppDurations.fast,
                      child: const Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 17,
                        color: AppColors.textMuted,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Text(
                      label,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ...actions,
        ],
      ),
    );
  }

  Widget _headerIconButton({
    required Key key,
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
    bool spinning = false,
  }) {
    final child = Icon(icon, size: 18);
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 30, height: 30),
      style: IconButton.styleFrom(
        foregroundColor: AppColors.textMuted,
        disabledForegroundColor: AppColors.textDisabled,
        backgroundColor: Colors.transparent,
        hoverColor: AppColors.accentSoft,
        focusColor: AppColors.accent.withValues(alpha: 0.12),
        highlightColor: AppColors.accent.withValues(alpha: 0.1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.small),
        ),
      ),
      icon: spinning
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 1.8,
                color: AppColors.accent,
              ),
            )
          : child,
    );
  }

  Widget _buildLocalPlaylistList(
    List<Playlist> playlists, {
    required bool libraryLoaded,
  }) {
    if (!libraryLoaded && widget.error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Center(
          child: Text(
            widget.error!,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.warning,
              fontSize: 11,
              height: 1.5,
            ),
          ),
        ),
      );
    }
    if (!libraryLoaded) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.accent,
            ),
          ),
        ),
      );
    }
    if (playlists.isEmpty) {
      return const _SidebarEmptyText('还没有本地歌单');
    }
    return Scrollbar(
      controller: _localScrollController,
      thumbVisibility: true,
      child: ListView.builder(
        key: const ValueKey<String>('local-playlist-list'),
        controller: _localScrollController,
        primary: false,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: playlists.length,
        itemBuilder: (context, index) {
          final playlist = playlists[index];
          return _SidebarTile(
            icon: playlist.isRecentlyPlayed
                ? Icons.history_rounded
                : Icons.queue_music_rounded,
            label: playlist.name,
            selected:
                !widget.searchSelected &&
                widget.selectedPlaylistId == playlist.id,
            onTap: () => widget.onSelectPlaylist(playlist.id),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                _PlaylistCount(count: playlist.songs.length),
                if (playlist.allowsLocalManagement)
                  PopupMenuButton<_PlaylistAction>(
                    tooltip: '歌单操作',
                    padding: EdgeInsets.zero,
                    iconSize: 17,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    icon: const Icon(
                      Icons.more_horiz_rounded,
                      size: 17,
                      color: AppColors.textMuted,
                    ),
                    onSelected: (action) {
                      switch (action) {
                        case _PlaylistAction.rename:
                          widget.onRenamePlaylist(playlist);
                        case _PlaylistAction.delete:
                          widget.onDeletePlaylist(playlist);
                      }
                    },
                    itemBuilder: (context) =>
                        const <PopupMenuEntry<_PlaylistAction>>[
                          PopupMenuItem<_PlaylistAction>(
                            value: _PlaylistAction.rename,
                            child: Text('重命名'),
                          ),
                          PopupMenuItem<_PlaylistAction>(
                            value: _PlaylistAction.delete,
                            child: Text('删除'),
                          ),
                        ],
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildRemotePlaylistList(
    List<Playlist> playlists, {
    required bool loggedIn,
  }) {
    if (!loggedIn) {
      return const _SidebarEmptyText('扫码登录后可刷新远程歌单');
    }
    if (playlists.isEmpty) {
      return _SidebarEmptyText(
        widget.refreshingRemotePlaylists ? '正在读取远程歌单…' : '点击刷新获取远程歌单',
      );
    }
    return Scrollbar(
      controller: _remoteScrollController,
      thumbVisibility: true,
      child: ListView.builder(
        key: const ValueKey<String>('remote-playlist-list'),
        controller: _remoteScrollController,
        primary: false,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: playlists.length,
        itemBuilder: (context, index) {
          final playlist = playlists[index];
          return _SidebarTile(
            icon: Icons.cloud_queue_rounded,
            label: playlist.name,
            selected:
                !widget.searchSelected &&
                widget.selectedPlaylistId == playlist.id,
            onTap: () => widget.onSelectPlaylist(playlist.id),
            trailing: _PlaylistCount(count: playlist.songs.length),
          );
        },
      ),
    );
  }
}

enum _PlaylistAction { rename, delete }

class _SidebarEmptyText extends StatelessWidget {
  const _SidebarEmptyText(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(
            Icons.music_off_rounded,
            size: 14,
            color: AppColors.textDisabled,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textDisabled,
                fontSize: 11,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaylistCount extends StatelessWidget {
  const _PlaylistCount({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 24),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        '$count',
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: AppColors.textMuted,
          fontSize: 9.5,
          fontWeight: FontWeight.w600,
          fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? AppColors.accentSoft : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.control),
          side: BorderSide(
            color: selected ? AppColors.accentBorder : Colors.transparent,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          hoverColor: AppColors.surfaceHover,
          child: Padding(
            padding: const EdgeInsets.only(
              left: 10,
              right: 5,
              top: 8,
              bottom: 8,
            ),
            child: Row(
              children: <Widget>[
                AnimatedContainer(
                  duration: AppDurations.fast,
                  width: 3,
                  height: 17,
                  margin: const EdgeInsets.only(right: 9),
                  decoration: BoxDecoration(
                    color: selected ? AppColors.accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Icon(
                  icon,
                  size: 17,
                  color: selected
                      ? AppColors.accentStrong
                      : AppColors.textMuted,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
