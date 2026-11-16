import 'music_source.dart';

/// 客户端本地保存的音乐平台授权账号。
///
/// 一个账号记录只保存后端生成的 accessKey 和用于展示的公开资料，绝不保存
/// qmKeyst、Cookie 等 QQ 音乐登录凭据。accessKey 为空时记录仍然保留，但用户
/// 不能切换到这个账号，只能删除或重新扫码授权。
class ClientAccountSession {
  /// 创建客户端本地授权账号。
  const ClientAccountSession({
    required this.accountId,
    required this.accessKey,
    required this.source,
    this.nickname = '',
    this.avatarUrl = '',
    this.updatedAt,
  });

  /// 平台账号 ID；该值只会展示给完成授权的本机用户。
  final String accountId;

  /// 账号所属平台。
  final MusicSource source;

  /// 后端生成的客户端授权密钥；授权失效后会被清空。
  final String? accessKey;

  /// 平台用户昵称。
  final String nickname;

  /// 平台用户头像地址。
  final String avatarUrl;

  /// 本地记录最近更新时间。
  final DateTime? updatedAt;

  /// 是否拥有可用于切换账号的有效授权密钥。
  bool get canSwitch => accessKey?.trim().isNotEmpty == true;

  /// 适合在按钮和列表中展示的名称。
  String get displayName {
    final value = nickname.trim();
    return value.isEmpty ? accountId : value;
  }

  /// 根据昵称生成头像加载失败时的占位文字。
  String get avatarFallbackText {
    final value = nickname.trim();
    if (value.isEmpty) {
      return source.avatarFallbackText;
    }
    return String.fromCharCode(value.runes.first);
  }

  /// 复制账号字段；需要清空 accessKey 时使用 [withoutAccessKey]。
  ClientAccountSession copyWith({
    String? accountId,
    String? accessKey,
    MusicSource? source,
    String? nickname,
    String? avatarUrl,
    DateTime? updatedAt,
  }) {
    return ClientAccountSession(
      accountId: accountId ?? this.accountId,
      accessKey: accessKey ?? this.accessKey,
      source: source ?? this.source,
      nickname: nickname ?? this.nickname,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// 仅清除授权密钥，保留账号资料和本地记录。
  ClientAccountSession withoutAccessKey() {
    return ClientAccountSession(
      accountId: accountId,
      accessKey: null,
      source: source,
      nickname: nickname,
      avatarUrl: avatarUrl,
      updatedAt: updatedAt,
    );
  }
}

/// 后端返回的音乐平台扫码会话状态。
class MusicLoginSession {
  /// 创建扫码会话状态。
  const MusicLoginSession({
    required this.sessionId,
    required this.status,
    required this.message,
    required this.source,
    this.expiresAt,
    this.imageUrl = '',
    this.accountId = '',
    this.accessKey = '',
    this.nickname = '',
    this.avatarUrl = '',
  });

  /// 从后端 JSON 创建扫码会话状态。
  factory MusicLoginSession.fromJson(Map<String, dynamic> json) {
    final responseAccountID = json['accountId']?.toString().trim() ?? '';
    return MusicLoginSession(
      sessionId: json['sessionId']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      message: json['message']?.toString() ?? '',
      source: MusicSourceDetails.fromStorage(json['source']?.toString()),
      expiresAt: DateTime.tryParse(json['expiresAt']?.toString() ?? ''),
      imageUrl: json['imageUrl']?.toString() ?? '',
      accountId: responseAccountID,
      accessKey: json['accessKey']?.toString() ?? '',
      nickname: json['nickname']?.toString() ?? '',
      avatarUrl: json['avatarUrl']?.toString() ?? '',
    );
  }

  /// 不透明会话 ID。
  final String sessionId;

  /// waiting、scanned、completed、expired、rejected、canceled 或 error。
  final String status;

  /// 适合直接展示的状态说明。
  final String message;

  /// 当前扫码会话所属平台。
  final MusicSource source;

  /// 二维码会话过期时间。
  final DateTime? expiresAt;

  /// 当前会话稳定的二维码图片地址。
  final String imageUrl;

  /// 登录完成后的平台账号 ID。
  final String accountId;

  /// 登录完成后的客户端授权密钥。
  final String accessKey;

  /// 登录完成后的平台昵称。
  final String nickname;

  /// 登录完成后的平台头像地址。
  final String avatarUrl;

  /// 在轮询时保留创建会话阶段已经取得的字段。
  MusicLoginSession copyWith({
    String? sessionId,
    String? status,
    String? message,
    MusicSource? source,
    DateTime? expiresAt,
    String? imageUrl,
    String? accountId,
    String? accessKey,
    String? nickname,
    String? avatarUrl,
  }) {
    return MusicLoginSession(
      sessionId: sessionId ?? this.sessionId,
      status: status ?? this.status,
      message: message ?? this.message,
      source: source ?? this.source,
      expiresAt: expiresAt ?? this.expiresAt,
      imageUrl: imageUrl ?? this.imageUrl,
      accountId: accountId ?? this.accountId,
      accessKey: accessKey ?? this.accessKey,
      nickname: nickname ?? this.nickname,
      avatarUrl: avatarUrl ?? this.avatarUrl,
    );
  }

  /// 登录完成时返回本地可持久化的账号；其他状态返回空。
  ClientAccountSession? get account {
    if (status != 'completed' || accountId.isEmpty || accessKey.isEmpty) {
      return null;
    }
    return ClientAccountSession(
      accountId: accountId,
      accessKey: accessKey,
      source: source,
      nickname: nickname,
      avatarUrl: avatarUrl,
    );
  }
}
