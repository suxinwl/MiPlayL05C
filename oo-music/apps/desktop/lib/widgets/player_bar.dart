import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/playback.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../platform/app_platform.dart';
import '../theme/app_theme.dart';
import 'music_source_badge.dart';

/// 底部播放器，包含歌曲信息、播放控制、进度、音量和音质切换。
class PlayerBar extends StatefulWidget {
  /// 创建底部播放器。
  const PlayerBar({
    super.key,
    required this.song,
    required this.playback,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.loading,
    required this.switchingQuality,
    required this.error,
    required this.playMode,
    required this.volume,
    required this.availableQualities,
    required this.canSkip,
    this.downloading = false,
    this.desktopLyricsSupported = true,
    this.desktopLyricsVisible = false,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
    required this.onPlayModeChanged,
    required this.onVolumeChanged,
    required this.onQualityChanged,
    this.onDownload,
    this.onToggleDesktopLyrics,
    this.nowPlayingExpanded = false,
    this.onToggleNowPlaying,
  });

  /// 当前歌曲。
  final Song? song;

  /// 当前播放结果。
  final PlaybackResult? playback;

  /// 当前播放位置。
  final Duration position;

  /// 音频总时长。
  final Duration duration;

  /// 是否正在播放。
  final bool isPlaying;

  /// 是否正在解析播放地址或加载播放器。
  final bool loading;

  /// 是否正在切换音质。
  final bool switchingQuality;

  /// 播放器错误。
  final String? error;

  /// 当前播放模式。
  final PlayMode playMode;

  /// 当前音量，范围 0 到 1。
  final double volume;

  /// 当前歌曲支持的音质标识。
  final List<String> availableQualities;

  /// 当前队列是否允许上一首、下一首。
  final bool canSkip;

  /// 当前歌曲是否正在下载。
  final bool downloading;

  /// 当前平台是否提供桌面歌词窗口。
  final bool desktopLyricsSupported;

  /// 桌面歌词窗口是否正在展示。
  final bool desktopLyricsVisible;

  /// 播放/暂停回调。
  final VoidCallback onTogglePlayback;

  /// 拖动进度条后的跳转回调。
  final ValueChanged<Duration> onSeek;

  /// 上一首回调。
  final VoidCallback onPrevious;

  /// 下一首回调。
  final VoidCallback onNext;

  /// 播放模式切换回调。
  final ValueChanged<PlayMode> onPlayModeChanged;

  /// 音量变化回调。
  final ValueChanged<double> onVolumeChanged;

  /// 音质切换回调。
  final ValueChanged<String> onQualityChanged;

  /// 下载当前歌曲回调。
  final VoidCallback? onDownload;

  /// 显示或隐藏桌面歌词回调。
  final VoidCallback? onToggleDesktopLyrics;

  /// 完整播放页是否正在展示。
  final bool nowPlayingExpanded;

  /// 展开或收起完整播放页。
  final VoidCallback? onToggleNowPlaying;

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  double? _dragMilliseconds;

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    final playback = widget.playback;
    final durationMilliseconds = widget.duration.inMilliseconds;
    final positionMilliseconds = widget.position.inMilliseconds
        .clamp(0, durationMilliseconds)
        .toDouble();
    final sliderValue =
        _dragMilliseconds ??
        (durationMilliseconds == 0 ? 0.0 : positionMilliseconds);
    final canPlay = song != null && playback?.available == true;
    final canSeek =
        canPlay &&
        durationMilliseconds > 0 &&
        !widget.loading &&
        !widget.switchingQuality;
    final canSkip = widget.canSkip && song != null;

