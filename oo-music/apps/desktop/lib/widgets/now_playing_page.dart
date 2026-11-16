import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../lyrics/lrc_parser.dart';
import '../models/lyric.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';
import 'music_source_badge.dart';
import '../platform/app_platform.dart';

/// 沉浸式“正在播放”页面。
///
/// 页面只负责展示歌曲、专辑盘面和歌词；底部播放控制仍由主页的
/// [PlayerBar] 提供，因此完整播放页与普通页面共享同一套播放状态。
class NowPlayingPage extends StatelessWidget {
  /// 创建完整播放页。
  const NowPlayingPage({
    super.key,
    required this.song,
    required this.isPlaying,
    required this.lyric,
    required this.lyricLines,
    required this.translations,
    required this.romanizations,
    required this.activeLyricIndex,
    required this.loadingLyrics,
    required this.lyricError,
  });

  /// 当前歌曲。
  final Song? song;

  /// 当前是否正在播放，用于控制专辑盘面的旋转。
  final bool isPlaying;

  /// 完整歌词数据。
  final LyricData? lyric;

  /// 解析后的歌词行。
  final List<LrcLine> lyricLines;

  /// 翻译歌词。
  final Map<int, String> translations;

  /// 罗马音歌词。
  final Map<int, String> romanizations;

  /// 当前高亮歌词行。
  final int activeLyricIndex;

  /// 是否正在加载歌词。
  final bool loadingLyrics;

  /// 歌词错误。
  final String? lyricError;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: const ValueKey<String>('now-playing-page'),
      color: AppColors.background,
      child: ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _ImmersiveBackdrop(song: song),
            LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 760;
                return wide
                    ? _buildWideLayout(context, constraints)
                    : _buildCompactLayout(context, constraints);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWideLayout(BuildContext context, BoxConstraints constraints) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(54, 38, 34, 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Expanded(
            flex: 10,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: _TrackAndLyrics(
                song: song,
                lyric: lyric,
                lyricLines: lyricLines,
                translations: translations,
                romanizations: romanizations,
                activeLyricIndex: activeLyricIndex,
                loadingLyrics: loadingLyrics,
                lyricError: lyricError,
              ),
            ),
          ),
          const SizedBox(width: 34),
          Expanded(
            flex: 11,
            child: LayoutBuilder(
              builder: (context, albumConstraints) {
                final size = math.min(
                  albumConstraints.maxWidth - 20,
                  albumConstraints.maxHeight - 10,
                );
                return Align(
                  alignment: Alignment.center,
                  child: _AlbumDisc(
                    song: song,
                    size: size.clamp(280.0, 500.0),
                    isPlaying: isPlaying,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactLayout(BuildContext context, BoxConstraints constraints) {
    final discSize = math.min(constraints.maxWidth * 0.60, 280.0);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(24, AppPlatform.isMobile ? 56 : 26, 24, 30),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _TrackIdentity(song: song),
          const SizedBox(height: 28),
          Center(
            child: _AlbumDisc(song: song, size: discSize, isPlaying: isPlaying),
          ),
          const SizedBox(height: 30),
          SizedBox(
            height: 390,
            child: _ImmersiveLyrics(
              song: song,
              lyric: lyric,
              lines: lyricLines,
              translations: translations,
              romanizations: romanizations,
              activeIndex: activeLyricIndex,
              loading: loadingLyrics,
              error: lyricError,
            ),
          ),
        ],
      ),
    );
  }
}

/// 大尺寸专辑封面形成柔和的环境色，页面不再使用独立卡片。
class _ImmersiveBackdrop extends StatelessWidget {
  const _ImmersiveBackdrop({required this.song});

  final Song? song;

  @override
  Widget build(BuildContext context) {
    final coverUrl = song?.coverUrl.trim() ?? '';
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ColoredBox(color: Color(0xFF0C1013)),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 520),
          switchInCurve: Curves.easeOutCubic,
          child: coverUrl.isEmpty
              ? const SizedBox.expand(key: ValueKey<String>('empty-backdrop'))
              : Opacity(
                  key: ValueKey<String>(coverUrl),
                  opacity: 0.26,
                  child: Image.network(
                    coverUrl,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.medium,
                    color: const Color(0xFF163529),
                    colorBlendMode: BlendMode.softLight,
                    errorBuilder: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: <Color>[
                Color(0xF21A2C23),
                Color(0xE60E1718),
                Color(0xFA0D1115),
              ],
              stops: <double>[0, 0.52, 1],
            ),
          ),
        ),
        Positioned(
          right: -112,
          top: -200,
          child: const SizedBox(
            width: 620,
            height: 620,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: <Color>[Color(0x4D69DFA0), Color(0x0069DFA0)],
                ),
              ),
            ),
          ),
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(-0.55, 0.15),
              radius: 1.2,
              colors: <Color>[Color(0x1AFFFFFF), Color(0x00000000)],
            ),
          ),
        ),
      ],
    );
  }
}

