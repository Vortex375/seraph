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

/// Claims the gesture arena for the platform view the moment a second touch
/// pointer goes down over it.
///
/// Why this exists: the surrounding `PageView`'s horizontal drag recognizer
/// accepts as soon as one pointer drifts [kTouchSlop] (18px) horizontally,
/// while the team's [ScaleGestureRecognizer] accepts a pinch only once the
/// two-finger span changes by [kScaleSlop] (18px) - and the span only starts
/// growing when the second finger lands. A pinch whose first finger drifts
/// even a little before the second lands therefore lets the pager win the
/// arena first, and the photo pages instead of zooming. This recognizer
/// accepts while the second pointer's arena is still open (the arena's
/// eager-winner path), which resolves BOTH pointers' arenas in the team
/// captain's favour: the platform view receives the complete two-finger
/// stream, and the pager's drag recognizer never reaches its slop. A
/// two-finger gesture over the photo can never page.
///
/// One-finger gestures never satisfy it (it only counts touch pointers), so
/// swiping pages exactly as before, and a non-touch pointer (a mouse click
/// while touching) does not turn a gesture into a pinch.
class PinchClaimGestureRecognizer extends OneSequenceGestureRecognizer {
  PinchClaimGestureRecognizer({super.debugOwner});

  /// The touch pointers currently down over the platform view.
  final Set<int> _touchPointers = <int>{};

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      if (event.kind == PointerDeviceKind.touch) {
        _touchPointers.add(event.pointer);
        if (_touchPointers.length >= 2) {
          // Two fingers down: this is a pinch (or a two-finger drag), and it
          // belongs to the photo, not the pager. Accepting resolves every
          // arena this recognizer is in - both pointers' - in the team
          // captain's favour.
          resolve(GestureDisposition.accepted);
        }
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _touchPointers.remove(event.pointer);
      stopTrackingIfPointerNoLongerDown(event);
    }
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _touchPointers.clear();
  }

  @override
  void dispose() {
    _touchPointers.clear();
    super.dispose();
  }

  @override
  String get debugDescription => 'pinch claim';
}

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
/// alive. The native view owns its transform - pinch zoom to 4x, clamped
/// pan, and double-tap zoom, all in the ImageView's view properties - and
/// the gesture split comes from the arena: the surface's recognizers form a
/// gesture-arena TEAM with the platform view itself as captain, so when any
/// of them claims a gesture the whole arena is handed to the platform view
/// and the native view sees every pointer. The team holds two recognizers:
/// [ScaleGestureRecognizer] claims pinches and, once zoomed in, the
/// one-finger pans (the pager's physics go NeverScrollable on the zoom
/// report, so the native view is then the last contender standing and pans
/// live); [PinchClaimGestureRecognizer] claims any two-finger gesture the
/// instant the second touch pointer lands, so a pinch can never lose the
/// arena to the pager's horizontal drag and page instead of zooming. At 1x a
/// one-finger swipe satisfies neither and still pages the `PageView`, and a
/// zoomed-out report re-enables the pager's physics so paging works
/// immediately. No Flutter-side transform is ever applied to the platform
/// view.
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
        // The surface's recognizers join a gesture-arena TEAM with the
        // surface itself as captain: when any of them claims a gesture, the
        // whole arena is handed to the platform view and the native view
        // sees every pointer.
        //
        // The scale recognizer claims pinches and, once zoomed in, the
        // one-finger pans (focal-point slop) - the pager's physics go
        // NeverScrollable on the zoom report, so the native view is then the
        // last contender standing and pans live. At 1x a one-finger
        // horizontal drag still beats it (the PageView's drag recognizer
        // accepts at kTouchSlop, the scale recognizer only at span/focal
        // slop), so paging works.
        //
        // The pinch-claim recognizer closes the remaining race: the pager's
        // drag recognizer accepts after a single pointer drifts kTouchSlop
        // horizontally, which a pinch produces as a side effect - often
        // before the scale recognizer's own acceptance - so a pinch used to
        // page instead of zooming. The claim recognizer accepts the moment a
        // second touch pointer lands over the photo, before any drag
        // threshold can fire, so a two-finger gesture always reaches the
        // native view and never pages.
        //
        // Each factory is parameterized with its concrete recognizer type:
        // the platform view asserts the factories' types are all distinct.
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
          Factory<ScaleGestureRecognizer>(ScaleGestureRecognizer.new),
          Factory<PinchClaimGestureRecognizer>(PinchClaimGestureRecognizer.new),
        },
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

