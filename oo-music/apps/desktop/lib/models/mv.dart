import 'music_source.dart';

/// 一首歌曲关联 MV 的元数据和播放地址。
class MvData {
  /// 创建 MV 数据模型。
  const MvData({
    required this.songId,
    required this.source,
    required this.vid,
    required this.available,
    required this.url,
    required this.name,
    required this.description,
    required this.coverUrl,
    required this.durationSeconds,
    required this.fileType,
    required this.fileSize,
    required this.reason,
  });

  /// 关联歌曲 ID；仅通过 VID 查询时为 0。
  final int songId;

  /// MV 所属平台。
  final MusicSource source;

  /// 平台 MV 标识。
  final String vid;

  /// 服务端是否返回了可播放地址。
  final bool available;

  /// MV 播放 URL。
  final String url;

  /// MV 标题。
  final String name;

  /// MV 描述。
  final String description;

  /// MV 封面 URL。
  final String coverUrl;

  /// MV 时长，单位为秒。
  final int durationSeconds;

  /// QQ 音乐清晰度档位。
  final int fileType;

  /// 文件大小，单位为字节。
  final int fileSize;

  /// 不可播放时的原因。
  final String reason;

  /// 从后端 JSON 创建 MV 数据。
  factory MvData.fromJson(Map<String, dynamic> json) {
    return MvData(
      songId: _asInt(json['songId']),
      source: MusicSourceDetails.fromStorage(json['source']?.toString()),
      vid: json['vid']?.toString() ?? '',
      available: json['available'] == true,
      url: json['url']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      coverUrl: json['coverUrl']?.toString() ?? '',
      durationSeconds: _asInt(json['durationSeconds']),
      fileType: _asInt(json['fileType']),
      fileSize: _asInt(json['fileSize']),
      reason: json['reason']?.toString() ?? '',
    );
  }

  /// 面向界面的不可播放原因。
  String get reasonLabel =>
      reason.isEmpty ? '当前 MV 暂时无法播放，可能受版权或账号权限限制' : reason;
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
