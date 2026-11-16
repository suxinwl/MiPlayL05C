import 'music_source.dart';

/// 播放与音质菜单使用的稳定音质展示顺序。
const List<String> supportedQualityOrder = <String>[
  'master',
  'flac',
  '320mp3',
  '192mp3',
  '128mp3',
  '96aac',
];

/// 将后端音质标识转换为界面文案。
String formatQualityLabel(String quality) {
  return switch (quality) {
    'master' => '臻品母带',
    'flac' => 'FLAC 无损',
    '320mp3' => '320 kbps',
    '192mp3' => '192 kbps',
    '128mp3' => '128 kbps',
    '96aac' => 'AAC 96 kbps',
    _ => quality.isEmpty ? '未知音质' : quality,
  };
}

/// 一次音质尝试的结果。
class PlaybackAttempt {
  /// 创建音质尝试结果。
  const PlaybackAttempt({required this.quality, required this.reason});

  /// 尝试的音质标识。
  final String quality;

  /// 未取得播放地址时的原因。
  final String reason;

  /// 从后端 JSON 创建音质尝试结果。
  factory PlaybackAttempt.fromJson(Map<String, dynamic> json) {
    return PlaybackAttempt(
      quality: json['quality']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
    );
  }
}

/// 后端返回的歌曲播放信息。
class PlaybackResult {
  /// 创建播放信息。
  const PlaybackResult({
    required this.songId,
    required this.source,
    required this.available,
    required this.url,
    required this.quality,
    required this.reason,
    required this.attempts,
  });

  /// 歌曲 ID。
  final int songId;

  /// 播放结果所属平台。
  final MusicSource source;

  /// 是否取得了可播放地址。
  final bool available;

  /// 可播放的媒体 URL。
  final String url;

  /// 实际取得的音质。
  final String quality;

  /// 不可播放时的原因。
  final String reason;

  /// 音质回退诊断。
  final List<PlaybackAttempt> attempts;

  /// 从后端 JSON 创建播放信息。
  factory PlaybackResult.fromJson(Map<String, dynamic> json) {
    final rawAttempts = json['attempts'];
    return PlaybackResult(
      songId: _asInt(json['songId']),
      source: MusicSourceDetails.fromStorage(json['source']?.toString()),
      available: json['available'] == true,
      url: json['url']?.toString() ?? '',
      quality: json['quality']?.toString() ?? '',
      reason: json['reason']?.toString() ?? '',
      attempts: rawAttempts is List
          ? rawAttempts
                .whereType<Map<String, dynamic>>()
                .map(PlaybackAttempt.fromJson)
                .toList(growable: false)
          : const <PlaybackAttempt>[],
    );
  }

  /// 面向界面的音质名称。
  String get qualityLabel => formatQualityLabel(quality);

  /// 面向界面的不可播放原因。
  String get reasonLabel {
    switch (reason) {
      case 'NO_VS':
        return '歌曲缺少播放文件标识';
      case 'NO_PLAYABLE_QUALITY':
        return '当前账号没有可用音质';
      case 'NO_VALID_AUDIO_SOURCE':
        return '当前平台源文件不存在或已下架，请尝试其他版本';
      case 'REQUEST_FAILED':
        return '播放地址请求失败';
      case '':
        return '当前歌曲不可播放';
      default:
        return reason;
    }
  }
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
