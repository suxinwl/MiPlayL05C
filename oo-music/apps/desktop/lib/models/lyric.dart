import 'music_source.dart';

/// 后端返回的歌词、翻译和罗马音数据。
class LyricData {
  /// 创建歌词数据模型。
  const LyricData({
    required this.songId,
    required this.source,
    required this.songMid,
    required this.title,
    required this.artist,
    required this.lyric,
    required this.translation,
    required this.romanization,
  });

  /// 歌曲 ID。
  final int songId;

  /// 歌词所属平台。
  final MusicSource source;

  /// 歌曲 MID。
  final String songMid;

  /// 歌词接口返回的歌曲名。
  final String title;

  /// 歌词接口返回的歌手名。
  final String artist;

  /// LRC 原文。
  final String lyric;

  /// LRC 翻译。
  final String translation;

  /// LRC 罗马音。
  final String romanization;

  /// 从后端 JSON 创建歌词数据。
  factory LyricData.fromJson(Map<String, dynamic> json) {
    return LyricData(
      songId: _asInt(json['songId']),
      source: MusicSourceDetails.fromStorage(json['source']?.toString()),
      songMid: json['songMid']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      artist: json['artist']?.toString() ?? '',
      lyric: json['lyric']?.toString() ?? '',
      translation: json['translation']?.toString() ?? '',
      romanization: json['romanization']?.toString() ?? '',
    );
  }

  /// 是否至少包含一种歌词内容。
  bool get hasContent =>
      lyric.trim().isNotEmpty ||
      translation.trim().isNotEmpty ||
      romanization.trim().isNotEmpty;
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
