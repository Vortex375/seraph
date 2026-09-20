import 'package:flutter/foundation.dart';

export 'web_photo_view_stub.dart'
    if (dart.library.js_interop) 'web_photo_view_html.dart';

/// Whether the web `<img>` HDR path owns photo pages here
/// (`.scratch/hdr-photo-viewer-web/spec.md`). True on the web build only;
/// Android keeps the native platform view, iOS the Flutter rendering.
bool get useWebPhotoView => kIsWeb;
