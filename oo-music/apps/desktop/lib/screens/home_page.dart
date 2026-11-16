import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/music_api.dart';
import '../lyrics/lrc_parser.dart';
import '../models/client_account.dart';
import '../models/lyric.dart';
import '../models/music_source.dart';
import '../models/playback.dart';
import '../models/playlist.dart';
import '../models/song.dart';
import '../platform/android_permissions.dart';
import '../platform/app_platform.dart';
import '../platform/desktop_lyrics_controller.dart';
import '../platform/download_file_export.dart';
import '../player/playback_engine.dart';
import '../player/playback_engine_factory.dart';
import '../player/play_queue.dart';
import '../services/download_service.dart';
import '../storage/local_library_store.dart';
import '../theme/app_theme.dart';
import '../widgets/account_dialog.dart';
import '../widgets/app_dialog.dart';
import '../widgets/library_sidebar.dart';
import '../widgets/lyrics_panel.dart';
import '../widgets/mobile_home_page.dart';
import '../widgets/mobile_now_playing_page.dart';
import '../widgets/music_source_switcher.dart';
import '../widgets/music_source_badge.dart';
import '../widgets/mv_player_dialog.dart';
import '../widgets/now_playing_page.dart';
import '../widgets/player_bar.dart';
import '../widgets/playlist_name_dialog.dart';

/// 音乐主页：搜索、播放、歌词和本地歌单。
class HomePage extends StatefulWidget {
  /// 创建主页；测试或嵌入时可以注入 API、音乐库和播放引擎。
  const HomePage({super.key, this.api, this.libraryStore, this.playbackEngine});

  /// 可选的自定义 API 客户端。
  final MusicApi? api;

  /// 可选的本地音乐库；为空时打开默认应用数据目录。
  final LocalLibraryStore? libraryStore;

  /// 可选的播放引擎；为空时创建当前平台的默认实现。
  final PlaybackEngine? playbackEngine;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final ScrollController _resultsScrollController = ScrollController();
  final DownloadService _downloads = DownloadService();
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final _mobilePlayerKey = GlobalKey<MobileNowPlayingPageState>();

  late final MusicApi _api;
  late final PlaybackEngine _player;
  late final bool _ownsApi;
  late final bool _ownsPlayer;
  late final bool _ownsStore;
  late final DesktopLyricsController _desktopLyrics;
  late final StreamSubscription<Duration> _positionSubscription;
  late final StreamSubscription<Duration> _durationSubscription;
  late final StreamSubscription<PlaybackEngineState> _playerStateSubscription;
  late final StreamSubscription<void> _completeSubscription;

  LocalLibraryStore? _store;
  LibrarySnapshot? _snapshot;
  ClientAccountSession? _qqAccount;
  ClientAccountSession? _neteaseAccount;
  MusicSource _selectedSource = MusicSource.qq;
  final Map<String, Song> _songCache = <String, Song>{};

  ClientAccountSession? get _activeAccount =>
      _selectedSource == MusicSource.qq ? _qqAccount : _neteaseAccount;

  List<Song> _searchResults = const <Song>[];
  final Map<MusicSource, List<Song>> _searchResultsBySource =
      <MusicSource, List<Song>>{};
  final Map<MusicSource, String> _searchQueryBySource = <MusicSource, String>{};
  List<Song> _playlistSongs = const <Song>[];
  List<LrcLine> _lyricLines = const <LrcLine>[];
  Map<int, String> _translations = const <int, String>{};
  Map<int, String> _romanizations = const <int, String>{};
  Song? _selectedSong;
  PlaybackResult? _playback;
  LyricData? _lyric;
  PlayQueue? _playQueue;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  PlaybackEngineState _playerState = PlaybackEngineState.stopped;
  int _activeLyricIndex = -1;
  int _searchSequence = 0;
  int _selectionSequence = 0;
  int _playlistSequence = 0;
  Future<void> _sourceOperations = Future<void>.value();

  bool _searchSelected = true;
  String? _selectedPlaylistId;
  PlayMode _playMode = PlayMode.sequentialLoop;
  double _volume = 0.8;
  String _preferredQualityQq = '320mp3';
  String _preferredQualityNetease = '320mp3';

