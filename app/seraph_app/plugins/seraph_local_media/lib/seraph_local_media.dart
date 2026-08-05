// seraph_local_media
//
// The native (Android) half of Gallery Mode's Local Source seam. This package
// exists as a Flutter plugin so its `seraph/local_media` MethodChannel handler
// is registered on EVERY FlutterEngine the app runs - including the separate
// engines `flutter_foreground_task` and `workmanager` create for headless
// background backup, which are NOT MainActivity's engine and therefore never
// ran `MainActivity.configureFlutterEngine`. Without this, `loadOriginal`
// (and every other channel call) from a background backup isolate threw
// MissingPluginException, the exception was swallowed by `AndroidLocalSource`,
// and every upload reported `deviceFileUnavailable` - "could not read this
// photo from the device" - even though the photo was perfectly readable from
// MainActivity's engine (which is why gallery thumbnails rendered fine).
//
// The Dart facade for the channel is `AndroidLocalSource`
// (`lib/src/gallery/local/android_local_source.dart` in the host app), which
// already owns the `MethodChannel('seraph/local_media')` instance and the
// full typed API. This library is intentionally a near-empty stub: a Flutter
// plugin package must expose a Dart library for the host's pubspec dependency
// to resolve, but the channel contract lives entirely in the host app's
// `AndroidLocalSource` (and is exercised by `android_local_source_test.dart`
// there). Nothing here is imported by the app at runtime; it exists only so
// `flutter pub get` registers the Android plugin and `GeneratedPluginRegistrant`
// auto-registers `SeraphLocalMediaPlugin` on each engine.
// `seraph_local_media`'s Dart-side stub. Declared as a plain library (no
// `library` name) to keep `flutter analyze` quiet; see the package doc above.
library;
