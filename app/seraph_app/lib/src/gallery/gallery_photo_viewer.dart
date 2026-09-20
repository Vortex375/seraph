import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_browser_controller.dart';
import 'package:seraph_app/src/file_browser/file_browser_view.dart';
import 'package:seraph_app/src/file_viewer/file_viewer_view.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';
import 'package:seraph_app/src/gallery/gallery_view.dart';
import 'package:seraph_app/src/gallery/hdr_photo_view.dart';
import 'package:seraph_app/src/gallery/local/local_image_loader.dart';
import 'package:seraph_app/src/gallery/web_photo_view.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_service.dart';

/// A gallery photo, full screen.
///
/// The viewer pages over the SAME list the grid draws - one
/// [GalleryGridController], one Capture-Date order, one item count - so
/// swiping moves through photos in exactly the order the grid showed them,
/// including through pages neither view has read yet.
class GalleryPhotoViewerView extends StatefulWidget {
  static const routeName = '/gallery/photo';

  const GalleryPhotoViewerView({super.key, this.initialIndex = 0});

  final int initialIndex;

  @override
  State<GalleryPhotoViewerView> createState() => _GalleryPhotoViewerViewState();
}

class _GalleryPhotoViewerViewState extends State<GalleryPhotoViewerView> {
  final GalleryGridController controller = Get.find();
  final GalleryImageLoader loader = Get.find();
  final LocalImageLoader localLoader = Get.find();

  /// Ticket 19: null on a platform with no `GalleryUploadService` registered
  /// - every platform without a Local Source, and every test that has
  /// nothing to do with upload - in which case the upload action is simply
  /// absent from the app bar, mirroring how [GalleryGridController.
  /// localScanService] being null hides the permission UI elsewhere in
  /// Gallery Mode.
  final GalleryUploadService? uploadService =
      Get.isRegistered<GalleryUploadService>()
          ? Get.find<GalleryUploadService>()
          : null;

  late final PageController _pageController;
  late final ValueNotifier<int> _currentIndex;

  /// True while an upload started from this view is in flight, so a second
  /// tap on the button (or on another photo mid-upload) is not offered.
  final ValueNotifier<bool> _uploading = ValueNotifier<bool>(false);

  /// Whether the viewer's chrome (app bar + system status/navigation bars)
  /// is visible. A tap on the photo flips this and the system-UI mode
  /// together, mirroring `FileViewerController.toggleUiVisible`.
  final ValueNotifier<bool> _isUiVisible = ValueNotifier<bool>(true);

  /// True while the current photo is zoomed in past 1×, so the `PageView`
  /// switches to `NeverScrollableScrollPhysics` and the `InteractiveViewer`
  /// enables panning - mirroring `FileViewerController.isZoomedIn`. A single
  /// shared state is acceptable because swiping is disabled while zoomed,
  /// so the user never sees two photos at different zooms (see the spec's
  /// "Out of Scope" note on per-photo zoom memory).
  final ValueNotifier<bool> _isZoomedIn = ValueNotifier<bool>(false);

