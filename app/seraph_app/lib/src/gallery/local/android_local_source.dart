import 'package:flutter/services.dart';
import 'package:seraph_app/src/gallery/local/local_media_item.dart';

/// The Android half of the Local Source seam: everything below this class
/// knows MediaStore exists; everything above [LocalSource] does not.
///
/// The native side (`MainActivity.kt`, channel `seraph/local_media`) runs the
/// single projection-only cursor over `_ID`, `DATE_TAKEN`, `DATE_MODIFIED`,
/// `SIZE`, `RELATIVE_PATH` and `DISPLAY_NAME` that ticket 15 calls the
/// correctness anchor, and normalises both dates to epoch MILLISECONDS before
/// they cross the channel (MediaStore's own `DATE_MODIFIED` is SECONDS -
/// `DATE_TAKEN` is milliseconds - a well-known inconsistency; the Dart side
/// should never have to know about it).
class AndroidLocalSource implements LocalSource {
  AndroidLocalSource({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel('seraph/local_media');

  final MethodChannel _channel;

  @override
  Future<List<LocalMediaItem>> fullScan() async {
    List<Object?>? raw;
    try {
      raw = await _channel.invokeMethod<List<Object?>>('fullScan');
    } on MissingPluginException {
      // No native handler registered - true on every platform this app
      // ships to except a real Android device/emulator, and in every
      // Dart-only test. Zero device photos, same as no Local Source at all.
      return const [];
    } on PlatformException {
      // Permission not granted, or the platform call failed outright.
      // Asking for permission - with the explanation the user is owed - is
      // ticket 16's job; here, no grant simply means no photos rather than
      // a crash, exactly ticket 15's "behaves as it did before this ticket"
      // criterion for the no-access case.
      return const [];
    }

    if (raw == null) {
      return const [];
    }

    final items = <LocalMediaItem>[];
    for (final entry in raw) {
      if (entry is! Map) {
        continue;
      }
      items.add(LocalMediaItem(
        relativePath: entry['relativePath'] as String? ?? '',
        displayName: entry['displayName'] as String? ?? '',
        size: (entry['size'] as num?)?.toInt() ?? 0,
        dateTakenMillis: (entry['dateTaken'] as num?)?.toInt() ?? 0,
        dateModifiedMillis: (entry['dateModified'] as num?)?.toInt() ?? 0,
        mediaStoreId: (entry['id'] as num?)?.toInt(),
      ));
    }
    return items;
  }

  @override
  Future<LocalPermissionStatus> permissionStatus() async {
    try {
      return _parseStatus(
          await _channel.invokeMethod<String>('permissionStatus'));
    } on MissingPluginException {
      // Same "no native handler" case fullScan() handles: no Android side to
      // ask, so there is nothing granted.
      return LocalPermissionStatus.denied;
    } on PlatformException {
      return LocalPermissionStatus.denied;
    }
  }

  @override
  Future<LocalPermissionStatus> requestPermission() async {
    try {
      return _parseStatus(
          await _channel.invokeMethod<String>('requestPermission'));
    } on MissingPluginException {
      return LocalPermissionStatus.denied;
    } on PlatformException {
      // Includes MainActivity's REQUEST_IN_PROGRESS - a second request while
      // one is already awaiting the user's answer. Reporting "denied" here
      // is not a lie about the grant, only about this particular call not
      // having produced a new answer; the caller re-reads permissionStatus()
      // on its own schedule regardless.
      return LocalPermissionStatus.denied;
    }
  }

  @override
  Future<void> openAppSettings() async {
    try {
      await _channel.invokeMethod<void>('openAppSettings');
    } on MissingPluginException {
      // Nothing to open outside a real Android host.
    } on PlatformException {
      // Best effort - there is no fallback UI action to take here.
    }
  }

  LocalPermissionStatus _parseStatus(String? raw) {
    switch (raw) {
      case 'granted':
        return LocalPermissionStatus.granted;
      case 'partial':
        return LocalPermissionStatus.partial;
      default:
        return LocalPermissionStatus.denied;
    }
  }
}
