import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';
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
            return GalleryPhotoPage(item: item, loader: loader);
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
  });

  final GalleryItem item;
  final GalleryImageLoader loader;

  @override
  Widget build(BuildContext context) {
    if (item.isUnsupported) {
      return _UnsupportedPhoto(item: item);
    }

    final providerId = item.providerId;
    final path = item.path;
    if (providerId == null || path == null) {
      return _UnsupportedPhoto(item: item);
    }

    return InteractiveViewer(
      maxScale: 4,
      child: Center(
        child: Stack(
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
      _DetailRow(Icons.folder_outlined, 'Seraph folder', item.folderDisplayPath),
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
      const _DetailRow(Icons.cloud_outlined, 'Availability', 'Cloud only'),
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
