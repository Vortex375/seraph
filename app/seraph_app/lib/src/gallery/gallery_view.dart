import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/gallery_photo_viewer.dart';
import 'package:seraph_app/src/gallery/gallery_source_folders_view.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';

/// Gallery Mode: the user's photos in Seraph, as a grid of thumbnails ordered
/// by Capture Date, newest first, scrolling back through the whole
/// collection.
///
/// Everything on screen comes from the local mirror, so scrolling is a
/// sequence of indexed SQLite reads and never a network round trip. See
/// [GalleryGridController] for why the item count is fixed on open and why
/// unloaded tiles are placeholders of the same size rather than absent.
///
/// There is nothing here to upload with, and no device-side control of any
/// kind: on every platform this build ships to, every Gallery Item is *Cloud
/// only* and nothing can yet put a photo into Seraph from the gallery. An
/// affordance for something the platform cannot do is worse than its absence.
class GalleryView extends StatefulWidget {

  static const routeName = '/gallery';

  const GalleryView({super.key});

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView> {
  static const double _spacing = 2;

  /// Target tile size in logical pixels. The grid picks whatever column count
  /// gets closest to it, so a phone gets three or four columns and a desktop
  /// window gets as many as it has room for.
  static const double _targetTileExtent = 140;

  final GalleryGridController controller = Get.find();
  final GalleryImageLoader loader = Get.find();
  final ScrollController _scroll = ScrollController();

  /// Index of the first tile in the topmost visible row - what the date
  /// heading reports on.
  final ValueNotifier<int> _firstVisibleIndex = ValueNotifier<int>(0);

  int _crossAxisCount = 3;
  double _rowExtent = 1;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _firstVisibleIndex.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients || _rowExtent <= 0) {
      return;
    }
    final row = (_scroll.offset / _rowExtent).floor().clamp(0, 1 << 30);
    final index = row * _crossAxisCount;
    if (_firstVisibleIndex.value != index) {
      _firstVisibleIndex.value = index;
    }
  }

  void _openFolders() {
    Get.toNamed(GallerySourceFoldersView.routeName);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: seraphAppBar(context,
        name: 'Gallery',
        routeName: GalleryView.routeName,
        actions: [
          Obx(() => IconButton(
                icon: controller.isSyncing.value
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
                tooltip: 'Check for new photos',
                onPressed:
                    controller.isSyncing.value ? null : controller.syncNow,
              )),
          IconButton(
            icon: const Icon(Icons.folder_special_outlined),
            tooltip: 'Gallery folders',
            onPressed: _openFolders,
          ),
        ]
      ),
      body: Obx(() {
        if (controller.isLoading.value) {
          return const Center(child: CircularProgressIndicator());
        }
        if (controller.totalCount.value == 0) {
          return _EmptyGallery(
            isSyncing: controller.isSyncing.value,
            syncError: controller.syncError.value,
            onChooseFolders: _openFolders,
          );
        }
        return _buildGrid(context);
      }),
    );
  }

  Widget _buildGrid(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final cross = _columnsFor(constraints.maxWidth);
      final tileExtent =
          (constraints.maxWidth - _spacing * (cross - 1)) / cross;
      _crossAxisCount = cross;
      _rowExtent = tileExtent + _spacing;

      final decodeWidth =
          (tileExtent * MediaQuery.devicePixelRatioOf(context)).round();

      return Stack(
        children: [
          Obx(() {
            // Reading revision is what makes the grid rebuild when a page of
            // the mirror has been read; the item count deliberately does not
            // change when that happens.
            controller.revision.value;
            final total = controller.totalCount.value;
            return GridView.builder(
              controller: _scroll,
              padding: EdgeInsets.zero,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cross,
                mainAxisSpacing: _spacing,
                crossAxisSpacing: _spacing,
              ),
              itemCount: total,
              itemBuilder: (context, index) {
                final item = controller.itemAt(index);
                return GestureDetector(
                  onTap: () => _openPhoto(index),
                  child: GalleryTile(
                    item: item,
                    loader: loader,
                    decodeWidth: decodeWidth,
                  ),
                );
              },
            );
          }),
          Positioned(
            top: 8,
            left: 0,
            right: 0,
            child: Center(
              child: _DateHeading(
                controller: controller,
                index: _firstVisibleIndex,
              ),
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            child: GalleryDateScrubber(
              controller: controller,
              scrollController: _scroll,
              indexAtFraction: (fraction) => _indexAtFraction(fraction),
            ),
          ),
        ],
      );
    });
  }

  int _columnsFor(double width) {
    final columns = (width / _targetTileExtent).round();
    return columns < 2 ? 2 : columns;
  }

  /// Which item a given fraction of the way down the whole grid lands on.
  /// The scrubber needs this to answer "what date is under my thumb" without
  /// waiting for the scroll to happen first.
  int _indexAtFraction(double fraction) {
    final total = controller.totalCount.value;
    if (total <= 0) {
      return 0;
    }
    final rows = (total / _crossAxisCount).ceil();
    final row = (fraction.clamp(0.0, 1.0) * (rows - 1)).round();
    final index = row * _crossAxisCount;
    return index >= total ? total - 1 : index;
  }

  void _openPhoto(int index) {
    Get.toNamed('${GalleryPhotoViewerView.routeName}?index=$index');
  }
}

