import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/platform/mv_playback_driver.dart';

void main() {
  test('未实现 MV 驱动的平台给出稳定错误', () async {
    final driver = UnsupportedMvPlaybackDriver();
    addTearDown(driver.dispose);

    expect(driver.snapshot.initialized, isFalse);
    await expectLater(
      driver.initialize(
        uri: Uri.parse('https://example.com/video.mp4'),
        httpHeaders: const <String, String>{},
      ),
      throwsA(isA<MvPlaybackUnavailableException>()),
    );
  });
}
