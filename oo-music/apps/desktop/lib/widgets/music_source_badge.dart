import 'package:flutter/material.dart';

import '../models/music_source.dart';

/// 歌曲或队列条目上的平台来源标识。
class MusicSourceBadge extends StatelessWidget {
  const MusicSourceBadge({
    super.key,
    required this.source,
    this.compact = false,
  });

  final MusicSource source;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = source == MusicSource.qq
        ? const Color(0xFF4CB9FF)
        : const Color(0xFFFF6B73);
    return Container(
      key: ValueKey<String>('source-badge-${source.storageValue}'),
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 5 : 6,
        vertical: compact ? 1 : 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        source == MusicSource.qq ? 'QQ' : '网易云',
        style: TextStyle(
          color: color,
          fontSize: compact ? 8.5 : 9.5,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}
