import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'hdr_photo_view.dart';

/// One full-screen photo page on the web build, rendered by the BROWSER's
/// image pipeline (`.scratch/hdr-photo-viewer-web/spec.md`): an `<img>`
/// whose `src` is a blob URL of the already-fetched bytes, hosted in an
/// [HtmlElementView]. A gain-map JPEG (the format the server serves)
/// renders HDR in Chrome/Edge/Safari 26; everywhere else it degrades to a
/// correct SDR base image - by design of the format, so there is no
/// capability gate (spec: "detection adds a branch that can never change
/// an outcome").
///
/// Same host contract as [HdrPhotoPage]: [fetch] produces the bytes,
/// [thumbnail] holds the frame until they land, [onToggleUi] toggles the
/// chrome, [onZoomChanged]/[onResetZoom] gate the host pager's physics.
///
/// Gestures: the element is styled `pointer-events: none`, so every
/// pointer falls through to the Flutter canvas and the gesture arena runs
/// unchanged - the page-level detector keeps taps, the surrounding
/// `PageView` keeps 1x paging (the same coexistence
/// `InteractiveViewer`-inside-`PageView` has). This widget owns one
/// `ScaleGestureRecognizer` for pinch AND pan (the exact shape
/// `InteractiveViewer` uses): zoom and pan are applied as a CSS transform
/// on the `<img>` - deliberately inverting the Android path's
/// "never transform the platform view" rule, because a DOM transform is
/// composited by the browser, not a Flutter transform over a hybrid view.
///
/// `ponytail:` a CSS-transformed `<img>` is rastered by the browser and
/// can soften at 4x. If that ever visibly matters, the upgrade path is an
/// HDR canvas (`rec2100-pq` 2D canvas in Chromium) drawn at full raster
/// scale - deliberately not built now (spec, "Known ceiling").
class HdrPhotoPageWeb extends StatefulWidget {
  const HdrPhotoPageWeb({
    super.key,
    required this.fetch,
    required this.thumbnail,
    required this.onToggleUi,
    required this.onZoomChanged,
    required this.onResetZoom,
  });

  /// Produces the photo's full-resolution bytes. A throw is a failure; a
  /// null or empty result is one too - both land in the failure state.
  final Future<Uint8List?> Function() fetch;

  /// The photo's already-loaded thumbnail - the same provider the grid
  /// (or the previous viewing) warmed, so it serves from Flutter's image
  /// cache and never re-fetches. Shown until the bytes arrive and the
  /// `<img>` replaces it - no cross-fade.
  final Widget thumbnail;

  /// Tapping the photo toggles the host's full-screen chrome. Handled by
  /// the host's page-level detector (this widget claims no taps).
  final VoidCallback onToggleUi;

  /// Receives the web view's zoom entered/exited reports, to gate the host
  /// pager's scroll physics.
  final ValueChanged<bool> onZoomChanged;

  /// Clears the host's shared zoom state when the view dies (fetch or
  /// `<img>` error), so the pager is never stranded on
  /// `NeverScrollableScrollPhysics`.
  final VoidCallback onResetZoom;

  @override
  State<HdrPhotoPageWeb> createState() => _HdrPhotoPageWebState();
}

class _HdrPhotoPageWebState extends State<HdrPhotoPageWeb> {
  static const _maxScale = 4.0; // parity with HdrPhotoImageView.MAX_SCALE

  /// Unique per instance: each page registers its own factory, because
  /// each page owns its own `<img>` element.
  late final String _viewType = 'seraph-hdr-photo-web-${_viewCounter++}';
  static int _viewCounter = 0;

  bool _failed = false;
  web.HTMLImageElement? _img;
  String? _blobUrl;

  // The transform state - the web counterpart of the Kotlin view
  // properties: scale about centre plus translation, focal point carried
  // in the translation.
  double _scale = 1.0;
  double _tx = 0.0;
  double _ty = 0.0;
  bool _reportedZoomed = false;

  /// The bitmap's width/height ratio, read from the loaded `<img>`.
  /// The pan clamp needs it: the photo is object-fit contained inside the
  /// page, so the content rect is smaller than the page on at least one
  /// axis, and clamping against the page size would let the photo be
  /// dragged past its own edge (exposing the thumbnail behind it - the
  /// 'second copy' bug the Android path had). 0 until the image loads.
  double _imgAspect = 0.0;

  double? _gestureStartScale;
  Offset? _gestureStartTranslation;
  Offset? _gestureStartFocal;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await widget.fetch();
    if (!mounted) {
      return;
    }
    if (bytes == null || bytes.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    final blob = web.Blob([bytes.toJS].toJS, web.BlobPropertyBag(
        type: 'image/jpeg'));
    final url = web.URL.createObjectURL(blob);
    final img = (web.document.createElement('img') as web.HTMLImageElement)
      ..src = url
      // Fill the page and letterbox like the thumbnail behind us -
      // BoxFit.contain's twin. pointer-events: none is the whole gesture
      // split (see the class doc).
      ..style.width = '100%'
      ..style.height = '100%'
      ..style.display = 'block'
      ..style.objectFit = 'contain'
      ..style.pointerEvents = 'none';
    img.addEventListener('load', _onImgLoad.toJS);
    img.addEventListener('error', _onImgError.toJS);
    ui_web.platformViewRegistry.registerViewFactory(
        _viewType, (int viewId) => img);
    setState(() {
      _failed = false;
      _blobUrl = url;
      _img = img;
    });
  }