class _TrackAndLyrics extends StatelessWidget {
  const _TrackAndLyrics({
    required this.song,
    required this.lyric,
    required this.lyricLines,
    required this.translations,
    required this.romanizations,
    required this.activeLyricIndex,
    required this.loadingLyrics,
    required this.lyricError,
  });

  final Song? song;
  final LyricData? lyric;
  final List<LrcLine> lyricLines;
  final Map<int, String> translations;
  final Map<int, String> romanizations;
  final int activeLyricIndex;
  final bool loadingLyrics;
  final String? lyricError;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _TrackIdentity(song: song),
        const SizedBox(height: 34),
        Expanded(
          child: _ImmersiveLyrics(
            song: song,
            lyric: lyric,
            lines: lyricLines,
            translations: translations,
            romanizations: romanizations,
            activeIndex: activeLyricIndex,
            loading: loadingLyrics,
            error: lyricError,
          ),
        ),
      ],
    );
  }
}

class _TrackIdentity extends StatelessWidget {
  const _TrackIdentity({required this.song});

  final Song? song;

  @override
  Widget build(BuildContext context) {
    final album = song?.album.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (song != null) ...<Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: MusicSourceBadge(source: song!.source),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          song?.name ?? '未选择歌曲',
          key: const ValueKey<String>('now-playing-title'),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 32,
            height: 1.18,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.9,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          song?.artistText ?? '搜索并选择一首歌曲',
          key: const ValueKey<String>('now-playing-artist'),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: Color(0xFFC3CAD4),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: <Widget>[
            const Icon(
              Icons.album_outlined,
              size: 16,
              color: AppColors.textMuted,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                album.isEmpty ? '未知专辑' : album,
                key: const ValueKey<String>('now-playing-album'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 12,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 25),
        Container(
          height: 1,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: <Color>[
                Color(0x6669DFA0),
                Color(0x1FFFFFFF),
                Color(0x00FFFFFF),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// 无边框歌词列表；仅通过字号、亮度和留白突出当前行。
class _ImmersiveLyrics extends StatefulWidget {
  const _ImmersiveLyrics({
    required this.song,
    required this.lyric,
    required this.lines,
    required this.translations,
    required this.romanizations,
    required this.activeIndex,
    required this.loading,
    required this.error,
  });

  final Song? song;
  final LyricData? lyric;
  final List<LrcLine> lines;
  final Map<int, String> translations;
  final Map<int, String> romanizations;
  final int activeIndex;
  final bool loading;
  final String? error;

  @override
  State<_ImmersiveLyrics> createState() => _ImmersiveLyricsState();
}

class _ImmersiveLyricsState extends State<_ImmersiveLyrics> {
  final ScrollController _scrollController = ScrollController();
  List<GlobalKey> _lineKeys = const <GlobalKey>[];
  int _lastCenteredIndex = -1;

  @override
  void initState() {
    super.initState();
    _rebuildLineKeys();
    _centerActiveLine();
  }

  @override
  void didUpdateWidget(covariant _ImmersiveLyrics oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.lines, widget.lines)) {
      _rebuildLineKeys();
      _lastCenteredIndex = -1;
    }
    if (!identical(oldWidget.lines, widget.lines) ||
        widget.activeIndex != oldWidget.activeIndex) {
      _centerActiveLine();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _rebuildLineKeys() {
    _lineKeys = List<GlobalKey>.generate(
      widget.lines.length,
      (_) => GlobalKey(),
      growable: false,
    );
  }

  void _centerActiveLine() {
    final index = widget.activeIndex;
    if (index < 0 || index >= _lineKeys.length || index == _lastCenteredIndex) {
      return;
    }
    _lastCenteredIndex = index;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) {
        return;
      }
      final lineContext = _lineKeys[index].currentContext;
      if (lineContext == null) {
        _lastCenteredIndex = -1;
        return;
      }
      Scrollable.ensureVisible(
        lineContext,
        alignment: 0.4,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.song == null) {
      return const _LyricsMessage(
        icon: Icons.lyrics_outlined,
        message: '选择歌曲后在这里显示歌词',
      );
    }
    if (widget.loading) {
      return const _LyricsMessage(loading: true, message: '正在加载歌词…');
    }
    if (widget.error != null && widget.lines.isEmpty) {
      return _LyricsMessage(
        icon: Icons.cloud_off_outlined,
        message: widget.error!,
      );
    }
    if (widget.lines.isEmpty) {
      final fallback = widget.lyric?.lyric.trim() ?? '';
      if (fallback.isEmpty) {
        return const _LyricsMessage(
          icon: Icons.lyrics_outlined,
          message: '暂无歌词',
        );
      }
      return ScrollConfiguration(
        behavior: const _HiddenScrollbarBehavior(),
        child: SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.only(top: 18, right: 20, bottom: 22),
          child: SelectableText(
            fallback,
            style: const TextStyle(
              color: AppColors.textSecondary,
              fontSize: 16,
              height: 1.85,
            ),
          ),
        ),
      );
    }

    return ScrollConfiguration(
      behavior: const _HiddenScrollbarBehavior(),
      child: SingleChildScrollView(
        key: const ValueKey<String>('now-playing-lyrics-scroll'),
        controller: _scrollController,
        padding: const EdgeInsets.only(top: 18, right: 20, bottom: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var index = 0; index < widget.lines.length; index++)
              _buildLine(index),
          ],
        ),
      ),
    );
  }

  Widget _buildLine(int index) {
    final line = widget.lines[index];
    final timestamp = line.timestamp;
    final translation = timestamp == null
        ? null
        : widget.translations[timestamp.inMilliseconds];
    final romanization = timestamp == null
        ? null
        : widget.romanizations[timestamp.inMilliseconds];
    final isActive = index == widget.activeIndex;
    final hasActiveLine = widget.activeIndex >= 0;
    return KeyedSubtree(
      key: _lineKeys[index],
      child: AnimatedOpacity(
        opacity: hasActiveLine && !isActive ? 0.48 : 1,
        duration: AppDurations.normal,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              AnimatedDefaultTextStyle(
                duration: AppDurations.normal,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: isActive
                      ? AppColors.lyricActive
                      : AppColors.textPrimary,
                  fontSize: isActive ? 22 : 17,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  height: 1.42,
                  letterSpacing: -0.12,
                ),
                child: Text(line.text, textAlign: TextAlign.center),
              ),
              if (translation?.trim().isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    translation!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFFB3BBC5),
                      fontSize: 13,
                      height: 1.45,
                    ),
                  ),
                ),
              if (romanization?.trim().isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    romanization!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textMuted,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                      height: 1.4,
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

class _HiddenScrollbarBehavior extends ScrollBehavior {
  const _HiddenScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return child;
  }
}

class _LyricsMessage extends StatelessWidget {
  const _LyricsMessage({
    required this.message,
    this.icon,
    this.loading = false,
  });

  final String message;
  final IconData? icon;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (loading)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.accent,
              ),
            )
          else
            Icon(icon ?? Icons.lyrics_outlined, size: 19),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: AppColors.textMuted, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

/// 黑胶唱片式专辑盘面，中心圆形封面随播放状态旋转。
class _AlbumDisc extends StatefulWidget {
  const _AlbumDisc({
    required this.song,
    required this.size,
    required this.isPlaying,
  });

