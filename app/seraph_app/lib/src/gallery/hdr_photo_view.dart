import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/services.dart';

import 'android_device.dart';

/// Test override: forces the native path on regardless of the platform gate,
/// so the viewer-level fake-channel tests can drive it on the test host
/// (where the real gate is false, keeping the existing Flutter-path tests
/// untouched).
@visibleForTesting
bool hdrPhotoNativeForTest = false;

/// Whether the gallery viewer's native HDR path is available here: a real
/// Android device or the test override. Never true on web (the gate there
/// keeps the existing Flutter rendering).
bool get hdrPhotoNativeAvailable => hdrPhotoNativeForTest || isAndroidDevice;

/// One full-screen photo rendered by a native Android `ImageView` hosted as
/// a platform view (`.scratch/hdr-photo-viewer/spec.md`).
///
/// Flutter's Android backend cannot draw an Ultra HDR gain map
/// (flutter/flutter#127852): it draws into an 8-bit sRGB surface and decodes
/// only the SDR base layer. A native `ImageView` decoded via `ImageDecoder`
/// does see the gain map, and under Classic Hybrid Composition
/// (`PlatformViewsService.initExpensiveAndroidView` - never the HCPP or
/// texture-layer init; see the spec's "Composition and renderer") the real
/// view sits in the activity's hierarchy where the window HDR colour mode
/// applies.
///
/// This widget is the feature's one Dart-side seam (spec, "Testing
/// Decisions"): photo [bytes] in as creation params; zoom-changed / tap /
/// decode-error callbacks out; plus the window colour mode call
/// (`setHdrColorMode` on the shared local-media channel) while any host is
/// alive. The native view owns its transform - pinch zoom to 4x and clamped
/// pan in the ImageView's view properties - and the gesture split comes for
/// free from the arena: with an empty `gestureRecognizers` set, a gesture
/// reaches the platform view only when no Flutter recognizer claims it
/// (RenderAndroidView's contract). At 1x the surrounding `PageView`'s drag
/// recognizer claims horizontal drags and pages; a pinch has no competitor,
/// goes native, and zooming in - reported to the pager's physics gate -
/// makes the native view the last one standing, so it pans. A zoomed-out
/// report re-enables the pager's physics and paging works immediately. No
/// Flutter-side transform is ever applied to the platform view.
class HdrPhotoView extends StatefulWidget {
  const HdrPhotoView({
    super.key,
    required this.bytes,
    required this.onTap,
    required this.onZoomChanged,
    required this.onError,
  });

  final Uint8List bytes;

  /// The user tapped the photo: toggle the viewer chrome.
  final VoidCallback onTap;

  /// The native view entered (true) or returned to (false) fit-center.
  final ValueChanged<bool> onZoomChanged;

  /// The native side could not decode [bytes]; the host page must stop
  /// showing this widget and fall back to the existing Flutter rendering.
  final VoidCallback onError;

  @override
  State<HdrPhotoView> createState() => _HdrPhotoViewState();
}

/// Live [HdrPhotoView] count. The window colour mode goes HDR when the first
/// host opens and back to default when the last one closes: a settled
/// `PageView` keeps exactly one host alive, but a page mid-swipe has two,
/// and a plain init/dispose pair would flip the mode off when the neighbour
/// is disposed while the current page still shows.
int _hdrViewCount = 0;

class _HdrPhotoViewState extends State<HdrPhotoView> {
  static const _viewType = 'seraph/hdr_photo';

  // Outbound colour-mode calls ride the shared local-media channel - the
  // same activity-bound handler the scan and load calls use, and outbound
  // calls never touch the inbound handler slot AndroidLocalSource owns (see
  // its class doc).
  static const _localMedia = MethodChannel('seraph/local_media');

  MethodChannel? _viewChannel;

  @override
  void initState() {
    super.initState();
    if (++_hdrViewCount == 1) {
      unawaited(_setColorMode(true));
    }
  }

  @override
  void dispose() {
    if (--_hdrViewCount == 0) {
      unawaited(_setColorMode(false));
    }
    _viewChannel?.setMethodCallHandler(null);
    super.dispose();
  }

  Future<void> _setColorMode(bool hdr) async {
    try {
      await _localMedia.invokeMethod<void>('setHdrColorMode', hdr);
    } on PlatformException {
      // A device that refuses it still shows the photo - tonemapped, but
      // shown.
    } on MissingPluginException {
      // No plugin on this engine (tests, headless).
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'tap':
        widget.onTap();
      case 'zoomChanged':
        widget.onZoomChanged(call.arguments as bool? ?? false);
      case 'decodeError':
        widget.onError();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: _viewType,
      surfaceFactory: (context, controller) => AndroidViewSurface(
        controller: controller as AndroidViewController,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        // Empty on purpose: a gesture reaches the platform view only when no
        // Flutter recognizer claims it (see the class doc) - that contract
        // is the whole gesture split, and no Flutter-side transform is ever
        // applied here.
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
      onCreatePlatformView: (params) {
        // Per-view callback channel, keyed by the platform view id - never
        // the shared local-media channel (whose single inbound handler slot
        // is owned by AndroidLocalSource's change listener; a second
        // setMethodCallHandler on that name would steal it). Keying by id
        // also keeps the current page's and a mid-swipe neighbour's views
        // from cross-talking during a swipe.
        final channel = MethodChannel('$_viewType/view/${params.id}');
        _viewChannel = channel;
        channel.setMethodCallHandler(_handleNativeCall);
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: _viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: widget.bytes,
          creationParamsCodec: const StandardMessageCodec(),
          onFocus: () => params.onFocusChanged(true),
        );
        controller
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
        return controller;
      },
    );
  }
}
