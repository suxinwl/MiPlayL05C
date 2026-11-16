import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/platform/download_file_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('oo_music/test_file_export');
  const exporter = DownloadFileExport(channel: channel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('Android 文件导出传路径与正确 MIME，不包含账号或媒体 URL', () async {
    for (final quality in ['320mp3', 'flac', 'master', '96aac']) {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return true;
      });
      expect(
        await exporter.saveAs(File('downloaded-song'), quality: quality),
        isTrue,
      );
      expect(received?.method, 'saveAs');
      expect(received?.arguments, {
        'path': 'downloaded-song',
        'mimeType': quality == '96aac'
            ? 'audio/mp4'
            : quality == '320mp3'
            ? 'audio/mpeg'
            : 'audio/flac',
      });
    }
  });

  test('取消保存保持为 false，不当成失败或删除下载', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => false);
    expect(
      await exporter.saveAs(File('downloaded-song'), quality: 'flac'),
      isFalse,
    );
  });

  test('平台错误不会泄露路径、URI 或凭据', () async {
    messenger.setMockMethodCallHandler(channel, (_) async {
      throw PlatformException(
        code: 'failed',
        message: 'content://private-provider?token=secret',
      );
    });
    await expectLater(
      exporter.saveAs(File('downloaded-song'), quality: 'flac'),
      throwsA(
        isA<DownloadExportException>().having(
          (e) => e.message,
          'safe message',
          allOf(contains('导出失败'), isNot(contains('secret'))),
        ),
      ),
    );
  });
}
