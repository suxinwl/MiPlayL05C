import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:oo_music/api/music_api.dart';
import 'package:oo_music/models/client_account.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/models/song.dart';

void main() {
  test('相对地址保留查询参数并支持 API 子路径', () {
    final api = MusicApi(baseUrl: 'https://music.test/backend');
    final resolved = api.resolveUrl(
      '/api/client/login/sessions/session/image?source=qq',
    );
    expect(
      resolved,
      'https://music.test/backend/api/client/login/sessions/session/image?source=qq',
    );

    final absolute = api.resolveUrl('https://cdn.test/qr.png?token=abc');
    expect(absolute, 'https://cdn.test/qr.png?token=abc');
  });

  test('校验账号时发送授权头并保留空响应中的本地资料', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/client/account');
      expect(request.url.queryParameters['source'], 'qq');
      expect(request.headers['X-OO-Music-Source'], 'qq');
      expect(request.headers['X-OO-Music-Account-ID'], '209192670');
      expect(request.headers['X-OO-Music-Access-Key'], 'access-key');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'accountId': '',
          'nickname': '',
          'avatarUrl': '',
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    const account = ClientAccountSession(
      source: MusicSource.qq,
      accountId: '209192670',
      accessKey: 'access-key',
      nickname: '本地昵称',
      avatarUrl: 'https://example.com/avatar.png',
    );

    final validated = await api.validateClientAccount(account);

    expect(validated.accountId, account.accountId);
    expect(validated.accessKey, account.accessKey);
    expect(validated.nickname, account.nickname);
    expect(validated.avatarUrl, account.avatarUrl);
  });

  test('校验账号使用后端返回的最新昵称和头像', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'accountId': '209192670',
          'nickname': '最新昵称',
          'avatarUrl': 'https://example.com/latest.png',
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    const account = ClientAccountSession(
      source: MusicSource.qq,
      accountId: '209192670',
      accessKey: 'access-key',
      nickname: '旧昵称',
      avatarUrl: 'https://example.com/old.png',
    );

    final validated = await api.validateClientAccount(account);

    expect(validated.nickname, '最新昵称');
    expect(validated.avatarUrl, 'https://example.com/latest.png');
  });

  test('后端返回 401 时抛出可识别的授权过期异常', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'error': <String, dynamic>{'message': '客户端授权已失效'},
        }),
        401,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);

    expect(
      () => api.validateClientAccount(
        const ClientAccountSession(
          source: MusicSource.qq,
          accountId: '209192670',
          accessKey: 'expired-key',
        ),
      ),
      throwsA(
        isA<MusicApiException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => error.message, 'message', '客户端授权已失效'),
      ),
    );
  });

  test('刷新远程歌单时携带当前账号授权头并解析歌单快照', () async {
    final client = MockClient((request) async {
      expect(request.method, 'GET');
      expect(request.url.path, '/api/client/playlists');
      expect(request.headers['X-OO-Music-Account-ID'], '209192670');
      expect(request.headers['X-OO-Music-Access-Key'], 'access-key');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'playlists': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': '735123',
              'source': 'qq',
              'name': '通勤',
              'coverUrl': 'https://example.com/cover.jpg',
              'songCount': 2,
              'songIds': <dynamic>[101, '202', 0],
              'qmKeyst': 'must-not-be-consumed',
            },
            <String, dynamic>{'id': '', 'name': 'ignored'},
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    const account = ClientAccountSession(
      source: MusicSource.qq,
      accountId: '209192670',
      accessKey: 'access-key',
    );

    final playlists = await api.remotePlaylists(account);

    expect(playlists, hasLength(1));
    expect(playlists.single.id, '735123');
    expect(playlists.single.name, '通勤');
    expect(playlists.single.coverUrl, 'https://example.com/cover.jpg');
    expect(playlists.single.songCount, 2);
    expect(playlists.single.trackIds, <int>[101, 202]);
  });

  test('刷新远程歌单遇到 401 时抛出授权过期异常', () async {
    final client = MockClient((_) async {
      return http.Response(
        jsonEncode(<String, dynamic>{
          'error': <String, dynamic>{'message': 'QQ 音乐登录态已过期，请重新扫码授权'},
        }),
        401,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    const account = ClientAccountSession(
      source: MusicSource.qq,
      accountId: '209192670',
      accessKey: 'expired-key',
    );

    await expectLater(
      api.remotePlaylists(account),
      throwsA(
        isA<MusicApiException>()
            .having((error) => error.statusCode, 'statusCode', 401)
            .having((error) => error.message, 'message', 'QQ 音乐登录态已过期，请重新扫码授权'),
      ),
    );
  });

  test('登录后公开业务接口自动携带当前账号授权头', () async {
    final requestedPaths = <String>[];
    final client = MockClient((request) async {
      requestedPaths.add(request.url.path);
      expect(request.headers['X-OO-Music-Account-ID'], '209192670');
      expect(request.headers['X-OO-Music-Access-Key'], 'access-key');
      final body = switch (request.url.path) {
        '/api/search' => <String, dynamic>{'items': <dynamic>[]},
        '/api/tracks' => <String, dynamic>{'items': <dynamic>[]},
        '/api/playback' => <String, dynamic>{
          'source': 'qq',
          'songId': 101,
          'available': false,
        },
        '/api/lyrics' => <String, dynamic>{'source': 'qq', 'songId': 101},
        '/api/mv' => <String, dynamic>{'source': 'qq', 'songId': 101},
        _ => <String, dynamic>{},
      };
      return http.Response(
        jsonEncode(body),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    api.setActiveAccount(
      MusicSource.qq,
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '209192670',
        accessKey: 'access-key',
      ),
    );
    const song = Song(
      source: MusicSource.qq,
      id: 101,
      mid: 'song-mid',
      name: '测试歌曲',
      artists: <String>['测试歌手'],
      album: '测试专辑',
      albumMid: 'album-mid',
      coverUrl: '',
      durationSeconds: 180,
      hasMv: true,
      mvVid: 'mv-vid',
    );

    await api.search('测试', source: MusicSource.qq);
    await api.tracks(MusicSource.qq, <int>[101]);
    await api.playback(song);
    await api.lyrics(song);
    await api.mv(song);

    expect(requestedPaths, <String>[
      '/api/search',
      '/api/tracks',
      '/api/playback',
      '/api/lyrics',
      '/api/mv',
    ]);
  });

  test('未登录时公开业务接口不携带授权头', () async {
    final client = MockClient((request) async {
      expect(request.headers['X-OO-Music-Source'], 'qq');
      expect(request.headers.containsKey('X-OO-Music-Account-ID'), isFalse);
      expect(request.headers.containsKey('X-OO-Music-Access-Key'), isFalse);
      return http.Response(
        jsonEncode(<String, dynamic>{'items': <dynamic>[]}),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);

    await api.search('测试', source: MusicSource.qq);
  });

  test('校验指定账号时显式授权头不会被当前登录账号覆盖', () async {
    final client = MockClient((request) async {
      expect(request.headers['X-OO-Music-Account-ID'], 'target-uin');
      expect(request.headers['X-OO-Music-Access-Key'], 'target-key');
      expect(request.headers['X-OO-Music-Source'], 'qq');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'accountId': 'target-uin',
          'nickname': '目标账号',
          'avatarUrl': '',
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    api.setActiveAccount(
      MusicSource.qq,
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: 'active-uin',
        accessKey: 'active-key',
      ),
    );

    final validated = await api.validateClientAccount(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: 'target-uin',
        accessKey: 'target-key',
      ),
    );

    expect(validated.accountId, 'target-uin');
  });

  test('每个请求按 source 选择对应平台账号，跨平台播放不串号', () async {
    final requests = <String>[];
    final client = MockClient((request) async {
      requests.add(request.url.path);
      expect(request.url.queryParameters['source'], 'netease');
      expect(request.headers['X-OO-Music-Source'], 'netease');
      expect(request.headers['X-OO-Music-Account-ID'], 'netease-account');
      expect(request.headers['X-OO-Music-Access-Key'], 'netease-key');
      final body = switch (request.url.path) {
        '/api/search' => <String, dynamic>{
          'source': 'netease',
          'items': <dynamic>[],
        },
        '/api/playback' => <String, dynamic>{
          'source': 'netease',
          'songId': 101,
          'available': false,
        },
        _ => <String, dynamic>{},
      };
      return http.Response(
        jsonEncode(body),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    api.setAccount(
      MusicSource.qq,
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: 'qq-account',
        accessKey: 'qq-key',
      ),
    );
    api.setAccount(
      MusicSource.netease,
      const ClientAccountSession(
        source: MusicSource.netease,
        accountId: 'netease-account',
        accessKey: 'netease-key',
      ),
    );
    api.setActiveAccount(
      MusicSource.qq,
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: 'qq-account',
        accessKey: 'qq-key',
      ),
    );
    const song = Song(
      source: MusicSource.netease,
      id: 101,
      mid: '',
      name: '网易云歌曲',
      artists: <String>['歌手'],
      album: '专辑',
      albumMid: '',
      coverUrl: '',
      durationSeconds: 120,
      hasMv: false,
    );

    await api.search('测试', source: MusicSource.netease);
    await api.playback(song);

    expect(requests, <String>['/api/search', '/api/playback']);
  });

  test('网易云匿名请求不会复用当前 QQ 账号授权头', () async {
    final client = MockClient((request) async {
      expect(request.headers['X-OO-Music-Source'], 'netease');
      expect(request.headers.containsKey('X-OO-Music-Account-ID'), isFalse);
      expect(request.headers.containsKey('X-OO-Music-Access-Key'), isFalse);
      return http.Response(
        jsonEncode(<String, dynamic>{
          'source': 'netease',
          'songId': 101,
          'available': false,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);
    api.setActiveAccount(
      MusicSource.qq,
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: 'qq-account',
        accessKey: 'qq-key',
      ),
    );

    await api.playback(
      const Song(
        source: MusicSource.netease,
        id: 101,
        mid: '',
        name: '匿名歌曲',
        artists: <String>[],
        album: '',
        albumMid: '',
        coverUrl: '',
        durationSeconds: 1,
        hasMv: false,
      ),
    );
  });

  test('扫码使用统一后端会话路径并保留平台类型', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/api/client/login/sessions');
      expect(request.url.queryParameters['source'], 'netease');
      expect(request.headers['X-OO-Music-Source'], 'netease');
      return http.Response(
        jsonEncode(<String, dynamic>{
          'sessionId': 'netease-session',
          'source': 'netease',
          'status': 'waiting',
          'message': '等待扫码',
        }),
        201,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final api = MusicApi(baseUrl: 'http://music.test', client: client);

    final session = await api.startLogin(MusicSource.netease);

    expect(session.sessionId, 'netease-session');
    expect(session.source, MusicSource.netease);
  });
}