/// One full-screen photo page for a pager, rendered through [HdrPhotoView]
/// on the native path - shared by the gallery photo viewer and the file
/// viewer (which fetches over WebDAV instead of the gallery loader; the
/// bytes and this page are identical either way).
///
/// Contract with its host: the host owns a pager whose scroll physics gate
/// on [onZoomChanged] reports exactly like both viewers' `isZoomedIn`
/// shape, owns the chrome tap while unzoomed, and supplies a
/// [Uint8List]-producing [fetch]; the [thumbnail] image (already in
/// Flutter's image cache from the grid or the previous viewing) holds the
/// frame until the bytes land - never a blank page. There is deliberately
/// no Hero support: a platform view cannot serve as a Hero child
/// mid-flight, and the file viewer is dropping its Hero (approved).
class HdrPhotoPage extends StatefulWidget {
  const HdrPhotoPage({
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
  /// native view replaces it - no cross-fade.
  final Widget thumbnail;

  /// Tapping the photo toggles the host's full-screen chrome. See
  /// [HdrPhotoView]'s class doc for how the tap reaches here.
  final VoidCallback onToggleUi;

  /// Receives the native view's zoom entered/exited reports, to gate the
  /// host pager's scroll physics.
  final ValueChanged<bool> onZoomChanged;

  /// Clears the host's shared zoom state when the native view dies (decode
  /// error), so the pager is never stranded on `NeverScrollableScrollPhysics`.
  final VoidCallback onResetZoom;

  @override
  State<HdrPhotoPage> createState() => _HdrPhotoPageState();
}

class _HdrPhotoPageState extends State<HdrPhotoPage> {
  /// The full-resolution bytes, once fetched. Null until then; a fetch that
  /// ended in failure lands in [_failed] instead.
  Uint8List? _bytes;

  /// The fetch failed (network, 404, an exhausted refresh-retry) or the
  /// native view could not decode what arrived: fall back to the existing
  /// Flutter error state.
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    Uint8List? bytes;
    try {
      bytes = await widget.fetch();
    } catch (_) {
      // Any failure - offline, 404, an expired token the retry could not
      // save - is the existing error state, not a crash.
      bytes = null;
    }
    if (!mounted) {
      return;
    }
    if (bytes == null || bytes.isEmpty) {
      setState(() => _failed = true);
      return;
    }
    setState(() => _bytes = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    return SizedBox.expand(
      child: Stack(
        alignment: Alignment.center,
        children: [
          // The already-loaded thumbnail holds the frame while the bytes
          // download - the page is never blank.
          widget.thumbnail,
          if (bytes != null)
            Positioned.fill(
              child: HdrPhotoView(
                bytes: bytes,
                onTap: widget.onToggleUi,
                onZoomChanged: widget.onZoomChanged,
                onError: () => setState(() {
                  // The native view is gone: forget its bytes (they are
                  // undecodable natively) and fall back to the existing
                  // error state.
                  _bytes = null;
                  _failed = true;
                  // The native zoom state died with the view; the pager
                  // must be swiping again for whatever shows next.
                  widget.onResetZoom();
                }),
              ),
            )
          else if (_failed)
            // The failure state: the thumbnail above keeps showing - the
            // existing "error leaves the thumbnail" behaviour, never a
            // blank page.
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}