  /// The shared zoom/pan transform for every page. The `InteractiveViewer`
  /// on each `GalleryPhotoPage` binds to this; a listener flips
  /// `_isZoomedIn` from `getMaxScaleOnAxis() > 1.0`, identical to
  /// `FileViewerController`'s wiring.
  late final TransformationController _transformController;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);
    _currentIndex = ValueNotifier<int>(widget.initialIndex);
    _transformController = TransformationController();
    _transformController.addListener(() {
      _isZoomedIn.value = _transformController.value.getMaxScaleOnAxis() > 1.0;
    });
    controller.ensureRangeLoaded(
        widget.initialIndex - 1, widget.initialIndex + 1);
  }

  @override
  void dispose() {
    // Always restore the system UI so leaving the viewer never strands the
    // rest of the app in immersive mode (a targeted fix the file viewer is
    // missing; see the spec's "Out of Scope" note).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _pageController.dispose();
    _currentIndex.dispose();
    _transformController.dispose();
    _isZoomedIn.dispose();
    _uploading.dispose();
    _isUiVisible.dispose();
    super.dispose();
  }

  /// Toggling the chrome flips the visibility flag and the system-UI mode
  /// in lockstep: hiding enters immersive, showing returns to edge-to-edge.
  Future<void> _toggleUi() async {
    _isUiVisible.value = !_isUiVisible.value;
    await SystemChrome.setEnabledSystemUIMode(
      _isUiVisible.value ? SystemUiMode.edgeToEdge : SystemUiMode.immersive,
    );
  }

  void _showDetails(GalleryItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => GalleryPhotoDetails(
        item: item,
        // Pop back to the Gallery: this dismisses the details modal sheet
        // AND the photo viewer, stopping at the Gallery route. Then push
        // the file browser at the folder the photo lives in on top of it,
        // giving the stack [FileBrowser(root), Gallery, FileBrowser(folder)]
        // - back from the folder returns to the Gallery, not the viewer.
        onOpenFolder: () {
          Get.until((route) => route.settings.name == GalleryView.routeName);
          Get.toNamed(
              '${FileBrowserView.routeName}?path=${item.folderDisplayPath}');
        },
        // Same pop back to the Gallery, then the file browser at the photo's
        // folder, then the file browser's own viewer on the photo itself:
        // [FileBrowser(root), Gallery, FileBrowser(folder), FileViewer(file)]
        // - back from the viewer returns to the folder, then the Gallery.
        onOpenFile: () {
          Get.until((route) => route.settings.name == GalleryView.routeName);
          // The viewer would otherwise inherit the index of a file the user
          // opened from the browser earlier and show that listing's file
          // instead of this one; a direct open has no listing beside it.
          Get.find<FileBrowserController>().resetOpenItem();
          Get.toNamed(
              '${FileBrowserView.routeName}?path=${item.folderDisplayPath}');
          Get.toNamed(
              '${FileViewerView.routeName}?path=${item.spaceDisplayPath}');
        },
      ),
    );
  }

  /// Ticket 19's "user presses a button on a photo and it lands in Seraph":
  /// the single manual trigger this ticket adds. Reports the outcome as a
  /// SnackBar and, on anything that changed the mirror ([GalleryUploadResult.
  /// uploaded]/[GalleryUploadResult.alreadyPresent]), reloads the grid so the
  /// tile behind this viewer picks up the new Synced Availability
  /// immediately rather than waiting for the next background sync.
  Future<void> _upload(GalleryItem item) async {
    final service = uploadService;
    if (service == null || _uploading.value) {
      return;
    }
    _uploading.value = true;
    try {
      final result = await service.upload(item);
      if (!mounted) {
        return;
      }
      switch (result) {
        case GalleryUploadResult.uploaded:
        case GalleryUploadResult.alreadyPresent:
          await controller.reload();
          if (!mounted) {
            return;
          }
          // Ticket 20: not "backed up" yet - Seraph has not independently
          // confirmed it, only this device's own upload response has.
          _showSnackBar('Uploaded to Seraph - awaiting confirmation.');
        case GalleryUploadResult.noSyncPair:
          _showSnackBar('No Sync Pair covers this folder.');
        case GalleryUploadResult.deviceFileUnavailable:
          _showSnackBar('This photo is no longer available on this device.');
        case GalleryUploadResult.deviceFileChanged:
          _showSnackBar(
              'This photo changed on this device and was not uploaded.');
        case GalleryUploadResult.notApplicable:
          break;
      }
    } on GalleryUploadException catch (e) {
      if (mounted) {
        _showSnackBar(e.message);
      }
    } finally {
      if (mounted) {
        _uploading.value = false;
      }
    }
  }

  void _showSnackBar(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: _isUiVisible,
      builder: (context, uiVisible, _) => Scaffold(
        backgroundColor: Colors.black,
        extendBodyBehindAppBar: true,
        appBar: uiVisible
            ? AppBar(
                backgroundColor: Colors.transparent,
                foregroundColor: Colors.white,
                title: ValueListenableBuilder<int>(
                  valueListenable: _currentIndex,
                  builder: (context, index, _) => Obx(() {
                    controller.revision.value;
                    // The header is a day-granularity label, so it must come
                    // from the item's own capture date - the boundary map
                    // [knownDateAt] answers only month granularity (day is
                    // always the 1st), and rendering it through
                    // [galleryDayLabel] showed e.g. "1 August 2026" for
                    // every photo taken that month. Until the item's page
                    // has loaded, fall back to the month label, which the
                    // boundary map can answer synchronously and which is
                    // never wrong (a photo on the 25th is still in August).
                    final item = controller.itemAt(index);
                    final exact = item?.capturedAtDateTime;
                    final month = controller.knownDateAt(index);
                    final label = exact != null
                        ? galleryDayLabel(exact)
                        : month == null
                            ? ''
                            : galleryMonthLabel(month);
                    return Text(
                      label,
                      style: const TextStyle(fontSize: 16),
                    );
                  }),
                ),
                actions: [
                  if (uploadService != null)
                    ValueListenableBuilder<int>(
                      valueListenable: _currentIndex,
                      builder: (context, index, _) => Obx(() {
                        controller.revision.value;
                        final item = controller.itemAt(index);
                        if (item == null ||
                            item.availability !=
                                GalleryAvailability.deviceOnly ||
                            item.isAwaitingVerification) {
                          // Ticket 20: an item already uploaded and awaiting the
                          // delta feed's confirmation must not offer the button
                          // again - it is still Device only (not yet Verified), but
                          // there is nothing more for a press to do until the feed
                          // answers.
                          return const SizedBox.shrink();
                        }
                        return ValueListenableBuilder<bool>(
                          valueListenable: _uploading,
                          builder: (context, uploading, _) => IconButton(
                            icon: uploading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.cloud_upload_outlined),
                            tooltip: 'Upload to Seraph',
                            onPressed: uploading ? null : () => _upload(item),
                          ),
                        );
                      }),
                    ),
                  ValueListenableBuilder<int>(
                    valueListenable: _currentIndex,
                    builder: (context, index, _) => Obx(() {
                      controller.revision.value;
                      final item = controller.itemAt(index);
                      return IconButton(
                        icon: const Icon(Icons.info_outline),
                        tooltip: 'Photo details',
                        onPressed:
                            item == null ? null : () => _showDetails(item),
                      );
                    }),
                  ),
                ],
              )
            : null,
        body: Obx(() {
          controller.revision.value;
          final total = controller.totalCount.value;
          if (total == 0) {
            return const SizedBox.shrink();
          }
          return ValueListenableBuilder<bool>(
            valueListenable: _isZoomedIn,
            builder: (context, zoomed, _) => PageView.builder(
              controller: _pageController,
              itemCount: total,
              // Disable swipe-to-next-image while zoomed so a drag pans the
              // photo instead of paging - identical to the file viewer's
              // gating on `isZoomedIn`.
              physics: zoomed
                  ? const NeverScrollableScrollPhysics()
                  : const PageScrollPhysics(),
              onPageChanged: (index) {
                _currentIndex.value = index;
                controller.ensureRangeLoaded(index - 1, index + 1);
              },
              itemBuilder: (context, index) {
                final item = controller.itemAt(index);
                if (item == null) {
                  return const Center(child: CircularProgressIndicator());
                }
                return GalleryPhotoPage(
                  item: item,
                  loader: loader,
                  localLoader: localLoader,
                  onToggleUi: _toggleUi,
                  transformationController: _transformController,
                  isZoomedIn: _isZoomedIn,
                );
              },
            ),
          );
        }),
      ),
    );
  }
}

