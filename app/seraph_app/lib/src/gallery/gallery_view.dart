import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/gallery_photo_viewer.dart';
import 'package:seraph_app/src/gallery/gallery_source_folders_view.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';
import 'package:seraph_app/src/gallery/local/local_image_loader.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';

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

class _GalleryViewState extends State<GalleryView> with WidgetsBindingObserver {
  static const double _spacing = 2;

  /// Target tile size in logical pixels. The grid picks whatever column count
  /// gets closest to it, so a phone gets three or four columns and a desktop
  /// window gets as many as it has room for.
  static const double _targetTileExtent = 140;

  final GalleryGridController controller = Get.find();
  final GalleryImageLoader loader = Get.find();
  final LocalImageLoader localLoader = Get.find();
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
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _firstVisibleIndex.dispose();
    super.dispose();
  }

  /// Ticket 16's "changing the grant while the app is running is picked up
  /// without requiring a restart": the only route to changing photo access
  /// mid-session is leaving the app (system Settings, the extended-selection
  /// picker) and coming back, which is exactly a resume. [syncOnResume] -
  /// not [syncNow] directly - is what upholds that under ticket 30's
  /// throttle: it re-checks the grant itself and forces past the throttle
  /// when the grant changed, so a resume landing inside the throttle window
  /// still picks up a permission change instead of being swallowed by it. A
  /// resume with no grant change is throttled exactly like any other call.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(controller.syncOnResume());
    }
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
            Obx(() => PopupMenuButton<GalleryAvailabilityFilter>(
                  tooltip: 'Filter',
                  icon: Icon(
                    controller.filter.value == GalleryAvailabilityFilter.all
                        ? Icons.filter_list
                        : Icons.filter_alt,
                  ),
                  initialValue: controller.filter.value,
                  onSelected: controller.setFilter,
                  itemBuilder: (context) => const [
                    PopupMenuItem(
                      value: GalleryAvailabilityFilter.all,
                      child: Text('All photos'),
                    ),
                    PopupMenuItem(
                      value: GalleryAvailabilityFilter.notBackedUp,
                      child: Text('Not backed up'),
                    ),
                    PopupMenuItem(
                      value: GalleryAvailabilityFilter.cloudOnly,
                      child: Text('Cloud only'),
                    ),
                  ],
                )),
            Obx(() => IconButton(
                  icon: controller.isSyncing.value
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh),
                  tooltip: 'Check for new photos',
                  // Forced (ticket 30): a manual tap is the user explicitly
                  // asking for a fresh look, so this bypasses both the
                  // throttle and the incremental-scan default rather than
                  // possibly doing nothing at all if pressed again soon after
                  // the gallery opened.
                  onPressed: controller.isSyncing.value
                      ? null
                      : () => controller.syncNow(force: true),
                )),
            IconButton(
              icon: const Icon(Icons.folder_special_outlined),
              tooltip: 'Gallery folders',
              onPressed: _openFolders,
            ),
          ]),
      body: Column(
        children: [
          _LocalPermissionBanner(controller: controller),
          _SummaryBar(controller: controller),
          Expanded(
            child: Obx(() {
              if (controller.isLoading.value) {
                return const Center(child: CircularProgressIndicator());
              }
              if (controller.totalCount.value == 0) {
                if (controller.filter.value != GalleryAvailabilityFilter.all) {
                  return _EmptyFilterResult(
                    onClearFilter: () =>
                        controller.setFilter(GalleryAvailabilityFilter.all),
                  );
                }
                return _EmptyGallery(
                  isSyncing: controller.isSyncing.value,
                  syncError: controller.syncError.value,
                  onChooseFolders: _openFolders,
                );
              }
              return _buildGrid(context);
            }),
          ),
        ],
      ),
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
                    localLoader: localLoader,
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
          // Before the first reload completes (or an empty gallery): stay out
          // of the way rather than flashing a wrong month. The date is
          // otherwise always available synchronously from the boundary map.
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
    // The month under the thumb is answered synchronously from the boundary
    // map the controller built on reload - no async lookup, no page load.
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

