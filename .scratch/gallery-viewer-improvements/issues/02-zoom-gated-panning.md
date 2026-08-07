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

**Status:** ready-for-agent

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
