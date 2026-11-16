import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../lyrics/lrc_parser.dart';
import '../lyrics/line_progress.dart';
import '../models/lyric.dart';
import '../models/playback.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../platform/system_volume.dart';
import '../theme/app_theme.dart';
import 'music_source_badge.dart';

const List<String> _lyricFontFamilyFallback = <String>[
  'PingFang SC',
  'Hiragino Sans GB',
  'Noto Sans CJK SC',
];

/// Android 移动端正在播放页，内部包含单句歌词页和完整歌词页。
class MobileNowPlayingPage extends StatefulWidget {
  const MobileNowPlayingPage({
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
    required this.downloading,
    required this.desktopLyricsSupported,
    required this.desktopLyricsVisible,
    required this.lyric,
    required this.lyricLines,
    required this.translations,
    required this.romanizations,
    required this.activeLyricIndex,
    required this.loadingLyrics,
    required this.lyricError,
    required this.onClose,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
    required this.onPlayModeChanged,
    required this.onVolumeChanged,
    required this.onQualityChanged,
    this.onDownload,
    this.onAddToPlaylist,
    this.onToggleDesktopLyrics,
  });

  final Song? song;
  final PlaybackResult? playback;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool loading;
  final bool switchingQuality;
  final String? error;
  final PlayMode playMode;
  final double volume;
  final List<String> availableQualities;
  final bool canSkip;
  final bool downloading;
  final bool desktopLyricsSupported;
  final bool desktopLyricsVisible;
  final LyricData? lyric;
  final List<LrcLine> lyricLines;
  final Map<int, String> translations;
  final Map<int, String> romanizations;
  final int activeLyricIndex;
  final bool loadingLyrics;
  final String? lyricError;
  final VoidCallback onClose;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<PlayMode> onPlayModeChanged;
  final ValueChanged<double> onVolumeChanged;
  final ValueChanged<String> onQualityChanged;
  final VoidCallback? onDownload;
  final VoidCallback? onAddToPlaylist;
  final VoidCallback? onToggleDesktopLyrics;

  @override
  State<MobileNowPlayingPage> createState() => MobileNowPlayingPageState();
}

