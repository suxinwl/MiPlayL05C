import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/models/playlist.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/models/song.dart';
import 'package:oo_music/player/play_queue.dart';

Song _song(int id, {MusicSource source = MusicSource.qq}) => Song(
  id: id,
  source: source,
  mid: 'mid-$id',
  name: '歌曲 $id',
  artists: const <String>['歌手'],
  album: '专辑',
  albumMid: 'album-$id',
  coverUrl: '',
  durationSeconds: 180,
  hasMv: false,
);

void main() {
  test('顺序循环与手动上一首/下一首会首尾衔接', () {
    final queue = PlayQueue(
      songs: <Song>[_song(1), _song(2), _song(3)],
      currentIndex: 2,
    );

    expect(queue.indexAfterCompletion(PlayMode.sequentialLoop), 0);
    expect(queue.indexAfterManualNext(PlayMode.sequentialLoop), 0);
    expect(queue.indexAfterPrevious(PlayMode.sequentialLoop), 1);
  });

  test('单曲循环自然结束返回当前歌曲，手动下一首仍前进', () {
    final queue = PlayQueue(
      songs: <Song>[_song(1), _song(2), _song(3)],
      currentIndex: 1,
    );

    expect(queue.indexAfterCompletion(PlayMode.repeatOne), 1);
    expect(queue.indexAfterManualNext(PlayMode.repeatOne), 2);
    expect(queue.indexAfterPrevious(PlayMode.repeatOne), 0);
  });

  test('随机模式不会连续选择当前歌曲', () {
    final queue = PlayQueue(
      songs: <Song>[_song(1), _song(2), _song(3), _song(4)],
      currentIndex: 2,
    );

    for (var seed = 0; seed < 100; seed++) {
      final next = queue.indexAfterCompletion(
        PlayMode.shuffle,
        random: Random(seed),
      );
      expect(next, isNot(2));
      expect(next, inInclusiveRange(0, 3));
    }
  });

  test('替换歌单顺序时保持当前歌曲并更新下标', () {
    final queue = PlayQueue(
      songs: <Song>[_song(1), _song(2), _song(3)],
      currentIndex: 1,
    );

    final retained = queue.replaceSongs(<Song>[_song(3), _song(1), _song(2)]);
    expect(retained, isTrue);
    expect(queue.current?.id, 2);
    expect(queue.currentIndex, 2);
  });

  test('相同数字 ID 的 QQ 与网易云歌曲按 mediaKey 区分', () {
    final qq = _song(42);
    final netease = _song(42, source: MusicSource.netease);
    final queue = PlayQueue(songs: <Song>[qq, netease], currentIndex: 1);

    final retained = queue.replaceSongs(<Song>[netease, qq]);
    expect(retained, isTrue);
    expect(queue.current?.mediaKey, 'netease:42');
    expect(queue.currentIndex, 0);
  });
}
