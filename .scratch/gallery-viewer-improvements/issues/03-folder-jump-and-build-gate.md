# 03 — Folder jump from details + build gate

**What to build:** Tapping the "File" row in a Seraph-backed photo's details
dialog opens the file browser at the Seraph folder the photo lives in. Backing
out of that folder returns to the Gallery (the viewer is popped, the gallery
stays). For a Device-only photo, which has no Seraph folder, the "File" row
stays a plain, non-interactive label — mirroring the existing "Seraph folder"
row, which is already omitted for Device-only items for the same reason.

The jump pops back to the Gallery (`Get.until` on `GalleryView.routeName`,
which also dismisses the details modal sheet) and pushes the file browser at
`folderDisplayPath` on top (`Get.toNamed`), giving the stack
`[FileBrowser(root), Gallery, FileBrowser(folder)]`.

This ticket also runs the full build gate for the whole feature, since it is
the last implementation ticket: `flutter analyze`, `flutter test`, the web
release build, and the Android release build (the feature touches system UI and
gestures, so the APK build is the honest check even though no `android/` file
changes).

**Blocked by:** 02 — Zoom-gated panning (same file; sequencing avoids
file-level edit conflicts).

**Status:** ready-for-agent

- [ ] `GalleryPhotoDetails` gains an `onOpenFolder` callback; the "File" row's
      `ListTile` gets `onTap: onOpenFolder` only when `item.providerId != null`,
      and stays a plain non-interactive `ListTile` for Device-only items.
- [ ] `_GalleryPhotoViewerViewState` provides the callback: it runs
      `Get.until((route) => route.settings.name == GalleryView.routeName)` then
      `Get.toNamed('${FileBrowserView.routeName}?path=${item.folderDisplayPath}')`.
- [ ] `gallery_photo_viewer.dart` imports `gallery_view.dart` and
      `file_browser_view.dart` for the route name constants.
- [ ] Widget test: with a Seraph-backed item, opening details and tapping the
      "File" row navigates to
      `'${FileBrowserView.routeName}?path=<folderDisplayPath>'` (the test's
      `wrap()` registers `FileBrowserView.routeName` so the navigation
      resolves).
- [ ] Widget test: with a Device-only item, the "File" row's `ListTile` has no
      `onTap` and tapping it does not navigate.
- [ ] `flutter analyze` and `flutter test` pass for the whole feature.
- [ ] `flutter build web --release --base-href=/app/` succeeds.
- [ ] `flutter build apk` succeeds.