/// One full-screen photo: the original file, at full resolution, with the
/// thumbnail already on screen behind it so the frame is never empty while
/// the original downloads.
///
/// Two rendering paths, decided by the platform gate - never per photo
/// (spec: "no per-image routing, no dual renderer"):
///
///  - Android: the bytes are fetched once (device copy via the Local Source,
///    falling back to the cloud stack; cloud-only over the authenticated
///    loader, which carries the reactive 401/403 refresh-and-retry) and fed
///    to [HdrPhotoView], which renders the Ultra HDR gain map natively. The
///    already-loaded thumbnail (a Flutter `Image`, served from the image
///    cache the grid warmed) shows until the bytes arrive and the platform
///    view replaces it - no cross-fade. Full-resolution bytes are not
///    cached: paging back re-fetches, thumbnail-first.
///  - Everywhere else (and the failure fallbacks): the existing Flutter
///    rendering, unchanged.
class GalleryPhotoPage extends StatefulWidget {
  const GalleryPhotoPage({
    super.key,
    required this.item,
    required this.loader,
    required this.localLoader,
    required this.onToggleUi,
    required this.transformationController,
    required this.isZoomedIn,
  });

  final GalleryItem item;
  final GalleryImageLoader loader;

  /// Ticket 28: loads the device copy's full-resolution bytes through the
  /// Local Source seam. Always given - see [GalleryTile.localLoader]'s doc.
  final LocalImageLoader localLoader;