    return LayoutBuilder(
      builder: (context, constraints) {
        if (AppPlatform.isMobile) {
          return _buildMobile(
            context,
            canPlay: canPlay,
            canSeek: canSeek,
            canSkip: canSkip,
            sliderValue: sliderValue,
            durationMilliseconds: durationMilliseconds,
          );
        }
        final compact = constraints.maxWidth < 760;
        final wide = constraints.maxWidth >= 1080;
        return Container(
          height: compact ? 118 : 128,
          padding: EdgeInsets.fromLTRB(
            compact ? 14 : 22,
            8,
            compact ? 14 : 22,
            8,
          ),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[AppColors.surfaceRaised, AppColors.surface],
            ),
            border: Border(top: BorderSide(color: AppColors.border)),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: AppColors.shadowSoft,
                blurRadius: 18,
                offset: Offset(0, -5),
              ),
            ],
          ),
          child: compact
              ? _buildCompact(context, song, playback, canPlay, canSkip)
              : _buildDesktop(
                  context,
                  song,
                  playback,
                  sliderValue,
                  durationMilliseconds,
                  canSeek,
                  canPlay,
                  canSkip,
                  wide: wide,
                ),
        );
      },
    );
  }

  Widget _buildMobile(
    BuildContext context, {
    required bool canPlay,
    required bool canSeek,
    required bool canSkip,
    required double sliderValue,
    required int durationMilliseconds,
  }) {
    final song = widget.song;
    final landscape = MediaQuery.sizeOf(context).height < 500;
    return Container(
      key: const ValueKey<String>('mobile-player-bar'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      decoration: const BoxDecoration(
        color: AppColors.surfaceRaised,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _Artwork(
                song: song,
                size: 44,
                radius: 10,
                expanded: widget.nowPlayingExpanded,
                onTap: widget.onToggleNowPlaying,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  onTap: widget.onToggleNowPlaying,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: <Widget>[
                            if (song != null) ...<Widget>[
                              MusicSourceBadge(
                                source: song.source,
                                compact: true,
                              ),
                              const SizedBox(width: 5),
                            ],
                            Expanded(
                              child: Text(
                                song?.name ?? '未选择歌曲',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.error ?? song?.artistText ?? '搜索并选择一首歌曲',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: widget.error == null
                                ? AppColors.textMuted
                                : AppColors.warning,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (landscape)
                IconButton(
                  key: const ValueKey<String>('player-previous'),
                  tooltip: '上一首',
                  onPressed: canSkip ? widget.onPrevious : null,
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
              IconButton.filled(
                key: const ValueKey<String>('player-toggle'),
                tooltip: widget.loading
                    ? '正在加载歌曲'
                    : widget.isPlaying
                    ? '暂停'
                    : '播放',
                onPressed:
                    canPlay && !widget.loading && !widget.switchingQuality
                    ? widget.onTogglePlayback
                    : null,
                style: IconButton.styleFrom(
                  minimumSize: const Size(44, 44),
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.accentOn,
                ),
                icon: widget.loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        widget.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                      ),
              ),
              if (landscape)
                IconButton(
                  key: const ValueKey<String>('player-next'),
                  tooltip: '下一首',
                  onPressed: canSkip ? widget.onNext : null,
                  icon: const Icon(Icons.skip_next_rounded),
                ),
              PopupMenuButton<String>(
                key: const ValueKey<String>('player-more'),
                tooltip: '播放设置',
                enabled: song != null,
                icon: const Icon(Icons.more_vert_rounded),
                onSelected: (value) {
                  if (value == 'download') {
                    widget.onDownload?.call();
                  } else if (value == 'lyrics') {
                    widget.onToggleNowPlaying?.call();
                  } else {
                    widget.onQualityChanged(value);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'lyrics', child: Text('打开歌曲和歌词')),
                  PopupMenuItem(
                    value: 'download',
                    enabled:
                        canPlay &&
                        !widget.downloading &&
                        widget.onDownload != null,
                    child: Text(widget.downloading ? '正在下载' : '下载当前歌曲'),
                  ),
                  const PopupMenuDivider(),
                  for (final quality in _orderedQualities(
                    widget.availableQualities,
                  ))
                    CheckedPopupMenuItem(
                      value: quality,
                      checked: quality == widget.playback?.quality,
                      enabled: !widget.loading && !widget.switchingQuality,
                      child: Text(formatQualityLabel(quality)),
                    ),
                ],
              ),
            ],
          ),
          _ProgressRow(
            sliderValue: sliderValue,
            durationMilliseconds: durationMilliseconds,
            duration: widget.duration,
            canSeek: canSeek,
            compact: true,
            onChanged: (value) => setState(() => _dragMilliseconds = value),
            onChangeEnd: (value) {
              setState(() => _dragMilliseconds = null);
              widget.onSeek(Duration(milliseconds: value.round()));
            },
          ),
          if (!landscape)
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                PopupMenuButton<PlayMode>(
                  key: const ValueKey<String>('player-play-mode'),
                  tooltip: '播放模式：${widget.playMode.label}',
                  enabled: song != null,
                  onSelected: widget.onPlayModeChanged,
                  icon: Icon(widget.playMode.icon, size: 22),
                  itemBuilder: (_) => [
                    for (final mode in PlayMode.values)
                      CheckedPopupMenuItem(
                        value: mode,
                        checked: mode == widget.playMode,
                        child: Text(mode.label),
                      ),
                  ],
                ),
                IconButton(
                  key: const ValueKey<String>('player-previous'),
                  tooltip: '上一首',
                  onPressed: canSkip ? widget.onPrevious : null,
                  icon: const Icon(Icons.skip_previous_rounded),
                ),
                IconButton(
                  key: const ValueKey<String>('player-next'),
                  tooltip: '下一首',
                  onPressed: canSkip ? widget.onNext : null,
                  icon: const Icon(Icons.skip_next_rounded),
                ),
                _VolumeButton(
                  volume: widget.volume,
                  onChanged: widget.onVolumeChanged,
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildDesktop(
    BuildContext context,
    Song? song,
    PlaybackResult? playback,
    double sliderValue,
    int durationMilliseconds,
    bool canSeek,
    bool canPlay,
    bool canSkip, {
    required bool wide,
  }) {
    return Row(
      children: <Widget>[
        SizedBox(
          width: wide ? 286 : 224,
          child: _NowPlayingInfo(
            song: song,
            subtitle: _subtitle(playback),
            hasError: widget.error != null,
            nowPlayingExpanded: widget.nowPlayingExpanded,
            onToggleNowPlaying: widget.onToggleNowPlaying,
          ),
        ),
        SizedBox(width: wide ? 18 : 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              _TransportControls(
                song: song,
                isPlaying: widget.isPlaying,
                loading: widget.loading,
                canPlay: canPlay,
                canSkip: canSkip,
                playMode: widget.playMode,
                volume: widget.volume,
                onTogglePlayback: widget.onTogglePlayback,
                onPrevious: widget.onPrevious,
                onNext: widget.onNext,
                onPlayModeChanged: widget.onPlayModeChanged,
                onVolumeChanged: widget.onVolumeChanged,
              ),
              const SizedBox(height: 2),
              _ProgressRow(
                sliderValue: sliderValue,
                durationMilliseconds: durationMilliseconds,
                duration: widget.duration,
                canSeek: canSeek,
                onChanged: (value) => setState(() => _dragMilliseconds = value),
                onChangeEnd: (value) {
                  setState(() => _dragMilliseconds = null);
                  widget.onSeek(Duration(milliseconds: value.round()));
                },
              ),
            ],
          ),
        ),
        SizedBox(width: wide ? 18 : 10),
        SizedBox(
          width: wide ? 250 : 208,
          child: _PlayerTools(
            playback: playback,
            song: song,
            canPlay: canPlay,
            downloading: widget.downloading,
            switchingQuality: widget.switchingQuality,
            availableQualities: widget.availableQualities,
            loading: widget.loading,
            desktopLyricsSupported: widget.desktopLyricsSupported,
            desktopLyricsVisible: widget.desktopLyricsVisible,
            desktopLyricsTooltip: _desktopLyricsTooltip(),
            onDownload: widget.onDownload,
            onToggleDesktopLyrics: widget.onToggleDesktopLyrics,
            onQualityChanged: widget.onQualityChanged,
          ),
        ),
      ],
    );
  }

  Widget _buildCompact(
    BuildContext context,
    Song? song,
    PlaybackResult? playback,
    bool canPlay,
    bool canSkip,
  ) {
    final theme = Theme.of(context);
    final durationMilliseconds = widget.duration.inMilliseconds;
    final sliderValue =
        _dragMilliseconds ??
        widget.position.inMilliseconds
            .clamp(0, durationMilliseconds)
            .toDouble();
    return Column(
      children: <Widget>[
        Expanded(
          child: Row(
            children: <Widget>[
              _Artwork(
                song: song,
                size: 48,
                radius: 12,
                expanded: widget.nowPlayingExpanded,
                onTap: widget.onToggleNowPlaying,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        if (song != null) ...<Widget>[
                          MusicSourceBadge(source: song.source, compact: true),
                          const SizedBox(width: 5),
                        ],
                        Expanded(
                          child: Text(
                            song?.name ?? '未选择歌曲',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      widget.error ?? song?.artistText ?? '搜索并选择一首歌曲',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: widget.error != null
                            ? AppColors.warning
                            : AppColors.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<PlayMode>(
                key: const ValueKey<String>('player-play-mode'),
                tooltip: '播放模式：${widget.playMode.label}',
                enabled: song != null,
                onSelected: widget.onPlayModeChanged,
                icon: Icon(
                  widget.playMode.icon,
                  size: 20,
                  color: song == null
                      ? AppColors.textDisabled
                      : AppColors.textMuted,
                ),
                itemBuilder: (context) => <PopupMenuEntry<PlayMode>>[
                  for (final mode in PlayMode.values)
                    CheckedPopupMenuItem<PlayMode>(
                      value: mode,
                      checked: mode == widget.playMode,
                      child: Text(mode.label),
                    ),
                ],
              ),
              IconButton(
                key: const ValueKey<String>('player-previous'),
                tooltip: '上一首',
                onPressed: canSkip ? widget.onPrevious : null,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_previous_rounded, size: 24),
              ),
              IconButton.filled(
                key: const ValueKey<String>('player-toggle'),
                tooltip: widget.isPlaying ? '暂停' : '播放',
                onPressed: canPlay && !widget.loading
                    ? widget.onTogglePlayback
                    : null,
                style: IconButton.styleFrom(
                  minimumSize: const Size(42, 42),
                  backgroundColor: AppColors.accent,
                  foregroundColor: AppColors.accentOn,
                  disabledBackgroundColor: AppColors.surfaceHigh,
                  disabledForegroundColor: AppColors.textDisabled,
                  shadowColor: AppColors.accent.withValues(alpha: 0.25),
                  elevation: canPlay ? 3 : 0,
                ),
                icon: widget.loading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        widget.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 24,
                      ),
              ),
              IconButton(
                key: const ValueKey<String>('player-next'),
                tooltip: '下一首',
                onPressed: canSkip ? widget.onNext : null,
                constraints: const BoxConstraints.tightFor(
                  width: 36,
                  height: 36,
                ),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.skip_next_rounded, size: 24),
              ),
              _VolumeButton(
                volume: widget.volume,
                onChanged: widget.onVolumeChanged,
              ),
              PopupMenuButton<Object>(
                key: const ValueKey<String>('player-more'),
                tooltip: '播放设置',
                enabled: song != null,
                onSelected: (value) {
                  if (value is String) {
                    widget.onQualityChanged(value);
                    return;
                  }
                  if (value == _CompactPlayerAction.desktopLyrics) {
                    widget.onToggleDesktopLyrics?.call();
                  } else if (value == _CompactPlayerAction.download) {
                    widget.onDownload?.call();
                  }
                },
                icon: const Icon(Icons.more_horiz_rounded, size: 21),
                itemBuilder: (context) => <PopupMenuEntry<Object>>[
                  if (widget.desktopLyricsSupported)
                    PopupMenuItem<Object>(
                      value: _CompactPlayerAction.desktopLyrics,
                      child: _CompactToolLabel(
                        icon: widget.desktopLyricsVisible
                            ? Icons.subtitles_rounded
                            : Icons.subtitles_outlined,
                        label: widget.desktopLyricsVisible
                            ? '关闭桌面歌词'
                            : '显示桌面歌词',
                        selected: widget.desktopLyricsVisible,
                      ),
                    ),
                  PopupMenuItem<Object>(
                    value: _CompactPlayerAction.download,
                    enabled: canPlay && !widget.downloading,
                    child: _CompactToolLabel(
                      icon: widget.downloading
                          ? Icons.downloading_rounded
                          : Icons.download_rounded,
                      label: widget.downloading ? '正在下载' : '下载当前歌曲',
                    ),
                  ),
                  if (_orderedQualities(widget.availableQualities)
                      .isNotEmpty) ...[
                    const PopupMenuDivider(),
                    for (final quality in _orderedQualities(
                      widget.availableQualities,
                    ))
                      CheckedPopupMenuItem<Object>(
                        value: quality,
                        checked: quality == playback?.quality,
                        enabled: !widget.switchingQuality,
                        child: Text(formatQualityLabel(quality)),
                      ),
                  ],
                ],
              ),
            ],
          ),
        ),
        _ProgressRow(
          sliderValue: sliderValue,
          durationMilliseconds: durationMilliseconds,
          duration: widget.duration,
          canSeek: canPlay && durationMilliseconds > 0,
          compact: true,
          onChanged: (value) => setState(() => _dragMilliseconds = value),
          onChangeEnd: (value) {
            setState(() => _dragMilliseconds = null);
            widget.onSeek(Duration(milliseconds: value.round()));
          },
        ),
      ],
    );
  }

  String? _subtitle(PlaybackResult? playback) {
    if (widget.error != null) {
      return widget.error;
    }
    if (playback == null) {
      return null;
    }
    if (!playback.available) {
      return playback.reasonLabel;
    }
    return '正在使用 ${playback.qualityLabel}';
  }

  String _desktopLyricsTooltip() {
    final action = widget.desktopLyricsVisible ? '关闭桌面歌词' : '显示桌面歌词';
    final shortcut = AppPlatform.desktopLyricsShortcutLabel;
    return shortcut.isEmpty ? action : '$action ($shortcut)';
  }
}

enum _CompactPlayerAction { desktopLyrics, download }

class _CompactToolLabel extends StatelessWidget {
  const _CompactToolLabel({
    required this.icon,
    required this.label,
    this.selected = false,
  });

  final IconData icon;
  final String label;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(
          icon,
          size: 18,
          color: selected ? AppColors.accent : AppColors.textMuted,
        ),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }
}

class _NowPlayingInfo extends StatelessWidget {
  const _NowPlayingInfo({
    required this.song,
    required this.subtitle,
    required this.hasError,
    required this.nowPlayingExpanded,
    this.onToggleNowPlaying,
  });

  final Song? song;
  final String? subtitle;
  final bool hasError;
  final bool nowPlayingExpanded;
  final VoidCallback? onToggleNowPlaying;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: <Widget>[
        _Artwork(
          song: song,
          expanded: nowPlayingExpanded,
          onTap: onToggleNowPlaying,
        ),
        const SizedBox(width: 13),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  if (song != null) ...<Widget>[
                    MusicSourceBadge(source: song!.source, compact: true),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      song?.name ?? '未选择歌曲',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                song?.artistText ?? '搜索并选择一首歌曲',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                ),
              ),
              if (subtitle != null) ...<Widget>[
                const SizedBox(height: 6),
                Row(
                  children: <Widget>[
                    Container(
                      width: 5,
                      height: 5,
                      decoration: BoxDecoration(
                        color: hasError ? AppColors.warning : AppColors.accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        subtitle!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: hasError
                              ? AppColors.warning
                              : AppColors.accentStrong,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _TransportControls extends StatelessWidget {
  const _TransportControls({
    required this.song,
    required this.isPlaying,
    required this.loading,
    required this.canPlay,
    required this.canSkip,
    required this.playMode,
    required this.volume,
    required this.onTogglePlayback,
    required this.onPrevious,
    required this.onNext,
    required this.onPlayModeChanged,
    required this.onVolumeChanged,
  });

  final Song? song;
  final bool isPlaying;
  final bool loading;
  final bool canPlay;
  final bool canSkip;
  final PlayMode playMode;
  final double volume;
  final VoidCallback onTogglePlayback;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<PlayMode> onPlayModeChanged;
  final ValueChanged<double> onVolumeChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: <Widget>[
        PopupMenuButton<PlayMode>(
          key: const ValueKey<String>('player-play-mode'),
          tooltip: '播放模式：${playMode.label}',
          enabled: song != null,
          onSelected: onPlayModeChanged,
          icon: Icon(
            playMode.icon,
            size: 20,
            color: song == null
                ? AppColors.textDisabled
                : AppColors.textSecondary,
          ),
          itemBuilder: (context) => <PopupMenuEntry<PlayMode>>[
            for (final mode in PlayMode.values)
              CheckedPopupMenuItem<PlayMode>(
                value: mode,
                checked: mode == playMode,
                child: Text(mode.label),
              ),
          ],
        ),
        IconButton(
          key: const ValueKey<String>('player-previous'),
          tooltip: '上一首',
          onPressed: canSkip ? onPrevious : null,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.skip_previous_rounded, size: 27),
        ),
        const SizedBox(width: 5),
        Tooltip(
          message: loading
              ? '正在加载歌曲'
              : isPlaying
              ? '暂停'
              : '播放',
          child: Semantics(
            container: true,
            button: true,
            enabled: canPlay && !loading,
            onTap: canPlay && !loading ? onTogglePlayback : null,
            label: loading
                ? '正在加载歌曲'
                : isPlaying
                ? '暂停'
                : '播放',
            excludeSemantics: true,
            child: IconButton.filled(
              key: const ValueKey<String>('player-toggle'),
              onPressed: canPlay && !loading ? onTogglePlayback : null,
              style: IconButton.styleFrom(
                minimumSize: const Size(46, 46),
                backgroundColor: AppColors.accent,
                foregroundColor: AppColors.accentOn,
                disabledBackgroundColor: AppColors.surfaceHigh,
                disabledForegroundColor: AppColors.textDisabled,
                shadowColor: AppColors.accent.withValues(alpha: 0.3),
                elevation: canPlay && !loading ? 4 : 0,
              ),
              // 保留稳定的语义按钮，不让进度动画反复替换原生可访问节点。
              icon: IndexedStack(
                index: loading ? 0 : 1,
                alignment: Alignment.center,
                children: [
                  TickerMode(
                    enabled: loading,
                    child: const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.3,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Icon(
                    isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 28,
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 5),
        IconButton(
          key: const ValueKey<String>('player-next'),
          tooltip: '下一首',
          onPressed: canSkip ? onNext : null,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.skip_next_rounded, size: 27),
        ),
        _VolumeButton(volume: volume, onChanged: onVolumeChanged),
      ],
    );
  }
}

class _ProgressRow extends StatefulWidget {
  const _ProgressRow({
    required this.sliderValue,
    required this.durationMilliseconds,
    required this.duration,
    required this.canSeek,
    required this.onChanged,
    required this.onChangeEnd,
    this.compact = false,
  });

  final double sliderValue;
  final int durationMilliseconds;
  final Duration duration;
  final bool canSeek;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;
  final bool compact;

  @override
  State<_ProgressRow> createState() => _ProgressRowState();
}

class _ProgressRowState extends State<_ProgressRow> {
  double? _hoverFraction;

  @override
  Widget build(BuildContext context) {
    const timeStyle = TextStyle(
      color: AppColors.textMuted,
      fontSize: 10.5,
      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
    );
    return SizedBox(
      height: widget.compact ? 22 : 30,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 42,
            child: Text(
              _formatDuration(
                Duration(milliseconds: widget.sliderValue.round()),
              ),
              textAlign: TextAlign.right,
              style: timeStyle,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final fraction = _hoverFraction;
                final previewMilliseconds = fraction == null
                    ? 0
                    : (fraction * widget.durationMilliseconds).round();
                final bubbleWidth = 52.0;
                final maxLeft = (constraints.maxWidth - bubbleWidth).clamp(
                  0.0,
                  double.infinity,
                );
                final bubbleLeft = fraction == null
                    ? 0.0
                    : (fraction * constraints.maxWidth - bubbleWidth / 2).clamp(
                        0.0,
                        maxLeft,
                      );
                return MouseRegion(
                  cursor: widget.canSeek
                      ? SystemMouseCursors.click
                      : MouseCursor.defer,
                  onHover: widget.canSeek
                      ? (event) {
                          final width = constraints.maxWidth;
                          if (width <= 0) {
                            return;
                          }
                          final next = (event.localPosition.dx / width).clamp(
                            0.0,
                            1.0,
                          );
                          if (_hoverFraction != next) {
                            setState(() => _hoverFraction = next);
                          }
                        }
                      : null,
                  onExit: (_) {
                    if (_hoverFraction != null) {
                      setState(() => _hoverFraction = null);
                    }
                  },
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: <Widget>[
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                          activeTrackColor: AppColors.accent,
                          inactiveTrackColor: const Color(0xFF343A46),
                          disabledActiveTrackColor: const Color(0xFF414752),
                          disabledInactiveTrackColor: const Color(0xFF272C35),
                        ),
                        child: Slider(
                          value: widget.sliderValue,
                          max: widget.durationMilliseconds > 0
                              ? widget.durationMilliseconds.toDouble()
                              : 1,
                          onChanged: widget.canSeek ? widget.onChanged : null,
                          onChangeEnd: widget.canSeek
                              ? widget.onChangeEnd
                              : null,
                        ),
                      ),
                      if (fraction != null) ...<Widget>[
                        Positioned(
                          left: bubbleLeft,
                          top: -21,
                          child: IgnorePointer(
                            child: Container(
                              width: bubbleWidth,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.surfaceHigh,
                                borderRadius: BorderRadius.circular(
                                  AppRadii.small,
                                ),
                                border: Border.all(
                                  color: AppColors.borderStrong,
                                ),
                                boxShadow: const <BoxShadow>[
                                  BoxShadow(
                                    color: Color(0x55000000),
                                    blurRadius: 10,
                                    offset: Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Text(
                                _formatDuration(
                                  Duration(milliseconds: previewMilliseconds),
                                ),
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: AppColors.textPrimary,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  fontFeatures: <FontFeature>[
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          left: bubbleLeft + bubbleWidth - 5,
                          top: -3,
                          child: IgnorePointer(
                            child: Transform.rotate(
                              angle: 0.785398,
                              child: Container(
                                width: 8,
                                height: 8,
                                decoration: const BoxDecoration(
                                  color: AppColors.surfaceHigh,
                                  border: Border(
                                    right: BorderSide(
                                      color: AppColors.borderStrong,
                                    ),
                                    bottom: BorderSide(
                                      color: AppColors.borderStrong,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 42,
            child: Text(_formatDuration(widget.duration), style: timeStyle),
          ),
        ],
      ),
    );
  }
}

class _PlayerTools extends StatelessWidget {
  const _PlayerTools({
    required this.playback,
    required this.song,
    required this.canPlay,
    required this.downloading,
    required this.switchingQuality,
    required this.availableQualities,
    required this.loading,
    required this.desktopLyricsSupported,
    required this.desktopLyricsVisible,
    required this.desktopLyricsTooltip,
    required this.onDownload,
    required this.onToggleDesktopLyrics,
    required this.onQualityChanged,
  });

  final PlaybackResult? playback;
  final Song? song;
  final bool canPlay;
  final bool downloading;
  final bool switchingQuality;
  final List<String> availableQualities;
  final bool loading;
  final bool desktopLyricsSupported;
  final bool desktopLyricsVisible;
  final String desktopLyricsTooltip;
  final VoidCallback? onDownload;
  final VoidCallback? onToggleDesktopLyrics;
  final ValueChanged<String> onQualityChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: <Widget>[
        if (desktopLyricsSupported) ...<Widget>[
          IconButton(
            key: const ValueKey<String>('player-desktop-lyrics'),
            tooltip: desktopLyricsTooltip,
            onPressed: song == null ? null : onToggleDesktopLyrics,
            visualDensity: VisualDensity.compact,
            icon: Icon(
              desktopLyricsVisible
                  ? Icons.subtitles_rounded
                  : Icons.subtitles_outlined,
              size: 21,
              color: desktopLyricsVisible
                  ? AppColors.accent
                  : AppColors.textMuted,
            ),
          ),
          const SizedBox(width: 2),
        ],
        IconButton(
          key: const ValueKey<String>('player-download'),
          tooltip: downloading ? '正在下载当前歌曲' : '下载当前歌曲',
          onPressed: canPlay && !downloading ? onDownload : null,
          visualDensity: VisualDensity.compact,
          icon: downloading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.accent,
                  ),
                )
              : const Icon(Icons.download_rounded, size: 21),
        ),
        const SizedBox(width: 8),
        _QualityMenu(
          playback: playback,
          qualities: availableQualities,
          switching: switchingQuality,
          enabled: song != null && !loading,
          onSelected: onQualityChanged,
        ),
      ],
    );
  }
}

class _Artwork extends StatefulWidget {
  const _Artwork({
    required this.song,
    this.size = 64,
    this.radius = 14,
    this.expanded = false,
    this.onTap,
  });

  final Song? song;
  final double size;
  final double radius;
  final bool expanded;
  final VoidCallback? onTap;

  @override
  State<_Artwork> createState() => _ArtworkState();
}

class _ArtworkState extends State<_Artwork> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final artwork = Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (widget.song?.coverUrl.isNotEmpty == true)
          Image.network(
            widget.song!.coverUrl,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) => const Icon(
              Icons.album_rounded,
              color: AppColors.textMuted,
              size: 30,
            ),
          )
        else
          const Icon(Icons.album_rounded, color: Color(0xFF596170), size: 30),
        if (widget.onTap != null)
          IgnorePointer(
            child: AnimatedOpacity(
              key: ValueKey<String>(
                widget.expanded
                    ? 'player-artwork-collapse-overlay'
                    : 'player-artwork-expand-overlay',
              ),
              opacity: _hovered ? 1 : 0,
              duration: AppDurations.fast,
              child: ColoredBox(
                color: const Color(0x64000000),
                child: Center(
                  child: SizedBox.square(
                    dimension: widget.size >= 56 ? 30 : 24,
                    child: CustomPaint(
                      painter: _CornerFramePainter(collapsed: widget.expanded),
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.onTap == null
            ? ''
            : widget.expanded
            ? '收起完整播放页'
            : '打开完整播放页',
        child: Material(
          color: AppColors.surfaceHigh,
          borderRadius: BorderRadius.circular(widget.radius),
          clipBehavior: Clip.antiAlias,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(widget.radius),
              border: Border.all(color: AppColors.borderStrong),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: AppColors.shadowSoft,
                  blurRadius: 14,
                  offset: Offset(0, 5),
                ),
              ],
            ),
            child: InkWell(
              key: const ValueKey<String>('player-artwork'),
              onTap: widget.onTap,
              child: SizedBox(
                width: widget.size,
                height: widget.size,
                child: artwork,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 用简洁的四角括号表达展开或收起，避免使用含义模糊的系统图标。
class _CornerFramePainter extends CustomPainter {
  const _CornerFramePainter({required this.collapsed});

  final bool collapsed;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.textPrimary
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.8, size.width * 0.085)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final center = Offset(size.width / 2, size.height / 2);
    final left = size.width * 0.18;
    final right = size.width * 0.82;
    final top = size.height * 0.18;
    final bottom = size.height * 0.82;

    final path = Path();
    if (collapsed) {
      path
        ..moveTo(right, center.dy)
        ..lineTo(center.dx, center.dy)
        ..lineTo(center.dx, top)
        ..moveTo(left, center.dy)
        ..lineTo(center.dx, center.dy)
        ..lineTo(center.dx, bottom);
    } else {
      path
        ..moveTo(center.dx, top)
        ..lineTo(right, top)
        ..lineTo(right, center.dy)
        ..moveTo(center.dx, bottom)
        ..lineTo(left, bottom)
        ..lineTo(left, center.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _CornerFramePainter oldDelegate) {
    return oldDelegate.collapsed != collapsed;
  }
}

class _VolumeButton extends StatelessWidget {
  const _VolumeButton({required this.volume, required this.onChanged});

  final double volume;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final clamped = volume.clamp(0.0, 1.0);
    final icon = switch (clamped) {
      <= 0 => Icons.volume_off_rounded,
      < 0.5 => Icons.volume_down_rounded,
      _ => Icons.volume_up_rounded,
    };
    return MenuAnchor(
      menuChildren: <Widget>[
        SizedBox(
          width: 190,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 14, 6),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 19, color: AppColors.textSecondary),
                Expanded(
                  child: Slider(value: clamped, onChanged: onChanged),
                ),
                SizedBox(
                  width: 34,
                  child: Text(
                    '${(clamped * 100).round()}%',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 11,
                      fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
      builder: (context, controller, child) {
        return IconButton(
          key: const ValueKey<String>('player-volume'),
          tooltip: '音量 ${(clamped * 100).round()}%',
          onPressed: () {
            if (controller.isOpen) {
              controller.close();
            } else {
              controller.open();
            }
          },
          icon: Icon(icon, size: 21),
        );
      },
    );
  }
}

class _QualityMenu extends StatelessWidget {
  const _QualityMenu({
    required this.playback,
    required this.qualities,
    required this.switching,
    required this.enabled,
    required this.onSelected,
  });

  final PlaybackResult? playback;
  final List<String> qualities;
  final bool switching;
  final bool enabled;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final ordered = _orderedQualities(qualities);
    final current = playback?.quality ?? '';
    final hasQualities = ordered.isNotEmpty;
    final label = switching
        ? '切换中'
        : current.isNotEmpty
        ? formatQualityLabel(current)
        : hasQualities
        ? '选择音质'
        : '--';

    return Tooltip(
      message: hasQualities ? '切换音质' : '当前歌曲没有可用音质',
      child: PopupMenuButton<String>(
        key: const ValueKey<String>('player-quality'),
        enabled: enabled && hasQualities && !switching,
        tooltip: '',
        position: PopupMenuPosition.over,
        onSelected: onSelected,
        itemBuilder: (context) => <PopupMenuEntry<String>>[
          for (final quality in ordered)
            CheckedPopupMenuItem<String>(
              key: ValueKey<String>('quality-option-$quality'),
              value: quality,
              checked: quality == current,
              child: Text(formatQualityLabel(quality)),
            ),
        ],
        child: _QualityChip(
          label: label,
          muted: !hasQualities,
          loading: switching,
        ),
      ),
    );
  }
}

class _QualityChip extends StatelessWidget {
  const _QualityChip({
    required this.label,
    this.muted = false,
    this.loading = false,
  });

  final String label;
  final bool muted;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 90),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: muted ? AppColors.surfaceHigh : AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadii.control),
        border: Border.all(
          color: muted ? AppColors.borderDisabled : AppColors.accentBorder,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          if (loading) ...<Widget>[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.6,
                color: AppColors.accentStrong,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: muted ? AppColors.textMuted : AppColors.accentStrong,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

List<String> _orderedQualities(List<String> qualities) {
  final remaining = qualities.toSet();
  final result = <String>[
    for (final quality in supportedQualityOrder)
      if (remaining.remove(quality)) quality,
    ...remaining,
  ];
  return List<String>.unmodifiable(result);
}

String _formatDuration(Duration duration) {
  final totalSeconds = duration.inSeconds.clamp(0, 359999);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
