import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/api/music_api.dart';
import 'package:oo_music/models/client_account.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/storage/local_library_store.dart';
import 'package:oo_music/widgets/account_dialog.dart';
import 'package:oo_music/widgets/music_source_switcher.dart';

void main() {
  test('平台来源标识用于音频、MV 和下载请求头', () {
    expect(MusicSource.qq.referer, 'https://y.qq.com/');
    expect(MusicSource.netease.referer, 'https://music.163.com/');
  });

  testWidgets('平台切换控件始终提供 QQ 和网易云入口', (tester) async {
    MusicSource? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MusicSourceSwitcher(
            selected: MusicSource.qq,
            qqAccount: const ClientAccountSession(
              source: MusicSource.qq,
              accountId: 'qq',
              accessKey: 'qq-key',
              nickname: 'QQ 用户',
            ),
            neteaseAccount: null,
            onChanged: (source) => selected = source,
          ),
        ),
      ),
    );

    expect(find.text('QQ'), findsOneWidget);
    expect(find.text('网易云'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('music-source-netease')),
    );
    expect(selected, MusicSource.netease);
  });

  testWidgets('账号面板只展示当前平台的账号', (tester) async {
    final store = LocalLibraryStore.inMemory();
    addTearDown(store.close);
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.qq,
        accountId: '12345678',
        accessKey: 'qq-key',
        nickname: 'QQ 用户',
        avatarUrl: 'https://example.com/qq.png',
      ),
    );
    store.saveClientAccountSession(
      const ClientAccountSession(
        source: MusicSource.netease,
        accountId: '12345678',
        accessKey: 'netease-key',
        nickname: '网易云用户',
        avatarUrl: 'https://example.com/netease.png',
      ),
    );
    final api = MusicApi(baseUrl: 'http://music.test');
    addTearDown(api.close);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AccountDialog(
            api: api,
            store: store,
            activeAccount: store.snapshot().accountFor(MusicSource.netease),
            source: MusicSource.netease,
          ),
        ),
      ),
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('show-account-switcher')),
    );
    await tester.pumpAndSettle();

    expect(find.text('网易云用户'), findsOneWidget);
    expect(find.text('QQ 用户'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('local-account-netease-12345678')),
      findsOneWidget,
    );
  });
}
