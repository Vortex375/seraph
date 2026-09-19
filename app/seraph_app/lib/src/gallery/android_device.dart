/// Whether this process runs on a real Android device.
///
/// Dispatched via a conditional import: `dart:io`'s [Platform] cannot be
/// referenced from the web build at all, and `defaultTargetPlatform` reports
/// Android in widget tests on the desktop host - which would silently flip
/// the gallery viewer's existing Flutter-path tests onto the native path.
/// `Platform.isAndroid` is false there (the host is Linux) and true on a
/// real device, which is exactly the split the gate needs.
library;

export 'android_device_stub.dart' if (dart.library.io) 'android_device_io.dart';
