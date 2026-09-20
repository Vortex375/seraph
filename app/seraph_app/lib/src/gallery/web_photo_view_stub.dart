import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// VM/test placeholder behind `web_photo_view.dart`'s conditional export -
/// the real [HdrPhotoPageWeb] lives in `web_photo_view_html.dart` and only
/// exists on the web build (it imports `dart:ui_web` and `package:web`).
/// Never constructed: every call site gates on `useWebPhotoView`.
class HdrPhotoPageWeb extends StatelessWidget {
  const HdrPhotoPageWeb({
    super.key,
    required this.fetch,
    required this.thumbnail,
    required this.onToggleUi,
    required this.onZoomChanged,
    required this.onResetZoom,
  });

  final Future<Uint8List?> Function() fetch;
  final Widget thumbnail;
  final VoidCallback onToggleUi;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback onResetZoom;

  @override
  Widget build(BuildContext context) => thumbnail;
}
