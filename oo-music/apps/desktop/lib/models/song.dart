import 'music_source.dart';

/// 搜索结果或歌曲详情中的一首歌曲。
class Song {
  /// 创建歌曲模型。
  const Song({
    required this.id,
    required this.source,
    required this.mid,
    required this.name,
    required this.artists,
    required this.album,
    required this.albumMid,
    required this.coverUrl,
    required this.durationSeconds,
    required this.hasMv,
    this.mvVid = '',
    this.availableQualities = const <String>[],
  });

  /// 歌曲在所属平台内的数字 ID。
  final int id;

  /// 歌曲所属平台。
  final MusicSource source;

  /// QQ 音乐歌曲 MID；网易云为空。
  final String mid;

  /// 歌曲名。
  final String name;

  /// 歌手名列表。
  final List<String> artists;

  /// 专辑名。
  final String album;

  /// QQ 音乐专辑 MID；网易云为空。
  final String albumMid;

  /// 专辑封面 URL。
  final String coverUrl;

  /// 歌曲时长，单位为秒。
  final int durationSeconds;

  /// 是否有关联 MV。
  final bool hasMv;

  /// 平台 MV 标识；为空表示没有关联 MV。
  final String mvVid;

  /// 歌曲详情接口返回的可用音质。
  final List<String> availableQualities;

  /// 从后端 JSON 创建歌曲模型。
  factory Song.fromJson(Map<String, dynamic> json) {
    final rawArtists = json['artists'];
    final rawQualities = json['availableQualities'];
    return Song(
      id: _asInt(json['id']),
      source: MusicSourceDetails.fromStorage(json['source']?.toString()),
      mid: _asString(json['mid']),
      name: _asString(json['name']),
      artists: rawArtists is List
          ? rawArtists
                .map((artist) => artist.toString())
                .toList(growable: false)
          : const <String>[],
      album: _asString(json['album']),
      albumMid: _asString(json['albumMid']),
      coverUrl: _asString(json['coverUrl']),
      durationSeconds: _asInt(json['durationSeconds']),
      hasMv: json['hasMv'] == true,
      mvVid: _asString(json['mvVid']),
      availableQualities: rawQualities is List
          ? rawQualities
                .map((quality) => quality.toString())
                .where((quality) => quality.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
    );
  }

  /// 为暂时无法取得元数据的本地歌单项创建占位歌曲。
  factory Song.placeholder(int id, {required MusicSource source}) {
    return Song(
      id: id,
      source: source,
      mid: '',
      name: '歌曲 $id',
      artists: const <String>[],
      album: '',
      albumMid: '',
      coverUrl: '',
      durationSeconds: 0,
      hasMv: false,
      mvVid: '',
    );
  }

  /// 复制歌曲并替换可变字段。
  Song copyWith({
    MusicSource? source,
    String? mid,
    String? name,
    List<String>? artists,
    String? album,
    String? albumMid,
    String? coverUrl,
    int? durationSeconds,
    bool? hasMv,
    String? mvVid,
    List<String>? availableQualities,
  }) {
    return Song(
      id: id,
      source: source ?? this.source,
      mid: mid ?? this.mid,
      name: name ?? this.name,
      artists: artists ?? this.artists,
      album: album ?? this.album,
      albumMid: albumMid ?? this.albumMid,
      coverUrl: coverUrl ?? this.coverUrl,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      hasMv: hasMv ?? this.hasMv,
      mvVid: mvVid ?? this.mvVid,
      availableQualities: availableQualities ?? this.availableQualities,
    );
  }

  /// 用分隔符连接的歌手展示文本。
  String get artistText => artists.isEmpty ? '未知歌手' : artists.join(' / ');

  /// 歌曲时长。
  Duration get duration => Duration(seconds: durationSeconds);

  /// 跨平台唯一键；同一数字 ID 在 QQ 和网易云不会冲突。
  String get mediaKey => '${source.storageValue}:$id';
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

String _asString(Object? value) => value?.toString() ?? '';
