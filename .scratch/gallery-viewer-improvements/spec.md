# Gallery Mode photo viewer improvements

## Problem Statement

A user looking at a photo full screen in Gallery Mode cannot get the photo out
of its chrome the way they can in the file viewer, cannot jump from a photo's
details to the folder the photo lives in, and cannot pan a zoomed photo without
the swipe-to-next-image gesture fighting them.

Concretely, three things are missing from the gallery-mode full-size viewer
that the file viewer already has, plus one navigation step the gallery viewer
does not yet offer at all:

1. **No full-screen toggle.** In the file viewer, tapping the photo hides the
   app bar and the system UI and turns the device full screen; tapping again
   brings the chrome back. The gallery-mode viewer has no such control — the
   app bar and system UI stay on screen for the whole viewing session.

2. **No folder jump from details.** The photo details dialog already names
   the Seraph folder a photo lives in, but the user cannot act on that: the
   "File" row is a plain label. To find the photo in the file browser the user
   has to leave the viewer, leave the gallery, and navigate the browser by
   hand.

3. **Pan & zoom is broken.** Pinch-to-zoom works, but once zoomed in the user
   cannot drag the photo around, because the horizontal drag is claimed by the
   `PageView`'s swipe-to-next-image gesture. The file viewer already solves
   this by gating the page swipe on zoom state: while zoomed in the page does
   not swipe and the photo pans; once back at 1× the page reclaims the swipe.

## Solution

Bring the gallery-mode full-size viewer up to parity with the file viewer for
chrome hiding and zoom-gated panning, and add a folder-jump affordance to the
photo details dialog.

From the user's perspective:

- Tapping the photo in the full-size viewer hides the app bar and the system
  status bar / navigation bar, leaving only the photo. Tapping again brings the
  chrome back. Leaving the viewer always restores the system UI.
- Pinching to zoom in on a photo disables the swipe-to-next-image gesture and
  lets the drag pan the photo. Pinching back out to 1× re-enables the swipe and
  stops panning.
- In the photo details dialog, tapping the "File" row opens the file browser at
  the Seraph folder the photo lives in. Backing out of that folder returns to
  the Gallery, not the viewer — the viewer is popped, the gallery stays.

Device-only items have no Seraph folder to open, so for those the "File" row
stays a plain, non-interactive label (mirroring the existing "Seraph folder"
row, which is already omitted for Device-only items for the same reason).

## User Stories

1. As a gallery user, I want to tap a photo in the full-size viewer to hide the
   app bar and system UI, so that the photo fills the screen with no chrome in
   the way.
2. As a gallery user, I want to tap the photo again to bring the app bar and
   system UI back, so that I can reach the date, the upload action, and the
   details action.
3. As a gallery user, I want the system UI to be restored when I leave the
   viewer, so that the rest of the app is not stuck in immersive mode.
4. As a gallery user, I want pinch-to-zoom to let me pan the zoomed photo by
   dragging, so that I can look at different parts of a zoomed-in photo.
5. As a gallery user, I want the swipe-to-next-image gesture to be disabled
   while I am zoomed in, so that dragging to pan does not skip to the next
   photo.
6. As a gallery user, I want the swipe-to-next-image gesture to come back once
   I have zoomed all the way out to 1×, so that I can move between photos again
   by swiping.
7. As a gallery user, I want panning to be disabled while I am at 1×, so that
   a drag at 1× always swipes to the next photo rather than nudging the photo.
8. As a gallery user, I want to tap the "File" row in a photo's details to open
   the file browser at the folder the photo lives in, so that I can find the
   photo there or over WebDAV.
9. As a gallery user, I want the back button from that folder to return me to
   the Gallery, so that I can keep browsing photos without re-opening the
   gallery.
10. As a gallery user with a Device-only photo, I want the "File" row in that
    photo's details to stay non-interactive, so that I am not offered a folder
    that does not exist.
11. As a gallery user, I want the full-screen toggle, the zoom-gated pan, and
    the folder jump to work together on the same photo, so that none of them
    disables the others.

## Implementation Decisions

The full-size viewer is `GalleryPhotoViewerView` in
`src/gallery/gallery_photo_viewer.dart`, a `StatefulWidget` whose state
(`_GalleryPhotoViewerViewState`) holds a `PageController`, a `ValueNotifier<int>`
for the current index, and a `ValueNotifier<bool>` for upload progress. The
photo details dialog is the `GalleryPhotoDetails` `StatelessWidget` in the same
file.

