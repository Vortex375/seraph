# 02 — Zoom-gated panning

**What to build:** Pinching to zoom in on a gallery photo lets the user pan the
photo by dragging, and disables the swipe-to-next-image gesture while zoomed
so the drag pans instead of paging. Zooming all the way back out to 1×
re-enables the swipe and disables panning, so a drag at 1× always pages.

This mirrors the file viewer's zoom gating: a shared `TransformationController`
drives an `isZoomedIn` flag (`getMaxScaleOnAxis() > 1.0`); the `PageView` uses
`NeverScrollableScrollPhysics` while zoomed and `PageScrollPhysics` otherwise;
the `InteractiveViewer` sets `panEnabled` to the zoom flag. Because swiping is
disabled while zoomed, the user never sees two photos at different zooms, so a
single shared zoom state (matching the file viewer) is acceptable.

**Blocked by:** 01 — Full-screen toggle (both rewrite `GalleryPhotoPage`'s
build tree; sequencing avoids file-level edit conflicts).

**Status:** resolved

Base SHA: ffea3e7eab44676e01f8f3839ed7857632d81fb9

## Comments

### Implementer report
Committed. Zoom-gated panning in the gallery photo viewer, mirroring the file viewer. `_GalleryPhotoViewerViewState` holds a shared `TransformationController` and `_isZoomedIn` `ValueNotifier<bool>`; a listener flips the flag from `getMaxScaleOnAxis() > 1.0`. The `PageView.builder` is wrapped in a `ValueListenableBuilder` selecting `NeverScrollableScrollPhysics` while zoomed and `PageScrollPhysics` otherwise. `GalleryPhotoPage` takes the controller + notifier, binds `transformationController`, keeps `maxScale: 4`, and gates `panEnabled` on the zoom flag via a `ValueListenableBuilder`. `dispose` disposes both. Files: `gallery_photo_viewer.dart`, `gallery_view_test.dart`. `flutter analyze` clean; all 30 tests pass, including the new zoom-gating test (two-pointer pinch in/out, asserting physics + `panEnabled` + fling-no-page while zoomed, fling-pages at 1×).
Decision the ticket didn't settle: `InteractiveViewer`'s default `minScale` is 0.8, so a pinch-in clamps at 0.8 (still < 1.0, flag flips correctly). Kept the default rather than pinning `minScale: 1.0`, matching the file viewer which also leaves it default.

### Verifier verdict
APPROVED — all criteria verified with the toolchain running. Listener, physics gating, controller binding, `maxScale: 4`, `panEnabled`, and dispose all correct. No regression to ticket 01's toggle/swipe/details/upload. Test drives a real two-finger scale gesture and asserts physics, `panEnabled`, and fling behaviour in both directions.

- [ ] `_GalleryPhotoViewerViewState` holds a `ValueNotifier<bool>` for zoom
      state and a shared `TransformationController` with a listener that sets
      the flag from `getMaxScaleOnAxis() > 1.0`.
- [ ] `dispose` disposes the `TransformationController` and the zoom notifier.
- [ ] The `PageView.builder`'s `physics` is `NeverScrollableScrollPhysics`
      while zoomed and `PageScrollPhysics` otherwise (gated on the zoom flag).
- [ ] `GalleryPhotoPage` takes the `TransformationController` and the zoom
      `ValueNotifier`; the `InteractiveViewer` binds `transformationController`,
      keeps `maxScale: 4`, and sets `panEnabled` from the zoom flag.
- [ ] Widget test: scaling a `GalleryPhotoPage` past 1× makes the `PageView`
      physics `NeverScrollableScrollPhysics` and `InteractiveViewer.panEnabled`
      true, and a horizontal fling does not change the page; scaling back to 1×
      restores `PageScrollPhysics`, `panEnabled` false, and a horizontal fling
      pages as before.
- [ ] `flutter analyze` and `flutter test` pass.