class MobileNowPlayingPageState extends State<MobileNowPlayingPage> {
  final PageController _pageController = PageController();
  final ValueNotifier<int> _settingsRevision = ValueNotifier(0);
  int _pageIndex = 0;
  double? _systemVolume;
  Timer? _volumePoll;
  bool _sheetOpen = false;
  int _volumeSequence = 0;
  int _volumeWrites = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSystemVolume());
  }

  Future<void> _loadSystemVolume() async {
    if (_volumeWrites > 0) return;
    final sequence = _volumeSequence;
    final value = await SystemVolume.read();
    if (mounted && sequence == _volumeSequence && value != _systemVolume) {
      _systemVolume = value;
      _settingsRevision.value++;
    }
  }

  @override
  void didUpdateWidget(covariant MobileNowPlayingPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sheetOpen &&
        (oldWidget.song?.mediaKey != widget.song?.mediaKey ||
            oldWidget.playback != widget.playback ||
            oldWidget.loading != widget.loading ||
            oldWidget.switchingQuality != widget.switchingQuality ||
            oldWidget.downloading != widget.downloading)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _settingsRevision.value++;
      });
    }
  }

  @override
  void dispose() {
    _volumePoll?.cancel();
    _settingsRevision.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _goToPage(int page) {
    if (!_pageController.hasClients || page == _pageIndex) return;
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  double get _effectiveVolume => _systemVolume ?? widget.volume;

  Future<void> _changeVolume(double value) async {
    final normalized = value.clamp(0.0, 1.0);
    final sequence = ++_volumeSequence;
    _systemVolume = normalized;
    _settingsRevision.value++;
    _volumeWrites++;
    final succeeded = await SystemVolume.write(normalized);
    _volumeWrites--;
    if (!mounted || sequence != _volumeSequence) return;
    if (!succeeded) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('系统音量调整失败，请使用手机音量键')));
    }
    await _loadSystemVolume();
  }

  /// Returns true when back navigates from full lyrics to the album page.
  bool handleBack() {
    if (_pageIndex == 0) return false;
    _goToPage(0);
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final song = widget.song;
    return Material(
      key: const ValueKey<String>('mobile-now-playing-page'),
      color: AppColors.background,
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          _MobileNowPlayingBackdrop(song: song),
          SafeArea(
            child: Column(
              children: <Widget>[
                _buildTopBar(),
                if (widget.error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Text(
                      widget.error!,
                      key: const ValueKey('mobile-playback-error'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.warning,
                        fontSize: 12,
                      ),
                    ),
                  ),
                Expanded(
                  child: PageView(
                    key: const ValueKey<String>('mobile-now-playing-pages'),
                    controller: _pageController,
                    onPageChanged: (value) {
                      setState(() => _pageIndex = value);
                    },
                    children: <Widget>[
                      _buildSingleLyricPage(),
                      _buildFullLyricsPage(),
                    ],
                  ),
                ),
                _MobilePlaybackControls(
                  song: song,
                  position: widget.position,
                  duration: widget.duration,
                  isPlaying: widget.isPlaying,
                  loading: widget.loading || widget.switchingQuality,
                  available: widget.playback?.available == true,
                  canSkip: widget.canSkip,
                  playMode: widget.playMode,
                  desktopLyricsSupported: widget.desktopLyricsSupported,
                  desktopLyricsVisible: widget.desktopLyricsVisible,
                  onTogglePlayback: widget.onTogglePlayback,
                  onSeek: widget.onSeek,
                  onPrevious: widget.onPrevious,
                  onNext: widget.onNext,
                  onPlayModeChanged: widget.onPlayModeChanged,
                  onToggleDesktopLyrics: widget.onToggleDesktopLyrics,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBar() {
    return SizedBox(
      height: 48,
      child: Row(
        children: <Widget>[
          IconButton(
            key: const ValueKey<String>('mobile-now-playing-back'),
            tooltip: _pageIndex == 0 ? '收起播放器' : '返回单句歌词',
            onPressed: _pageIndex == 0 ? widget.onClose : () => _goToPage(0),
            icon: Icon(
              _pageIndex == 0
                  ? Icons.keyboard_arrow_down_rounded
                  : Icons.arrow_back_rounded,
            ),
          ),
          Expanded(
            child: Text(
              _pageIndex == 0 ? '正在播放' : '完整歌词',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey<String>('mobile-now-playing-more'),
            tooltip: '更多操作',
            onPressed: widget.song == null
                ? null
                : () => unawaited(_showMoreSheet()),
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
    );
  }

  Widget _buildSingleLyricPage() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxHeight < 400;
        final discSize = math.min(
          math.min(constraints.maxWidth * 0.70, 300.0),
          math.max(100.0, constraints.maxHeight - 180),
        );
        return SingleChildScrollView(
          key: const ValueKey<String>('mobile-single-lyric-page'),
          padding: EdgeInsets.fromLTRB(22, compact ? 8 : 16, 22, 10),
          child: Column(
            children: <Widget>[
              _RotatingAlbumDisc(
                song: widget.song,
                size: discSize,
                isPlaying: widget.isPlaying,
              ),
              SizedBox(height: compact ? 12 : 23),
              if (widget.song != null) ...<Widget>[
                MusicSourceBadge(source: widget.song!.source, compact: true),
                const SizedBox(height: 6),
              ],
              Text(
                widget.song?.name ?? '未选择歌曲',
                key: const ValueKey<String>('mobile-now-playing-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: compact ? 18 : 22,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.song == null
                    ? '选择一首歌曲开始播放'
                    : '${widget.song!.artistText} · ${widget.song!.album}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                ),
              ),
              SizedBox(height: compact ? 14 : 24),
              SizedBox(
                height: compact ? 52 : 65,
                child: Center(child: _buildCurrentLyric()),
              ),
              if (!compact) ...<Widget>[
                const SizedBox(height: 10),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      '左滑查看完整歌词',
                      style: TextStyle(
                        color: AppColors.textDisabled,
                        fontSize: 9,
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      size: 14,
                      color: AppColors.textDisabled,
                    ),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _buildCurrentLyric() {
    if (widget.loadingLyrics) {
      return const Text(
        '正在加载歌词…',
        style: TextStyle(color: AppColors.textMuted, fontSize: 13),
      );
    }
    if (widget.lyricError != null) {
      return Text(
        widget.lyricError!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppColors.warning, fontSize: 12),
      );
    }
    final lines = widget.lyricLines;
    final index = widget.activeLyricIndex;
    if (index < 0 || index >= lines.length) {
      return Text(
        lines.isEmpty ? '等待歌词…' : lines.first.text,
        key: const ValueKey<String>('mobile-now-playing-lyric'),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: AppColors.textSecondary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
          height: 1.45,
        ),
      );
    }
    final text = lines[index].text;
    final progress = _karaokeProgress(index);
    return ShaderMask(
      key: const ValueKey<String>('mobile-now-playing-lyric'),
      blendMode: BlendMode.srcIn,
      shaderCallback: (bounds) => LinearGradient(
        colors: const <Color>[
          AppColors.accentStrong,
          AppColors.accentStrong,
          Color(0xFF66707D),
          Color(0xFF66707D),
        ],
        stops: <double>[0, progress, progress, 1],
      ).createShader(bounds),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 17,
          fontWeight: FontWeight.w700,
          height: 1.45,
        ),
      ),
    );
  }

  double _karaokeProgress(int index) {
    return estimateLyricLineProgress(
          lines: widget.lyricLines,
          index: index,
          position: widget.position,
          duration: widget.duration,
        ) ??
        0;
  }

  Widget _buildFullLyricsPage() {
    return Column(
      key: const ValueKey<String>('mobile-full-lyrics-page'),
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(22, 2, 22, 9),
          child: Column(
            children: <Widget>[
              if (widget.song != null) ...<Widget>[
                MusicSourceBadge(source: widget.song!.source, compact: true),
                const SizedBox(height: 6),
              ],
              Text(
                widget.song?.name ?? '未选择歌曲',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.35,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.song == null
                    ? ''
                    : '${widget.song!.artistText} · ${widget.song!.album}',
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
        Expanded(
          child: _MobileFullLyrics(
            lines: widget.lyricLines,
            translations: widget.translations,
            romanizations: widget.romanizations,
            activeIndex: widget.activeLyricIndex,
            visible: _pageIndex == 1,
            loading: widget.loadingLyrics,
            error: widget.lyricError,
          ),
        ),
      ],
    );
  }

  Future<void> _showMoreSheet() async {
    if (_sheetOpen) return;
    _sheetOpen = true;
    await _loadSystemVolume();
    if (!mounted) return;
    _volumePoll = Timer.periodic(const Duration(milliseconds: 600), (_) {
      unawaited(_loadSystemVolume());
    });
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        barrierColor: const Color(0x99000000),
        builder: (sheetContext) {
          return ListenableBuilder(
            listenable: _settingsRevision,
            builder: (context, _) {
              final volume = _effectiveVolume;
              final qualities = _orderedQualities(widget.availableQualities);
              final currentQuality = widget.playback?.quality ?? '';
              final qualityLabel = currentQuality.isEmpty
                  ? (qualities.isEmpty ? '暂无可用音质' : '选择音质')
                  : formatQualityLabel(currentQuality);
              return FractionallySizedBox(
                heightFactor: 0.58,
                alignment: Alignment.bottomCenter,
                child: Container(
                  key: const ValueKey<String>('mobile-more-sheet'),
                  decoration: const BoxDecoration(
                    color: Color(0xFF18212A),
                    borderRadius: BorderRadius.vertical(
                      top: Radius.circular(22),
                    ),
                  ),
                  child: Column(
                    children: <Widget>[
                      const SizedBox(height: 9),
                      Container(
                        width: 34,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0x557D8593),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                      SizedBox(
                        height: 53,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(19, 5, 6, 0),
                          child: Row(
                            children: <Widget>[
                              const Expanded(
                                child: Text(
                                  '更多操作',
                                  style: TextStyle(
                                    color: AppColors.textPrimary,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              IconButton(
                                key: const ValueKey<String>(
                                  'mobile-more-close',
                                ),
                                tooltip: '关闭',
                                onPressed: () =>
                                    Navigator.of(sheetContext).pop(),
                                icon: const Icon(Icons.close_rounded),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 19),
                          children: <Widget>[
                            _MobileSheetRow(
                              key: const ValueKey<String>('mobile-download'),
                              icon: Icons.download_rounded,
                              title: widget.downloading ? '正在下载' : '下载歌曲',
                              value: '保存到本地',
                              enabled:
                                  widget.onDownload != null &&
                                  !widget.downloading &&
                                  !widget.loading,
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                widget.onDownload?.call();
                              },
                            ),
                            _MobileSheetRow(
                              key: const ValueKey<String>('mobile-quality'),
                              icon: Icons.tune_rounded,
                              title: '选择音质',
                              value: qualityLabel,
                              enabled:
                                  qualities.isNotEmpty &&
                                  !widget.loading &&
                                  !widget.switchingQuality,
                              onTap: () => unawaited(
                                _showQualityPicker(sheetContext, qualities),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      const Icon(
                                        Icons.volume_up_rounded,
                                        size: 20,
                                        color: AppColors.accentStrong,
                                      ),
                                      const SizedBox(width: 11),
                                      const Text(
                                        '音量',
                                        style: TextStyle(
                                          color: AppColors.textPrimary,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const Spacer(),
                                      Text(
                                        _systemVolume == null
                                            ? '系统音量暂不可用'
                                            : '跟随系统媒体音量',
                                        style: const TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 9,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Slider(
                                    key: const ValueKey<String>(
                                      'mobile-volume',
                                    ),
                                    value: volume,
                                    onChanged: _systemVolume == null
                                        ? null
                                        : (value) =>
                                              unawaited(_changeVolume(value)),
                                  ),
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: <Widget>[
                                      const Text(
                                        '静音',
                                        style: TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 9,
                                        ),
                                      ),
                                      Text(
                                        '${(volume * 100).round()}%',
                                        style: const TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 9,
                                        ),
                                      ),
                                      const Text(
                                        '最大',
                                        style: TextStyle(
                                          color: AppColors.textMuted,
                                          fontSize: 9,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            _MobileSheetRow(
                              key: const ValueKey<String>(
                                'mobile-add-to-playlist',
                              ),
                              icon: Icons.playlist_add_rounded,
                              title: '添加到歌单',
                              value: widget.song?.name ?? '',
                              enabled: widget.onAddToPlaylist != null,
                              onTap: () {
                                Navigator.of(sheetContext).pop();
                                widget.onAddToPlaylist?.call();
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } finally {
      _volumePoll?.cancel();
      _volumePoll = null;
      _sheetOpen = false;
    }
  }

  Future<void> _showQualityPicker(
    BuildContext context,
    List<String> qualities,
  ) async {
    final current = widget.playback?.quality ?? '';
    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('选择音质'),
        children: <Widget>[
          for (final quality in qualities)
            SimpleDialogOption(
              onPressed: () => Navigator.of(dialogContext).pop(quality),
              child: Row(
                children: <Widget>[
                  Icon(
                    quality == current
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    size: 19,
                    color: quality == current
                        ? AppColors.accent
                        : AppColors.textMuted,
                  ),
                  const SizedBox(width: 10),
                  Text(formatQualityLabel(quality)),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null && mounted) widget.onQualityChanged(selected);
  }
}

class _MobilePlaybackControls extends StatefulWidget {
  const _MobilePlaybackControls({
    required this.song,
    required this.position,
    required this.duration,
    required this.isPlaying,
    required this.loading,
    required this.available,
    required this.canSkip,
    required this.playMode,
    required this.desktopLyricsSupported,
    required this.desktopLyricsVisible,
    required this.onTogglePlayback,
    required this.onSeek,
    required this.onPrevious,
    required this.onNext,
    required this.onPlayModeChanged,
    required this.onToggleDesktopLyrics,
  });

  final Song? song;
  final Duration position;
  final Duration duration;
  final bool isPlaying;
  final bool loading;
  final bool available;
  final bool canSkip;
  final PlayMode playMode;
  final bool desktopLyricsSupported;
  final bool desktopLyricsVisible;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Duration> onSeek;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final ValueChanged<PlayMode> onPlayModeChanged;
  final VoidCallback? onToggleDesktopLyrics;

  @override
  State<_MobilePlaybackControls> createState() =>
      _MobilePlaybackControlsState();
}

class _MobilePlaybackControlsState extends State<_MobilePlaybackControls> {
  double? _dragMilliseconds;

  @override
  void didUpdateWidget(covariant _MobilePlaybackControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song?.mediaKey != widget.song?.mediaKey) {
      _dragMilliseconds = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.duration.inMilliseconds;
    final current = widget.position.inMilliseconds
        .clamp(0, total < 0 ? 0 : total)
        .toDouble();
    final sliderValue = (_dragMilliseconds ?? current).clamp(
      0.0,
      math.max(1, total).toDouble(),
    );
    final canPlay = widget.song != null && widget.available && !widget.loading;
    final canSeek = canPlay && total > 0;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 3, 18, 4),
      decoration: const BoxDecoration(
        color: Color(0xCC0D1116),
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
              activeTrackColor: AppColors.accent,
              inactiveTrackColor: AppColors.borderStrong,
              thumbColor: AppColors.accentStrong,
            ),
            child: Slider(
              key: const ValueKey<String>('mobile-progress'),
              value: sliderValue,
              max: total <= 0 ? 1 : total.toDouble(),
              onChanged: canSeek
                  ? (value) => setState(() => _dragMilliseconds = value)
                  : null,
              onChangeEnd: canSeek
                  ? (value) {
                      setState(() => _dragMilliseconds = null);
                      widget.onSeek(Duration(milliseconds: value.round()));
                    }
                  : null,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 5),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  _formatDuration(Duration(milliseconds: sliderValue.round())),
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 9,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  _formatDuration(widget.duration),
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 9,
                    fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 64,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: <Widget>[
                IconButton(
                  key: const ValueKey<String>('mobile-play-mode'),
                  tooltip: '播放模式：${widget.playMode.label}',
                  onPressed: widget.song == null
                      ? null
                      : () => widget.onPlayModeChanged(
                          _nextPlayMode(widget.playMode),
                        ),
                  icon: Icon(widget.playMode.icon, size: 21),
                ),
                IconButton(
                  key: const ValueKey<String>('mobile-previous'),
                  tooltip: '上一首',
                  onPressed: widget.canSkip ? widget.onPrevious : null,
                  icon: const Icon(Icons.skip_previous_rounded, size: 27),
                ),
                IconButton.filled(
                  key: const ValueKey<String>('mobile-toggle-playback'),
                  tooltip: widget.loading
                      ? '正在加载歌曲'
                      : widget.isPlaying
                      ? '暂停'
                      : '播放',
                  onPressed: canPlay ? widget.onTogglePlayback : null,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(56, 56),
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.accentOn,
                    disabledBackgroundColor: AppColors.surfaceHigh,
                  ),
                  icon: widget.loading
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(
                          widget.isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 28,
                        ),
                ),
                IconButton(
                  key: const ValueKey<String>('mobile-next'),
                  tooltip: '下一首',
                  onPressed: widget.canSkip ? widget.onNext : null,
                  icon: const Icon(Icons.skip_next_rounded, size: 27),
                ),
                IconButton(
                  key: const ValueKey<String>('mobile-desktop-lyrics'),
                  tooltip: widget.desktopLyricsVisible ? '关闭桌面歌词' : '桌面歌词',
                  onPressed: widget.onToggleDesktopLyrics,
                  color: widget.desktopLyricsVisible ? AppColors.accent : null,
                  icon: const Icon(Icons.subtitles_rounded, size: 21),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RotatingAlbumDisc extends StatefulWidget {
  const _RotatingAlbumDisc({
    required this.song,
    required this.size,
    required this.isPlaying,
  });

  final Song? song;
  final double size;
  final bool isPlaying;

  @override
  State<_RotatingAlbumDisc> createState() => _RotatingAlbumDiscState();
}

class _RotatingAlbumDiscState extends State<_RotatingAlbumDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 34),
  );

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant _RotatingAlbumDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) _sync();
  }

  void _sync() {
    if (widget.isPlaying) {
      _rotation.repeat();
    } else {
      _rotation.stop(canceled: false);
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final url = widget.song?.coverUrl.trim() ?? '';
    return SizedBox.square(
      key: const ValueKey<String>('mobile-now-playing-disc'),
      dimension: widget.size,
      child: RotationTransition(
        turns: _rotation,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: <Color>[
                Color(0xFF242A2B),
                Color(0xFF121719),
                Color(0xFF1D2324),
                Color(0xFF090C0E),
              ],
              stops: <double>[0, 0.52, 0.78, 1],
            ),
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: Color(0x99000000),
                blurRadius: 45,
                offset: Offset(0, 24),
              ),
              BoxShadow(color: Color(0x2E69DFA0), blurRadius: 55),
            ],
          ),
          child: Stack(
            alignment: Alignment.center,
            children: <Widget>[
              for (final scale in const <double>[0.94, 0.82, 0.69])
                FractionallySizedBox(
                  widthFactor: scale,
                  heightFactor: scale,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: const Color(0x14FFFFFF)),
                    ),
                  ),
                ),
              FractionallySizedBox(
                widthFactor: 0.88,
                heightFactor: 0.88,
                child: ClipOval(
                  child: url.isEmpty
                      ? const ColoredBox(
                          color: AppColors.surfaceHigh,
                          child: Icon(
                            Icons.album_rounded,
                            size: 48,
                            color: AppColors.textMuted,
                          ),
                        )
                      : Image.network(
                          url,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const ColoredBox(
                            color: AppColors.surfaceHigh,
                            child: Icon(
                              Icons.album_rounded,
                              size: 48,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                ),
              ),
              const FractionallySizedBox(
                widthFactor: 0.085,
                heightFactor: 0.085,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Color(0xFF0B0F14),
                    shape: BoxShape.circle,
                    border: Border.fromBorderSide(
                      BorderSide(color: Color(0x55FFFFFF)),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MobileFullLyrics extends StatefulWidget {
  const _MobileFullLyrics({
    required this.lines,
    required this.translations,
    required this.romanizations,
    required this.activeIndex,
    required this.visible,
    required this.loading,
    required this.error,
  });

  final List<LrcLine> lines;
  final Map<int, String> translations;
  final Map<int, String> romanizations;
  final int activeIndex;
  final bool visible;
  final bool loading;
  final String? error;

  @override
  State<_MobileFullLyrics> createState() => _MobileFullLyricsState();
}

class _MobileFullLyricsState extends State<_MobileFullLyrics> {
  final ScrollController _scrollController = ScrollController();
  List<GlobalKey> _lineKeys = const <GlobalKey>[];
  int _lastCenteredIndex = -1;
  bool _browsing = false;

  @override
  void initState() {
    super.initState();
    _rebuildKeys();
    _centerActiveLine();
  }

  @override
  void didUpdateWidget(covariant _MobileFullLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      _rebuildKeys();
      _lastCenteredIndex = -1;
    }
    if (!oldWidget.visible && widget.visible) _lastCenteredIndex = -1;
    if (!identical(oldWidget.lines, widget.lines) ||
        oldWidget.activeIndex != widget.activeIndex ||
        oldWidget.visible != widget.visible) {
      _centerActiveLine();
    }
  }

  void _rebuildKeys() {
    _lineKeys = List<GlobalKey>.generate(
      widget.lines.length,
      (_) => GlobalKey(),
      growable: false,
    );
  }

  void _centerActiveLine() {
    if (!widget.visible || _browsing) return;
    final index = widget.activeIndex;
    if (index < 0 || index >= _lineKeys.length || index == _lastCenteredIndex) {
      return;
    }
    _lastCenteredIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final context = _lineKeys[index].currentContext;
      if (context == null) {
        _lastCenteredIndex = -1;
        return;
      }
      Scrollable.ensureVisible(
        context,
        alignment: 0.38,
        duration: const Duration(milliseconds: 360),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    if (widget.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: Text(
            widget.error!,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.warning, fontSize: 12),
          ),
        ),
      );
    }
    if (widget.lines.isEmpty) {
      return const Center(
        child: Text(
          '暂无歌词',
          style: TextStyle(color: AppColors.textMuted, fontSize: 12),
        ),
      );
    }
    return Stack(
      children: [
        NotificationListener<ScrollStartNotification>(
          onNotification: (notification) {
            if (notification.dragDetails != null && !_browsing) {
              setState(() => _browsing = true);
            }
            return false;
          },
          child: SingleChildScrollView(
            key: const ValueKey<String>('mobile-full-lyrics-list'),
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 80),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: List.generate(widget.lines.length, (index) {
                final line = widget.lines[index];
                final active = index == widget.activeIndex;
                final baseTextStyle = DefaultTextStyle.of(context).style;
                final fontFallback =
                    baseTextStyle.fontFamilyFallback ??
                    _lyricFontFamilyFallback;
                final timestamp = line.timestamp?.inMilliseconds;
                final translation =
                    widget.translations[timestamp]?.trim() ?? '';
                final romanization =
                    widget.romanizations[timestamp]?.trim() ?? '';
                return KeyedSubtree(
                  key: _lineKeys[index],
                  child: AnimatedOpacity(
                    opacity: active || widget.activeIndex < 0 ? 1 : 0.48,
                    duration: const Duration(milliseconds: 220),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: <Widget>[
                          AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 220),
                            textAlign: TextAlign.center,
                            style: baseTextStyle.copyWith(
                              color: active
                                  ? AppColors.accentStrong
                                  : AppColors.textPrimary,
                              fontSize: active ? 20 : 15,
                              fontWeight: active
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              height: 1.42,
                              fontFamilyFallback: fontFallback,
                            ),
                            child: Text(line.text, textAlign: TextAlign.center),
                          ),
                          if (translation.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 3),
                              child: Text(
                                translation,
                                textAlign: TextAlign.center,
                                style: baseTextStyle.copyWith(
                                  color: AppColors.textSecondary,
                                  fontSize: 12,
                                  height: 1.45,
                                  fontFamilyFallback: fontFallback,
                                ),
                              ),
                            ),
                          if (romanization.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                romanization,
                                textAlign: TextAlign.center,
                                style: baseTextStyle.copyWith(
                                  color: AppColors.textMuted,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                  fontFamilyFallback: fontFallback,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
        if (_browsing)
          Positioned(
            right: 16,
            bottom: 10,
            child: FilledButton.tonalIcon(
              key: const ValueKey('mobile-resume-lyrics-follow'),
              onPressed: () {
                setState(() => _browsing = false);
                _lastCenteredIndex = -1;
                _centerActiveLine();
              },
              icon: const Icon(Icons.my_location_rounded, size: 16),
              label: const Text('回到当前歌词'),
            ),
          ),
      ],
    );
  }
}

class _MobileNowPlayingBackdrop extends StatelessWidget {
  const _MobileNowPlayingBackdrop({required this.song});

  final Song? song;

  @override
  Widget build(BuildContext context) {
    final coverUrl = song?.coverUrl.trim() ?? '';
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ColoredBox(color: Color(0xFF0B0F14)),
        if (coverUrl.isNotEmpty)
          Opacity(
            opacity: 0.18,
            child: Image.network(
              coverUrl,
              fit: BoxFit.cover,
              filterQuality: FilterQuality.low,
              color: const Color(0xFF163529),
              colorBlendMode: BlendMode.softLight,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                Color(0xD914241D),
                Color(0xE80E1217),
                Color(0xFF0B0F14),
              ],
              stops: <double>[0, 0.55, 1],
            ),
          ),
        ),
      ],
    );
  }
}

class _MobileSheetRow extends StatelessWidget {
  const _MobileSheetRow({
    super.key,
    required this.icon,
    required this.title,
    required this.value,
    required this.enabled,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String value;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? onTap : null,
      child: Container(
        height: 53,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.border)),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              icon,
              size: 20,
              color: enabled ? AppColors.accentStrong : AppColors.textDisabled,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: enabled ? AppColors.textPrimary : AppColors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppColors.textMuted, fontSize: 9),
              ),
            ),
            const SizedBox(width: 5),
            const Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: AppColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

PlayMode _nextPlayMode(PlayMode mode) {
  return switch (mode) {
    PlayMode.sequentialLoop => PlayMode.shuffle,
    PlayMode.shuffle => PlayMode.repeatOne,
    PlayMode.repeatOne => PlayMode.sequentialLoop,
  };
}

List<String> _orderedQualities(List<String> qualities) {
  const order = <String>['master', 'flac', '320mp3', '128mp3', '96aac'];
  final remaining = qualities.toSet();
  return <String>[
    for (final quality in order)
      if (remaining.remove(quality)) quality,
    ...remaining,
  ];
}

String _formatDuration(Duration duration) {
  final total = duration.inSeconds.clamp(0, 359999);
  return '${total ~/ 60}:${(total % 60).toString().padLeft(2, '0')}';
}