/// "1,234 backed up · 12 not backed up" - the one number to trust, per
/// ticket 15's summary criterion. Always over the whole gallery, independent
/// of any Availability filter currently narrowing what the grid shows below
/// it - hidden entirely once there is nothing in the gallery at all.
///
/// Under a partial photo-access grant (ticket 16), this count can only ever
/// be a count of the photos the app can see - a device photo outside the
/// user's selection is invisible to the scan and cannot be reflected here
/// at all, in either direction. The design's rule ("no summary... states or
/// implies that everything is backed up") is met by saying so directly
/// rather than by trusting the persistent warning banner above it alone.
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({required this.controller});

  final GalleryGridController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final summary = controller.summary.value;
      if (summary.total == 0) {
        return const SizedBox.shrink();
      }
      final isPartial =
          controller.localPermission.value == LocalPermissionStatus.partial;
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        color: theme.colorScheme.surfaceContainerHighest,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${summary.backedUp} backed up · ${summary.notBackedUp} not backed up',
              style: theme.textTheme.bodySmall,
            ),
            if (isPartial)
              Text(
                'Does not count device photos outside your selection - they '
                "are not visible to Seraph and aren't included here.",
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
          ],
        ),
      );
    });
  }
}

/// Ticket 16's photo-access UI: an explanation-first prompt before the very
/// first request, and a persistent warning while access is only partial.
/// Nothing is shown once access is granted in full, on a platform with no
/// Local Source at all, or (deliberately - see the class body) once access
/// has been explicitly refused, so the cloud-only gallery is never nagged at
/// after an honest "no".
class _LocalPermissionBanner extends StatefulWidget {
  const _LocalPermissionBanner({required this.controller});

  final GalleryGridController controller;

  @override
  State<_LocalPermissionBanner> createState() => _LocalPermissionBannerState();
}

class _LocalPermissionBannerState extends State<_LocalPermissionBanner> {
  // Session-only: Android's permission API cannot tell "never asked" apart
  // from "explicitly denied" (see LocalPermissionStatus.denied), so this
  // banner cannot remember a refusal across a restart without guessing.
  // Dismissing for this open of the gallery is enough to stop it competing
  // with the grid without lying about a decision that never persisted.
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final status = widget.controller.localPermission.value;
      switch (status) {
        case LocalPermissionStatus.partial:
          return _warningBanner(theme);
        case LocalPermissionStatus.denied:
          if (_dismissed) {
            return const SizedBox.shrink();
          }
          return _promptBanner(theme);
        case LocalPermissionStatus.granted:
        case LocalPermissionStatus.unsupported:
          return const SizedBox.shrink();
      }
    });
  }

  /// Shown before the very first request, and again after an explicit
  /// refusal (until dismissed) so changing one's mind is always one tap
  /// away. Ticket 16's first criterion: the explanation is the banner's own
  /// text, shown before [GalleryGridController.requestLocalPermission] ever
  /// fires the platform's own dialog.
  Widget _promptBanner(ThemeData theme) {
    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.photo_library_outlined,
              color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Seraph can include and back up photos on this device, '
              "alongside your Seraph photos. It only reads photos you're "
              "asked about; nothing is uploaded unless you set up backup "
              'separately.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSecondaryContainer),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => widget.controller.requestLocalPermission(),
            child: const Text('Allow access'),
          ),
          TextButton(
            onPressed: () => setState(() => _dismissed = true),
            child: const Text('Not now'),
          ),
        ],
      ),
    );
  }

  /// Persistent while access is partial (ticket 16: "a persistent,
  /// comprehensible warning that it cannot see the rest") - deliberately has
  /// no dismiss button, unlike [_promptBanner]. Offers both routes out: the
  /// picker for more photos, and Settings for full access.
  Widget _warningBanner(ThemeData theme) {
    return Container(
      key: const Key('gallery-partial-access-banner'),
      width: double.infinity,
      color: theme.colorScheme.errorContainer,
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
      child: Row(
        children: [
          Icon(Icons.warning_amber_outlined,
              color: theme.colorScheme.onErrorContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Limited photo access: Seraph can only see the photos you '
              "selected. This gallery and its summary don't include the "
              'rest of your device photos.',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onErrorContainer),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => widget.controller.requestLocalPermission(),
            child: const Text('Choose more photos'),
          ),
          TextButton(
            onPressed: () => widget.controller.openLocalPermissionSettings(),
            child: const Text('Allow full access'),
          ),
        ],
      ),
    );
  }
}

/// Shown when an Availability filter narrows the gallery to nothing - distinct
/// from [_EmptyGallery], which is about an empty gallery altogether, so the
/// user is not told to go choose folders when the real fix is to clear a
/// filter.
class _EmptyFilterResult extends StatelessWidget {
  const _EmptyFilterResult({required this.onClearFilter});

  final VoidCallback onClearFilter;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No photos match this filter.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onClearFilter,
              child: const Text('Show all photos'),
            ),
          ],
        ),
      ),
    );
  }
}
