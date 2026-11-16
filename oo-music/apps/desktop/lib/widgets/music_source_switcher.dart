import 'package:flutter/material.dart';

import '../models/client_account.dart';
import '../models/music_source.dart';
import '../theme/app_theme.dart';

/// 左上角使用的 QQ 音乐 / 网易云音乐平台切换控件。
class MusicSourceSwitcher extends StatelessWidget {
  const MusicSourceSwitcher({
    super.key,
    required this.selected,
    required this.qqAccount,
    required this.neteaseAccount,
    required this.onChanged,
    this.compact = false,
  });

  final MusicSource selected;
  final ClientAccountSession? qqAccount;
  final ClientAccountSession? neteaseAccount;
  final ValueChanged<MusicSource> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey<String>('music-source-switcher'),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: AppColors.surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _buildSource(source: MusicSource.qq, account: qqAccount),
          _buildSource(source: MusicSource.netease, account: neteaseAccount),
        ],
      ),
    );
  }

  Widget _buildSource({
    required MusicSource source,
    required ClientAccountSession? account,
  }) {
    final active = selected == source;
    return Semantics(
      button: true,
      selected: active,
      label: '切换到${source.label}',
      child: InkWell(
        key: ValueKey<String>('music-source-${source.storageValue}'),
        onTap: () => onChanged(source),
        borderRadius: BorderRadius.circular(9),
        child: AnimatedContainer(
          duration: AppDurations.fast,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 9 : 12,
            vertical: compact ? 7 : 8,
          ),
          decoration: BoxDecoration(
            color: active ? AppColors.accent : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                source == MusicSource.qq
                    ? Icons.music_note_rounded
                    : Icons.cloud_rounded,
                size: compact ? 14 : 15,
                color: active ? AppColors.accentOn : AppColors.textMuted,
              ),
              const SizedBox(width: 5),
              Text(
                source.shortLabel,
                style: TextStyle(
                  color: active ? AppColors.accentOn : AppColors.textSecondary,
                  fontSize: compact ? 11 : 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (account?.canSwitch == true) ...<Widget>[
                const SizedBox(width: 5),
                Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: active ? AppColors.accentOn : AppColors.accent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
