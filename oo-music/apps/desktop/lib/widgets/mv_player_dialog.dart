import 'dart:async';

import 'package:flutter/material.dart';

import '../api/music_api.dart';
import '../models/music_source.dart';
import '../models/mv.dart';
import '../models/song.dart';
import '../platform/app_platform.dart';
import '../platform/mv_playback_driver.dart';
import '../platform/mv_playback_driver_factory.dart';
import '../theme/app_theme.dart';

/// 创建一次 MV 播放驱动的工厂；测试和平台扩展时可以注入自定义实现。
typedef MvPlaybackDriverFactory = MvPlaybackDriver Function();

/// 在弹窗中加载并播放歌曲关联的 MV。
class MvPlayerDialog extends StatefulWidget {
  /// 创建 MV 播放弹窗。
  const MvPlayerDialog({
    super.key,
    required this.api,
    required this.song,
    this.driverFactory,
  });

  /// 本地音乐 API。
  final MusicApi api;

  /// 当前要播放 MV 的歌曲。
  final Song song;

  /// 可选的 MV 播放驱动工厂。
  final MvPlaybackDriverFactory? driverFactory;

  @override
  State<MvPlayerDialog> createState() => _MvPlayerDialogState();
}

class _MvPlayerDialogState extends State<MvPlayerDialog> {
  MvPlaybackDriver? _driver;
  MvData? _data;
  String? _error;
  bool _loading = true;
  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final generation = ++_loadGeneration;
    final previous = _driver;
    previous?.removeListener(_handleDriverChanged);
    previous?.dispose();
    if (!mounted || generation != _loadGeneration) {
      return;
    }

    final driver = (widget.driverFactory ?? createMvPlaybackDriver)();
    driver.addListener(_handleDriverChanged);
    setState(() {
      _driver = driver;
      _data = null;
      _loading = true;
      _error = null;
    });

    try {
      final data = await widget.api.mv(widget.song);
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      if (!data.available || data.url.trim().isEmpty) {
        throw MusicApiException(data.reasonLabel);
      }
      await driver.initialize(
        uri: Uri.parse(data.url),
        httpHeaders: <String, String>{
          'Referer': widget.song.source.referer,
          'User-Agent': AppPlatform.networkUserAgent,
        },
      );
      if (!mounted || generation != _loadGeneration) return;
      await driver.play();
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      setState(() {
        _data = data;
        _loading = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _loadGeneration) {
        return;
      }
      driver.removeListener(_handleDriverChanged);
      driver.dispose();
      setState(() {
        _driver = null;
        _error = switch (error) {
          MusicApiException() => error.message,
          MvPlaybackUnavailableException() => error.message,
          _ => 'MV 加载失败，请重试或检查网络连接',
        };
        _loading = false;
      });
    }
  }

  void _handleDriverChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _loadGeneration++;
    final driver = _driver;
    driver?.removeListener(_handleDriverChanged);
    if (driver != null) {
      driver.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final availableHeight = (MediaQuery.sizeOf(context).height - 40).clamp(
      360.0,
      760.0,
    );
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: 920, maxHeight: availableHeight),
        child: DecoratedBox(
          decoration: appDialogDecoration(),
          child: SizedBox(
            width: double.infinity,
            height: availableHeight,
            child: Column(
              children: <Widget>[
                _header(),
                const Divider(height: 1, color: AppColors.border),
                Expanded(child: _body()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final title = _data?.name.trim().isNotEmpty == true
        ? _data!.name
        : '${widget.song.name} · MV';
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 12, 14),
      child: Row(
        children: <Widget>[
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: AppColors.warningSurface,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: AppColors.warningBorder),
            ),
            alignment: Alignment.center,
            child: const Text(
              'MV',
              style: TextStyle(
                color: AppColors.warning,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  widget.song.artistText,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            key: const ValueKey<String>('close-mv-dialog'),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 58,
              height: 58,
              decoration: BoxDecoration(
                color: AppColors.surfaceRaised,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.border),
              ),
              alignment: Alignment.center,
              child: const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              ),
            ),
            const SizedBox(height: 13),
            const Text(
              '正在加载 MV…',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
          ],
        ),
      );
    }
    final playbackError = _error ?? _driver?.snapshot.error;
    if (playbackError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 410),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: AppColors.errorSurface,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: AppColors.errorBorder),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  const Icon(
                    Icons.video_file_outlined,
                    size: 42,
                    color: AppColors.error,
                  ),
                  const SizedBox(height: 13),
                  const Text(
                    'MV 加载失败',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Text(
                    playbackError,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: AppColors.textSecondary,
                      fontSize: 12,
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _load,
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final driver = _driver;
    if (driver == null || !driver.snapshot.initialized) {
      return const Center(child: Text('MV 播放器尚未就绪'));
    }
    return _MvSurface(driver: driver, data: _data);
  }
}

class _MvSurface extends StatefulWidget {
  const _MvSurface({required this.driver, required this.data});

  final MvPlaybackDriver driver;
  final MvData? data;

  @override
  State<_MvSurface> createState() => _MvSurfaceState();
}

class _MvSurfaceState extends State<_MvSurface> {
  double? _dragMilliseconds;

  @override
  Widget build(BuildContext context) {
    final state = widget.driver.snapshot;
    final durationMilliseconds = state.duration.inMilliseconds;
    final maxMilliseconds = durationMilliseconds > 0
        ? durationMilliseconds.toDouble()
        : 1.0;
    final positionMilliseconds = state.position.inMilliseconds
        .clamp(0, durationMilliseconds)
        .toDouble();
    final sliderValue = (_dragMilliseconds ?? positionMilliseconds).clamp(
      0.0,
      maxMilliseconds,
    );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Flexible(
          child: ColoredBox(
            color: Colors.black,
            child: Center(
              child: AspectRatio(
                aspectRatio: state.aspectRatio,
                child: widget.driver.buildView(),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 18, 10),
          child: Row(
            children: <Widget>[
              IconButton(
                tooltip: state.playing ? '暂停' : '播放',
                onPressed: () {
                  if (state.playing) {
                    unawaited(widget.driver.pause());
                  } else {
                    unawaited(widget.driver.play());
                  }
                },
                icon: Icon(
                  state.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                ),
              ),
              Expanded(
                child: Slider(
                  min: 0,
                  max: maxMilliseconds,
                  value: sliderValue,
                  onChanged: durationMilliseconds <= 0
                      ? null
                      : (value) => setState(() => _dragMilliseconds = value),
                  onChangeEnd: durationMilliseconds <= 0
                      ? null
                      : (value) {
                          setState(() => _dragMilliseconds = null);
                          unawaited(
                            widget.driver.seek(
                              Duration(milliseconds: value.round()),
                            ),
                          );
                        },
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_format(Duration(milliseconds: sliderValue.round()))} / '
                '${_format(state.duration)}',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                  fontFeatures: <FontFeature>[FontFeature.tabularFigures()],
                ),
              ),
              if ((widget.data?.description ?? '')
                  .trim()
                  .isNotEmpty) ...<Widget>[
                const SizedBox(width: 14),
                Tooltip(
                  message: widget.data!.description,
                  child: const Icon(
                    Icons.info_outline_rounded,
                    size: 18,
                    color: AppColors.textDisabled,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  String _format(Duration duration) {
    final total = duration.inSeconds.clamp(0, 359999);
    final minutes = total ~/ 60;
    final seconds = total % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }
}
