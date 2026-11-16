/// 当前客户端支持的音乐平台。
enum MusicSource { qq, netease }

/// 平台在存储、接口和界面中的稳定表示。
extension MusicSourceDetails on MusicSource {
  /// 后端和 SQLite 使用的稳定值。
  String get storageValue => switch (this) {
    MusicSource.qq => 'qq',
    MusicSource.netease => 'netease',
  };

  /// 完整平台名称。
  String get label => switch (this) {
    MusicSource.qq => 'QQ 音乐',
    MusicSource.netease => '网易云音乐',
  };

  /// 紧凑平台名称。
  String get shortLabel => switch (this) {
    MusicSource.qq => 'QQ',
    MusicSource.netease => '网易云',
  };

  /// 音频、MV 和下载请求使用的来源站点。
  String get referer => switch (this) {
    MusicSource.qq => 'https://y.qq.com/',
    MusicSource.netease => 'https://music.163.com/',
  };

  /// 头像资料为空时使用的占位文字。
  String get avatarFallbackText => switch (this) {
    MusicSource.qq => 'Q',
    MusicSource.netease => '网',
  };

  /// 从数据库或接口字段恢复平台；缺失或未知值视为数据错误。
  static MusicSource fromStorage(String? value) {
    return switch (value?.trim().toLowerCase()) {
      'qq' => MusicSource.qq,
      'netease' => MusicSource.netease,
      _ => throw FormatException('无效的音乐平台: ${value ?? ''}'),
    };
  }
}
