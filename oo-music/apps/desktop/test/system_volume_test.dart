import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oo_music/platform/system_volume.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('oo_music/system_volume');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  testWidgets('system media volume accepts numeric results and clamps writes', (
    _,
  ) async {
    MethodCall? last;
    messenger.setMockMethodCallHandler(channel, (call) async {
      last = call;
      return call.method == 'get' ? 1 : true;
    });
    expect(await SystemVolume.read(), 1.0);
    expect(await SystemVolume.write(1.5), isTrue);
    expect(last!.arguments, {'value': 1.0});
    expect(await SystemVolume.write(double.nan), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('missing/denied native volume is reported as unavailable', (
    _,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw MissingPluginException();
    });
    expect(await SystemVolume.read(), isNull);
    expect(await SystemVolume.write(0.5), isFalse);
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'volume_denied');
    });
    expect(await SystemVolume.read(), isNull);
    expect(await SystemVolume.write(0.5), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('desktop never invokes Android media volume channel', (_) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      fail('Android-only channel used on desktop');
    });
    expect(await SystemVolume.read(), isNull);
    expect(await SystemVolume.write(0.5), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}
