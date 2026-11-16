import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/lyrics/lrc_parser.dart';
import 'package:oo_music/models/music_source.dart';
import 'package:oo_music/models/song.dart';
import 'package:oo_music/theme/app_theme.dart';
import 'package:oo_music/widgets/lyrics_panel.dart';
import 'package:oo_music/widgets/now_playing_page.dart';

void main() {
  final lines = List<LrcLine>.generate(
    50,
    (index) => LrcLine(
      timestamp: Duration(seconds: index * 3),
      text: '第 $index 行',
    ),
    growable: false,
  );

  testWidgets('左侧歌词在用户滚远后仍会跟随下一句', (tester) async {
    await tester.binding.setSurfaceSize(const Size(760, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_lyricsPanelHarness(lines: lines, activeIndex: 2));
    await tester.pumpAndSettle();

    final scrollView = find.byKey(
      const ValueKey<String>('lyrics-panel-scroll'),
    );
    final scrollable = find.descendant(
      of: scrollView,
      matching: find.byType(Scrollable),
    );
    final initialOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;

    await tester.drag(scrollView, const Offset(0, -3000));
    await tester.pumpAndSettle();
    final manuallyScrolledOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;
    expect(manuallyScrolledOffset, greaterThan(initialOffset + 400));

    await tester.pumpWidget(_lyricsPanelHarness(lines: lines, activeIndex: 35));
    await tester.pumpAndSettle();

    final followedOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;
    expect(followedOffset, isNot(manuallyScrolledOffset));
    final viewport = tester.getRect(scrollView);
    final target = tester.getRect(find.text('第 35 行'));
    expect(target.top, greaterThan(viewport.top));
    expect(target.bottom, lessThan(viewport.bottom));
  });

  testWidgets('完整播放页歌词在用户滚远后仍会跟随下一句', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_nowPlayingHarness(lines: lines, activeIndex: 2));
    await tester.pumpAndSettle();

    final scrollView = find.byKey(
      const ValueKey<String>('now-playing-lyrics-scroll'),
    );
    final scrollable = find.descendant(
      of: scrollView,
      matching: find.byType(Scrollable),
    );
    final initialOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;

    await tester.drag(scrollView, const Offset(0, -3000));
    await tester.pumpAndSettle();
    final manuallyScrolledOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;
    expect(manuallyScrolledOffset, greaterThan(initialOffset + 400));

    await tester.pumpWidget(_nowPlayingHarness(lines: lines, activeIndex: 38));
    await tester.pumpAndSettle();

    final followedOffset = tester
        .state<ScrollableState>(scrollable)
        .position
        .pixels;
    expect(followedOffset, isNot(manuallyScrolledOffset));
    final viewport = tester.getRect(scrollView);
    final target = tester.getRect(find.text('第 38 行'));
    expect(target.top, greaterThan(viewport.top));
    expect(target.bottom, lessThan(viewport.bottom));
  });

  testWidgets('歌词面板和完整播放页歌词统一居中显示', (tester) async {
    await tester.binding.setSurfaceSize(const Size(760, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(_lyricsPanelHarness(lines: lines, activeIndex: 2));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('第 2 行')).textAlign, TextAlign.center);

    await tester.pumpWidget(_nowPlayingHarness(lines: lines, activeIndex: 2));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('第 2 行')).textAlign, TextAlign.center);
  });
}

Widget _lyricsPanelHarness({
  required List<LrcLine> lines,
  required int activeIndex,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: 620,
          height: 620,
          child: LyricsPanel(
            song: const Song(
              source: MusicSource.qq,
              id: 1,
              mid: 'test-mid',
              name: '测试歌曲',
              artists: <String>['测试歌手'],
              album: '测试专辑',
              albumMid: 'album-mid',
              coverUrl: '',
              durationSeconds: 240,
              hasMv: false,
            ),
            lyric: null,
            lines: lines,
            translations: const <int, String>{},
            romanizations: const <int, String>{},
            activeIndex: activeIndex,
            loading: false,
            error: null,
          ),
        ),
      ),
    ),
  );
}

Widget _nowPlayingHarness({
  required List<LrcLine> lines,
  required int activeIndex,
}) {
  return MaterialApp(
    theme: buildAppTheme(),
    home: NowPlayingPage(
      song: const Song(
        source: MusicSource.qq,
        id: 1,
        mid: 'test-mid',
        name: '测试歌曲',
        artists: <String>['测试歌手'],
        album: '测试专辑',
        albumMid: 'album-mid',
        coverUrl: '',
        durationSeconds: 240,
        hasMv: false,
      ),
      isPlaying: false,
      lyric: null,
      lyricLines: lines,
      translations: const <int, String>{},
      romanizations: const <int, String>{},
      activeLyricIndex: activeIndex,
      loadingLyrics: false,
      lyricError: null,
    ),
  );
}