  void _onImgLoad(web.Event event) {
    final img = _img;
    if (img == null) {
      return;
    }
    final w = img.naturalWidth;
    final h = img.naturalHeight;
    if (w > 0 && h > 0) {
      // Read during gestures, not build - no setState.
      _imgAspect = w / h;
    }
  }

  void _onImgError(web.Event event) {
    if (!mounted) {
      return;
    }
    _revoke();
    setState(() {
      _failed = true;
      _blobUrl = null;
      _img = null;
    });
    // The zoom state died with the view; the pager must be swiping again
    // for whatever shows next.
    widget.onResetZoom();
  }

  void _revoke() {
    final url = _blobUrl;
    if (url != null) {
      web.URL.revokeObjectURL(url);
    }
    _blobUrl = null;
    _img = null;
  }

  @override
  void dispose() {
    _revoke();
    super.dispose();
  }

  // --- Gestures: one scale recognizer for pinch and pan -------------------

  void _onScaleStart(ScaleStartDetails details) {
    _gestureStartScale = _scale;
    _gestureStartTranslation = Offset(_tx, _ty);
    _gestureStartFocal = details.localFocalPoint;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final s0 = _gestureStartScale;
    final startT = _gestureStartTranslation;
    final startFocal = _gestureStartFocal;
    final size = context.size;
    if (s0 == null || startT == null || startFocal == null || size == null) {
      return;
    }
    final s1 = (s0 * details.scale).clamp(1.0, _maxScale);
    final cx = size.width / 2;
    final cy = size.height / 2;
    // Keep the content point that was under the fingers at gesture start
    // under the fingers now - the same focal-point formula
    // HdrPhotoImageView.zoomTo uses. For a one-finger drag (s1 == s0) it
    // reduces to translation-by-finger-delta: pan.
    final focal = details.localFocalPoint;
    final tx = focal.dx - cx - (s1 / s0) * (startFocal.dx - cx - startT.dx);
    final ty = focal.dy - cy - (s1 / s0) * (startFocal.dy - cy - startT.dy);
    _applyTransform(s1, tx, ty);
  }

  void _onScaleEnd(ScaleEndDetails details) {
    if (_scale <= 1.0) {
      // Back at fit-center: clear the pan (the clamp below already zeroes
      // a letterboxed axis at 1x; this pins both).
      _applyTransform(1.0, 0.0, 0.0);
    }
    _gestureStartScale = null;
    _gestureStartTranslation = null;
    _gestureStartFocal = null;
  }

  /// Applies scale about the page's centre plus a clamped translation.
  ///
  /// The photo is object-fit contained, so the content rect is smaller
  /// than the page on at least one axis. An axis can pan only once the
  /// SCALED content exceeds the page on that axis (the behaviour every
  /// photo viewer has); the free slack per axis is
  /// `(scaledContentSize - pageSize) / 2`, and zero pins the photo's
  /// centre to the page's - which at 1x is exactly fit-center again, and
  /// the report below re-enables paging.
  void _applyTransform(double s, double tx, double ty) {
    final size = context.size;
    final img = _img;
    if (img == null || size == null) {
      return;
    }
    final w = size.width;
    final h = size.height;
    var contentW = w;
    var contentH = h;
    if (_imgAspect > 0 && w > 0 && h > 0) {
      final viewAspect = w / h;
      if (_imgAspect > viewAspect) {
        // Photo wider than the page: fills the width, HEIGHT letterboxed.
        contentH = w / _imgAspect;
      } else {
        // Photo taller (or matching): fills the height, WIDTH pillarboxed.
        contentW = h * _imgAspect;
      }
    }
    final maxTx = ((contentW * s - w) / 2).clamp(0.0, double.infinity);
    final maxTy = ((contentH * s - h) / 2).clamp(0.0, double.infinity);
    final clamped = s.clamp(1.0, _maxScale);
    _scale = clamped;
    _tx = tx.clamp(-maxTx, maxTx);
    _ty = ty.clamp(-maxTy, maxTy);
    img.style.transform =
        'translate(${_tx}px, ${_ty}px) scale($_scale)';
    final zoomed = clamped > 1.0;
    if (zoomed != _reportedZoomed) {
      _reportedZoomed = zoomed;
      widget.onZoomChanged(zoomed);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_blobUrl != null && !_failed) {
      return SizedBox.expand(
        child: Stack(
          alignment: Alignment.center,
          children: [
            // The already-loaded thumbnail holds the frame while the bytes
            // download; once the element covers it, it stays fully hidden
            // (same geometry) until a clamped pan can no longer expose it.
            widget.thumbnail,
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onScaleStart: _onScaleStart,
                onScaleUpdate: _onScaleUpdate,
                onScaleEnd: _onScaleEnd,
                child: HtmlElementView(viewType: _viewType),
              ),
            ),
          ],
        ),
      );
    }
    // Bytes still downloading, or a fetch/`<img>` failure: the thumbnail
    // keeps showing - the existing "error leaves the thumbnail" state,
    // never a blank page.
    return SizedBox.expand(child: widget.thumbnail);
  }
}