  final Song? song;
  final double size;
  final bool isPlaying;

  @override
  State<_AlbumDisc> createState() => _AlbumDiscState();
}

class _AlbumDiscState extends State<_AlbumDisc>
    with SingleTickerProviderStateMixin {
  late final AnimationController _rotation = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 34),
  );

  @override
  void initState() {
    super.initState();
    _syncRotation(play: widget.isPlaying);
  }

  @override
  void didUpdateWidget(covariant _AlbumDisc oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isPlaying != widget.isPlaying) {
      _syncRotation(play: widget.isPlaying);
    }
  }

  @override
  void dispose() {
    _rotation.dispose();
    super.dispose();
  }

  void _syncRotation({required bool play}) {
    if (play) {
      _rotation.repeat();
    } else {
      _rotation.stop(canceled: false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox.square(
      key: const ValueKey<String>('now-playing-disc'),
      dimension: widget.size,
      child: RotationTransition(
        turns: _rotation,
        child: _DiscSurface(song: widget.song),
      ),
    );
  }
}

class _DiscSurface extends StatelessWidget {
  const _DiscSurface({required this.song});

  final Song? song;

  @override
  Widget build(BuildContext context) {
    final coverUrl = song?.coverUrl.trim() ?? '';
    return DecoratedBox(
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
            blurRadius: 60,
            offset: Offset(0, 28),
          ),
          BoxShadow(color: Color(0x3369DFA0), blurRadius: 80, spreadRadius: 12),
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
            widthFactor: 0.50,
            heightFactor: 0.50,
            child: ClipOval(
              child: coverUrl.isEmpty
                  ? const ColoredBox(
                      color: AppColors.surfaceHigh,
                      child: Icon(
                        Icons.album_rounded,
                        size: 64,
                        color: AppColors.textMuted,
                      ),
                    )
                  : Image.network(
                      coverUrl,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.medium,
                      errorBuilder: (_, _, _) => const ColoredBox(
                        color: AppColors.surfaceHigh,
                        child: Icon(
                          Icons.album_rounded,
                          size: 64,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
            ),
          ),
          FractionallySizedBox(
            widthFactor: 0.50,
            heightFactor: 0.50,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: const Color(0x66FFFFFF), width: 2),
                boxShadow: const <BoxShadow>[
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 18,
                    spreadRadius: 2,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
