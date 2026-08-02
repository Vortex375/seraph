import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/local/android_local_source.dart';

/// Covers `AndroidLocalSource` at its own boundary - the method channel -
/// rather than trusting it only through `LocalScanService`'s fake. Uses
/// [TestDefaultBinaryMessengerBinding] to stand in for the native side ticket
/// 15 adds in `MainActivity.kt`, so these run on every platform `flutter
/// test` runs on, not just a real Android device.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('seraph/local_media');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('with no native handler registered, fullScan returns no photos rather '
      'than throwing', () async {
    // No handler is set at all - exactly what every non-Android platform,
    // and every test that does not opt in below, looks like.
    final source = AndroidLocalSource(channel: channel);
    expect(await source.fullScan(), isEmpty);
  });

  test('a PlatformException (permission not granted) yields no photos, not '
      'an error', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'PERMISSION_DENIED');
    });

    final source = AndroidLocalSource(channel: channel);
    expect(await source.fullScan(), isEmpty);
  });

  test('parses a successful native response into LocalMediaItem values',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'fullScan');
      return [
        {
          'id': 42,
          'dateTaken': 1700000000000,
          'dateModified': 1700000001000,
          'size': 12345,
          'relativePath': 'DCIM/Camera/',
          'displayName': 'IMG_0001.jpg',
        },
      ];
    });

    final source = AndroidLocalSource(channel: channel);
    final items = await source.fullScan();

    expect(items, hasLength(1));
    expect(items.single.relativePath, 'DCIM/Camera/');
    expect(items.single.displayName, 'IMG_0001.jpg');
    expect(items.single.size, 12345);
    expect(items.single.dateTakenMillis, 1700000000000);
    expect(items.single.dateModifiedMillis, 1700000001000);
    expect(items.single.mediaStoreId, 42);
  });
}
