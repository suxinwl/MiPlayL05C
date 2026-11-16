import 'package:flutter/material.dart';

import '../lyrics/lrc_parser.dart';
import '../models/lyric.dart';
import '../models/song.dart';
import '../theme/app_theme.dart';

/// 展示当前歌曲歌词并跟随播放进度滚动。
class LyricsPanel extends StatefulWidget {
  /// 创建歌词面板。
  const LyricsPanel({
    super.key,
    required this.song,
    required this.lyric,
    required this.lines,
    required this.translations,
    required this.romanizations,
    required this.activeIndex,
    required this.loading,
    required this.error,
  });

  /// 当前歌曲。
  final Song? song;

  /// 后端返回的完整歌词数据。
  final LyricData? lyric;

  /// 解析后的原文歌词。
  final List<LrcLine> lines;

  /// 按时间戳索引的翻译歌词。
  final Map<int, String> translations;

  /// 按时间戳索引的罗马音歌词。
  final Map<int, String> romanizations;

  /// 当前应高亮的歌词行。
  final int activeIndex;

  /// 是否正在加载歌词。
  final bool loading;

  /// 歌词加载错误。
  final String? error;

  @override
  State<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<LyricsPanel> {
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
  void didUpdateWidget(covariant LyricsPanel oldWidget) {
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
      final context = _lineKeys[index].currentContext;
      if (context == null) {
        _lastCenteredIndex = -1;
        return;
      }
      Scrollable.ensureVisible(
        context,
        alignment: 0.42,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: appPanelDecoration(color: AppColors.surface),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.panel),
        child: Column(
          children: <Widget>[
            DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[Color(0x1F69DFA0), Colors.transparent],
                ),
              ),
              child: _LyricsHeader(song: widget.song, lyric: widget.lyric),
            ),
            const Divider(height: 1, color: AppColors.border),
            Expanded(child: _buildBody(theme)),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    if (widget.song == null) {
      return const _LyricsEmptyState(
        icon: Icons.queue_music_rounded,
        title: '歌词将在这里显示',
        description: '从左侧选择一首歌曲开始播放',
      );
    }
    if (widget.loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 26,
              height: 26,
              child: CircularProgressIndicator(
                strokeWidth: 2.2,
                color: AppColors.accent,
              ),
            ),
            SizedBox(height: AppSpacing.md),
            Text(
              '正在加载歌词…',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      );
    }
    if (widget.error != null && widget.lines.isEmpty) {
      return _LyricsEmptyState(
        icon: Icons.cloud_off_rounded,
        title: '歌词加载失败',
        description: widget.error!,
      );
    }
    if (widget.lines.isEmpty) {
      final fallback = widget.lyric?.lyric.trim() ?? '';
      if (fallback.isNotEmpty) {
        return SingleChildScrollView(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 48),
          child: SelectableText(
            fallback,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyLarge?.copyWith(
              color: AppColors.textSecondary,
              height: 1.8,
            ),
          ),
        );
      }
      return const _LyricsEmptyState(
        icon: Icons.lyrics_outlined,
        title: '暂无歌词',
        description: '这首歌曲暂时没有返回歌词内容',
      );
    }

    // 歌词行总量很小，全部预构建后才能可靠地滚动到屏幕外的当前行。
    return SingleChildScrollView(
      key: const ValueKey<String>('lyrics-panel-scroll'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(26, 78, 26, 120),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (var index = 0; index < widget.lines.length; index++)
            _buildLine(theme, index),
        ],
      ),
    );
  }

  Widget _buildLine(ThemeData theme, int index) {
    final line = widget.lines[index];
    final timestamp = line.timestamp;
    final translation = timestamp == null
        ? null
        : widget.translations[timestamp.inMilliseconds];
    final romanization = timestamp == null
        ? null
        : widget.romanizations[timestamp.inMilliseconds];
    final isActive = index == widget.activeIndex;
    final dimmed = widget.activeIndex >= 0 && !isActive;
    return KeyedSubtree(
      key: _lineKeys[index],
      child: AnimatedOpacity(
        opacity: dimmed ? 0.52 : 1,
        duration: AppDurations.normal,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Text(
                line.text,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium?.copyWith(
                  color: isActive
                      ? AppColors.lyricActive
                      : AppColors.textPrimary,
                  fontSize: isActive ? 21 : 18,
                  fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                  height: 1.45,
                ),
              ),
              if (translation?.trim().isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    translation!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.lyricTranslation,
                      height: 1.4,
                    ),
                  ),
                ),
              if (romanization?.trim().isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    romanization!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.lyricRomanization,
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

class _LyricsHeader extends StatelessWidget {
  const _LyricsHeader({required this.song, required this.lyric});

  final Song? song;
  final LyricData? lyric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 82,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(
          children: <Widget>[
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: song?.coverUrl.isNotEmpty == true
                  ? Image.network(
                      song!.coverUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.music_note_rounded,
                        color: AppColors.textMuted,
                      ),
                    )
                  : const Icon(
                      Icons.music_note_rounded,
                      color: AppColors.textMuted,
                    ),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    song?.name ?? '歌词',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    song?.artistText ?? '同步歌词与翻译',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            const _LiveBadge(),
          ],
        ),
      ),
    );
  }
}

class _LiveBadge extends StatelessWidget {
  const _LiveBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadii.pill),
        border: Border.all(color: AppColors.accentBorder),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 6,
            height: 6,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: AppColors.accent,
                shape: BoxShape.circle,
              ),
            ),
          ),
          SizedBox(width: 6),
          Text(
            '同步歌词',
            style: TextStyle(
              color: AppColors.accentStrong,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _LyricsEmptyState extends StatelessWidget {
  const _LyricsEmptyState({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: AppColors.surfaceHigh,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.border),
              ),
              child: Icon(icon, size: 27, color: AppColors.textMuted),
            ),
            const SizedBox(height: 15),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 7),
            Text(
              description,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textMuted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
