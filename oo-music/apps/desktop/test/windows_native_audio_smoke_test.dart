import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:oo_music/player/media_kit_playback_engine.dart';

/// Optional real-DLL stress test. Normal tests remain hermetic and offline.
/// Build Windows first, then set OO_MUSIC_NATIVE_AUDIO_TEST=1 and run this file.
void main() {
  test(
    'Windows 原生 libmpv 反复打开、取消、切歌、暂停和跳转不阻塞',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final dll = File('build/windows/x64/runner/Release/libmpv-2.dll')
          .absolute;
      expect(dll.existsSync(), isTrue, reason: '先构建 Windows Release');
      MediaKit.ensureInitialized(libmpv: dll.path);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final wav = _silentWav();
      var served = 0;
      final listener = server.listen((request) async {
        served++;
        request.response.headers.contentType = ContentType('audio', 'wav');
        request.response.headers.set('Accept-Ranges', 'bytes');
        final match = RegExp(r'bytes=(\d+)-(\d*)')
            .firstMatch(request.headers.value('Range') ?? '');
        final start = match == null ? 0 : int.parse(match.group(1)!);
        final end = match == null || match.group(2)!.isEmpty
            ? wav.length - 1
            : int.parse(match.group(2)!);
        if (start >= wav.length) {
          request.response.statusCode = 416;
        } else {
          if (match != null) {
            request.response.statusCode = 206;
            request.response.headers.set(
              'Content-Range',
              'bytes $start-$end/${wav.length}',
            );
          }
          request.response.contentLength = end - start + 1;
          request.response.add(wav.sublist(start, end + 1));
        }
        await request.response.close();
      });
      addTearDown(() async {
        await listener.cancel();
        await server.close(force: true);
      });
      final nativePlayer = Player(
        configuration: const PlayerConfiguration(
          muted: true,
          title: 'oo music native test',
        ),
      );
      // The sandbox has no Windows audio device. Use libmpv's null output to
      // stress native load/seek/stop without pretending to test speakers.
      final native = nativePlayer.platform as NativePlayer;
      final logSubscription = nativePlayer.stream.log.listen((log) {
        if (log.level == 'error') debugPrint('native-test: ${log.text}');
      });
      addTearDown(logSubscription.cancel);
      await native.setProperty('ao', 'null');
      await native.setProperty('cache-on-disk', 'no');
      final engine = MediaKitPlaybackEngine(
        playerFactory: () => nativePlayer,
        loadTimeout: const Duration(seconds: 5),
        commandTimeout: const Duration(seconds: 5),
      );
      addTearDown(engine.dispose);
      final errors = <Object>[];
      final subscription = engine.onStateChanged.listen(
        (_) {},
        onError: errors.add,
      );
      addTearDown(subscription.cancel);
      final base = 'http://127.0.0.1:${server.port}/silent.wav';
      for (var i = 0; i < 20; i++) {
        final first = engine.setSourceUrl('$base?first=$i');
        await Future<void>.delayed(const Duration(milliseconds: 12));
        final stop = engine.stop();
        final latest = engine.setSourceUrl('$base?latest=$i');
        await Future.wait([first, stop, latest]);
        await engine.resume();
        await Future<void>.delayed(const Duration(milliseconds: 60));
        await engine.seek(const Duration(milliseconds: 250));
        await engine.pause();
      }
      await Future.wait(
        List.generate(100, (i) => engine.setSourceUrl('$base?burst=$i')),
      );
      await engine.resume();
      await engine.stop();
      expect(served, greaterThanOrEqualTo(20));
      expect(errors, isEmpty);
      await engine.dispose();
    },
    skip:
        !Platform.isWindows ||
        Platform.environment['OO_MUSIC_NATIVE_AUDIO_TEST'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Uint8List _silentWav() {
  const samples = 8000 * 5;
  final result = Uint8List(44 + samples * 2);
  final header = ByteData.sublistView(result);
  result.setRange(0, 4, 'RIFF'.codeUnits);
  header.setUint32(4, result.length - 8, Endian.little);
  result.setRange(8, 12, 'WAVE'.codeUnits);
  result.setRange(12, 16, 'fmt '.codeUnits);
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 8000, Endian.little);
  header.setUint32(28, 16000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  result.setRange(36, 40, 'data'.codeUnits);
  header.setUint32(40, samples * 2, Endian.little);
  return result;
}