  /// Tapping the photo toggles the viewer's full-screen chrome. In the
  /// Flutter path the tap comes from the surrounding detector; in the
  /// native path, once the platform view is zoomed and claims gestures,
  /// the tap is reported by the native view over its channel instead. The
  /// two never fire for the same tap - they compete in one gesture arena.
  final VoidCallback onToggleUi;

  /// The viewer's shared zoom/pan transform. Bound to this page's
  /// [InteractiveViewer] in the Flutter path so a listener on the
  /// controller can gate the `PageView`'s swipe physics; reset to identity
  /// the moment the native view takes over, so a stale Flutter zoom cannot
  /// leave the pager stuck on `NeverScrollableScrollPhysics` while the
  /// native transform (which this controller knows nothing about) is at 1x.
  final TransformationController transformationController;

  /// The viewer's shared zoom flag. In the Flutter path the
  /// [InteractiveViewer]'s transform listener drives it; in the native path
  /// the native view's zoom reports drive it - the same `isZoomedIn` shape
  /// either way, and the only thing gating the pager's physics.
  final ValueNotifier<bool> isZoomedIn;

  @override
  State<GalleryPhotoPage> createState() => _GalleryPhotoPageState();
}

class _GalleryPhotoPageState extends State<GalleryPhotoPage> {
  @override
  Widget build(BuildContext context) {
    if (widget.item.isUnsupported) {
      return _UnsupportedPhoto(item: widget.item);
    }

    final providerId = widget.item.providerId;
    final path = widget.item.path;
    final hasCloud = providerId != null && path != null;
    final hasLocal = widget.item.hasLocalCopy;

    if (!hasCloud && !hasLocal) {
      // Should not happen (see GalleryItemDisplay.hasLocalCopy's doc) but
      // stays an honest "on this device" state rather than a crash.
      return _DeviceOnlyPhoto(item: widget.item);
    }

    final child = useWebPhotoView
        ? HdrPhotoPageWeb(
            fetch: _fetchBytes,
            onToggleUi: widget.onToggleUi,
            onZoomChanged: (z) => widget.isZoomedIn.value = z,
            onResetZoom: () {
              widget.isZoomedIn.value = false;
              // The native view owns its transform; clear any zoom the
              // thumbnail's InteractiveViewer accumulated so the pager is
              // never stranded on NeverScrollableScrollPhysics while
              // nothing is zoomed.
              widget.transformationController.value = Matrix4.identity();
            },
            thumbnail: _thumbnailImage(
                hasCloud: hasCloud, providerId: providerId, path: path),
          )
        : hdrPhotoNativeAvailable
            ? HdrPhotoPage(
                fetch: _fetchBytes,
                onToggleUi: widget.onToggleUi,
                onZoomChanged: (z) => widget.isZoomedIn.value = z,
                onResetZoom: () {
                  widget.isZoomedIn.value = false;
                  // The native view owns its transform; clear any zoom the
                  // thumbnail's InteractiveViewer accumulated so the pager
                  // is never stranded on NeverScrollableScrollPhysics
                  // while nothing is zoomed.
                  widget.transformationController.value =
                      Matrix4.identity();
                },
                thumbnail: _thumbnailImage(
                    hasCloud: hasCloud, providerId: providerId, path: path),
              )
            : _buildFlutter(
                hasCloud: hasCloud, providerId: providerId, path: path);

    // The outer tap toggles the chrome in the Flutter path (and while the
    // native path is still on its thumbnail); once the native view is
    // zoomed it claims gestures and reports taps over its channel instead.
    // Both compete in one gesture arena, so a tap toggles exactly once.
    return GestureDetector(
      onTap: widget.onToggleUi,
      behavior: HitTestBehavior.opaque,
      child: child,
    );
  }

