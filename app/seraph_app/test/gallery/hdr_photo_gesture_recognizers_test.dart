import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/hdr_photo_view.dart';

/// Unit tests for [PinchClaimGestureRecognizer] (`.scratch/hdr-photo-viewer/
/// issues/06`): the recognizer that keeps a two-finger pinch from losing the
/// gesture arena to the pager's horizontal drag recognizer.
///
/// Each test drives the recognizer the way the framework would over a live
/// platform view: every pointer down is registered with
/// [GestureRecognizer.addPointer], delivered through the pointer router (so
/// the recognizer's handleEvent sees it), and its arena closed; moves and ups
/// are routed the same way and the arena swept. A [HorizontalDragGestureRecognizer]
/// stands in for the surrounding PageView's drag recognizer, which is the
/// competitor the claim recognizer exists to beat. The tests run as
/// testWidgets (not plain tests) because the drag recognizer's velocity
/// tracker needs the test binding's fake clock.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// The claim recognizer with its arena callbacks recorded.
  late _ObservingPinchClaim claim;

  /// The pager's stand-in drag recognizer with its arena callbacks recorded.
  late _ObservingDrag drag;

  setUp(() {
    claim = _ObservingPinchClaim();
    drag = _ObservingDrag()..onDown = (_) {};
    addTearDown(claim.dispose);
    addTearDown(drag.dispose);
  });

  /// Registers both recognizers for [event] and delivers it to them, the way
  /// the hit-test dispatch does for pointers over the platform view.
  void pointerDown(PointerDownEvent event) {
    claim.addPointer(event);
    drag.addPointer(event);
    GestureBinding.instance.pointerRouter.route(event);
    GestureBinding.instance.gestureArena.close(event.pointer);
  }

  void pointerMove(PointerMoveEvent event) {
    GestureBinding.instance.pointerRouter.route(event);
  }

  testWidgets(
      'accepts both pointers as soon as a second touch pointer goes down',
      (tester) async {
    pointerDown(PointerDownEvent(pointer: 1, position: const Offset(100, 100)));
    expect(claim.accepted, isEmpty, reason: 'one finger is not a pinch');

    final down2 =
        PointerDownEvent(pointer: 2, position: const Offset(140, 100));
    claim.addPointer(down2);
    drag.addPointer(down2);
    GestureBinding.instance.pointerRouter.route(down2);

    // The accept lands while the second pointer's arena is still open (the
    // arena's eager-winner path): the first pointer's arena, already closed,
    // resolves in the claim's favour immediately; the second's follows at
    // close.
    expect(claim.accepted, contains(1));
    expect(claim.accepted, isNot(contains(2)));
    GestureBinding.instance.gestureArena.close(2);
    expect(claim.accepted, containsAll(<int>[1, 2]),
        reason: 'the whole two-finger gesture belongs to the platform view');
    expect(drag.rejected, containsAll(<int>[1, 2]),
        reason: 'the pager must lose the arena to the claim');
  });

  testWidgets('a one-finger horizontal drag is left to the pager',
      (tester) async {
    pointerDown(PointerDownEvent(pointer: 1, position: const Offset(100, 100)));

    // 20px horizontal in one move: past kTouchSlop, so the pager's drag
    // recognizer accepts - paging keeps its standard framework slop. (The
    // drag recognizer accumulates PointerMoveEvent.delta, not positions.)
    pointerMove(PointerMoveEvent(
      pointer: 1,
      position: const Offset(80, 100),
      delta: const Offset(-20, 0),
    ));

    expect(drag.accepted, contains(1));
    expect(claim.accepted, isEmpty);
    expect(claim.rejected, contains(1));
  });

  testWidgets('a one-finger gesture that ends without moving never claims',
      (tester) async {
    pointerDown(PointerDownEvent(pointer: 1, position: const Offset(100, 100)));

    final up = PointerUpEvent(pointer: 1, position: const Offset(100, 100));
    GestureBinding.instance.pointerRouter.route(up);
    GestureBinding.instance.gestureArena.sweep(1);

    // The sweep hands the unresolved arena to its first member - the claim
    // recognizer, registered before the drag recognizer - but that is the
    // framework's sweep, not a claim: nothing accepted during the gesture.
    expect(claim.acceptedDuringGesture, isEmpty);
    expect(drag.accepted, isEmpty);
  });

  testWidgets('a non-touch second pointer does not claim', (tester) async {
    pointerDown(PointerDownEvent(pointer: 1, position: const Offset(100, 100)));

    // A mouse pointer landing while a finger is down is not a pinch.
    pointerDown(PointerDownEvent(
      pointer: 2,
      position: const Offset(140, 100),
      kind: PointerDeviceKind.mouse,
    ));
    expect(claim.accepted, isEmpty);

    // The subsequent horizontal drag still goes to the pager, for both
    // pointers - the drag recognizer resolves every arena it is in.
    pointerMove(PointerMoveEvent(
      pointer: 1,
      position: const Offset(80, 100),
      delta: const Offset(-20, 0),
    ));
    expect(drag.accepted, containsAll(<int>[1, 2]));
    expect(claim.accepted, isEmpty);
    expect(claim.rejected, containsAll(<int>[1, 2]));
  });
}

/// A [PinchClaimGestureRecognizer] that records its arena callbacks, and
/// whether an accept happened during the gesture (before any sweep).
class _ObservingPinchClaim extends PinchClaimGestureRecognizer {
  final List<int> accepted = <int>[];
  final List<int> rejected = <int>[];

  /// Pointers accepted while their arena was still open - i.e. by an actual
  /// claim, not by the sweep's first-member-wins default.
  final List<int> acceptedDuringGesture = <int>[];

  bool _gestureLive = false;

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerDownEvent) {
      _gestureLive = true;
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _gestureLive = false;
    }
    super.handleEvent(event);
  }

  @override
  void acceptGesture(int pointer) {
    accepted.add(pointer);
    if (_gestureLive) {
      acceptedDuringGesture.add(pointer);
    }
    super.acceptGesture(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    rejected.add(pointer);
    super.rejectGesture(pointer);
  }
}

/// A [HorizontalDragGestureRecognizer] (the pager's stand-in) that records
/// its arena callbacks.
class _ObservingDrag extends HorizontalDragGestureRecognizer {
  final List<int> accepted = <int>[];
  final List<int> rejected = <int>[];

  @override
  void acceptGesture(int pointer) {
    accepted.add(pointer);
    super.acceptGesture(pointer);
  }

  @override
  void rejectGesture(int pointer) {
    rejected.add(pointer);
    super.rejectGesture(pointer);
  }
}
