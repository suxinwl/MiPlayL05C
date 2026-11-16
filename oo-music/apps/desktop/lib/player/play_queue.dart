import 'dart:math';

import '../models/playlist.dart';
import '../models/song.dart';

/// 当前播放队列及播放模式决策。
///
/// 用户点击搜索结果或歌单歌曲时创建队列；模式变化不会重建队列。
class PlayQueue {
  /// 创建队列并定位到 [currentIndex]。
  PlayQueue({
    required List<Song> songs,
    required int currentIndex,
    this.sourcePlaylistId,
  }) : _songs = List<Song>.of(songs),
       _currentIndex = songs.isEmpty
           ? -1
           : currentIndex.clamp(0, songs.length - 1);

  final List<Song> _songs;
  int _currentIndex;

  /// 队列来源歌单 ID；来自搜索结果时为空。
  final String? sourcePlaylistId;

  /// 队列歌曲快照。
  List<Song> get songs => List<Song>.unmodifiable(_songs);

  /// 当前歌曲下标；空队列为 -1。
  int get currentIndex => _currentIndex;

  /// 当前歌曲；空队列为空。
  Song? get current => _currentIndex >= 0 && _currentIndex < _songs.length
      ? _songs[_currentIndex]
      : null;

  /// 队列是否为空。
  bool get isEmpty => _songs.isEmpty;

  /// 播放完成后的下一首下标；单曲循环返回当前歌曲。
  int? indexAfterCompletion(PlayMode mode, {Random? random}) {
    if (_songs.isEmpty) {
      return null;
    }
    if (mode == PlayMode.repeatOne) {
      return _currentIndex;
    }
    if (mode == PlayMode.shuffle) {
      return _randomIndex(random);
    }
    return (_currentIndex + 1) % _songs.length;
  }

  /// 用户点击“下一首”时的目标下标。
  ///
  /// 即使当前是单曲循环，手动下一首仍然切换到队列中的下一首歌。
  int? indexAfterManualNext(PlayMode mode, {Random? random}) {
    if (_songs.isEmpty) {
      return null;
    }
    if (mode == PlayMode.shuffle) {
      return _randomIndex(random);
    }
    return (_currentIndex + 1) % _songs.length;
  }

  /// 用户点击“上一首”时的目标下标。
  int? indexAfterPrevious(PlayMode mode, {Random? random}) {
    if (_songs.isEmpty) {
      return null;
    }
    if (mode == PlayMode.shuffle) {
      return _randomIndex(random);
    }
    return (_currentIndex - 1 + _songs.length) % _songs.length;
  }

  /// 记录实际开始播放的队列下标。
  void moveTo(int index) {
    if (_songs.isEmpty) {
      _currentIndex = -1;
      return;
    }
    _currentIndex = index.clamp(0, _songs.length - 1);
  }

  /// 用新的歌单顺序替换队列，并尽量保持当前歌曲不变。
  ///
  /// 返回替换后是否仍然包含当前歌曲。
  bool replaceSongs(List<Song> songs) {
    final currentKey = current?.mediaKey;
    _songs
      ..clear()
      ..addAll(songs);
    if (_songs.isEmpty) {
      _currentIndex = -1;
      return false;
    }
    if (currentKey == null) {
      _currentIndex = _currentIndex.clamp(0, _songs.length - 1);
      return false;
    }
    final newIndex = _songs.indexWhere((song) => song.mediaKey == currentKey);
    if (newIndex < 0) {
      _currentIndex = _currentIndex.clamp(0, _songs.length - 1);
      return false;
    }
    _currentIndex = newIndex;
    return true;
  }

  int _randomIndex(Random? random) {
    if (_songs.length <= 1) {
      return 0;
    }
    final source = random ?? Random();
    var next = source.nextInt(_songs.length - 1);
    if (next >= _currentIndex) {
      next++;
    }
    return next;
  }
}
