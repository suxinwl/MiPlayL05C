import 'lrc_parser.dart';

/// LRC has line timestamps, so the colour sweep is an estimate between lines.
/// Untimed text has no meaningful progress and remains readable without a sweep.
double? estimateLyricLineProgress({
  required List<LrcLine> lines,
  required int index,
  required Duration position,
  required Duration duration,
}) {
  if (index < 0 || index >= lines.length) return null;
  final start = lines[index].timestamp;
  if (start == null) return null;
  Duration? end;
  for (var i = index + 1; i < lines.length; i++) {
    final timestamp = lines[i].timestamp;
    if (timestamp != null && timestamp > start) {
      end = timestamp;
      break;
    }
  }
  end ??= duration > start ? duration : start + const Duration(seconds: 6);
  return ((position - start).inMilliseconds / (end - start).inMilliseconds)
      .clamp(0.0, 1.0);
}