  /// Device copy first, cloud stack as the fallback - the same preference
  /// order the Flutter rendering below uses, with the Local Source's
  /// quiet-null-on-failure contract and the cloud loader's
  /// [GalleryImageUnavailable] flattened into one null = failed outcome.
  Future<Uint8List?> _fetchBytes() async {
    Uint8List? bytes;
    try {
      if (widget.item.hasLocalCopy) {
        bytes = await widget.localLoader.original(
          widget.item.localRelativePath!,
          widget.item.localDisplayName!,
        );
      }
      if (bytes == null || bytes.isEmpty) {
        final providerId = widget.item.providerId;
        final path = widget.item.path;
        bytes = (providerId == null || path == null)
            ? null
            : await widget.loader.fullResolution(providerId, path);
      }
    } catch (_) {
      // Any failure - offline, 404, an expired token the retry could not
      // save - is the existing error state, not a crash.
      return null;
    }
    return bytes;
  }

  /// The existing Flutter rendering, unchanged - the NON-Android path of
  /// the gallery viewer. On Android, [HdrPhotoPage]'s failure states cover
  /// the same ground (thumbnail keeps showing, or an honest placeholder).
  Widget _buildFlutter({
    required bool hasCloud,
    String? providerId,
    String? path,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.isZoomedIn,
      builder: (context, zoomed, _) => InteractiveViewer(
        transformationController: widget.transformationController,
        maxScale: 4,
        // Panning is only enabled while zoomed in; at 1× the page
        // reclaims the swipe and the photo does not pan - identical to
        // the file viewer's `panEnabled: isZoomedIn`.
        panEnabled: zoomed,
        child: Center(
          child: widget.item.hasLocalCopy
              ? _LocalPhotoStack(
                  item: widget.item,
                  localLoader: widget.localLoader,
                  fallback: hasCloud
                      ? _CloudPhotoStack(
                          loader: widget.loader,
                          providerId: providerId!,
                          path: path!)
                      : _DeviceOnlyPhoto(item: widget.item),
                )
              : _CloudPhotoStack(
                  loader: widget.loader, providerId: providerId!, path: path!),
        ),
      ),
    );
  }

  /// The photo's already-loaded thumbnail - the same provider the grid
  /// (or the previous viewing) warmed, so this serves from Flutter's image
  /// cache and never re-fetches.
  Widget _thumbnailImage({
    required bool hasCloud,
    String? providerId,
    String? path,
  }) {
    final item = widget.item;
    return Image(
      image: item.hasLocalCopy
          ? LocalGalleryImage(
              loader: widget.localLoader,
              relativePath: item.localRelativePath!,
              displayName: item.localDisplayName!,
              width: galleryThumbnailSize,
              height: galleryThumbnailSize,
            )
          : GalleryImage(
              loader: widget.loader,
              providerId: providerId!,
              path: path!,
              size: galleryThumbnailSize,
            ),
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
    );
  }
}

/// The cloud image pair - a 512px thumbnail behind the full-resolution
/// original, so the frame is never empty while the original downloads.
/// Unchanged behaviour from before ticket 28: a Cloud only item renders
/// exactly this, and it is also what a Synced item falls back to when its
/// device copy cannot be read.
class _CloudPhotoStack extends StatelessWidget {
  const _CloudPhotoStack({
    required this.loader,
    required this.providerId,
    required this.path,
  });

  final GalleryImageLoader loader;
  final String providerId;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        Image(
          image: GalleryImage(
            loader: loader,
            providerId: providerId,
            path: path,
            size: galleryThumbnailSize,
          ),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
        Image(
          image: GalleryImage(
            loader: loader,
            providerId: providerId,
            path: path,
          ),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) {
              return child;
            }
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 150),
              child: child,
            );
          },
        ),
      ],
    );
  }
}

/// The device-copy image pair, mirroring [_CloudPhotoStack]'s two-layer
/// shape - a thumbnail-sized decode behind the full-resolution original -
/// through the Local Source seam instead of HTTP. If the full-resolution
/// layer cannot be decoded (a corrupt file, a revoked grant, a file deleted
/// between scan and render), [fallback] takes its place: the cloud version
/// for a Synced item, or the honest "on this device" placeholder for a
/// Device only one that turned out to be unreadable.
class _LocalPhotoStack extends StatelessWidget {
  const _LocalPhotoStack({
    required this.item,
    required this.localLoader,
    required this.fallback,
  });

