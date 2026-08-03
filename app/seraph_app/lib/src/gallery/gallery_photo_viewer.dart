import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';
import 'package:seraph_app/src/gallery/local/local_image_loader.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

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

  late final PageController _pageController;
  late final ValueNotifier<int> _currentIndex;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.initialIndex);
    _currentIndex = ValueNotifier<int>(widget.initialIndex);
    controller.ensureRangeLoaded(widget.initialIndex - 1, widget.initialIndex + 1);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _currentIndex.dispose();
    super.dispose();
  }

  void _showDetails(GalleryItem item) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => GalleryPhotoDetails(item: item),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        title: ValueListenableBuilder<int>(
          valueListenable: _currentIndex,
          builder: (context, index, _) => Obx(() {
            controller.revision.value;
            final date = controller.knownDateAt(index);
            return Text(
              date == null ? '' : galleryDayLabel(date),
              style: const TextStyle(fontSize: 16),
            );
          }),
        ),
        actions: [
          ValueListenableBuilder<int>(
            valueListenable: _currentIndex,
            builder: (context, index, _) => Obx(() {
              controller.revision.value;
              final item = controller.itemAt(index);
              return IconButton(
                icon: const Icon(Icons.info_outline),
                tooltip: 'Photo details',
                onPressed: item == null ? null : () => _showDetails(item),
              );
            }),
          ),
        ],
      ),
      body: Obx(() {
        controller.revision.value;
        final total = controller.totalCount.value;
        if (total == 0) {
          return const SizedBox.shrink();
        }
        return PageView.builder(
          controller: _pageController,
          itemCount: total,
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
                item: item, loader: loader, localLoader: localLoader);
          },
        );
      }),
    );
  }
}

/// One full-screen photo: the original file, at full resolution, with the
/// thumbnail already on screen behind it so the frame is never empty while
/// the original downloads.
class GalleryPhotoPage extends StatelessWidget {
  const GalleryPhotoPage({
    super.key,
    required this.item,
    required this.loader,
    required this.localLoader,
  });

  final GalleryItem item;
  final GalleryImageLoader loader;

  /// Ticket 28: loads the device copy's full-resolution bytes through the
  /// Local Source seam. Always given - see [GalleryTile.localLoader]'s doc.
  final LocalImageLoader localLoader;

  @override
  Widget build(BuildContext context) {
    if (item.isUnsupported) {
      return _UnsupportedPhoto(item: item);
    }

    final providerId = item.providerId;
    final path = item.path;
    final hasCloud = providerId != null && path != null;
    final hasLocal = item.hasLocalCopy;

    if (!hasCloud && !hasLocal) {
      // Should not happen (see GalleryItemDisplay.hasLocalCopy's doc) but
      // stays an honest "on this device" state rather than a crash.
      return _DeviceOnlyPhoto(item: item);
    }

    // The outer InteractiveViewer/Center chrome is applied exactly once,
    // regardless of source, so a Synced item whose device copy fails to
    // decode can fall back to the cloud version's own image stack without
    // nesting a second InteractiveViewer inside this one.
    return InteractiveViewer(
      maxScale: 4,
      child: Center(
        child: hasLocal
            ? _LocalPhotoStack(
                item: item,
                localLoader: localLoader,
                fallback: hasCloud
                    ? _CloudPhotoStack(
                        loader: loader, providerId: providerId, path: path)
                    : _DeviceOnlyPhoto(item: item),
              )
            : _CloudPhotoStack(
                loader: loader, providerId: providerId!, path: path!),
      ),
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
          errorBuilder: (context, error, stackTrace) =>
              const SizedBox.shrink(),
        ),
        Image(
          image: GalleryImage(
            loader: loader,
            providerId: providerId,
            path: path,
          ),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) =>
              const SizedBox.shrink(),
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
          errorBuilder: (context, error, stackTrace) =>
              const SizedBox.shrink(),
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
  const GalleryPhotoDetails({super.key, required this.item});

  final GalleryItem item;

  @override
  Widget build(BuildContext context) {
    final rows = <_DetailRow>[
      _DetailRow(Icons.image_outlined, 'File', item.fileName),
      // A Device only item has no Seraph folder to name at all - showing one
      // would be a folder that does not exist.
      if (item.providerId != null)
        _DetailRow(
            Icons.folder_outlined, 'Seraph folder', item.folderDisplayPath),
      _DetailRow(
        Icons.event_outlined,
        item.captureDateSourceLabel,
        galleryDayLabel(item.capturedAtDateTime),
      ),
      if (item.displayWidth > 0 && item.displayHeight > 0)
        _DetailRow(Icons.aspect_ratio_outlined, 'Dimensions',
            '${item.displayWidth} x ${item.displayHeight}'),
      if (item.size > 0)
        _DetailRow(Icons.sd_storage_outlined, 'Size',
            _formatBytes(item.size)),
      if (item.mime.isNotEmpty)
        _DetailRow(Icons.description_outlined, 'Type', item.mime),
      _DetailRow(Icons.info_outline, 'Availability', item.availabilityLabel),
    ];

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          for (final row in rows)
            ListTile(
              leading: Icon(row.icon),
              title: Text(row.label),
              subtitle: Text(row.value),
            ),
        ],
      ),
    );
  }
}

class _DetailRow {
  const _DetailRow(this.icon, this.label, this.value);

  final IconData icon;
  final String label;
  final String value;
}

String _formatBytes(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final rendered = unit == 0 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$rendered ${units[unit]}';
}