  bool _searching = false;
  bool _loadingLyrics = false;
  bool _loadingPlayback = false;
  bool _loadingPlaylist = false;
  bool _switchingQuality = false;
  bool _openingAccountLogin = false;
  bool _refreshingRemotePlaylists = false;
  bool _desktopLyricsVisible = false;
  bool _showNowPlaying = false;
  int _mobileTab = 0;
  String? _searchError;
  String _lastSearchQuery = '';
  String? _lyricError;
  String? _playbackError;
  String? _playlistError;
  String? _libraryError;
  Timer? _volumeSaveTimer;
  final Set<String> _downloadingSongKeys = <String>{};
  final Map<String, double?> _downloadProgress = <String, double?>{};
  String _lastDesktopLyric = '';
  String _lastDesktopTranslation = '';
  bool _lastDesktopPlaying = false;
  bool Function(KeyEvent event)? _globalShortcutHandler;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? MusicApi();
    _ownsApi = widget.api == null;
    _player = widget.playbackEngine ?? createPlaybackEngine();
    _ownsPlayer = widget.playbackEngine == null;
    _ownsStore = widget.libraryStore == null;
    final mediaPlayer = _player;
    if (mediaPlayer is SystemMediaPlaybackEngine) {
      (mediaPlayer as SystemMediaPlaybackEngine).bindSystemControls(
        previous: () async {
          if (mounted) _playPrevious();
        },
        next: () async {
          if (mounted) _playNext();
        },
        retry: _retrySystemPlayback,
      );
    }
    _desktopLyrics = DesktopLyricsController(
      onClosed: _handleDesktopLyricsClosed,
      onToggle: () => unawaited(_toggleDesktopLyrics()),
      onPrevious: _playPrevious,
      onTogglePlayback: () => unawaited(_togglePlayback()),
      onNext: _playNext,
    );
    _positionSubscription = _player.onPositionChanged.listen(
      _handlePositionChanged,
      onError: _handlePlayerStreamError,
    );
    _durationSubscription = _player.onDurationChanged.listen(
      _handleDurationChanged,
      onError: _handlePlayerStreamError,
    );
    _playerStateSubscription = _player.onStateChanged.listen((state) {
      if (!mounted) {
        return;
      }
      setState(() => _playerState = state);
      _syncDesktopLyrics(force: true);
    }, onError: _handlePlayerStreamError);
    _completeSubscription = _player.onComplete.listen((_) {
      _handlePlaybackCompleted();
    }, onError: _handlePlayerStreamError);
    _globalShortcutHandler = _handleGlobalShortcut;
    HardwareKeyboard.instance.addHandler(_globalShortcutHandler!);
    unawaited(_initializeLibrary());
  }

  @override
  void dispose() {
    _searchSequence++;
    _selectionSequence++;
    _playlistSequence++;
    _volumeSaveTimer?.cancel();
    _searchController.dispose();
    _searchFocusNode.dispose();
    _resultsScrollController.dispose();
    _positionSubscription.cancel();
    _durationSubscription.cancel();
    _playerStateSubscription.cancel();
    _completeSubscription.cancel();
    final keyHandler = _globalShortcutHandler;
    if (keyHandler != null) {
      HardwareKeyboard.instance.removeHandler(keyHandler);
    }
    if (_ownsPlayer) {
      unawaited(_player.dispose());
    }
    _downloads.close();
    unawaited(_desktopLyrics.dispose());
    if (_ownsApi) {
      _api.close();
    }
    if (_ownsStore) {
      _store?.close();
    }
    super.dispose();
  }

  Future<void> _initializeLibrary() async {
    try {
      final store =
          widget.libraryStore ?? await LocalLibraryStore.openDefault();
      final snapshot = store.snapshot();
      _api.setAccount(MusicSource.qq, snapshot.qqAccount);
      _api.setAccount(MusicSource.netease, snapshot.neteaseAccount);
      _api.setActiveAccount(
        snapshot.selectedSource,
        snapshot.accountFor(snapshot.selectedSource),
      );
      final effectiveVolume = AppPlatform.current == AppPlatformKind.android
          ? 1.0
          : snapshot.volume;
      await _player.setVolume(effectiveVolume);
      if (!mounted) {
        if (_ownsStore) {
          store.close();
        }
        return;
      }
      setState(() {
        _store = store;
        _snapshot = snapshot;
        _selectedSource = snapshot.selectedSource;
        _qqAccount = snapshot.qqAccount;
        _neteaseAccount = snapshot.neteaseAccount;
        _playMode = snapshot.playMode;
        _volume = effectiveVolume;
        _preferredQualityQq = snapshot.preferredQualityQq;
        _preferredQualityNetease = snapshot.preferredQualityNetease;
        _libraryError = null;
      });
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _libraryError = '本地歌单加载失败：${_messageFor(error)}');
    }
  }

  void _handlePlayerStreamError(Object error, StackTrace stackTrace) {
    if (!mounted) {
      return;
    }
    setState(() {
      _playbackError = '播放器异常：${_messageFor(error)}';
      _loadingPlayback = false;
      _switchingQuality = false;
    });
  }

  void _handleDesktopLyricsClosed() {
    if (!mounted) {
      return;
    }
    setState(() {
      _desktopLyricsVisible = false;
      _lastDesktopLyric = '';
      _lastDesktopTranslation = '';
      _lastDesktopPlaying = false;
    });
  }

  /// 处理跨平台全局快捷键。
  ///
  /// Esc 优先关闭完整播放页或退出搜索输入；搜索快捷键聚焦并全选现有
  /// 关键词；桌面歌词快捷键仅在平台支持且已有歌曲时生效。
  bool _handleGlobalShortcut(KeyEvent event) {
    if (AppPlatform.matchesEscape(event)) {
      if (_showNowPlaying) {
        setState(() => _showNowPlaying = false);
        return true;
      }
      if (_searchFocusNode.hasFocus) {
        _searchFocusNode.unfocus();
        return true;
      }
      return false;
    }
    if (AppPlatform.matchesSearchShortcut(event) && !_showNowPlaying) {
      _searchFocusNode.requestFocus();
      _searchController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _searchController.text.length,
      );
      return true;
    }
    if (!AppPlatform.matchesDesktopLyricsShortcut(event) ||
        !_desktopLyrics.isSupported) {
      return false;
    }
    if (_selectedSong != null) {
      unawaited(_toggleDesktopLyrics());
    }
    return true;
  }

  String _desktopLyricText() {
    final song = _selectedSong;
    if (song == null) {
      return 'oo music';
    }
    if (_lyricLines.isEmpty) {
      return _loadingLyrics ? '正在加载歌词…' : song.name;
    }
    if (_activeLyricIndex < 0 || _activeLyricIndex >= _lyricLines.length) {
      return song.name;
    }
    return _lyricLines[_activeLyricIndex].text;
  }

  String _desktopTranslationText() {
    if (_activeLyricIndex < 0 || _activeLyricIndex >= _lyricLines.length) {
      return '';
    }
    final timestamp = _lyricLines[_activeLyricIndex].timestamp;
    if (timestamp == null) {
      return '';
    }
    return _translations[timestamp.inMilliseconds] ?? '';
  }

  void _syncDesktopLyrics({bool force = false}) {
    if (!_desktopLyricsVisible) {
      return;
    }
    final lyric = _desktopLyricText();
    final translation = _desktopTranslationText();
    final playing = _playerState == PlaybackEngineState.playing;
    if (!force &&
        lyric == _lastDesktopLyric &&
        translation == _lastDesktopTranslation &&
        playing == _lastDesktopPlaying) {
      return;
    }
    _lastDesktopLyric = lyric;
    _lastDesktopTranslation = translation;
    _lastDesktopPlaying = playing;
    unawaited(
      _desktopLyrics.update(
        lyric: lyric,
        translation: translation,
        isPlaying: playing,
      ),
    );
  }

  void _syncSystemMedia() {
    final player = _player;
    final song = _selectedSong;
    if (player is! SystemMediaPlaybackEngine || song == null) return;
    final artwork = song.coverUrl.trim();
    final uri = artwork.isEmpty ? null : Uri.tryParse(_api.resolveUrl(artwork));
    (player as SystemMediaPlaybackEngine).updateSystemMedia(
      PlaybackMetadata(
        id: song.mediaKey,
        title: song.name,
        artist: song.artistText,
        album: song.album,
        duration: _duration,
        artUri: uri?.scheme == 'https' || uri?.host == '127.0.0.1' ? uri : null,
      ),
      canSkip: _playQueue != null && !_playQueue!.isEmpty,
    );
  }

  Future<void> _retrySystemPlayback() async {
    final song = _selectedSong;
    if (!mounted || song == null || _loadingPlayback || _switchingQuality) {
      return;
    }
    final sequence = _selectionSequence;
    setState(() {
      _loadingPlayback = true;
      _playbackError = null;
    });
    await _loadPlayback(song, sequence, quality: _chooseQuality(song));
  }

  void _handlePositionChanged(Duration position) {
    if (!mounted) {
      return;
    }
    final activeIndex = LrcParser.activeIndex(_lyricLines, position);
    setState(() {
      _position = position;
      _activeLyricIndex = activeIndex;
    });
    _syncDesktopLyrics();
  }

  void _handleDurationChanged(Duration duration) {
    if (!mounted || duration <= Duration.zero) {
      return;
    }
    setState(() => _duration = duration);
    _syncSystemMedia();
  }

  void _handlePlaybackCompleted() {
    if (!mounted) {
      return;
    }
    setState(() {
      _playerState = PlaybackEngineState.completed;
      _position = _duration;
      _activeLyricIndex = _lyricLines.isEmpty ? -1 : _lyricLines.length - 1;
    });
    _syncDesktopLyrics(force: true);
    final queue = _playQueue;
    if (queue == null || queue.isEmpty) {
      return;
    }
    final nextIndex = queue.indexAfterCompletion(_playMode);
    if (nextIndex == null) {
      return;
    }
    queue.moveTo(nextIndex);
    final nextSong = queue.current;
    if (nextSong != null) {
      unawaited(
        _selectSong(
          nextSong,
          queueSongs: queue.songs,
          queueIndex: nextIndex,
          sourcePlaylistId: queue.sourcePlaylistId,
        ),
      );
    }
  }

  Future<void> _search() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() => _searchError = '请输入歌曲、歌手或专辑名');
      return;
    }

    FocusScope.of(context).unfocus();
    final source = _selectedSource;
    final sequence = ++_searchSequence;
    setState(() {
      _lastSearchQuery = query;
      _searchQueryBySource[source] = query;
      _searching = true;
      _searchError = null;
      _searchSelected = true;
      _selectedPlaylistId = null;
      _playlistSongs = const <Song>[];
      _playlistError = null;
      _loadingPlaylist = false;
    });

    try {
      final songs = await _api.search(query, source: source);
      if (!mounted ||
          sequence != _searchSequence ||
          source != _selectedSource) {
        return;
      }
      _cacheSongs(songs);
      _searchResultsBySource[source] = songs;
      setState(() {
        _searchResults = songs;
        _searching = false;
      });
    } on Object catch (error) {
      if (!mounted ||
          sequence != _searchSequence ||
          source != _selectedSource) {
        return;
      }
      _searchResultsBySource[source] = const <Song>[];
      setState(() {
        _searchResults = const <Song>[];
        _searching = false;
        _searchError = _messageFor(error);
      });
    }
  }

  void _selectSearch() {
    _playlistSequence++;
    setState(() {
      _searchSelected = true;
      _selectedPlaylistId = null;
      _playlistSongs = const <Song>[];
      _playlistError = null;
      _loadingPlaylist = false;
    });
  }

  void _selectPlaylist(String playlistId) {
    final playlist = _snapshot?.playlistById(playlistId);
    if (playlist == null) {
      return;
    }
    final sequence = ++_playlistSequence;
    final songs = _songsForPlaylist(playlist);
    final needsDetails = playlist.songs.any(
      (song) => !_songCache.containsKey(song.mediaKey),
    );
    setState(() {
      _searchSelected = false;
      _selectedPlaylistId = playlistId;
      _playlistSongs = songs;
      _playlistError = null;
      _loadingPlaylist = needsDetails;
    });
    if (needsDetails) {
      unawaited(_loadPlaylistDetails(playlistId, sequence));
    }
  }

  Future<void> _loadPlaylistDetails(String playlistId, int sequence) async {
    final playlist = _snapshot?.playlistById(playlistId);
    if (playlist == null) {
      return;
    }
    final missingBySource = <MusicSource, List<int>>{};
    for (final song in playlist.songs) {
      if (_songCache.containsKey(song.mediaKey)) {
        continue;
      }
      missingBySource.putIfAbsent(song.source, () => <int>[]).add(song.songId);
    }
    if (missingBySource.isEmpty) {
      if (mounted && sequence == _playlistSequence) {
        setState(() => _loadingPlaylist = false);
      }
      return;
    }

    try {
      final details = <Song>[];
      for (final entry in missingBySource.entries) {
        final sourceIds = entry.value.toSet().toList(growable: false);
        for (var start = 0; start < sourceIds.length; start += 50) {
          final end = (start + 50).clamp(0, sourceIds.length);
          details.addAll(
            await _api.tracks(entry.key, sourceIds.sublist(start, end)),
          );
        }
      }
      if (!mounted || sequence != _playlistSequence) {
        return;
      }
      _cacheSongs(details);
      final current = _snapshot?.playlistById(playlistId);
      setState(() {
        if (current != null) {
          _playlistSongs = _songsForPlaylist(current);
        }
        _loadingPlaylist = false;
        _playlistError = null;
      });
    } on Object catch (error) {
      if (!mounted || sequence != _playlistSequence) {
        return;
      }
      setState(() {
        _loadingPlaylist = false;
        _playlistError = '歌曲信息加载失败：${_messageFor(error)}';
      });
    }
  }

  List<Song> _songsForPlaylist(Playlist playlist) {
    return <Song>[
      for (final song in playlist.songs)
        _songCache[song.mediaKey] ??
            Song.placeholder(song.songId, source: song.source),
    ];
  }

  void _cacheSongs(Iterable<Song> songs) {
    for (final song in songs) {
      _songCache[song.mediaKey] = song;
    }
  }

  Future<void> _selectSong(
    Song song, {
    required List<Song> queueSongs,
    required int queueIndex,
    required String? sourcePlaylistId,
  }) async {
    _touchRecentlyPlayed(song);
    final sequence = ++_selectionSequence;
    final queue = PlayQueue(
      songs: queueSongs,
      currentIndex: queueIndex,
      sourcePlaylistId: sourcePlaylistId,
    );
    setState(() {
      _playQueue = queue;
      _selectedSong = song;
      _playback = null;
      _lyric = null;
      _lyricLines = const <LrcLine>[];
      _translations = const <int, String>{};
      _romanizations = const <int, String>{};
      _position = Duration.zero;
      _duration = song.duration;
      _activeLyricIndex = -1;
      _playerState = PlaybackEngineState.stopped;
      _loadingLyrics = true;
      _loadingPlayback = true;
      _lyricError = null;
      _playbackError = null;
      _switchingQuality = false;
    });
    _syncDesktopLyrics(force: true);

    try {
      final player = _player;
      if (player is SystemMediaPlaybackEngine) {
        await (player as SystemMediaPlaybackEngine)
            .prepareForSourceSwitch()
            .timeout(const Duration(seconds: 5));
      } else {
        await player.stop().timeout(const Duration(seconds: 5));
      }
    } on Object {
      // 旧音源停止失败不应阻止加载新歌曲，也不能无限阻塞主页。
    }
    if (!mounted || sequence != _selectionSequence) return;
    _syncSystemMedia();

    unawaited(_prepareSong(song, sequence));
  }

  Future<void> _prepareSong(Song initialSong, int sequence) async {
    var song = initialSong;
    try {
      final details = await _api.tracks(initialSong.source, <int>[
        initialSong.id,
      ]);
      if (details.isNotEmpty) {
        song = details.first;
        _cacheSongs(details);
      }
    } on Object {
      // 详情失败时仍使用搜索结果中的基础信息继续尝试播放。
    }
    if (!mounted || sequence != _selectionSequence) {
      return;
    }

    final queue = _playQueue;
    if (queue != null) {
      final updated = <Song>[
        for (final item in queue.songs)
          item.mediaKey == song.mediaKey ? song : item,
      ];
      queue.replaceSongs(updated);
    }
    setState(() {
      _selectedSong = song;
      _duration = song.duration;
    });
    _syncSystemMedia();

    unawaited(_loadLyrics(song, sequence));
    await _loadPlayback(song, sequence, quality: _chooseQuality(song));
  }

  Future<void> _loadLyrics(Song song, int sequence) async {
    try {
      final lyric = await _api.lyrics(song);
      if (!mounted || sequence != _selectionSequence) {
        return;
      }
      final lines = LrcParser.parse(
        lyric.lyric.trim().isNotEmpty ? lyric.lyric : lyric.translation,
      );
      setState(() {
        _lyric = lyric;
        _lyricLines = lines;
        _translations = LrcParser.byTimestamp(
          LrcParser.parse(lyric.translation),
        );
        _romanizations = LrcParser.byTimestamp(
          LrcParser.parse(lyric.romanization),
        );
        _activeLyricIndex = LrcParser.activeIndex(lines, _position);
        _loadingLyrics = false;
      });
      _syncDesktopLyrics(force: true);
    } on Object catch (error) {
      if (!mounted || sequence != _selectionSequence) {
        return;
      }
      setState(() {
        _loadingLyrics = false;
        _lyricError = _messageFor(error);
      });
    }
  }

  Future<void> _loadPlayback(
    Song song,
    int sequence, {
    required String quality,
  }) async {
    try {
      final playback = await _api.playback(song, quality: quality);
      if (!mounted || sequence != _selectionSequence) {
        return;
      }
      setState(() {
        _playback = playback;
        _loadingPlayback = playback.available;
      });
      if (!playback.available) {
        if (_player is SystemMediaPlaybackEngine) await _player.stop();
        return;
      }

      await _serializeSource(sequence, () async {
        await _setPlayerSource(playback.url, song.source);
        if (!_currentSelection(sequence)) return;
        await _player.setVolume(_volume);
        if (!_currentSelection(sequence)) return;
        await _player.resume();
      });
      if (mounted && sequence == _selectionSequence) {
        setState(() => _loadingPlayback = false);
      }
    } on Object catch (error) {
      if (!mounted || sequence != _selectionSequence) {
        return;
      }
      if (_player is SystemMediaPlaybackEngine) await _player.stop();
      if (!_currentSelection(sequence)) return;
      setState(() {
        _loadingPlayback = false;
        _playbackError = _messageFor(error);
      });
    }
  }

  Future<void> _setPlayerSource(
    String url,
    MusicSource source, {
    Duration initialPosition = Duration.zero,
  }) async {
    final player = _player;
    if (player is SourceAwarePlaybackEngine) {
      return (player as SourceAwarePlaybackEngine).setSource(
        url,
        source: source,
        initialPosition: initialPosition,
      );
    }
    await player.setSourceUrl(url);
    if (initialPosition > Duration.zero) {
      await player.seek(initialPosition);
    }
  }

  bool _currentSelection(int sequence) =>
      mounted && sequence == _selectionSequence;

  Future<void> _serializeSource(int sequence, Future<void> Function() action) {
    final result = _sourceOperations.then((_) async {
      if (_currentSelection(sequence)) await action();
    });
    _sourceOperations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  String _chooseQuality(Song song) {
    final available = song.availableQualities;
    final preferred = song.source == MusicSource.qq
        ? _preferredQualityQq
        : _preferredQualityNetease;
    if (available.isEmpty) {
      return preferred;
    }
    if (available.contains(preferred)) {
      return preferred;
    }
    for (final quality in supportedQualityOrder) {
      if (available.contains(quality)) {
        return quality;
      }
    }
    return available.first;
  }

  Future<void> _togglePlayback() async {
    if (_selectedSong == null ||
        _playback?.available != true ||
        _loadingPlayback ||
        _switchingQuality) {
      return;
    }
    if (_playbackError != null ||
        (_playerState == PlaybackEngineState.stopped &&
            _player is SystemMediaPlaybackEngine)) {
      // The failed native instance was discarded. Retry by resolving/loading
      // the current song again instead of sending resume to a dead instance.
      final song = _selectedSong!;
      final queue = _playQueue;
      await _selectSong(
        song,
        queueSongs: queue?.songs ?? [song],
        queueIndex: queue?.currentIndex ?? 0,
        sourcePlaylistId: queue?.sourcePlaylistId,
      );
      return;
    }
    try {
      if (_playerState == PlaybackEngineState.playing) {
        await _player.pause();
        return;
      }
      if (_playerState == PlaybackEngineState.completed) {
        await _player.seek(Duration.zero);
        if (mounted) {
          setState(() {
            _position = Duration.zero;
            _activeLyricIndex = -1;
          });
          _syncDesktopLyrics(force: true);
        }
      }
      await _player.resume();
    } on Object catch (error) {
      if (mounted) {
        setState(() => _playbackError = '播放失败：${_messageFor(error)}');
      }
    }
  }

  Future<void> _toggleDesktopLyrics() async {
    if (!_desktopLyricsVisible && _selectedSong == null) {
      _showSnackBar('请先播放一首歌曲');
      return;
    }
    if (_desktopLyricsVisible) {
      await _desktopLyrics.hide();
      if (mounted) {
        setState(() {
          _desktopLyricsVisible = false;
          _lastDesktopLyric = '';
          _lastDesktopTranslation = '';
        });
      }
      return;
    }

    final lyric = _desktopLyricText();
    final translation = _desktopTranslationText();
    final playing = _playerState == PlaybackEngineState.playing;
    final shown = await _desktopLyrics.show(
      lyric: lyric,
      translation: translation,
      isPlaying: playing,
    );
    if (!mounted) {
      return;
    }
    if (!shown) {
      _showSnackBar(
        AppPlatform.current == AppPlatformKind.android
            ? '请允许“显示在其他应用上层”权限，然后再次打开桌面歌词'
            : '桌面歌词窗口打开失败',
      );
      return;
    }
    setState(() {
      _desktopLyricsVisible = true;
      _lastDesktopLyric = lyric;
      _lastDesktopTranslation = translation;
      _lastDesktopPlaying = playing;
    });
  }

  Future<void> _downloadSong(Song song) async {
    final songKey = song.mediaKey;
    if (_downloadingSongKeys.contains(songKey)) {
      return;
    }
    setState(() {
      _downloadingSongKeys.add(songKey);
      _downloadProgress[songKey] = 0;
    });
    try {
      final current = _playback;
      final playback =
          _selectedSong?.mediaKey == songKey && current?.available == true
          ? current!
          : await _api.playback(song, quality: _chooseQuality(song));
      if (!playback.available || playback.url.trim().isEmpty) {
        throw MusicApiException(playback.reasonLabel);
      }
      final result = await _downloads.download(
        song: song,
        url: playback.url,
        quality: playback.quality,
        onProgress: (received, total) =>
            _updateDownloadProgress(songKey, received, total),
      );
      if (!mounted) {
        return;
      }
      if (AppPlatform.current == AppPlatformKind.android) {
        final exported = await const DownloadFileExport().saveAs(
          result.file,
          quality: result.quality,
        );
        if (!mounted) return;
        _showSnackBar(
          exported
              ? '已保存“${song.name}”到选择的位置'
              : '已下载“${song.name}”，取消导出后文件仍保留在应用下载目录',
        );
        return;
      }
      _showSnackBar('已下载“${song.name}”到 ${result.file.parent.path}');
    } on Object catch (error) {
      if (mounted) {
        _showSnackBar('下载失败：${_messageFor(error)}');
      }
    } finally {
      if (mounted) {
        setState(() {
          _downloadingSongKeys.remove(songKey);
          _downloadProgress.remove(songKey);
        });
      }
    }
  }

  void _updateDownloadProgress(String songKey, int received, int total) {
    if (!mounted) {
      return;
    }
    final progress = total > 0 ? received / total : null;
    final previous = _downloadProgress[songKey];
    if (progress != null &&
        previous != null &&
        (progress * 100).floor() == (previous * 100).floor()) {
      return;
    }
    setState(() => _downloadProgress[songKey] = progress);
  }

  Future<void> _playMv(Song song) async {
    final wasPlaying = _playerState == PlaybackEngineState.playing;
    try {
      if (wasPlaying) {
        await _player.pause();
      }
    } on Object {
      // MV 弹窗仍可独立播放，暂停歌曲失败不应阻断。
    }
    if (!mounted) {
      return;
    }
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (context) => MvPlayerDialog(api: _api, song: song),
    );
    if (wasPlaying && mounted && !_loadingPlayback && !_switchingQuality) {
      try {
        await _player.resume();
      } on Object catch (error) {
        if (mounted) {
          setState(() => _playbackError = '恢复播放失败：$error');
        }
      }
    }
  }

  Future<void> _seek(Duration position) async {
    if (_loadingPlayback || _switchingQuality) return;
    final sequence = _selectionSequence;
    try {
      await _player.seek(position);
      if (!_currentSelection(sequence)) {
        return;
      }
      setState(() {
        _position = position;
        _activeLyricIndex = LrcParser.activeIndex(_lyricLines, position);
      });
      _syncDesktopLyrics(force: true);
    } on Object catch (error) {
      if (_currentSelection(sequence)) {
        setState(() => _playbackError = '跳转失败：$error');
      }
    }
  }

  void _playNext() {
    final queue = _playQueue;
    if (queue == null || queue.isEmpty) {
      return;
    }
    final index = queue.indexAfterManualNext(_playMode);
    if (index == null) {
      return;
    }
    queue.moveTo(index);
    final song = queue.current;
    if (song != null) {
      unawaited(
        _selectSong(
          song,
          queueSongs: queue.songs,
          queueIndex: index,
          sourcePlaylistId: queue.sourcePlaylistId,
        ),
      );
    }
  }

  void _playPrevious() {
    final queue = _playQueue;
    if (queue == null || queue.isEmpty) {
      return;
    }
    final index = queue.indexAfterPrevious(_playMode);
    if (index == null) {
      return;
    }
    queue.moveTo(index);
    final song = queue.current;
    if (song != null) {
      unawaited(
        _selectSong(
          song,
          queueSongs: queue.songs,
          queueIndex: index,
          sourcePlaylistId: queue.sourcePlaylistId,
        ),
      );
    }
  }

  Future<void> _changePlayMode(PlayMode mode) async {
    if (mode == _playMode) {
      return;
    }
    setState(() => _playMode = mode);
    try {
      _store?.setPlayMode(mode);
    } on Object catch (error) {
      _showSnackBar('播放模式保存失败：${_messageFor(error)}');
    }
  }

  void _changeVolume(double value) {
    final volume = value.clamp(0.0, 1.0);
    setState(() => _volume = volume);
    unawaited(
      _player.setVolume(volume).catchError((Object error) {
        if (mounted) {
          setState(() => _playbackError = '音量调整失败：${_messageFor(error)}');
        }
      }),
    );
    _volumeSaveTimer?.cancel();
    _volumeSaveTimer = Timer(const Duration(milliseconds: 300), () {
      try {
        _store?.setVolume(volume);
      } on Object catch (error) {
        _showSnackBar('音量保存失败：${_messageFor(error)}');
      }
    });
  }

  Future<void> _changeQuality(String quality) async {
    final song = _selectedSong;
    final current = _playback;
    if (song == null ||
        current == null ||
        !current.available ||
        quality == current.quality ||
        _loadingPlayback ||
        _switchingQuality) {
      return;
    }
    if (!song.availableQualities.contains(quality)) {
      return;
    }

    var switchPosition = _position;
    final sequence = _selectionSequence;
    final wasPlaying = _playerState == PlaybackEngineState.playing;
    setState(() {
      _switchingQuality = true;
      _playbackError = null;
    });
    try {
      final next = await _api.playback(
        song,
        quality: quality,
        allowFallback: false,
      );
      if (!_currentSelection(sequence)) return;
      if (!next.available) {
        throw MusicApiException(next.reasonLabel);
      }
      await _serializeSource(sequence, () async {
        // 旧音频在请求新地址期间仍在播放，因此必须在真正替换音源前取进度。
        switchPosition = _position;
        try {
          await _setPlayerSource(
            next.url,
            song.source,
            initialPosition: switchPosition,
          );
          if (!_currentSelection(sequence)) return;
          if (wasPlaying) await _player.resume();
        } on Object {
          // 只为同一首歌回滚；过期音质请求不能恢复旧歌并停止新歌。
          if (!_currentSelection(sequence)) return;
          await _setPlayerSource(
            current.url,
            song.source,
            initialPosition: switchPosition,
          );
          if (_currentSelection(sequence) && wasPlaying) await _player.resume();
          rethrow;
        }
      });
      if (!_currentSelection(sequence)) return;
      setState(() {
        _playback = next;
        _position = switchPosition;
        _activeLyricIndex = LrcParser.activeIndex(_lyricLines, switchPosition);
        if (song.source == MusicSource.qq) {
          _preferredQualityQq = quality;
        } else {
          _preferredQualityNetease = quality;
        }
      });
      _syncDesktopLyrics(force: true);
      _store?.setPreferredQuality(quality, song.source);
    } on Object catch (error) {
      if (_currentSelection(sequence)) {
        setState(() => _playbackError = '音质切换失败：${_messageFor(error)}');
      }
    } finally {
      if (_currentSelection(sequence)) {
        setState(() => _switchingQuality = false);
      }
    }
  }

  void _touchRecentlyPlayed(Song song) {
    final store = _store;
    if (store == null) {
      return;
    }
    try {
      store.touchRecentlyPlayed(song.source, song.id);
      final snapshot = store.snapshot();
      if (!mounted) {
        return;
      }
      setState(() {
        _snapshot = snapshot;
        if (_selectedPlaylistId == recentlyPlayedPlaylistId) {
          _playlistSongs = _songsForPlaylist(snapshot.recentlyPlayed);
        }
      });
    } on Object catch (error) {
      if (mounted) {
        _showSnackBar('最近播放记录失败：${_messageFor(error)}');
      }
    }
  }

  Future<void> _createPlaylist() async {
    final store = _store;
    if (store == null) {
      _showSnackBar('本地歌单尚未加载完成');
      return;
    }
    final name = await _promptPlaylistName(title: '新建歌单');
    if (name == null || !mounted) {
      return;
    }
    try {
      final playlist = store.createPlaylist(name);
      final snapshot = store.snapshot();
      setState(() => _snapshot = snapshot);
      _showSnackBar('已创建“${playlist.name}”');
    } on Object catch (error) {
      _showSnackBar(_messageFor(error));
    }
  }

  Future<void> _renamePlaylist(Playlist playlist) async {
    final store = _store;
    if (store == null || !playlist.allowsLocalManagement) {
      return;
    }
    final name = await _promptPlaylistName(
      title: '重命名歌单',
      initialValue: playlist.name,
    );
    if (name == null || !mounted) {
      return;
    }
    try {
      store.renamePlaylist(playlist.id, name);
      final snapshot = store.snapshot();
      setState(() => _snapshot = snapshot);
      _showSnackBar('歌单已重命名');
    } on Object catch (error) {
      _showSnackBar(_messageFor(error));
    }
  }

  Future<void> _deletePlaylist(Playlist playlist) async {
    final store = _store;
    if (store == null || !playlist.allowsLocalManagement) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AppDialog(
        title: '删除歌单',
        description: '本地记录会一并删除，此操作无法撤销。',
        icon: Icons.delete_outline_rounded,
        width: 440,
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: AppColors.accentOn,
            ),
            child: const Text('删除'),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.errorSurface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: AppColors.errorBorder),
          ),
          child: Row(
            children: <Widget>[
              const Icon(
                Icons.queue_music_rounded,
                size: 20,
                color: AppColors.error,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  playlist.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${playlist.songs.length} 首',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !mounted) {
      return;
    }
    try {
      store.deletePlaylist(playlist.id);
      final snapshot = store.snapshot();
      setState(() {
        _snapshot = snapshot;
        if (_selectedPlaylistId == playlist.id) {
          _searchSelected = true;
          _selectedPlaylistId = null;
          _playlistSongs = const <Song>[];
        }
      });
      _showSnackBar('歌单已删除');
    } on Object catch (error) {
      _showSnackBar(_messageFor(error));
    }
  }

  Future<void> _refreshRemotePlaylists() async {
    final store = _store;
    final source = _selectedSource;
    final account = _activeAccount;
    if (store == null) {
      _showSnackBar('本地歌单尚未加载完成');
      return;
    }
    if (account == null || !account.canSwitch) {
      _showSnackBar('请先扫码授权${source.label}账号');
      return;
    }
    if (_refreshingRemotePlaylists) {
      return;
    }

    final requestedAccountID = account.accountId;
    setState(() => _refreshingRemotePlaylists = true);
    try {
      final remotePlaylists = await _api.remotePlaylists(account);
      if (!mounted) {
        return;
      }

      // 网络请求成功后才替换缓存；失败时继续保留上一次可用数据。
      store.replaceRemotePlaylists(source, requestedAccountID, remotePlaylists);
      final snapshot = store.snapshot();
      final selected = snapshot.playlistById(_selectedPlaylistId ?? '');
      final activeAccountID = snapshot.accountFor(source)?.accountId ?? '';
      final keepRemoteSelection =
          selected != null &&
          selected.isRemote &&
          selected.musicSource == source &&
          selected.accountId == activeAccountID;
      final clearSelection =
          selected != null &&
          selected.isRemote &&
          (selected.musicSource != source ||
              selected.accountId != activeAccountID);
      if (clearSelection) {
        _playlistSequence++;
      }

      setState(() {
        _snapshot = snapshot;
        if (clearSelection) {
          _searchSelected = true;
          _selectedPlaylistId = null;
          _playlistSongs = const <Song>[];
          _playlistError = null;
          _loadingPlaylist = false;
        }
      });
      if (keepRemoteSelection) {
        _selectPlaylist(selected.id);
      }
      _showSnackBar('已刷新 ${remotePlaylists.length} 个远程歌单');
    } on MusicApiException catch (error) {
      if (!mounted) {
        return;
      }
      if (error.statusCode == 401) {
        store.clearClientAccountAccessKey(source, requestedAccountID);
        final snapshot = store.snapshot();
        final nextAccount = snapshot.accountFor(source);
        _api.setAccount(source, nextAccount);
        if (source == _selectedSource) {
          _api.setActiveAccount(
            source,
            nextAccount?.canSwitch == true ? nextAccount : null,
          );
        }
        final selected = snapshot.playlistById(_selectedPlaylistId ?? '');
        final clearSelection =
            selected?.isRemote == true &&
            (selected?.musicSource != source ||
                selected?.accountId != (nextAccount?.accountId ?? ''));
        if (clearSelection) {
          _playlistSequence++;
        }
        setState(() {
          _snapshot = snapshot;
          if (clearSelection) {
            _searchSelected = true;
            _selectedPlaylistId = null;
            _playlistSongs = const <Song>[];
            _playlistError = null;
            _loadingPlaylist = false;
          }
        });
        _showSnackBar('${source.label}授权已过期，旧远程缓存已保留，请重新扫码授权');
      } else {
        _showSnackBar('刷新远程歌单失败：${error.message}');
      }
    } on Object catch (error) {
      if (mounted) {
        _showSnackBar('刷新远程歌单失败：${_messageFor(error)}');
      }
    } finally {
      if (mounted) {
        setState(() => _refreshingRemotePlaylists = false);
      }
    }
  }

  Future<void> _importRemotePlaylist() async {
    final store = _store;
    final snapshot = _snapshot;
    if (store == null || snapshot == null) {
      _showSnackBar('本地歌单尚未加载完成');
      return;
    }
    final account = _activeAccount;
    final remotePlaylists = snapshot.remotePlaylistsFor(
      _selectedSource,
      account?.accountId ?? '',
    );
    if (remotePlaylists.isEmpty) {
      _showSnackBar('暂无远程歌单缓存，请先刷新远程歌单');
      return;
    }
    final localPlaylists = snapshot.customPlaylists;
    if (localPlaylists.isEmpty) {
      _showSnackBar('请先新建一个本地歌单');
      return;
    }

    var selectedSourceId = remotePlaylists.first.id;
    var selectedTargetId = localPlaylists.first.id;
    final selection = await showDialog<_PlaylistImportSelection>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AppDialog(
          title: '导入远程歌单',
          description: '按远程歌单顺序追加到本地歌单末尾，已存在的歌曲自动跳过。',
          icon: Icons.playlist_add_rounded,
          width: 470,
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey<String>('confirm-import-playlist'),
              onPressed: () => Navigator.of(dialogContext).pop(
                _PlaylistImportSelection(
                  sourcePlaylistId: selectedSourceId,
                  targetPlaylistId: selectedTargetId,
                ),
              ),
              child: const Text('开始导入'),
            ),
          ],
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              AppSelectField<String>(
                fieldKey: const ValueKey<String>('import-source-playlist'),
                value: selectedSourceId,
                labelText: '远程歌单',
                prefixIcon: Icons.cloud_queue_rounded,
                items: <DropdownMenuItem<String>>[
                  for (final playlist in remotePlaylists)
                    DropdownMenuItem<String>(
                      value: playlist.id,
                      child: Text(
                        '${playlist.name}（${playlist.songs.length} 首）',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setDialogState(() => selectedSourceId = value);
                  }
                },
              ),
              const SizedBox(height: 14),
              AppSelectField<String>(
                fieldKey: const ValueKey<String>('import-target-playlist'),
                value: selectedTargetId,
                labelText: '导入到本地歌单',
                prefixIcon: Icons.queue_music_rounded,
                items: <DropdownMenuItem<String>>[
                  for (final playlist in localPlaylists)
                    DropdownMenuItem<String>(
                      value: playlist.id,
                      child: Text(
                        '${playlist.name}（${playlist.songs.length} 首）',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setDialogState(() => selectedTargetId = value);
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
    if (selection == null || !mounted) {
      return;
    }

    try {
      final source = snapshot.playlistById(selection.sourcePlaylistId);
      final target = snapshot.playlistById(selection.targetPlaylistId);
      if (source == null || target == null) {
        _showSnackBar('歌单数据已经变化，请重试');
        return;
      }
      final added = store.importPlaylistSongs(
        sourcePlaylistId: source.id,
        targetPlaylistId: target.id,
      );
      final skipped = source.songs.length - added;
      final nextSnapshot = store.snapshot();
      setState(() => _snapshot = nextSnapshot);
      if (_selectedPlaylistId == target.id) {
        _selectPlaylist(target.id);
      }
      _showSnackBar('已导入 $added 首歌曲，跳过 $skipped 首已存在歌曲');
    } on Object catch (error) {
      _showSnackBar('导入失败：${_messageFor(error)}');
    }
  }

  Future<void> _addRemoteSongToLocalPlaylist(Song song) async {
    await _chooseLocalPlaylistForSong(song);
  }

  Future<void> _addSongToOtherLocalPlaylist(
    Song song,
    String currentPlaylistId,
  ) async {
    await _chooseLocalPlaylistForSong(
      song,
      disabledPlaylistId: currentPlaylistId,
    );
  }

  Future<void> _chooseLocalPlaylistForSong(
    Song song, {
    String? disabledPlaylistId,
  }) async {
    final localPlaylists = _snapshot?.customPlaylists ?? const <Playlist>[];
    if (localPlaylists.isEmpty) {
      _showSnackBar('请先新建一个本地歌单');
      return;
    }
    final target = await showDialog<Playlist>(
      context: context,
      builder: (dialogContext) => AppDialog(
        title: '添加到本地歌单',
        description: '选择“${song.name}”要加入的歌单。',
        icon: Icons.playlist_add_rounded,
        width: 470,
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
        ],
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 330),
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: localPlaylists.length,
            separatorBuilder: (_, _) => const SizedBox(height: 7),
            itemBuilder: (context, index) {
              final playlist = localPlaylists[index];
              final isCurrent = playlist.id == disabledPlaylistId;
              return AppChoiceTile(
                key: ValueKey<String>('target-playlist-${playlist.id}'),
                icon: Icons.queue_music_rounded,
                title: playlist.name,
                subtitle: isCurrent
                    ? '当前歌单，请选择其他歌单'
                    : '${playlist.songs.length} 首歌曲',
                enabled: !isCurrent,
                trailing: isCurrent
                    ? const Icon(
                        Icons.check_circle_rounded,
                        size: 18,
                        color: Color(0xFF5E6875),
                      )
                    : const Icon(
                        Icons.chevron_right_rounded,
                        size: 18,
                        color: Color(0xFF68717E),
                      ),
                onTap: () => Navigator.of(dialogContext).pop(playlist),
              );
            },
          ),
        ),
      ),
    );
    if (target == null || !mounted) {
      return;
    }
    _addSongToPlaylist(song, target.id);
  }

  Future<String?> _promptPlaylistName({
    required String title,
    String initialValue = '',
  }) {
    return showDialog<String>(
      context: context,
      builder: (context) =>
          PlaylistNameDialog(title: title, initialValue: initialValue),
    );
  }

  void _addSongToPlaylist(Song song, String playlistId) {
    final store = _store;
    if (store == null) {
      _showSnackBar('本地歌单尚未加载完成');
      return;
    }
    try {
      final added = store.addSongToPlaylist(playlistId, song.source, song.id);
      final snapshot = store.snapshot();
      _cacheSongs(<Song>[song]);
      setState(() => _snapshot = snapshot);
      final playlist = snapshot.playlistById(playlistId);
      if (!added) {
        _showSnackBar('“${song.name}”已经在“${playlist?.name ?? '歌单'}”中');
        return;
      }
      _showSnackBar('已添加到“${playlist?.name ?? '歌单'}”');
    } on Object catch (error) {
      _showSnackBar(_messageFor(error));
    }
  }

  void _removeSongFromPlaylist(Playlist playlist, Song song) {
    final store = _store;
    if (store == null || !playlist.isLocal) {
      return;
    }
    try {
      final removed = store.removeSongFromPlaylist(
        playlist.id,
        song.source,
        song.id,
      );
      if (!removed) {
        return;
      }
      final snapshot = store.snapshot();
      final current = snapshot.playlistById(playlist.id);
      setState(() {
        _snapshot = snapshot;
        _playlistSongs = current == null
            ? const <Song>[]
            : _songsForPlaylist(current);
      });
      _showSnackBar('已从“${playlist.name}”移除');
    } on Object catch (error) {
      _showSnackBar(_messageFor(error));
    }
  }

  void _reorderPlaylistSongs(int oldIndex, int newIndex) {
    final store = _store;
    final playlist = _snapshot?.playlistById(_selectedPlaylistId ?? '');
    if (store == null || playlist == null || !playlist.allowsReorder) {
      return;
    }
    final songs = List<Song>.of(_playlistSongs);
    if (oldIndex < 0 || oldIndex >= songs.length) {
      return;
    }
    if (newIndex < 0 || newIndex >= songs.length || newIndex == oldIndex) {
      return;
    }
    final moved = songs.removeAt(oldIndex);
    songs.insert(newIndex, moved);
    try {
      store.reorderSongs(
        playlist.id,
        songs
            .map(
              (song) => PlaylistSongRef(source: song.source, songId: song.id),
            )
            .toList(growable: false),
      );
      final snapshot = store.snapshot();
      setState(() {
        _snapshot = snapshot;
        _playlistSongs = songs;
      });
    } on Object catch (error) {
      _showSnackBar('排序保存失败：${_messageFor(error)}');
    }
  }

  void _showSnackBar(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _messageFor(Object error) {
    if (error is MusicApiException) {
      return error.message;
    }
    if (error is PlatformException) {
      return '音频加载失败，当前平台源文件可能不存在或已下架，请尝试其他版本';
    }
    return error.toString();
  }

  void _switchMusicSource(MusicSource source) {
    if (source == _selectedSource) {
      return;
    }
    _searchResultsBySource[_selectedSource] = _searchResults;
    _searchQueryBySource[_selectedSource] = _searchController.text.trim();
    _searchSequence++;
    final nextQuery = _searchQueryBySource[source] ?? '';
    final selected = _snapshot?.playlistById(_selectedPlaylistId ?? '');
    final clearRemoteSelection = selected?.isRemote == true;
    _store?.setSelectedSource(source);
    final snapshot = _store?.snapshot();
    if (snapshot != null) {
      _api.setAccount(MusicSource.qq, snapshot.qqAccount);
      _api.setAccount(MusicSource.netease, snapshot.neteaseAccount);
    }
    _searchController.value = TextEditingValue(
      text: nextQuery,
      selection: TextSelection.collapsed(offset: nextQuery.length),
    );
    if (clearRemoteSelection) {
      _playlistSequence++;
    }
    setState(() {
      _selectedSource = source;
      if (snapshot != null) {
        _snapshot = snapshot;
        _qqAccount = snapshot.qqAccount;
        _neteaseAccount = snapshot.neteaseAccount;
        _preferredQualityQq = snapshot.preferredQualityQq;
        _preferredQualityNetease = snapshot.preferredQualityNetease;
      }
      _searchResults = _searchResultsBySource[source] ?? const <Song>[];
      _lastSearchQuery = nextQuery;
      _searchError = null;
      _searching = false;
      if (clearRemoteSelection) {
        _searchSelected = true;
        _selectedPlaylistId = null;
        _playlistSongs = const <Song>[];
        _playlistError = null;
        _loadingPlaylist = false;
      }
    });
    _api.setActiveAccount(source, _activeAccount);
  }

  Future<void> _openAccountPanel() async {
    if (_openingAccountLogin) {
      return;
    }
    final store = _store;
    if (store == null) {
      _showSnackBar('本地存储尚未初始化，请稍后重试');
      return;
    }

    setState(() => _openingAccountLogin = true);
    try {
      await AccountDialog.show(
        context,
        api: _api,
        store: store,
        activeAccount: _activeAccount,
        source: _selectedSource,
      );
      if (!mounted) {
        return;
      }
      final snapshot = store.snapshot();
      final source = snapshot.selectedSource;
      final account = snapshot.accountFor(source);
      _api.setAccount(MusicSource.qq, snapshot.qqAccount);
      _api.setAccount(MusicSource.netease, snapshot.neteaseAccount);
      _api.setActiveAccount(
        source,
        account?.canSwitch == true ? account : null,
      );
      final selected = snapshot.playlistById(_selectedPlaylistId ?? '');
      final clearRemoteSelection =
          selected?.isRemote == true &&
          (selected?.musicSource != source ||
              selected?.accountId != (account?.accountId ?? ''));
      if (clearRemoteSelection) {
        _playlistSequence++;
      }
      setState(() {
        _selectedSource = source;
        _qqAccount = snapshot.qqAccount;
        _neteaseAccount = snapshot.neteaseAccount;
        _preferredQualityQq = snapshot.preferredQualityQq;
        _preferredQualityNetease = snapshot.preferredQualityNetease;
        _snapshot = snapshot;
        if (clearRemoteSelection) {
          _searchSelected = true;
          _selectedPlaylistId = null;
          _playlistSongs = const <Song>[];
          _playlistError = null;
          _loadingPlaylist = false;
        }
      });
    } finally {
      if (mounted) {
        setState(() => _openingAccountLogin = false);
      }
    }
  }

  /// 创建侧边栏；宽屏直接展示，窄屏通过 Scaffold 抽屉展示。
  Widget _buildLibrarySidebar() {
    return LibrarySidebar(
      snapshot: _snapshot,
      error: _libraryError,
      searchSelected: _searchSelected,
      selectedPlaylistId: _selectedPlaylistId,
      onSelectSearch: () {
        if (_scaffoldKey.currentState?.isDrawerOpen == true) {
          Navigator.of(context).pop();
        }
        _selectSearch();
      },
      onSelectPlaylist: (playlistId) {
        if (_scaffoldKey.currentState?.isDrawerOpen == true) {
          Navigator.of(context).pop();
        }
        _selectPlaylist(playlistId);
      },
      onCreatePlaylist: () => unawaited(_createPlaylist()),
      onImportPlaylist: () => unawaited(_importRemotePlaylist()),
      onRefreshRemotePlaylists: _refreshRemotePlaylists,
      refreshingRemotePlaylists: _refreshingRemotePlaylists,
      onRenamePlaylist: (playlist) => unawaited(_renamePlaylist(playlist)),
      onDeletePlaylist: (playlist) => unawaited(_deletePlaylist(playlist)),
    );
  }

  /// 创建主内容面板，在搜索列表和当前歌单之间切换。
  Widget _buildPrimaryPanel() {
    final currentPlaylist = _snapshot?.playlistById(_selectedPlaylistId ?? '');
    if (_searchSelected || currentPlaylist == null) {
      return _SearchResultsPanel(
        songs: _searchResults,
        selectedSong: _selectedSong,
        playing: _playerState == PlaybackEngineState.playing,
        searching: _searching,
        error: _searchError,
        searched: _lastSearchQuery.isNotEmpty,
        lastQuery: _lastSearchQuery,
        scrollController: _resultsScrollController,
        customPlaylists: _snapshot?.customPlaylists ?? const <Playlist>[],
        downloadingSongKeys: _downloadingSongKeys,
        downloadProgress: _downloadProgress,
        onDownload: (song) => unawaited(_downloadSong(song)),
        onPlayMv: (song) => unawaited(_playMv(song)),
        onSelect: (song) {
          final index = _searchResults.indexWhere(
            (item) => item.mediaKey == song.mediaKey,
          );
          if (index < 0) {
            return;
          }
          unawaited(
            _selectSong(
              song,
              queueSongs: _searchResults,
              queueIndex: index,
              sourcePlaylistId: null,
            ),
          );
        },
        onTogglePlayback: () => unawaited(_togglePlayback()),
        onAddSong: _addSongToPlaylist,
      );
    }
    return _PlaylistPanel(
      playlist: currentPlaylist,
      songs: _playlistSongs,
      selectedSong: _selectedSong,
      playing: _playerState == PlaybackEngineState.playing,
      loading: _loadingPlaylist,
      error: _playlistError,
      downloadingSongKeys: _downloadingSongKeys,
      downloadProgress: _downloadProgress,
      onDownload: (song) => unawaited(_downloadSong(song)),
      onPlayMv: (song) => unawaited(_playMv(song)),
      onSelect: (song) {
        final index = _playlistSongs.indexWhere(
          (item) => item.mediaKey == song.mediaKey,
        );
        if (index < 0) {
          return;
        }
        unawaited(
          _selectSong(
            song,
            queueSongs: _playlistSongs,
            queueIndex: index,
            sourcePlaylistId: currentPlaylist.id,
          ),
        );
      },
      onTogglePlayback: () => unawaited(_togglePlayback()),
      onRemove: (song) => _removeSongFromPlaylist(currentPlaylist, song),
      onAddToLocal: (song) => unawaited(_addRemoteSongToLocalPlaylist(song)),
      onAddToPlaylist: (song) =>
          unawaited(_addSongToOtherLocalPlaylist(song, currentPlaylist.id)),
      onReorder: _reorderPlaylistSongs,
      onRename: () => unawaited(_renamePlaylist(currentPlaylist)),
      onDelete: () => unawaited(_deletePlaylist(currentPlaylist)),
    );
  }

  /// 创建歌词面板；宽屏嵌入三栏，窄屏通过右侧抽屉显示。
  Widget _buildLyricsPanel() {
    return LyricsPanel(
      song: _selectedSong,
      lyric: _lyric,
      lines: _lyricLines,
      translations: _translations,
      romanizations: _romanizations,
      activeIndex: _activeLyricIndex,
      loading: _loadingLyrics,
      error: _lyricError,
    );
  }

  /// 创建完整播放页，并复用主页中的实时播放状态。
  Widget _buildNowPlayingPage() {
    return NowPlayingPage(
      song: _selectedSong,
      isPlaying: _playerState == PlaybackEngineState.playing,
      lyric: _lyric,
      lyricLines: _lyricLines,
      translations: _translations,
      romanizations: _romanizations,
      activeLyricIndex: _activeLyricIndex,
      loadingLyrics: _loadingLyrics,
      lyricError: _lyricError,
    );
  }

  Widget _buildMobileNowPlayingPage() {
    final song = _selectedSong;
    final duration = _duration > Duration.zero
        ? _duration
        : Duration(seconds: song?.durationSeconds ?? 0);
    return MobileNowPlayingPage(
      key: _mobilePlayerKey,
      song: song,
      playback: _playback,
      position: _position,
      duration: duration,
      isPlaying: _playerState == PlaybackEngineState.playing,
      loading: _loadingPlayback,
      switchingQuality: _switchingQuality,
      error: _playbackError,
      playMode: _playMode,
      volume: _volume,
      availableQualities: song?.availableQualities ?? const <String>[],
      canSkip: _playQueue != null && !_playQueue!.isEmpty,
      downloading: song != null && _downloadingSongKeys.contains(song.mediaKey),
      desktopLyricsSupported: _desktopLyrics.isSupported,
      desktopLyricsVisible: _desktopLyricsVisible,
      lyric: _lyric,
      lyricLines: _lyricLines,
      translations: _translations,
      romanizations: _romanizations,
      activeLyricIndex: _activeLyricIndex,
      loadingLyrics: _loadingLyrics,
      lyricError: _lyricError,
      onClose: () => setState(() => _showNowPlaying = false),
      onTogglePlayback: () => unawaited(_togglePlayback()),
      onSeek: (position) => unawaited(_seek(position)),
      onPrevious: _playPrevious,
      onNext: _playNext,
      onPlayModeChanged: (mode) => unawaited(_changePlayMode(mode)),
      onVolumeChanged: _changeVolume,
      onQualityChanged: (quality) => unawaited(_changeQuality(quality)),
      onDownload: song == null ? null : () => unawaited(_downloadSong(song)),
      onAddToPlaylist: song == null
          ? null
          : () => unawaited(_addRemoteSongToLocalPlaylist(song)),
      onToggleDesktopLyrics: _toggleMobileDesktopLyrics,
    );
  }

  Widget _buildMobileApp(BuildContext context) {
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final currentPlaylist = _snapshot?.playlistById(_selectedPlaylistId ?? '');
    final playlistOpen =
        _mobileTab == 1 && !_searchSelected && currentPlaylist != null;
    return PopScope<Object?>(
      canPop: !_showNowPlaying && !playlistOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_showNowPlaying) {
          if (_mobilePlayerKey.currentState?.handleBack() != true) {
            setState(() => _showNowPlaying = false);
          }
        } else if (playlistOpen) {
          _closeMobilePlaylist();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: _showNowPlaying
            ? _buildMobileNowPlayingPage()
            : SafeArea(
                child: Column(
                  children: <Widget>[
                    Offstage(
                      offstage: keyboardVisible,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: MusicSourceSwitcher(
                            selected: _selectedSource,
                            qqAccount: _qqAccount,
                            neteaseAccount: _neteaseAccount,
                            onChanged: _switchMusicSource,
                            compact: true,
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: _buildMobilePage()),
                    if (_selectedSong != null)
                      Offstage(
                        offstage: keyboardVisible,
                        child: MobileMiniPlayer(
                          song: _selectedSong!,
                          position: _position,
                          duration: _duration,
                          isPlaying:
                              _playerState == PlaybackEngineState.playing,
                          loading: _loadingPlayback,
                          error: _playbackError,
                          onOpen: () => setState(() => _showNowPlaying = true),
                          onTogglePlayback: () => unawaited(_togglePlayback()),
                        ),
                      ),
                    Offstage(
                      offstage: keyboardVisible,
                      child: MobileBottomNavigation(
                        selectedIndex: _mobileTab,
                        onSelected: _switchMobileTab,
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  void _switchMobileTab(int index) {
    _searchFocusNode.unfocus();
    if (index == 1 && _mobileTab == 1) {
      _closeMobilePlaylist();
      return;
    }
    setState(() => _mobileTab = index);
  }

  void _closeMobilePlaylist() {
    _playlistSequence++;
    setState(() {
      _selectedPlaylistId = null;
      _playlistSongs = const <Song>[];
      _playlistError = null;
      _loadingPlaylist = false;
      _searchSelected = false;
      _mobileTab = 1;
    });
  }

  Widget _buildMobilePage() {
    final snapshot = _snapshot;
    final account = _activeAccount;
    final avatarUrl = account?.avatarUrl.trim().isNotEmpty == true
        ? _api.resolveUrl(account!.avatarUrl)
        : '';
    if (_mobileTab == 1) {
      final playlist = snapshot?.playlistById(_selectedPlaylistId ?? '');
      if (!_searchSelected && playlist != null) {
        return MobilePlaylistPage(
          playlist: playlist,
          songs: _playlistSongs,
          selectedSong: _selectedSong,
          playing: _playerState == PlaybackEngineState.playing,
          loading: _loadingPlaylist,
          error: _playlistError,
          downloadingSongKeys: _downloadingSongKeys,
          downloadProgress: _downloadProgress,
          onBack: _closeMobilePlaylist,
          onSelect: (song) {
            final index = _playlistSongs.indexWhere(
              (item) => item.mediaKey == song.mediaKey,
            );
            if (index < 0) return;
            unawaited(
              _selectSong(
                song,
                queueSongs: _playlistSongs,
                queueIndex: index,
                sourcePlaylistId: playlist.id,
              ),
            );
          },
          onTogglePlayback: () => unawaited(_togglePlayback()),
          onDownload: (song) => unawaited(_downloadSong(song)),
          onPlayMv: (song) => unawaited(_playMv(song)),
          onAddToPlaylist: (song) {
            if (playlist.isRemote) {
              unawaited(_addRemoteSongToLocalPlaylist(song));
            } else {
              unawaited(_addSongToOtherLocalPlaylist(song, playlist.id));
            }
          },
          onRemoveSong: (song) => _removeSongFromPlaylist(playlist, song),
          onRename: () => unawaited(_renamePlaylist(playlist)),
          onDelete: () => unawaited(_deletePlaylist(playlist)),
        );
      }
      return MobileLibraryPage(
        snapshot: snapshot,
        error: _libraryError,
        refreshingRemotePlaylists: _refreshingRemotePlaylists,
        onCreatePlaylist: () => unawaited(_createPlaylist()),
        onImportPlaylist: () => unawaited(_importRemotePlaylist()),
        onRefreshRemotePlaylists: _refreshRemotePlaylists,
        onOpenPlaylist: (playlist) {
          setState(() {
            _mobileTab = 1;
            _searchSelected = false;
          });
          _selectPlaylist(playlist.id);
        },
        onRenamePlaylist: (playlist) => unawaited(_renamePlaylist(playlist)),
        onDeletePlaylist: (playlist) => unawaited(_deletePlaylist(playlist)),
        onOpenAccount: () => unawaited(_openAccountPanel()),
      );
    }
    if (_mobileTab == 2) {
      return MobileAccountPage(
        account: account,
        source: _selectedSource,
        avatarUrl: avatarUrl,
        openingAccountLogin: _openingAccountLogin,
        localPlaylistCount: snapshot?.localPlaylists.length ?? 0,
        remotePlaylistCount:
            snapshot
                ?.remotePlaylistsFor(_selectedSource, account?.accountId ?? '')
                .length ??
            0,
        onOpenAccount: () => unawaited(_openAccountPanel()),
        onOpenNotificationSettings: () =>
            unawaited(openAndroidNotificationSettings()),
      );
    }
    return MobileSearchPage(
      source: _selectedSource,
      controller: _searchController,
      focusNode: _searchFocusNode,
      searching: _searching,
      account: account,
      accountAvatarUrl: avatarUrl,
      openingAccountLogin: _openingAccountLogin,
      songs: _searchResults,
      selectedSong: _selectedSong,
      playing: _playerState == PlaybackEngineState.playing,
      error: _searchError,
      searched: _lastSearchQuery.isNotEmpty,
      lastQuery: _lastSearchQuery,
      downloadingSongKeys: _downloadingSongKeys,
      downloadProgress: _downloadProgress,
      onSearch: () => unawaited(_search()),
      onAccountPressed: () => unawaited(_openAccountPanel()),
      onSelect: (song) {
        final index = _searchResults.indexWhere(
          (item) => item.mediaKey == song.mediaKey,
        );
        if (index < 0) return;
        unawaited(
          _selectSong(
            song,
            queueSongs: _searchResults,
            queueIndex: index,
            sourcePlaylistId: null,
          ),
        );
      },
      onTogglePlayback: () => unawaited(_togglePlayback()),
      onDownload: (song) => unawaited(_downloadSong(song)),
      onPlayMv: (song) => unawaited(_playMv(song)),
      onAddToPlaylist: (song) => unawaited(_addRemoteSongToLocalPlaylist(song)),
    );
  }

  void _toggleMobileDesktopLyrics() {
    if (!_desktopLyrics.isSupported) {
      _showSnackBar('当前平台不支持桌面歌词');
      return;
    }
    unawaited(_toggleDesktopLyrics());
  }

  @override
  Widget build(BuildContext context) {
    if (AppPlatform.isMobile) {
      return _buildMobileApp(context);
    }
    final queue = _playQueue;
    final screenWidth = MediaQuery.sizeOf(context).width;
    // Scaffold removes bottom insets from its resized body. Read the keyboard
    // state here, before entering that body, rather than from LayoutBuilder.
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    final libraryDrawerWidth = screenWidth * 0.86 < 236
        ? screenWidth * 0.86
        : 236.0;
    final lyricsDrawerWidth = screenWidth * 0.9 < 440
        ? screenWidth * 0.9
        : 440.0;
    return PopScope<Object?>(
      canPop: !_showNowPlaying,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showNowPlaying) setState(() => _showNowPlaying = false);
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: Drawer(
          width: libraryDrawerWidth,
          backgroundColor: Colors.transparent,
          child: SafeArea(child: _buildLibrarySidebar()),
        ),
        endDrawer: Drawer(
          width: lyricsDrawerWidth,
          backgroundColor: Colors.transparent,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 16, 16, 16),
              child: _buildLyricsPanel(),
            ),
          ),
        ),
        body: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final showSidebar = AppPlatform.isDesktop && width >= 900;
              final showLyrics = AppPlatform.isDesktop && width >= 1280;
              final compactPadding = width < 600;
              final content = DecoratedBox(
                decoration: const BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(-0.8, -1.05),
                    radius: 1.15,
                    colors: <Color>[Color(0xFF18241E), Color(0xFF101218)],
                    stops: <double>[0, 0.58],
                  ),
                ),
                child: Column(
                  children: <Widget>[
                    _TopSearchBar(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      searching: _searching,
                      source: _selectedSource,
                      qqAccount: _qqAccount,
                      neteaseAccount: _neteaseAccount,
                      account: _activeAccount,
                      accountAvatarUrl:
                          _activeAccount?.avatarUrl.trim().isNotEmpty == true
                          ? _api.resolveUrl(_activeAccount!.avatarUrl)
                          : '',
                      openingAccountLogin: _openingAccountLogin,
                      showLibraryButton: !showSidebar,
                      showLyricsButton: !showLyrics,
                      onSearch: _search,
                      onSourceChanged: _switchMusicSource,
                      onAccountPressed: () => unawaited(_openAccountPanel()),
                      onOpenLibrary: () =>
                          _scaffoldKey.currentState?.openDrawer(),
                      onOpenLyrics: () =>
                          _scaffoldKey.currentState?.openEndDrawer(),
                    ),
                    Expanded(
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(
                          compactPadding ? 10 : 24,
                          4,
                          compactPadding ? 10 : 24,
                          compactPadding ? 8 : 18,
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            if (showSidebar) ...<Widget>[
                              _buildLibrarySidebar(),
                              const SizedBox(width: 18),
                            ],
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  Expanded(
                                    flex: showLyrics ? 11 : 1,
                                    child: _buildPrimaryPanel(),
                                  ),
                                  if (showLyrics) ...<Widget>[
                                    const SizedBox(width: 18),
                                    Expanded(
                                      flex: 9,
                                      child: _buildLyricsPanel(),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
              return Column(
                children: <Widget>[
                  Expanded(
                    child: Stack(
                      fit: StackFit.expand,
                      children: <Widget>[
                        content,
                        IgnorePointer(
                          ignoring: !_showNowPlaying,
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 460),
                            reverseDuration: const Duration(milliseconds: 340),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            layoutBuilder: (currentChild, previousChildren) {
                              return Stack(
                                fit: StackFit.expand,
                                children: <Widget>[
                                  ...previousChildren,
                                  ?currentChild,
                                ],
                              );
                            },
                            transitionBuilder: (child, animation) {
                              final curved = CurvedAnimation(
                                parent: animation,
                                curve: Curves.easeOutCubic,
                                reverseCurve: Curves.easeInCubic,
                              );
                              return FadeTransition(
                                opacity: curved,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, 0.025),
                                    end: Offset.zero,
                                  ).animate(curved),
                                  child: ScaleTransition(
                                    scale: Tween<double>(
                                      begin: 0.985,
                                      end: 1,
                                    ).animate(curved),
                                    child: child,
                                  ),
                                ),
                              );
                            },
                            child: _showNowPlaying
                                ? KeyedSubtree(
                                    key: const ValueKey<String>(
                                      'now-playing-layer',
                                    ),
                                    child: Stack(
                                      fit: StackFit.expand,
                                      children: [
                                        _buildNowPlayingPage(),
                                        if (AppPlatform.isMobile)
                                          Positioned(
                                            left: 4,
                                            top: 4,
                                            child: IconButton(
                                              key: const ValueKey<String>(
                                                'close-now-playing-mobile',
                                              ),
                                              tooltip: '返回音乐库',
                                              onPressed: () => setState(
                                                () => _showNowPlaying = false,
                                              ),
                                              icon: const Icon(
                                                Icons
                                                    .keyboard_arrow_down_rounded,
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  )
                                : const SizedBox.expand(
                                    key: ValueKey<String>('main-content-layer'),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!AppPlatform.isMobile || !keyboardVisible)
                    PlayerBar(
                      song: _selectedSong,
                      playback: _playback,
                      position: _position,
                      duration: _duration,
                      isPlaying: _playerState == PlaybackEngineState.playing,
                      loading: _loadingPlayback,
                      switchingQuality: _switchingQuality,
                      error: _playbackError,
                      playMode: _playMode,
                      volume: _volume,
                      availableQualities:
                          _selectedSong?.availableQualities ?? const <String>[],
                      canSkip: queue != null && !queue.isEmpty,
                      downloading:
                          _selectedSong != null &&
                          _downloadingSongKeys.contains(
                            _selectedSong!.mediaKey,
                          ),
                      desktopLyricsSupported: _desktopLyrics.isSupported,
                      desktopLyricsVisible: _desktopLyricsVisible,
                      onTogglePlayback: () => unawaited(_togglePlayback()),
                      onSeek: (position) => unawaited(_seek(position)),
                      onPrevious: _playPrevious,
                      onNext: _playNext,
                      onPlayModeChanged: (mode) =>
                          unawaited(_changePlayMode(mode)),
                      onVolumeChanged: _changeVolume,
                      onQualityChanged: (quality) =>
                          unawaited(_changeQuality(quality)),
                      onDownload: _selectedSong == null
                          ? null
                          : () => unawaited(_downloadSong(_selectedSong!)),
                      onToggleDesktopLyrics: _selectedSong == null
                          ? null
                          : () => unawaited(_toggleDesktopLyrics()),
                      nowPlayingExpanded: _showNowPlaying,
                      onToggleNowPlaying: _selectedSong == null
                          ? null
                          : () => setState(
                              () => _showNowPlaying = !_showNowPlaying,
                            ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// 顶部搜索输入框的统一焦点、悬停和快捷键反馈。
class _SearchFieldShell extends StatefulWidget {
  const _SearchFieldShell({
    required this.controller,
    required this.focusNode,
    required this.searching,
    required this.compact,
    required this.showSearchButton,
    required this.showShortcutHint,
    required this.onSearch,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool searching;
  final bool compact;
  final bool showSearchButton;
  final bool showShortcutHint;
  final VoidCallback onSearch;

  @override
  State<_SearchFieldShell> createState() => _SearchFieldShellState();
}

class _SearchFieldShellState extends State<_SearchFieldShell> {
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_handleFocusChanged);
  }

  @override
  void didUpdateWidget(covariant _SearchFieldShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      oldWidget.focusNode.removeListener(_handleFocusChanged);
      widget.focusNode.addListener(_handleFocusChanged);
    }
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_handleFocusChanged);
    super.dispose();
  }

  void _handleFocusChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final focused = widget.focusNode.hasFocus;
    final borderColor = focused
        ? AppColors.accent
        : _hovered
        ? AppColors.borderStrong
        : AppColors.border;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: AppDurations.fast,
        curve: Curves.easeOutCubic,
        height: widget.compact ? 46 : 50,
        decoration: BoxDecoration(
          color: focused ? AppColors.surfaceHigh : AppColors.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadii.search),
          border: Border.all(color: borderColor, width: focused ? 1.2 : 1),
          boxShadow: <BoxShadow>[
            const BoxShadow(
              color: Color(0x18000000),
              blurRadius: 18,
              offset: Offset(0, 7),
            ),
            if (focused)
              BoxShadow(
                color: AppColors.accent.withValues(alpha: 0.13),
                blurRadius: 20,
                spreadRadius: 1,
              ),
          ],
        ),
        child: Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('search-field'),
                controller: widget.controller,
                focusNode: widget.focusNode,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => widget.onSearch(),
                onTapOutside: (_) => FocusScope.of(context).unfocus(),
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: widget.compact ? '搜索歌曲、歌手' : '搜索歌曲、歌手或专辑',
                  hintStyle: const TextStyle(
                    color: AppColors.textDisabled,
                    fontSize: 13,
                  ),
                  prefixIcon: const Icon(
                    Icons.search_rounded,
                    color: AppColors.textMuted,
                    size: 21,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                  contentPadding: EdgeInsets.symmetric(
                    vertical: widget.compact ? 13 : 15,
                  ),
                ),
              ),
            ),
            if (widget.showShortcutHint &&
                !focused &&
                !widget.searching) ...<Widget>[
              Container(
                margin: const EdgeInsets.only(right: 9),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(AppRadii.small),
                  border: Border.all(color: AppColors.border),
                ),
                child: Text(
                  AppPlatform.searchShortcutLabel,
                  style: const TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (widget.showSearchButton) ...<Widget>[
              Padding(
                padding: const EdgeInsets.only(right: 7),
                child: FilledButton(
                  key: const ValueKey<String>('search-button'),
                  onPressed: widget.searching ? null : widget.onSearch,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(46, 36),
                    maximumSize: const Size(46, 36),
                    padding: EdgeInsets.zero,
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.accentOn,
                    disabledBackgroundColor: AppColors.accentSoft,
                    disabledForegroundColor: AppColors.accentBorder,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(AppRadii.control),
                    ),
                  ),
                  child: widget.searching
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.accent.withValues(alpha: 0.58),
                          ),
                        )
                      : const Icon(Icons.arrow_forward_rounded, size: 20),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TopSearchBar extends StatelessWidget {
  const _TopSearchBar({
    required this.controller,
    required this.focusNode,
    required this.searching,
    required this.source,
    required this.qqAccount,
    required this.neteaseAccount,
    required this.account,
    required this.accountAvatarUrl,
    required this.openingAccountLogin,
    required this.showLibraryButton,
    required this.showLyricsButton,
    required this.onSearch,
    required this.onSourceChanged,
    required this.onAccountPressed,
    required this.onOpenLibrary,
    required this.onOpenLyrics,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool searching;
  final MusicSource source;
  final ClientAccountSession? qqAccount;
  final ClientAccountSession? neteaseAccount;
  final ClientAccountSession? account;
  final String accountAvatarUrl;
  final bool openingAccountLogin;
  final bool showLibraryButton;
  final bool showLyricsButton;
  final VoidCallback onSearch;
  final ValueChanged<MusicSource> onSourceChanged;
  final VoidCallback onAccountPressed;
  final VoidCallback onOpenLibrary;
  final VoidCallback onOpenLyrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        if (AppPlatform.isMobile) {
          if (MediaQuery.sizeOf(context).height < 500) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Row(
                children: [
                  IconButton(
                    key: const ValueKey<String>('open-library'),
                    tooltip: '打开音乐库',
                    onPressed: onOpenLibrary,
                    icon: const Icon(Icons.library_music_rounded),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _SearchFieldShell(
                      controller: controller,
                      focusNode: focusNode,
                      searching: searching,
                      compact: true,
                      showSearchButton: true,
                      showShortcutHint: false,
                      onSearch: onSearch,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey<String>('open-lyrics'),
                    tooltip: '查看歌词',
                    onPressed: onOpenLyrics,
                    icon: const Icon(Icons.lyrics_outlined),
                  ),
                  IconButton(
                    key: const ValueKey<String>('account-button'),
                    tooltip: '${source.label}账号',
                    onPressed: openingAccountLogin ? null : onAccountPressed,
                    icon: _TopAccountContent(
                      account: account,
                      avatarUrl: accountAvatarUrl,
                      loading: openingAccountLogin,
                      compact: true,
                    ),
                  ),
                ],
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      key: const ValueKey<String>('open-library'),
                      tooltip: '打开音乐库',
                      onPressed: onOpenLibrary,
                      icon: const Icon(Icons.library_music_rounded),
                    ),
                    Expanded(
                      child: Text(
                        'oo music',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      key: const ValueKey<String>('open-lyrics'),
                      tooltip: '查看歌词',
                      onPressed: onOpenLyrics,
                      icon: const Icon(Icons.lyrics_outlined),
                    ),
                    IconButton(
                      key: const ValueKey<String>('account-button'),
                      tooltip: '${source.label}账号',
                      onPressed: openingAccountLogin ? null : onAccountPressed,
                      icon: _TopAccountContent(
                        account: account,
                        avatarUrl: accountAvatarUrl,
                        loading: openingAccountLogin,
                        compact: true,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                _SearchFieldShell(
                  controller: controller,
                  focusNode: focusNode,
                  searching: searching,
                  compact: true,
                  showSearchButton: true,
                  showShortcutHint: false,
                  onSearch: onSearch,
                ),
              ],
            ),
          );
        }
        final compact = width < 1000;
        final showBrand = width >= 740;
        final detailedBrand = width >= 980;
        final accountCompact = width < 940;
        final horizontalPadding = width < 600
            ? 10.0
            : compact
            ? 16.0
            : 28.0;
        return SizedBox(
          height: compact ? 82 : 96,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: horizontalPadding,
              vertical: compact ? 14 : 18,
            ),
            child: Row(
              children: <Widget>[
                if (showLibraryButton) ...<Widget>[
                  IconButton(
                    key: const ValueKey<String>('open-library'),
                    tooltip: '打开音乐库',
                    onPressed: onOpenLibrary,
                    style: _toolbarIconButtonStyle(),
                    icon: const Icon(Icons.library_music_rounded, size: 20),
                  ),
                  const SizedBox(width: 10),
                ],
                MusicSourceSwitcher(
                  selected: source,
                  qqAccount: qqAccount,
                  neteaseAccount: neteaseAccount,
                  onChanged: onSourceChanged,
                  compact: compact,
                ),
                SizedBox(width: compact ? 10 : 14),
                if (showBrand) ...<Widget>[
                  SizedBox(
                    width: detailedBrand ? 208 : 146,
                    child: Row(
                      children: <Widget>[
                        Container(
                          width: detailedBrand ? 45 : 40,
                          height: detailedBrand ? 45 : 40,
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(
                              detailedBrand ? 14 : 12,
                            ),
                            boxShadow: const <BoxShadow>[
                              BoxShadow(
                                color: Color(0x3369DFA0),
                                blurRadius: 22,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.graphic_eq_rounded,
                            color: AppColors.accentOn,
                            size: 27,
                          ),
                        ),
                        SizedBox(width: detailedBrand ? 12 : 9),
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                'oo music',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.headlineSmall?.copyWith(
                                  fontSize: detailedBrand ? 23 : 19,
                                ),
                              ),
                              if (detailedBrand)
                                Text(
                                  '${source.label} · ${AppPlatform.displayName}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: AppColors.textDisabled,
                                    fontSize: 10.5,
                                    letterSpacing: 1,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  SizedBox(width: detailedBrand ? 18 : 12),
                ],
                Expanded(
                  child: _SearchFieldShell(
                    controller: controller,
                    focusNode: focusNode,
                    searching: searching,
                    compact: compact,
                    showSearchButton: width >= 450,
                    showShortcutHint: width >= 1050,
                    onSearch: onSearch,
                  ),
                ),
                if (showLyricsButton) ...<Widget>[
                  SizedBox(width: compact ? 8 : 10),
                  IconButton(
                    key: const ValueKey<String>('open-lyrics'),
                    tooltip: '查看歌词',
                    onPressed: onOpenLyrics,
                    style: _toolbarIconButtonStyle(),
                    icon: const Icon(Icons.lyrics_outlined, size: 20),
                  ),
                ],
                SizedBox(width: compact ? 8 : 18),
                SizedBox(
                  width: accountCompact ? 48 : (account == null ? 126 : 174),
                  height: compact ? 46 : 50,
                  child: OutlinedButton(
                    key: const ValueKey<String>('account-button'),
                    onPressed: openingAccountLogin ? null : onAccountPressed,
                    style: _accountTriggerStyle(
                      horizontalPadding: account == null ? 14 : 9,
                    ),
                    child: _TopAccountContent(
                      account: account,
                      avatarUrl: accountAvatarUrl,
                      loading: openingAccountLogin,
                      compact: accountCompact,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TopAccountContent extends StatelessWidget {
  const _TopAccountContent({
    required this.account,
    required this.avatarUrl,
    required this.loading,
    required this.compact,
  });

  final ClientAccountSession? account;
  final String avatarUrl;
  final bool loading;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final current = account;
    if (loading) {
      return const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (current == null) {
      if (compact) {
        return const Icon(Icons.qr_code_2_rounded, size: 20);
      }
      return const Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(Icons.qr_code_2_rounded, size: 20),
          SizedBox(width: 8),
          Text(
            '扫码登录',
            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      );
    }
    if (compact) {
      return _TopAccountAvatar(account: current, imageUrl: avatarUrl);
    }
    return Row(
      children: <Widget>[
        _TopAccountAvatar(account: current, imageUrl: avatarUrl),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                current.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${current.source.label}账号',
                style: const TextStyle(
                  color: AppColors.textMuted,
                  fontSize: 9.5,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
        const Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 16,
          color: AppColors.textDisabled,
        ),
      ],
    );
  }
}

class _TopAccountAvatar extends StatelessWidget {
  const _TopAccountAvatar({required this.account, required this.imageUrl});

  final ClientAccountSession account;
  final String imageUrl;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 34,
      height: 34,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: AppColors.surfaceHigh,
        shape: BoxShape.circle,
      ),
      child: Text(
        account.avatarFallbackText,
        style: const TextStyle(
          color: AppColors.textPrimary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    return Container(
      width: 36,
      height: 36,
      padding: const EdgeInsets.all(1.5),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: AppColors.surfaceRaised,
        border: Border.all(color: AppColors.accentBorder),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: AppColors.shadowSoft,
            blurRadius: 10,
            offset: Offset(0, 3),
          ),
        ],
      ),
      child: ClipOval(
        child: imageUrl.isEmpty
            ? fallback
            : Image.network(
                imageUrl,
                width: 33,
                height: 33,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => fallback,
              ),
      ),
    );
  }
}

class _SearchResultsPanel extends StatelessWidget {
  const _SearchResultsPanel({
    required this.songs,
    required this.selectedSong,
    required this.playing,
    required this.searching,
    required this.error,
    required this.searched,
    required this.lastQuery,
    required this.scrollController,
    required this.customPlaylists,
    required this.downloadingSongKeys,
    required this.downloadProgress,
    required this.onDownload,
    required this.onPlayMv,
    required this.onSelect,
    required this.onTogglePlayback,
    required this.onAddSong,
  });

  final List<Song> songs;
  final Song? selectedSong;
  final bool playing;
  final bool searching;
  final String? error;
  final bool searched;
  final String lastQuery;
  final ScrollController scrollController;
  final List<Playlist> customPlaylists;
  final Set<String> downloadingSongKeys;
  final Map<String, double?> downloadProgress;
  final ValueChanged<Song> onDownload;
  final ValueChanged<Song> onPlayMv;
  final ValueChanged<Song> onSelect;
  final VoidCallback onTogglePlayback;
  final void Function(Song song, String playlistId) onAddSong;

  @override
  Widget build(BuildContext context) {
    return _LibraryPanel(
      icon: Icons.library_music_rounded,
      title: '搜索结果',
      count: songs.isEmpty ? null : '${songs.length} 首',
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (searching && songs.isEmpty) {
      return const _SearchSkeletonList();
    }
    if (error != null) {
      return _ResultsMessage(
        icon: Icons.cloud_off_rounded,
        title: '搜索失败',
        description: error!,
      );
    }
    if (songs.isEmpty) {
      if (searched) {
        return _ResultsMessage(
          icon: Icons.search_off_rounded,
          title: '没有找到“$lastQuery”',
          description: '试试更短的关键词，或换用歌手名、专辑名搜索',
        );
      }
      return const _ResultsMessage(
        icon: Icons.search_rounded,
        title: '搜索音乐',
        description: '输入歌曲名、歌手或专辑名开始搜索',
      );
    }
    return Scrollbar(
      controller: scrollController,
      thumbVisibility: true,
      child: ListView.builder(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
        itemCount: songs.length,
        itemBuilder: (context, index) {
          final song = songs[index];
          return _SongTile(
            key: ValueKey<String>('search-song-${song.mediaKey}'),
            song: song,
            selected: selectedSong?.mediaKey == song.mediaKey,
            playing: playing,
            onTap: () => onSelect(song),
            onTogglePlayback: onTogglePlayback,
            downloading: downloadingSongKeys.contains(song.mediaKey),
            downloadProgress: downloadProgress[song.mediaKey],
            onDownload: () => onDownload(song),
            onPlayMv: song.hasMv ? () => onPlayMv(song) : null,
            actionSlots: 1,
            action: SizedBox(
              width: 32,
              height: 32,
              child: PopupMenuButton<String>(
                key: ValueKey<String>('add-song-${song.mediaKey}'),
                tooltip: '添加到歌单',
                enabled: customPlaylists.isNotEmpty,
                padding: EdgeInsets.zero,
                iconSize: 19,
                onSelected: (playlistId) => onAddSong(song, playlistId),
                itemBuilder: (context) {
                  if (customPlaylists.isEmpty) {
                    return const <PopupMenuEntry<String>>[
                      PopupMenuItem<String>(
                        enabled: false,
                        child: Text('请先创建歌单'),
                      ),
                    ];
                  }
                  return <PopupMenuEntry<String>>[
                    for (final playlist in customPlaylists)
                      PopupMenuItem<String>(
                        value: playlist.id,
                        child: Row(
                          children: <Widget>[
                            const Icon(Icons.queue_music_rounded, size: 18),
                            const SizedBox(width: 9),
                            Expanded(
                              child: Text(
                                playlist.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ];
                },
                icon: const Icon(
                  Icons.add_circle_outline_rounded,
                  color: Color(0xFF7E8795),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 搜索请求期间用列表骨架保持页面结构稳定，避免内容区域突然跳变。
class _SearchSkeletonList extends StatefulWidget {
  const _SearchSkeletonList();

  @override
  State<_SearchSkeletonList> createState() => _SearchSkeletonListState();
}

class _SearchSkeletonListState extends State<_SearchSkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1450),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: const ValueKey<String>('search-skeleton'),
      child: AnimatedBuilder(
        animation: _controller,
        child: _buildList(),
        builder: (context, child) {
          final offset = -1.7 + _controller.value * 3.4;
          return ShaderMask(
            blendMode: BlendMode.srcATop,
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment(offset - 0.7, 0),
              end: Alignment(offset + 0.7, 0),
              colors: const <Color>[
                AppColors.surfaceHigh,
                AppColors.surfaceHover,
                AppColors.surfaceHigh,
              ],
              stops: const <double>[0.18, 0.5, 0.82],
            ).createShader(bounds),
            child: child,
          );
        },
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 20),
      itemCount: 7,
      itemBuilder: (context, index) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: AppColors.surfaceRaised.withValues(
              alpha: 0.48 - index * 0.035,
            ),
            borderRadius: BorderRadius.circular(AppRadii.tile),
            border: Border.all(color: AppColors.border.withValues(alpha: 0.6)),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppColors.surfaceHigh,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    FractionallySizedBox(
                      widthFactor: index.isEven ? 0.42 : 0.34,
                      child: Container(
                        height: 11,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    FractionallySizedBox(
                      widthFactor: index.isEven ? 0.25 : 0.31,
                      child: Container(
                        height: 8,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceHigh.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(99),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PlaylistImportSelection {
  const _PlaylistImportSelection({
    required this.sourcePlaylistId,
    required this.targetPlaylistId,
  });

  final String sourcePlaylistId;
  final String targetPlaylistId;
}

class _PlaylistPanel extends StatelessWidget {
  const _PlaylistPanel({
    required this.playlist,
    required this.songs,
    required this.selectedSong,
    required this.playing,
    required this.loading,
    required this.error,
    required this.downloadingSongKeys,
    required this.downloadProgress,
    required this.onDownload,
    required this.onPlayMv,
    required this.onSelect,
    required this.onTogglePlayback,
    required this.onRemove,
    required this.onAddToLocal,
    required this.onAddToPlaylist,
    required this.onReorder,
    required this.onRename,
    required this.onDelete,
  });

  final Playlist playlist;
  final List<Song> songs;
  final Song? selectedSong;
  final bool playing;
  final bool loading;
  final String? error;
  final Set<String> downloadingSongKeys;
  final Map<String, double?> downloadProgress;
  final ValueChanged<Song> onDownload;
  final ValueChanged<Song> onPlayMv;
  final ValueChanged<Song> onSelect;
  final VoidCallback onTogglePlayback;
  final ValueChanged<Song> onRemove;
  final ValueChanged<Song> onAddToLocal;
  final ValueChanged<Song> onAddToPlaylist;
  final ReorderCallback onReorder;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return _LibraryPanel(
      icon: playlist.isRecentlyPlayed
          ? Icons.history_rounded
          : playlist.isRemote
          ? Icons.cloud_queue_rounded
          : Icons.queue_music_rounded,
      title: playlist.name,
      count: '${songs.length} 首',
      progress: loading,
      actions: !playlist.allowsLocalManagement
          ? null
          : <Widget>[
              IconButton(
                tooltip: '重命名歌单',
                onPressed: onRename,
                style: _libraryPanelActionStyle(),
                icon: const Icon(Icons.edit_outlined, size: 19),
              ),
              IconButton(
                tooltip: '删除歌单',
                onPressed: onDelete,
                style: _libraryPanelActionStyle(),
                icon: const Icon(Icons.delete_outline_rounded, size: 19),
              ),
            ],
      child: _buildContent(context),
    );
  }

  Widget _buildContent(BuildContext context) {
    if (loading && songs.isEmpty) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
    }
    if (error != null && songs.isEmpty) {
      return _ResultsMessage(
        icon: Icons.cloud_off_rounded,
        title: '歌单加载失败',
        description: error!,
      );
    }
    if (songs.isEmpty) {
      return _ResultsMessage(
        icon: playlist.isRecentlyPlayed
            ? Icons.history_toggle_off_rounded
            : playlist.isRemote
            ? Icons.cloud_download_outlined
            : Icons.playlist_add_rounded,
        title: playlist.isRecentlyPlayed
            ? '还没有播放记录'
            : playlist.isRemote
            ? '远程歌单还是空的'
            : '歌单还是空的',
        description: playlist.isRecentlyPlayed
            ? '播放任意歌曲后，它会自动出现在这里'
            : playlist.isRemote
            ? '该${playlist.musicSource?.label ?? '平台'}歌单中没有可播放的歌曲'
            : '从搜索结果点击“+”，将歌曲加入这个歌单',
      );
    }

    Widget buildTile(
      BuildContext context,
      int index, {
      required bool draggable,
    }) {
      final song = songs[index];
      final tileKey = ValueKey<String>(
        'playlist-song-${playlist.id}-${song.mediaKey}',
      );
      final actionSlots = playlist.isRemote ? 1 : 2;
      final tile = _SongTile(
        song: song,
        selected: selectedSong?.mediaKey == song.mediaKey,
        playing: playing,
        onTap: () => onSelect(song),
        onTogglePlayback: onTogglePlayback,
        downloading: downloadingSongKeys.contains(song.mediaKey),
        downloadProgress: downloadProgress[song.mediaKey],
        onDownload: () => onDownload(song),
        onPlayMv: song.hasMv ? () => onPlayMv(song) : null,
        actionSlots: actionSlots,
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                key: ValueKey<String>(
                  playlist.isRemote
                      ? 'add-remote-song-${song.mediaKey}'
                      : 'add-local-song-${song.mediaKey}',
                ),
                tooltip: playlist.isRemote ? '添加到本地歌单' : '添加到其他本地歌单',
                onPressed: playlist.isRemote
                    ? () => onAddToLocal(song)
                    : () => onAddToPlaylist(song),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                style: IconButton.styleFrom(
                  minimumSize: const Size(32, 32),
                  maximumSize: const Size(32, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                constraints: const BoxConstraints.tightFor(
                  width: 32,
                  height: 32,
                ),
                icon: const Icon(Icons.playlist_add_rounded, size: 19),
              ),
            ),
            if (!playlist.isRemote)
              SizedBox(
                width: 32,
                height: 32,
                child: IconButton(
                  key: ValueKey<String>(
                    'remove-playlist-song-${song.mediaKey}',
                  ),
                  tooltip: '从歌单移除',
                  onPressed: () => onRemove(song),
                  padding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  style: IconButton.styleFrom(
                    minimumSize: const Size(32, 32),
                    maximumSize: const Size(32, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                  icon: const Icon(
                    Icons.remove_circle_outline_rounded,
                    size: 19,
                  ),
                ),
              ),
          ],
        ),
      );
      if (!draggable) {
        return KeyedSubtree(key: tileKey, child: tile);
      }
      final dragListener = AppPlatform.isMobile
          ? ReorderableDelayedDragStartListener(index: index, child: tile)
          : ReorderableDragStartListener(index: index, child: tile);
      return KeyedSubtree(key: tileKey, child: dragListener);
    }

    if (!playlist.allowsReorder) {
      return ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
        itemCount: songs.length,
        itemBuilder: (context, index) =>
            buildTile(context, index, draggable: false),
      );
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      buildDefaultDragHandles: false,
      itemCount: songs.length,
      onReorderItem: onReorder,
      proxyDecorator: (child, index, animation) => Material(
        color: AppColors.accentSoft,
        borderRadius: BorderRadius.circular(AppRadii.tile),
        elevation: 8,
        child: child,
      ),
      itemBuilder: (context, index) =>
          buildTile(context, index, draggable: true),
    );
  }
}

class _LibraryPanel extends StatelessWidget {
  const _LibraryPanel({
    required this.icon,
    required this.title,
    required this.child,
    this.count,
    this.progress = false,
    this.actions,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final String? count;
  final bool progress;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 430;
        return DecoratedBox(
          decoration: appPanelDecoration(color: AppColors.surface),
          child: Column(
            children: <Widget>[
              SizedBox(
                height: compact ? 64 : 72,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(compact ? 12 : 18, 0, 10, 0),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: compact ? 30 : 34,
                        height: compact ? 30 : 34,
                        decoration: BoxDecoration(
                          color: AppColors.accentSoft,
                          borderRadius: BorderRadius.circular(compact ? 9 : 11),
                          border: Border.all(color: AppColors.accentBorder),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          icon,
                          color: AppColors.accentStrong,
                          size: compact ? 16 : 18,
                        ),
                      ),
                      SizedBox(width: compact ? 8 : 11),
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: compact ? 14.5 : 16,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.15,
                          ),
                        ),
                      ),
                      if (count != null && !compact)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 9,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceHigh,
                            borderRadius: BorderRadius.circular(AppRadii.pill),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Text(
                            count!,
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      if (actions != null) ...<Widget>[
                        const SizedBox(width: 6),
                        ...actions!,
                      ],
                    ],
                  ),
                ),
              ),
              if (progress)
                const LinearProgressIndicator(
                  minHeight: 2,
                  color: AppColors.accent,
                  backgroundColor: AppColors.surfaceHigh,
                ),
              const Divider(height: 1, color: AppColors.border),
              Expanded(child: child),
            ],
          ),
        );
      },
    );
  }
}

class _SongTile extends StatefulWidget {
  const _SongTile({
    super.key,
    required this.song,
    required this.selected,
    required this.playing,
    required this.onTap,
    required this.onTogglePlayback,
    this.onDownload,
    this.onPlayMv,
    this.downloading = false,
    this.downloadProgress,
    this.actionSlots = 0,
    this.action,
  });

  final Song song;
  final bool selected;
  final bool playing;
  final VoidCallback onTap;
  final VoidCallback onTogglePlayback;
  final VoidCallback? onDownload;
  final VoidCallback? onPlayMv;
  final bool downloading;
  final double? downloadProgress;
  final int actionSlots;
  final Widget? action;

  @override
  State<_SongTile> createState() => _SongTileState();
}

class _SongTileState extends State<_SongTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final desktop = AppPlatform.isDesktop;
    final showActions =
        !desktop || _hovered || widget.downloading || widget.actionSlots == 0;
    final showCoverOverlay = widget.selected || _hovered;
    // Reserve the Material tap-target width rather than the visible icon width.
    // This keeps the hover controls from overflowing when several actions are
    // available (for example download + add + remove in a playlist row).
    final actionWidth =
        ((widget.onDownload == null ? 0 : 1) + widget.actionSlots) * 32.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 640;
        final coverSize = compact ? 44.0 : 52.0;
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: MouseRegion(
            onEnter: (_) {
              if (desktop && !_hovered) {
                setState(() => _hovered = true);
              }
            },
            onExit: (_) {
              if (desktop && _hovered) {
                setState(() => _hovered = false);
              }
            },
            child: AnimatedContainer(
              duration: AppDurations.fast,
              curve: Curves.easeOut,
              decoration: BoxDecoration(
                color: widget.selected
                    ? AppColors.accentSoft
                    : _hovered
                    ? AppColors.surfaceRaised
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(AppRadii.tile),
                border: Border.all(
                  color: widget.selected
                      ? AppColors.accentBorder
                      : _hovered
                      ? AppColors.borderStrong
                      : Colors.transparent,
                ),
              ),
              child: Semantics(
                button: true,
                label: '播放 ${widget.song.name}，${widget.song.artistText}',
                child: InkWell(
                  onTap: widget.onTap,
                  borderRadius: BorderRadius.circular(AppRadii.tile),
                  hoverColor: Colors.transparent,
                  child: Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: compact ? 8 : 10,
                      vertical: 8,
                    ),
                    child: Row(
                      children: <Widget>[
                        _buildCover(showCoverOverlay, coverSize),
                        SizedBox(width: compact ? 9 : 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Row(
                                children: <Widget>[
                                  Flexible(
                                    child: Text(
                                      widget.song.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            color: widget.selected
                                                ? AppColors.accentStrong
                                                : AppColors.textPrimary,
                                            fontWeight: FontWeight.w700,
                                            fontSize: compact ? 13.5 : 14,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  MusicSourceBadge(
                                    source: widget.song.source,
                                    compact: compact,
                                  ),
                                  if (widget.song.hasMv) ...<Widget>[
                                    const SizedBox(width: 7),
                                    _MvBadge(
                                      key: ValueKey<String>(
                                        'mv-song-${widget.song.mediaKey}',
                                      ),
                                      onTap: widget.onPlayMv,
                                    ),
                                  ],
                                ],
                              ),
                              SizedBox(height: compact ? 4 : 5),
                              Text(
                                compact || widget.song.album.trim().isEmpty
                                    ? widget.song.artistText
                                    : '${widget.song.artistText}  ·  ${widget.song.album}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: AppColors.textMuted,
                                  fontSize: compact ? 11 : 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(width: compact ? 5 : 8),
                        if (actionWidth > 0)
                          SizedBox(
                            width: actionWidth,
                            height: 32,
                            child: IgnorePointer(
                              ignoring: !showActions,
                              child: AnimatedOpacity(
                                opacity: showActions ? 1 : 0,
                                duration: const Duration(milliseconds: 140),
                                curve: Curves.easeOut,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: <Widget>[
                                    if (widget.onDownload != null)
                                      _SongDownloadButton(
                                        key: ValueKey<String>(
                                          'download-song-${widget.song.mediaKey}',
                                        ),
                                        downloading: widget.downloading,
                                        progress: widget.downloadProgress,
                                        onPressed: widget.onDownload,
                                      ),
                                    ?widget.action,
                                  ],
                                ),
                              ),
                            ),
                          ),
                        SizedBox(width: compact ? 5 : 8),
                        SizedBox(
                          width: compact ? 36 : 42,
                          child: Text(
                            _formatSongDuration(widget.song.duration),
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: compact ? 10.5 : 11,
                              fontFeatures: <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildCover(bool showOverlay, double size) {
    final interactive = !AppPlatform.isDesktop || _hovered;
    final icon = widget.selected && !interactive
        ? Icons.graphic_eq_rounded
        : widget.selected && widget.playing
        ? Icons.pause_rounded
        : Icons.play_arrow_rounded;
    return ClipRRect(
      borderRadius: BorderRadius.circular(size <= 44 ? 9 : 11),
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            if (widget.song.coverUrl.isEmpty)
              const ColoredBox(
                color: AppColors.surfaceHigh,
                child: Icon(
                  Icons.music_note_rounded,
                  color: AppColors.textMuted,
                ),
              )
            else
              Image.network(
                widget.song.coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => const ColoredBox(
                  color: AppColors.surfaceHigh,
                  child: Icon(
                    Icons.music_note_rounded,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            IgnorePointer(
              ignoring: !showOverlay,
              child: AnimatedOpacity(
                opacity: showOverlay ? 1 : 0,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                child: Material(
                  color: AppColors.overlay,
                  child: InkWell(
                    onTap: widget.selected
                        ? widget.onTogglePlayback
                        : widget.onTap,
                    child: Center(
                      child: widget.selected && !_hovered
                          ? const _PlayingIndicator()
                          : Icon(icon, size: 25, color: AppColors.textPrimary),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MvBadge extends StatelessWidget {
  const _MvBadge({super.key, required this.onTap});

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '播放 MV',
      child: Material(
        color: AppColors.warningSurface,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(6),
          hoverColor: AppColors.warning.withValues(alpha: 0.08),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(5, 2, 6, 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.play_circle_fill_rounded,
                  size: 11,
                  color: AppColors.warning,
                ),
                SizedBox(width: 2),
                Text(
                  'MV',
                  style: TextStyle(
                    color: AppColors.warning,
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                    letterSpacing: 0.25,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayingIndicator extends StatelessWidget {
  const _PlayingIndicator();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: const <Widget>[
        _PlayingBar(height: 8),
        SizedBox(width: 2),
        _PlayingBar(height: 15),
        SizedBox(width: 2),
        _PlayingBar(height: 11),
      ],
    );
  }
}

class _PlayingBar extends StatelessWidget {
  const _PlayingBar({required this.height});

  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: height,
      decoration: BoxDecoration(
        color: AppColors.accent,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _SongDownloadButton extends StatelessWidget {
  const _SongDownloadButton({
    super.key,
    required this.downloading,
    required this.progress,
    required this.onPressed,
  });

  final bool downloading;
  final double? progress;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    if (downloading) {
      final percent = progress == null ? null : (progress! * 100).round();
      return Tooltip(
        message: percent == null ? '正在下载' : '正在下载 $percent%',
        child: SizedBox(
          width: 32,
          height: 32,
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                value: progress,
                strokeWidth: 2,
                color: AppColors.accent,
              ),
            ),
          ),
        ),
      );
    }
    return IconButton(
      tooltip: '下载歌曲',
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        minimumSize: const Size(32, 32),
        maximumSize: const Size(32, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      icon: const Icon(
        Icons.download_rounded,
        size: 20,
        color: AppColors.textMuted,
      ),
    );
  }
}

class _ResultsMessage extends StatelessWidget {
  const _ResultsMessage({
    required this.icon,
    required this.title,
    required this.description,
  });

  final IconData icon;
  final String title;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 62,
              height: 62,
              decoration: BoxDecoration(
                color: AppColors.surfaceRaised,
                borderRadius: BorderRadius.circular(19),
                border: Border.all(color: AppColors.border),
              ),
              alignment: Alignment.center,
              child: Icon(icon, size: 27, color: AppColors.textMuted),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                color: AppColors.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Text(
                description,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.textMuted,
                  height: 1.55,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatSongDuration(Duration duration) {
  final totalSeconds = duration.inSeconds.clamp(0, 359999);
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}

ButtonStyle _toolbarIconButtonStyle() {
  return ButtonStyle(
    minimumSize: const WidgetStatePropertyAll<Size>(Size(44, 44)),
    animationDuration: AppDurations.fast,
    foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.textDisabled;
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return AppColors.accentStrong;
      }
      return AppColors.textSecondary;
    }),
    backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.surfaceDisabled;
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return AppColors.surfaceHover;
      }
      return AppColors.surfaceRaised;
    }),
    side: WidgetStateProperty.resolveWith<BorderSide?>((states) {
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return const BorderSide(color: AppColors.accentBorder);
      }
      return const BorderSide(color: AppColors.border);
    }),
    overlayColor: WidgetStatePropertyAll<Color>(
      AppColors.accent.withValues(alpha: 0.08),
    ),
    shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.input),
      ),
    ),
  );
}

ButtonStyle _libraryPanelActionStyle() {
  return IconButton.styleFrom(
    foregroundColor: AppColors.textMuted,
    hoverColor: AppColors.accentSoft,
    focusColor: AppColors.accent.withValues(alpha: 0.12),
    highlightColor: AppColors.accent.withValues(alpha: 0.1),
    minimumSize: const Size(38, 38),
    maximumSize: const Size(38, 38),
    padding: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(AppRadii.small),
    ),
  );
}

ButtonStyle _accountTriggerStyle({required double horizontalPadding}) {
  return ButtonStyle(
    animationDuration: AppDurations.fast,
    padding: WidgetStatePropertyAll<EdgeInsets>(
      EdgeInsets.symmetric(horizontal: horizontalPadding),
    ),
    foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.textDisabled;
      }
      return AppColors.textPrimary;
    }),
    backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        return AppColors.surfaceDisabled;
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return AppColors.surfaceHover;
      }
      return AppColors.surface;
    }),
    side: WidgetStateProperty.resolveWith<BorderSide?>((states) {
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.focused)) {
        return const BorderSide(color: AppColors.accentBorder);
      }
      return const BorderSide(color: AppColors.borderStrong);
    }),
    overlayColor: WidgetStatePropertyAll<Color>(
      AppColors.accent.withValues(alpha: 0.08),
    ),
    shape: WidgetStatePropertyAll<RoundedRectangleBorder>(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.search),
      ),
    ),
  );
}
