import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/local/android_local_source.dart';
import 'package:seraph_app/src/gallery/local/local_media_item.dart';

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

  group('permissionStatus', () {
    test('with no native handler registered, permissionStatus is denied '
        'rather than throwing', () async {
      final source = AndroidLocalSource(channel: channel);
      expect(await source.permissionStatus(), LocalPermissionStatus.denied);
    });

    test('parses "granted" from the native side', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'permissionStatus');
        return 'granted';
      });
      final source = AndroidLocalSource(channel: channel);
      expect(await source.permissionStatus(), LocalPermissionStatus.granted);
    });

    test('parses "partial" from the native side', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => 'partial');
      final source = AndroidLocalSource(channel: channel);
      expect(await source.permissionStatus(), LocalPermissionStatus.partial);
    });

    test('parses "denied" from the native side', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => 'denied');
      final source = AndroidLocalSource(channel: channel);
      expect(await source.permissionStatus(), LocalPermissionStatus.denied);
    });

    test('a PlatformException yields denied, not an error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'SOMETHING_WRONG');
      });
      final source = AndroidLocalSource(channel: channel);
      expect(await source.permissionStatus(), LocalPermissionStatus.denied);
    });
  });

  group('requestPermission', () {
    test('with no native handler registered, requestPermission is denied '
        'rather than throwing', () async {
      final source = AndroidLocalSource(channel: channel);
      expect(await source.requestPermission(), LocalPermissionStatus.denied);
    });

    test('resolves to whatever the native side reports after the request',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'requestPermission');
        return 'partial';
      });
      final source = AndroidLocalSource(channel: channel);
      expect(await source.requestPermission(), LocalPermissionStatus.partial);
    });

    test('a REQUEST_IN_PROGRESS error yields denied rather than throwing',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'REQUEST_IN_PROGRESS');
      });
      final source = AndroidLocalSource(channel: channel);
      expect(await source.requestPermission(), LocalPermissionStatus.denied);
    });
  });

  group('openAppSettings', () {
    test('with no native handler registered, does not throw', () async {
      final source = AndroidLocalSource(channel: channel);
      await source.openAppSettings();
    });

    test('invokes the native side', () async {
      String? invoked;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        invoked = call.method;
        return null;
      });
      final source = AndroidLocalSource(channel: channel);
      await source.openAppSettings();
      expect(invoked, 'openAppSettings');
    });
  });

  // Ticket 17: the incremental scan and the content-observer trigger.
  group('incrementalScan', () {
    test('with no native handler registered, returns no items and echoes '
        'the given watermark back', () async {
      final source = AndroidLocalSource(channel: channel);
      final result = await source.incrementalScan(42);
      expect(result.items, isEmpty);
      expect(result.generation, 42,
          reason: 'a missing native side must never advance the watermark - '
              'that would silently skip whatever it would have reported');
    });

    test('a PlatformException yields no items and the same watermark, not '
        'an error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'SCAN_FAILED');
      });
      final source = AndroidLocalSource(channel: channel);
      final result = await source.incrementalScan(7);
      expect(result.items, isEmpty);
      expect(result.generation, 7);
    });

    test('passes the watermark through and parses a successful response',
        () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'incrementalScan');
        expect(call.arguments, {'since': 100});
        return {
          'items': [
            {
              'id': 9,
              'dateTaken': 1700000000000,
              'dateModified': 1700000001000,
              'size': 555,
              'relativePath': 'DCIM/Camera/',
              'displayName': 'IMG_new.jpg',
            },
          ],
          'generation': 150,
        };
      });
      final source = AndroidLocalSource(channel: channel);
      final result = await source.incrementalScan(100);

      expect(result.generation, 150);
      expect(result.items, hasLength(1));
      expect(result.items.single.displayName, 'IMG_new.jpg');
      expect(result.items.single.size, 555);
    });
  });

  group('currentGeneration', () {
    test('with no native handler registered, returns 0 rather than throwing',
        () async {
      final source = AndroidLocalSource(channel: channel);
      expect(await source.currentGeneration(), 0);
    });

    test('a PlatformException yields 0, not an error', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'SOMETHING_WRONG');
      });
      final source = AndroidLocalSource(channel: channel);
      expect(await source.currentGeneration(), 0);
    });

    test('returns the native side\'s value', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'currentGeneration');
        return 12345;
      });
      final source = AndroidLocalSource(channel: channel);
      expect(await source.currentGeneration(), 12345);
    });
  });

  group('changes', () {
    test('emits when the native side calls onLocalMediaChanged', () async {
      final source = AndroidLocalSource(channel: channel);
      final events = <void>[];
      final subscription = source.changes.listen(events.add);

      await _simulateNativeCall(channel, 'onLocalMediaChanged');
      await pumpEventQueue();

      expect(events, hasLength(1));
      await subscription.cancel();
    });

    test('a native call before anyone is listening is simply dropped - the '
        'trigger is never load-bearing', () async {
      final source = AndroidLocalSource(channel: channel);

      // Nobody is listening to `changes` yet - this must not throw or
      // buffer in a way a later listener unexpectedly receives.
      await _simulateNativeCall(channel, 'onLocalMediaChanged');
      await pumpEventQueue();

      final events = <void>[];
      final subscription = source.changes.listen(events.add);
      await pumpEventQueue();
      expect(events, isEmpty);
      await subscription.cancel();
    });

    test('an unrelated native call is ignored', () async {
      final source = AndroidLocalSource(channel: channel);
      final events = <void>[];
      final subscription = source.changes.listen(events.add);

      await _simulateNativeCall(channel, 'somethingElse');
      await pumpEventQueue();

      expect(events, isEmpty);
      await subscription.cancel();
    });
  });
}

/// Simulates the native side calling [method] on [channel] with no
/// arguments - what `MainActivity.kt`'s content observer does when it calls
/// `localMediaChannel?.invokeMethod("onLocalMediaChanged", null)`.
Future<void> _simulateNativeCall(MethodChannel channel, String method) async {
  final data = channel.codec.encodeMethodCall(MethodCall(method));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(channel.name, data, (_) {});
}
