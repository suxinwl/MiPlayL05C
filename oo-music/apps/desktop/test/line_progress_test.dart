import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/lyrics/line_progress.dart';
import 'package:oo_music/lyrics/lrc_parser.dart';

void main() {
  test('LRC sweep estimates between distinct timestamps and clamps seeks', () {
    final lines = LrcParser.parse(
      '[00:10]first\n[00:10]translation\n[00:20]last',
    );
    double? progress(int seconds) => estimateLyricLineProgress(
      lines: lines,
      index: 0,
      position: Duration(seconds: seconds),
      duration: const Duration(seconds: 30),
    );
    expect(progress(5), 0);
    expect(progress(15), 0.5);
    expect(progress(25), 1);
    expect(
      estimateLyricLineProgress(
        lines: lines,
        index: 2,
        position: const Duration(seconds: 25),
        duration: const Duration(seconds: 30),
      ),
      0.5,
    );
  });

  test('untimed text and invalid indices have no estimated sweep', () {
    final lines = LrcParser.parse('plain lyrics');
    for (final index in [-1, 0, 1]) {
      expect(
        estimateLyricLineProgress(
          lines: lines,
          index: index,
          position: Duration.zero,
          duration: Duration.zero,
        ),
        isNull,
      );
    }
  });
}