The reference implementation for the full-screen toggle and the zoom-gated
pan is the file viewer:
`src/file_viewer/file_viewer_controller.dart` (`FileViewerController` holds
`isUiVisible`, `isZoomedIn`, and a `TransformationController`; `toggleUiVisible`
flips `SystemChrome.setEnabledSystemUIMode` between `immersive` and
`edgeToEdge`; the `TransformationController` listener sets `isZoomedIn` from
`getMaxScaleOnAxis() > 1.0`) and
`src/file_viewer/file_viewer_view.dart` (the `PageView` uses
`NeverScrollableScrollPhysics` when zoomed and `PageScrollPhysics` otherwise;
the `InteractiveViewer` sets `panEnabled` to `isZoomedIn` and binds
`transformationController` to the controller's).

### State lives in `_GalleryPhotoViewerViewState`, not a new GetxController

The viewer's state is two flags and one controller. That is small enough to
live as `ValueNotifier`s on the `State` (the file already uses `ValueNotifier`
for `_currentIndex` and `_uploading`), and avoids introducing a new
`GetxController` + binding pair for two booleans. The trade-off — zoom does not
carry per-photo — matches the file viewer's behaviour: because swiping is
disabled while zoomed, the user never sees two photos at different zooms.

New state on `_GalleryPhotoViewerViewState`:
- `final ValueNotifier<bool> _isUiVisible = ValueNotifier<bool>(true);`
- `final ValueNotifier<bool> _isZoomedIn = ValueNotifier<bool>(false);`
- `final TransformationController _transformController =
    TransformationController();`

`_transformController.addListener` sets `_isZoomedIn.value` from
`_transformController.value.getMaxScaleOnAxis() > 1.0` (identical to
`FileViewerController`). `dispose` disposes all three and restores the system
UI to `edgeToEdge` so leaving the viewer never strands the app in immersive
mode (a targeted fix the file viewer is missing).

### Full-screen toggle (improvement 1)

`_toggleUi` flips `_isUiVisible` and calls
`SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive)` when hiding and
`SystemUiMode.edgeToEdge` when showing, mirroring
`FileViewerController.toggleUiVisible`.

The `Scaffold`'s `appBar` is wrapped in a `ValueListenableBuilder<bool>` on
`_isUiVisible`: when visible, the existing `AppBar` (date title, upload
action, details action) renders unchanged; when hidden, `appBar` is `null` and
`extendBodyBehindAppBar` lets the photo fill the top of the screen. The body
is otherwise unchanged.

`GalleryPhotoPage` gains an `onToggleUi` callback. The existing
`InteractiveViewer`/`Center` tree is wrapped in a
`GestureDetector(onTap: onToggleUi, behavior: HitTestBehavior.opaque)`. A tap
does not claim scale gestures, so pinch-to-zoom still reaches the
`InteractiveViewer`.

### Zoom-gated panning (improvement 3)

`GalleryPhotoPage` gains a `transformationController` (the shared
`TransformationController`) and an `isZoomedIn` (the shared
`ValueNotifier<bool>`) parameter.

The `PageView.builder` is wrapped in a `ValueListenableBuilder<bool>` on
`_isZoomedIn`; its `physics` is `NeverScrollableScrollPhysics` while zoomed and
`PageScrollPhysics` otherwise (identical to the file viewer). While zoomed,
horizontal drags no longer page — they go to the `InteractiveViewer`'s pan.

The `InteractiveViewer` is wrapped in a `ValueListenableBuilder<bool>` on
`isZoomedIn` setting `panEnabled: zoomed`, with `transformationController`
bound to the shared controller and `maxScale` left at 4. Panning is only
enabled when zoomed in; at 1× the page reclaims the swipe and the photo does
not pan.

### Folder jump from details (improvement 2)

`GalleryPhotoDetails` gains an `onOpenFolder` callback. The "File" row's
`ListTile` gets `onTap: onOpenFolder` only when the item has a real Seraph
folder (`item.providerId != null`); for Device-only items the row is a plain,
non-interactive `ListTile`, the same way the "Seraph folder" row is already
omitted for Device-only items.

The callback is provided by `_GalleryPhotoViewerViewState` and runs:
```
Get.until((route) => route.settings.name == GalleryView.routeName);
Get.toNamed('${FileBrowserView.routeName}?path=${item.folderDisplayPath}');
```
`Get.until` pops the details modal sheet and the photo viewer, stopping at the
Gallery. `Get.toNamed` pushes the file browser at `folderDisplayPath` (e.g.
`/family-space/Holidays/Crete`) on top of the Gallery. Final stack:
`[FileBrowser(root), Gallery, FileBrowser(folder)]` — back from the folder
returns to the Gallery.

This adds imports of `gallery_view.dart` and `file_browser_view.dart` to
`gallery_photo_viewer.dart`.

### Disposition

No schema, API, event, or backend change. No new routes (the existing
`FileBrowserView.routeName` is reused). No change to `GalleryItem` or the
mirror. All changes are confined to `gallery_photo_viewer.dart`.

## Testing Decisions

One seam, no new test file: extend the existing widget tests at
`test/gallery/gallery_view_test.dart`. That file already mounts `GalleryView`
plus the `GalleryPhotoViewerView` route in a `GetMaterialApp` and asserts
against the rendered tree, including one test that opens the details dialog and
one that drives the `PageView`. All three improvements are external behavior
visible at that seam.

Good tests assert external behavior, not implementation details:
- they do not reach into `_GalleryPhotoViewerViewState`'s fields directly;
- they drive the viewer the way a user does (tap, scale, fling) and assert
  what the user sees (`AppBar` present/absent, `PageView` physics,
  `InteractiveViewer.panEnabled`, the current route).

Tests to add:
- Tap the photo page → the `AppBar` disappears and the system-UI mode is set
  to immersive (asserted via a `SystemChannels.platform` mock handler, the
  standard Flutter test approach for `SystemChrome`). Tap again → the
  `AppBar` reappears and the mode is `edgeToEdge`.
- Scale a `GalleryPhotoPage` in past 1× → the `PageView`'s physics is
  `NeverScrollableScrollPhysics` and the `InteractiveViewer.panEnabled` is
  true; a horizontal fling does not change the page. Scale back to 1× → the
  `PageView`'s physics is `PageScrollPhysics`, `panEnabled` is false, and a
  horizontal fling pages as before.
- With a Seraph-backed item, open details and tap the "File" row →
  `Get.currentRoute` is
  `'${FileBrowserView.routeName}?path=<folderDisplayPath>'` (the test's
  `wrap()` registers `FileBrowserView.routeName` so the navigation resolves).
- With a Device-only item, the "File" row's `ListTile` has no `onTap`
  (verified by the absence of ink/ripple and by the row not navigating when
  tapped).

Prior art: `test/gallery/gallery_view_test.dart`'s "tapping a photo opens it
full screen", "the viewer swipes through photos in the grid order", and "a
photo's details name the Seraph folder it lives in" tests.

Manual build gate: `flutter build web --release --base-href=/app/` and
`flutter build apk` (this touches gestures and system UI, so the APK build is
the honest check), plus `flutter analyze` and `flutter test`.

## Out of Scope

- Per-photo zoom memory. The file viewer shares one zoom state across the
  whole page list, and this spec matches that. Tracking zoom per photo is a
  separate improvement.
- Carrying the file browser's `openItemIndex` / preview-widget Hero transition
  across the gallery→file-browser jump. The folder opens at the folder, not
  pre-selected on the file; a Hero transition from a gallery tile to a file
  browser row is a separate piece of work.
- The file viewer's theme-mode switching (`Get.changeThemeMode`) on image
  pages. The gallery viewer does not do this today and this spec does not add
  it.
- Restoring immersive mode on the file viewer on its way out. The file viewer
  does not restore `SystemUiMode.edgeToEdge` in `onClose`; the gallery viewer
  will (a targeted fix limited to the gallery viewer), but fixing the file
  viewer's version of the same gap is out of scope here.

## Further Notes

- The shared zoom state means a zoomed photo resets to 1× when the user pages
  away from it (because the `TransformationController` is shared and the next
  page starts at identity). This matches the file viewer and is acceptable for
  the same reason: swiping is disabled while zoomed, so the only way to page
  away is to zoom out first, at which point the reset is invisible.
- `Get.until` with a predicate on `route.settings.name` is the standard GetX
  way to pop back to a named route. The gallery route is registered under
  `GalleryView.routeName` in `app.dart`, so the predicate resolves.
- `folderDisplayPath` is already defined on `GalleryItem` and is already
  surfaced as the "Seraph folder" row's value, so the jump reuses the exact
  string the user can read in the dialog.
