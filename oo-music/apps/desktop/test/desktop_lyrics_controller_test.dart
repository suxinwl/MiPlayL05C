import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/platform/desktop_lyrics_controller.dart';
import 'package:oo_music/platform/desktop_lyrics_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('oo_music/desktop_lyrics');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'show') {
            return true;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('桌面歌词控制器通过方法通道显示、更新和隐藏窗口', () async {
    final controller = DesktopLyricsController(
      platform: MethodChannelDesktopLyricsPlatform(channel: channel),
    );
    addTearDown(controller.dispose);

    final shown = await controller.show(
      lyric: '故事的小黄花',
      translation: 'The little yellow flowers in our story',
      isPlaying: true,
    );

    expect(shown, isTrue);
    expect(controller.visible, isTrue);
    expect(calls.map((call) => call.method), <String>['show']);
    expect(calls.single.arguments, <String, Object>{
      'lyric': '故事的小黄花',
      'translation': 'The little yellow flowers in our story',
      'isPlaying': true,
    });

    await controller.update(
      lyric: '从出生那年就飘着',
      translation: '',
      isPlaying: false,
    );
    expect(calls.last.method, 'update');
    expect(calls.last.arguments, <String, Object>{
      'lyric': '从出生那年就飘着',
      'translation': '',
      'isPlaying': false,
    });

    await controller.hide();
    expect(controller.visible, isFalse);
    expect(calls.last.method, 'hide');
  });

  test('平台不支持桌面歌词时安全返回 false', () async {
    final controller = DesktopLyricsController(
      platform: const UnsupportedDesktopLyricsPlatform(),
    );
    addTearDown(controller.dispose);

    expect(controller.isSupported, isFalse);
    expect(
      await controller.show(
        lyric: '歌词',
        translation: 'translation',
        isPlaying: false,
      ),
      isFalse,
    );
  });

  test('原生播放控制按钮通过方法通道回传给控制器', () async {
    var previousCount = 0;
    var playbackCount = 0;
    var nextCount = 0;
    final controller = DesktopLyricsController(
      platform: MethodChannelDesktopLyricsPlatform(channel: channel),
      onPrevious: () => previousCount++,
      onTogglePlayback: () => playbackCount++,
      onNext: () => nextCount++,
    );
    addTearDown(controller.dispose);

    Future<void> emit(String method) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
            (_) {},
          );
    }

    await emit('previous');
    await emit('togglePlayback');
    await emit('next');

    expect(previousCount, 1);
    expect(playbackCount, 1);
    expect(nextCount, 1);
  });
}