/// The floating "August 2026" heading. Month granularity: finer churns on
/// every flick, coarser loses a year of resolution.
class _DateHeading extends StatelessWidget {
  const _DateHeading({required this.controller, required this.index});

  final GalleryGridController controller;
  final ValueNotifier<int> index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: index,
      builder: (context, value, _) => Obx(() {
        controller.revision.value;
        final date = controller.knownDateAt(value);
        if (date == null) {
          // Not loaded yet: ask, and stay out of the way until the answer
          // arrives rather than flashing a wrong month.
          controller.dateAt(value);
          return const SizedBox.shrink();
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            galleryMonthLabel(date),
            style: theme.textTheme.labelLarge,
          ),
        );
      }),
    );
  }
}

/// Jump to a point in time.
///
/// Dragging the handle moves the grid directly rather than animating to it,
/// and reports the month under the thumb as it goes, so reaching photos from
/// three years ago is a gesture rather than three minutes of flicking.
class GalleryDateScrubber extends StatefulWidget {
  const GalleryDateScrubber({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.indexAtFraction,
  });

  final GalleryGridController controller;
  final ScrollController scrollController;
  final int Function(double fraction) indexAtFraction;

  @override
  State<GalleryDateScrubber> createState() => _GalleryDateScrubberState();
}

class _GalleryDateScrubberState extends State<GalleryDateScrubber> {
  static const double _trackWidth = 32;
  static const double _handleHeight = 44;

  bool _dragging = false;
  double _fraction = 0;

  @override
  void initState() {
    super.initState();
    widget.scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    widget.scrollController.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    if (_dragging || !widget.scrollController.hasClients) {
      return;
    }
    final max = widget.scrollController.position.maxScrollExtent;
    final fraction = max <= 0 ? 0.0 : widget.scrollController.offset / max;
    setState(() => _fraction = fraction.clamp(0.0, 1.0));
  }

  void _jumpTo(double fraction, double trackHeight) {
    final clamped = fraction.clamp(0.0, 1.0);
    setState(() => _fraction = clamped);

    if (widget.scrollController.hasClients) {
      final max = widget.scrollController.position.maxScrollExtent;
      widget.scrollController.jumpTo(clamped * max);
    }
    // Make sure the month bubble can answer, even for a position whose page
    // is nowhere near loaded.
    widget.controller.dateAt(widget.indexAtFraction(clamped));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return LayoutBuilder(builder: (context, constraints) {
      final trackHeight = constraints.maxHeight;
      final travel = (trackHeight - _handleHeight).clamp(0.0, double.infinity);
      final top = _fraction * travel;

      return SizedBox(
        width: _trackWidth,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (details) {
            setState(() => _dragging = true);
            _jumpTo(
              travel <= 0
                  ? 0
                  : (details.localPosition.dy - _handleHeight / 2) / travel,
              trackHeight,
            );
          },
          onVerticalDragUpdate: (details) {
            _jumpTo(
              travel <= 0
                  ? 0
                  : (details.localPosition.dy - _handleHeight / 2) / travel,
              trackHeight,
            );
          },
          onVerticalDragEnd: (_) => setState(() => _dragging = false),
          onVerticalDragCancel: () => setState(() => _dragging = false),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                top: top,
                right: 4,
                child: Semantics(
                  label: 'Jump to a point in time',
                  child: Container(
                    key: const Key('gallery-scrubber-handle'),
                    width: 24,
                    height: _handleHeight,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.drag_handle,
                      size: 18,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ),
              if (_dragging)
                Positioned(
                  top: top,
                  right: 36,
                  child: _ScrubberBubble(
                    controller: widget.controller,
                    index: widget.indexAtFraction(_fraction),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

class _ScrubberBubble extends StatelessWidget {
  const _ScrubberBubble({required this.controller, required this.index});

  final GalleryGridController controller;
  final int index;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      controller.revision.value;
      final date = controller.knownDateAt(index);
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.inverseSurface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          date == null ? '…' : galleryMonthLabel(date),
          style: theme.textTheme.labelLarge
              ?.copyWith(color: theme.colorScheme.onInverseSurface),
        ),
      );
    });
  }
}

class _EmptyGallery extends StatelessWidget {
  const _EmptyGallery({
    required this.isSyncing,
    required this.syncError,
    required this.onChooseFolders,
  });

  final bool isSyncing;
  final String? syncError;
  final VoidCallback onChooseFolders;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No photos in your gallery yet.\n\n'
              'Choose which folders in Seraph feed Gallery Mode, and the '
              'photos already in them will appear here.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: onChooseFolders,
              child: const Text('Choose folders'),
            ),
            if (isSyncing) ...[
              const SizedBox(height: 24),
              const CircularProgressIndicator(),
            ],
            if (syncError != null) ...[
              const SizedBox(height: 24),
              Text(
                'Could not reach Seraph: $syncError',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
