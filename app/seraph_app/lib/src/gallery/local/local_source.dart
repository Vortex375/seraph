import 'package:seraph_app/src/gallery/local/local_media_item.dart';

import 'local_source_unsupported.dart'
    if (dart.library.io) 'local_source_io.dart' as impl;

export 'local_media_item.dart';

/// The platform's [LocalSource], or null where none exists.
///
/// This exists as a conditional-import seam for the same reason
/// `mirror/connection/connection.dart` does: the app ships to the web too
/// (`flutter build web`, served as Seraph's own web UI), and `dart:io` -
/// which `Platform.isAndroid` needs - does not exist there. Only one
/// implementation is ever compiled into a given build:
///
/// - `local_source_io.dart` (`dart.library.io`): every native platform.
///   Returns an `AndroidLocalSource` on Android and null everywhere else -
///   iOS and desktop have no Local Source in this iteration (D7: Android
///   first, behind this very seam, because iOS' photo library has no
///   user-visible relative path to anchor one).
/// - `local_source_unsupported.dart` (the web build): always null. The web
///   has no device media to speak of.
///
/// Null is not a failure case to special-case at call sites - it is ticket
/// 15's explicit criterion: "on platforms without a Local Source
/// implementation, the gallery behaves exactly as it did before this
/// ticket". [LocalScanService] (`local_scan_service.dart`) is where that is
/// upheld: a null source makes a scan a no-op.
LocalSource? createLocalSource() => impl.createLocalSource();
