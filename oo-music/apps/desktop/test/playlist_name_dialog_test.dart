import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/theme/app_theme.dart';
import 'package:oo_music/widgets/playlist_name_dialog.dart';

void main() {
  setUp(() => WidgetController.hitTestWarningShouldBeFatal = true);
  tearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
  final platforms = TargetPlatformVariant({
    TargetPlatform.android,
    TargetPlatform.windows,
  });

  for (final dismissal in ['save', 'submit', 'cancel', 'back']) {
    testWidgets('歌单名称弹窗 $dismissal 退场期间输入法变化不产生异常', (tester) async {
      String? result;
      var closed = false;
      await _openDialog(
        tester,
        onClosed: (value) {
          result = value;
          closed = true;
        },
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('playlist-name-field')),
        '  QA name  ',
      );
      switch (dismissal) {
        case 'save':
          await tester.tap(find.byKey(const ValueKey('save-playlist-name')));
        case 'submit':
          await tester.testTextInput.receiveAction(TextInputAction.done);
        case 'cancel':
          await tester.tap(find.byKey(const ValueKey('cancel-playlist-name')));
        case 'back':
          await tester.binding.handlePopRoute();
      }
      await tester.pump();
      tester.view.resetViewInsets();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(closed, isTrue);
      expect(
        result,
        dismissal == 'save' || dismissal == 'submit' ? 'QA name' : null,
      );
      expect(find.byType(PlaylistNameDialog), findsNothing);
    }, variant: platforms);
  }

  testWidgets('重命名保留初始名称，拒绝空白并修剪提交结果', (tester) async {
    String? result;
    await _openDialog(
      tester,
      initialValue: 'Old name',
      onClosed: (value) => result = value,
    );
    final field = find.byKey(const ValueKey('playlist-name-field'));
    expect(find.text('Old name'), findsOneWidget);
    await tester.enterText(field, '   ');
    await tester.tap(find.byKey(const ValueKey('save-playlist-name')));
    await tester.pumpAndSettle();
    expect(find.byType(PlaylistNameDialog), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(field, '  New name  ');
    await tester.tap(find.byKey(const ValueKey('save-playlist-name')));
    await tester.pumpAndSettle();
    expect(result, 'New name');
    expect(tester.takeException(), isNull);
  }, variant: platforms);
}

Future<void> _openDialog(
  WidgetTester tester, {
  String initialValue = '',
  required ValueChanged<String?> onClosed,
}) async {
  const size = Size(360, 720);
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () async {
                final result = await showDialog<String>(
                  context: context,
                  builder: (_) => PlaylistNameDialog(
                    title: '歌单名称',
                    initialValue: initialValue,
                  ),
                );
                onClosed(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}
