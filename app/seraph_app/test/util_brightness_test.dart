import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('seraph/local_media');
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test('on Android, forwards the flag to the channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await setBrightnessBoost(true);
    await setBrightnessBoost(false);
    expect(calls.map((c) => '${c.method}:${c.arguments}'),
        ['setBrightnessBoost:true', 'setBrightnessBoost:false']);
  });

  test('off Android, never touches the channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await setBrightnessBoost(true);
    expect(calls, isEmpty);
  });

  test('a platform failure does not propagate to the viewer', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'nope');
    });
    await expectLater(setBrightnessBoost(true), completes);
  });
}
