/// LRC 中的一行歌词。
class LrcLine {
  /// 创建歌词行；纯文本歌词的时间戳为空。
  const LrcLine({required this.timestamp, required this.text});

  /// 该行开始播放的时间。
  final Duration? timestamp;

  /// 去除时间标签后的歌词文字。
  final String text;
}

/// 将 LRC 文本解析成可按播放时间定位的歌词行。
class LrcParser {
  static final RegExp _timeTag = RegExp(
    r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]',
  );
  static final RegExp _offsetTag = RegExp(r'\[offset:([+-]?\d+)\]');
  static final RegExp _metadataTag = RegExp(r'^\[[a-zA-Z]+:.*\]$');

  /// 解析 LRC；支持一行多个时间标签、翻译以及 offset。
  static List<LrcLine> parse(String source) {
    if (source.trim().isEmpty) {
      return const <LrcLine>[];
    }

    final offsetMatch = _offsetTag.firstMatch(source);
    final offsetMilliseconds = int.tryParse(offsetMatch?.group(1) ?? '') ?? 0;
    final lines = <LrcLine>[];

    for (final rawLine in source.split(RegExp(r'\r?\n'))) {
      final line = rawLine.trim();
      if (line.isEmpty || line.startsWith('[offset:')) {
        continue;
      }

      final matches = _timeTag.allMatches(line).toList(growable: false);
      if (matches.isEmpty) {
        if (!_metadataTag.hasMatch(line)) {
          lines.add(LrcLine(timestamp: null, text: line));
        }
        continue;
      }

      final text = line.replaceAll(_timeTag, '').trim();
      if (text.isEmpty) {
        continue;
      }
      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fraction = match.group(3) ?? '';
        final milliseconds = switch (fraction.length) {
          0 => 0,
          1 => int.parse(fraction) * 100,
          2 => int.parse(fraction) * 10,
          _ => int.parse(fraction.padRight(3, '0').substring(0, 3)),
        };
        final timestamp = Duration(
          minutes: minutes,
          seconds: seconds,
          milliseconds: milliseconds + offsetMilliseconds,
        );
        lines.add(
          LrcLine(
            timestamp: timestamp < Duration.zero ? Duration.zero : timestamp,
            text: text,
          ),
        );
      }
    }

    lines.sort((left, right) {
      final leftTime = left.timestamp;
      final rightTime = right.timestamp;
      if (leftTime == null && rightTime == null) {
        return 0;
      }
      if (leftTime == null) {
        return -1;
      }
      if (rightTime == null) {
        return 1;
      }
      return leftTime.compareTo(rightTime);
    });
    return lines;
  }

  /// 返回当前播放时间应高亮的歌词下标；没有可定位歌词时返回 -1。
  static int activeIndex(List<LrcLine> lines, Duration position) {
    var active = -1;
    for (var index = 0; index < lines.length; index++) {
      final timestamp = lines[index].timestamp;
      if (timestamp == null) {
        continue;
      }
      if (timestamp > position) {
        break;
      }
      active = index;
    }
    return active;
  }

  /// 将带时间标签的歌词转成“毫秒 -> 文本”的映射。
  static Map<int, String> byTimestamp(List<LrcLine> lines) {
    final result = <int, String>{};
    for (final line in lines) {
      final timestamp = line.timestamp;
      if (timestamp != null) {
        result[timestamp.inMilliseconds] = line.text;
      }
    }
    return result;
  }
}