  final GalleryItem item;
  final LocalImageLoader localLoader;
  final Widget fallback;

  @override
  Widget build(BuildContext context) {
    final relativePath = item.localRelativePath!;
    final displayName = item.localDisplayName!;
    return Stack(
      alignment: Alignment.center,
      children: [
        Image(
          image: LocalGalleryImage(
            loader: localLoader,
            relativePath: relativePath,
            displayName: displayName,
            width: galleryThumbnailSize,
            height: galleryThumbnailSize,
          ),
          fit: BoxFit.contain,
          errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
        ),
        Image(
          image: LocalGalleryImage(
            loader: localLoader,
            relativePath: relativePath,
            displayName: displayName,
          ),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => fallback,
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) {
              return child;
            }
            return AnimatedOpacity(
              opacity: frame == null ? 0 : 1,
              duration: const Duration(milliseconds: 150),
              child: child,
            );
          },
        ),
      ],
    );
  }
}

/// A photo that only exists on the device, full screen.
class _DeviceOnlyPhoto extends StatelessWidget {
  const _DeviceOnlyPhoto({required this.item});

  final GalleryItem item;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.smartphone_outlined,
                size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            Text(
              item.fileName,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              'This photo is only on this device',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

class _UnsupportedPhoto extends StatelessWidget {
  const _UnsupportedPhoto({required this.item});

  final GalleryItem item;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.broken_image_outlined,
                size: 64, color: Colors.white54),
            const SizedBox(height: 16),
            Text(
              item.fileName,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              item.unsupportedReasonLabel,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }
}

/// What is known about one photo - including which Seraph folder it lives in,
/// so the user can go and find the file again through the file browser or
/// over WebDAV.
class GalleryPhotoDetails extends StatelessWidget {
  const GalleryPhotoDetails({
    super.key,
    required this.item,
    this.onOpenFolder,
    this.onOpenFile,
  });

  final GalleryItem item;

  /// Opens the file browser at [item.folderDisplayPath]. Only wired up for
  /// items that have a real Seraph folder ([item.providerId] non-null); a
  /// Device-only item has no folder to open, so its "Seraph folder" row is
  /// omitted outright and its "File" row stays a plain, non-interactive
  /// label - there is no Seraph copy for either to land on.
  final VoidCallback? onOpenFolder;

  /// Opens the file browser's own file viewer on this item's file (at
  /// [GalleryItem.spaceDisplayPath]). Same [item.providerId] gating as
  /// [onOpenFolder]. A Device-only item has no Seraph copy to show.
  final VoidCallback? onOpenFile;

  @override
  Widget build(BuildContext context) {
    final rows = <_DetailRow>[
      // A Device only item has no Seraph folder to name at all - showing one
      // would be a folder that does not exist.
      if (item.providerId != null)
        _DetailRow(
            Icons.folder_outlined, 'Seraph folder', item.folderDisplayPath,
            onTap: onOpenFolder),
      _DetailRow(
        Icons.event_outlined,
        item.captureDateSourceLabel,
        galleryDayLabel(item.capturedAtDateTime),
      ),
      if (item.displayWidth > 0 && item.displayHeight > 0)
        _DetailRow(Icons.aspect_ratio_outlined, 'Dimensions',
            '${item.displayWidth} x ${item.displayHeight}'),
      if (item.size > 0)
        _DetailRow(Icons.sd_storage_outlined, 'Size', _formatBytes(item.size)),
      if (item.mime.isNotEmpty)
        _DetailRow(Icons.description_outlined, 'Type', item.mime),
      _DetailRow(Icons.info_outline, 'Availability', item.availabilityLabel),
    ];

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.image_outlined),
            title: const Text('File'),
            subtitle: Text(item.fileName),
            // Only a Seraph-backed item has a file to open in the file
            // browser; a Device-only item's "File" row is a plain,
            // non-interactive label.
            onTap: item.providerId != null ? onOpenFile : null,
          ),
          for (final row in rows)
            ListTile(
              leading: Icon(row.icon),
              title: Text(row.label),
              subtitle: Text(row.value),
              onTap: row.onTap,
            ),
        ],
      ),
    );
  }
}

class _DetailRow {
  const _DetailRow(this.icon, this.label, this.value, {this.onTap});

  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final rendered =
      unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$rendered ${units[unit]}';
}
