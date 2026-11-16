import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/client_account.dart';
import '../models/lyric.dart';
import '../models/mv.dart';
import '../models/music_source.dart';
import '../models/playback.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../platform/app_platform.dart';

/// 访问本地 oo-music Web 服务的客户端。
class MusicApi {
  /// 创建 API 客户端；默认连接本机 8787 端口。
  ///
  /// Android 模拟器使用 `10.0.2.2` 访问宿主机。真机或正式环境应通过
  /// `--dart-define=API_BASE_URL=...` 指向可访问的 HTTPS 后端。
  MusicApi({String? baseUrl, http.Client? client})
    : _baseUrl = (baseUrl ?? _defaultBaseUrl()).replaceFirst(RegExp(r'/$'), ''),
      _client = client ?? http.Client(),
      _ownsClient = client == null;

  static String _defaultBaseUrl() {
    final configured = const String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) {
      return configured;
    }
    if (AppPlatform.current == AppPlatformKind.android) {
      return 'http://10.0.2.2:8787';
    }
    return 'http://127.0.0.1:8787';
  }

  final String _baseUrl;
  final http.Client _client;
  final bool _ownsClient;
  MusicSource _activeSource = MusicSource.qq;
  final Map<MusicSource, ClientAccountSession?> _accounts =
      <MusicSource, ClientAccountSession?>{};

  /// 当前后端地址。
  String get baseUrl => _baseUrl;

  /// 设置当前界面平台及其账号；账号为空时保持该平台的匿名模式。
  void setActiveAccount(MusicSource source, ClientAccountSession? account) {
    _activeSource = source;
    setAccount(source, account);
  }

  /// 更新一个平台的本机账号，不影响另一个平台的当前账号。
  void setAccount(MusicSource source, ClientAccountSession? account) {
    if (account != null && account.source != source) {
      throw ArgumentError.value(
        account.source,
        'account.source',
        '账号平台与目标平台不一致',
      );
    }
    _accounts[source] = account;
  }

  /// 当前授权身份对应的请求头；未登录时为空。
  Map<String, String> get clientAuthorizationHeaders {
    return authorizationHeadersFor(_activeSource);
  }

  /// 指定平台请求应携带的授权头；无账号时仍携带平台标识以支持匿名请求。
  Map<String, String> authorizationHeadersFor(MusicSource source) {
    final account = _accounts[source];
    final headers = <String, String>{'X-OO-Music-Source': source.storageValue};
    if (account != null && account.source == source && account.canSwitch) {
      headers['X-OO-Music-Account-ID'] = account.accountId;
      headers['X-OO-Music-Access-Key'] = account.accessKey!.trim();
    }
    return headers;
  }

  /// 使用指定本地账号的账号 ID/accessKey 校验后端授权是否仍然有效。
  ///
  /// 成功时返回后端最新昵称和头像，并保留原 accessKey；HTTP 401 表示授权
  /// 或 QQ 音乐登录态已经失效，调用方应清除该账号本地的 accessKey。
  Future<ClientAccountSession> validateClientAccount(
    ClientAccountSession account,
  ) async {
    final accountID = account.accountId.trim();
    final accessKey = account.accessKey?.trim() ?? '';
    if (accountID.isEmpty || accessKey.isEmpty) {
      throw const MusicApiException('该账号授权已过期，请重新扫码授权', statusCode: 401);
    }
    final json = await _requestJson(
      httpMethod: 'GET',
      path: '/api/client/account',
      queryParameters: <String, String>{'source': account.source.storageValue},
      headers: <String, String>{
        'X-OO-Music-Source': account.source.storageValue,
        'X-OO-Music-Account-ID': accountID,
        'X-OO-Music-Access-Key': accessKey,
      },
    );
    final responseAccountID = json['accountId']?.toString().trim() ?? '';
    final responseNickname = json['nickname']?.toString().trim() ?? '';
    final responseAvatarUrl = json['avatarUrl']?.toString().trim() ?? '';
    return account.copyWith(
      accountId: responseAccountID.isEmpty ? accountID : responseAccountID,
      nickname: responseNickname.isEmpty ? account.nickname : responseNickname,
      avatarUrl: responseAvatarUrl.isEmpty
          ? account.avatarUrl
          : responseAvatarUrl,
    );
  }

  /// 创建指定平台的扫码登录会话。
  Future<MusicLoginSession> startLogin(MusicSource source) async {
    final json = await _requestJson(
      httpMethod: 'POST',
      path: '/api/client/login/sessions',
      queryParameters: <String, String>{'source': source.storageValue},
      headers: <String, String>{'X-OO-Music-Source': source.storageValue},
    );
    return MusicLoginSession.fromJson(json);
  }

  /// 查询指定平台的扫码会话状态。
  Future<MusicLoginSession> pollLogin(
    MusicSource source,
    String sessionId,
  ) async {
    final normalized = sessionId.trim();
    if (normalized.isEmpty) {
      throw const MusicApiException('扫码会话 ID 不能为空');
    }
    final json = await _requestJson(
      httpMethod: 'GET',
      path: '/api/client/login/sessions/${Uri.encodeComponent(normalized)}',
      queryParameters: <String, String>{'source': source.storageValue},
      headers: <String, String>{'X-OO-Music-Source': source.storageValue},
    );
    return MusicLoginSession.fromJson(json);
  }

  /// 取消并释放指定平台的后端扫码会话。
  Future<void> cancelLogin(MusicSource source, String sessionId) async {
    final normalized = sessionId.trim();
    if (normalized.isEmpty) {
      return;
    }
    await _requestJson(
      httpMethod: 'DELETE',
      path: '/api/client/login/sessions/${Uri.encodeComponent(normalized)}',
      queryParameters: <String, String>{'source': source.storageValue},
      headers: <String, String>{'X-OO-Music-Source': source.storageValue},
      allowEmpty: true,
    );
  }

  /// 把后端返回的相对路径解析为可直接请求的完整地址。
  String resolveUrl(String value) {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.hasScheme) {
      return uri.toString();
    }
    final base = Uri.parse(_baseUrl);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final relativePath = uri == null
        ? (value.startsWith('/') ? value : '/$value')
        : (uri.path.startsWith('/') ? uri.path : '/${uri.path}');
    return base
        .replace(
          path: '$basePath$relativePath',
          query: uri?.hasQuery == true ? uri!.query : null,
          fragment: uri?.hasFragment == true ? uri!.fragment : null,
        )
        .toString();
  }

  /// 搜索歌曲。
  Future<List<Song>> search(
    String query, {
    required MusicSource source,
    int page = 1,
    int pageSize = 30,
  }) async {
    final json = await _getJson(
      '/api/search',
      queryParameters: <String, String>{
        'source': source.storageValue,
        'q': query,
        'page': '$page',
        'page_size': '$pageSize',
      },
      headers: authorizationHeadersFor(source),
    );
    final items = json['items'];
    if (items is! List) {
      return const <Song>[];
    }
    return items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromJson)
        .toList(growable: false);
  }

  /// 批量查询歌曲详情和当前歌曲可用的音质。
  Future<List<Song>> tracks(MusicSource source, Iterable<int> songIds) async {
    final ids = songIds.where((id) => id > 0).toSet().toList(growable: false);
    if (ids.isEmpty) {
      return const <Song>[];
    }
    final json = await _getJson(
      '/api/tracks',
      queryParameters: <String, String>{
        'source': source.storageValue,
        'ids': ids.join(','),
      },
      headers: authorizationHeadersFor(source),
    );
    final items = json['items'];
    if (items is! List) {
      return const <Song>[];
    }
    return items
        .whereType<Map<String, dynamic>>()
        .map(Song.fromJson)
        .toList(growable: false);
  }

  /// 使用指定平台授权账号读取远程歌单。
  ///
  /// 请求显式携带账号 ID、平台和 accessKey。HTTP 401 表示授权或平台登录态
  /// 已经失效。
  Future<List<RemotePlaylistSnapshot>> remotePlaylists(
    ClientAccountSession account,
  ) async {
    final accessKey = account.accessKey?.trim() ?? '';
    if (!account.canSwitch || accessKey.isEmpty) {
      throw MusicApiException(
        '请先扫码授权${account.source.label}账号',
        statusCode: 401,
      );
    }
    final json = await _requestJson(
      httpMethod: 'GET',
      path: '/api/client/playlists',
      queryParameters: <String, String>{'source': account.source.storageValue},
      headers: <String, String>{
        'X-OO-Music-Source': account.source.storageValue,
        'X-OO-Music-Account-ID': account.accountId,
        'X-OO-Music-Access-Key': accessKey,
      },
    );
    final items = json['playlists'];
    if (items is! List) {
      return const <RemotePlaylistSnapshot>[];
    }
    final playlists = <RemotePlaylistSnapshot>[];
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        continue;
      }
      final id = item['id']?.toString().trim() ?? '';
      if (id.isEmpty) {
        continue;
      }
      final rawSongIds = item['songIds'];
      final songIds = rawSongIds is List
          ? rawSongIds
                .map((value) => int.tryParse(value.toString()) ?? 0)
                .where((value) => value > 0)
                .toList(growable: false)
          : const <int>[];
      playlists.add(
        RemotePlaylistSnapshot(
          id: id,
          source: MusicSourceDetails.fromStorage(item['source']?.toString()),
          name: item['name']?.toString().trim() ?? '',
          coverUrl: item['coverUrl']?.toString().trim() ?? '',
          songCount: int.tryParse(item['songCount']?.toString() ?? '') ?? 0,
          trackIds: songIds,
        ),
      );
    }
    return playlists;
  }

  /// 查询歌曲播放地址，默认请求稳定完整的 320 kbps MP3。
  ///
  /// [allowFallback] 为 false 时只尝试指定音质，用于用户主动切换音质，
  /// 避免界面显示切换成功但实际回退到了另一种音质。
  Future<PlaybackResult> playback(
    Song song, {
    String quality = '320mp3',
    bool allowFallback = true,
  }) async {
    final json = await _getJson(
      '/api/playback',
      queryParameters: <String, String>{
        'source': song.source.storageValue,
        'song_id': '${song.id}',
        'quality': quality,
        'allow_fallback': '$allowFallback',
      },
      headers: authorizationHeadersFor(song.source),
    );
    return PlaybackResult.fromJson(json);
  }

  /// 查询歌曲歌词、翻译和罗马音。
  Future<LyricData> lyrics(Song song) async {
    final json = await _getJson(
      '/api/lyrics',
      queryParameters: <String, String>{
        'source': song.source.storageValue,
        'song_id': '${song.id}',
        'mid': song.mid,
      },
      headers: authorizationHeadersFor(song.source),
    );
    return LyricData.fromJson(json);
  }

  /// 查询歌曲关联 MV 的元数据和播放地址。
  Future<MvData> mv(Song song) async {
    final json = await _getJson(
      '/api/mv',
      queryParameters: <String, String>{
        'source': song.source.storageValue,
        'song_id': '${song.id}',
        if (song.mvVid.trim().isNotEmpty) 'vid': song.mvVid,
      },
      headers: authorizationHeadersFor(song.source),
    );
    return MvData.fromJson(json);
  }

  Future<Map<String, dynamic>> _getJson(
    String path, {
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
  }) => _requestJson(
    httpMethod: 'GET',
    path: path,
    queryParameters: queryParameters,
    headers: headers,
  );

  Future<Map<String, dynamic>> _requestJson({
    required String httpMethod,
    required String path,
    Map<String, String>? queryParameters,
    Map<String, String>? headers,
    bool allowEmpty = false,
  }) async {
    final base = Uri.parse(_baseUrl);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final uri = base.replace(
      path: '$basePath$path',
      queryParameters: queryParameters,
    );

    http.Response response;
    try {
      final requestHeaders = <String, String>{
        'Accept': 'application/json',
        ...clientAuthorizationHeaders,
      };
      if (headers != null) {
        if (headers.containsKey('X-OO-Music-Source')) {
          requestHeaders.remove('X-OO-Music-Account-ID');
          requestHeaders.remove('X-OO-Music-Access-Key');
        }
        requestHeaders.addAll(headers);
      }
      final future = switch (httpMethod) {
        'POST' => _client.post(uri, headers: requestHeaders),
        'DELETE' => _client.delete(uri, headers: requestHeaders),
        _ => _client.get(uri, headers: requestHeaders),
      };
      response = await future.timeout(const Duration(seconds: 35));
    } on TimeoutException {
      throw const MusicApiException('请求超时，请检查后端服务和网络连接');
    } on http.ClientException {
      throw MusicApiException('无法连接后端服务：$_baseUrl');
    }

    Map<String, dynamic>? body;
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map<String, dynamic>) {
        body = decoded;
      }
    } on FormatException {
      body = null;
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = body?['error'];
      final message = error is Map<String, dynamic>
          ? error['message']?.toString()
          : null;
      throw MusicApiException(
        message?.isNotEmpty == true
            ? message!
            : '请求失败（HTTP ${response.statusCode}）',
        statusCode: response.statusCode,
      );
    }
    if (allowEmpty && response.bodyBytes.isEmpty) {
      return <String, dynamic>{};
    }
    if (body == null) {
      throw const MusicApiException('后端返回了无法解析的数据');
    }
    return body;
  }

  /// 释放客户端内部持有的 HTTP 连接。
  void close() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

/// 本地音乐服务调用失败。
class MusicApiException implements Exception {
  /// 创建 API 异常。
  const MusicApiException(this.message, {this.statusCode});

  /// 可直接展示给用户的错误描述。
  final String message;

  /// 后端 HTTP 状态码。
  final int? statusCode;

  @override
  String toString() => message;
}
