import 'package:flutter/material.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

/// The size, in pixels, Gallery Mode asks the preview endpoint for.
///
/// It matches the size the server warms ahead of time (design decision: warm
/// exactly one configurable size, 512 by default). Asking for anything else
/// would miss every warmed thumbnail and generate a second set on demand.
const int galleryThumbnailSize = 512;

/// One tile in the gallery grid.
///
/// [item] is null when its page has not been read from the mirror yet. That
/// case renders at exactly the same size as a loaded tile, because the grid's
/// geometry comes from the item count rather than from what has loaded - a
/// tile filling in must change pixels and never layout.
class GalleryTile extends StatelessWidget {
  const GalleryTile({
    super.key,
    required this.item,
    required this.loader,
    this.decodeWidth,
  });

  final GalleryItem? item;
  final GalleryImageLoader loader;

  /// Width to decode the thumbnail at, in device pixels. A grid of 512 px
  /// JPEGs decoded at full size would hold far more memory than the tiles can
  /// show.
  final int? decodeWidth;

  @override
  Widget build(BuildContext context) {
    final current = item;
    if (current == null) {
      return ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
      );
    }

    // Availability shown discreetly on every tile - ticket 15 - as a small
    // corner badge over whatever content the tile would otherwise show,
    // never affecting the tile's size or the grid's layout.
    return Stack(
      fit: StackFit.expand,
      children: [
        _content(context, current),
        Positioned(
          left: 3,
          bottom: 3,
          child: _AvailabilityBadge(availability: current.availability),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, GalleryItem current) {
    final theme = Theme.of(context);

    if (current.isUnsupported) {
      return _UnsupportedTile(item: current);
    }

    final providerId = current.providerId;
    final path = current.path;
    if (providerId == null || path == null) {
      // Device only: nothing has been fetched from Seraph for this item -
      // there is nothing to fetch. Rendering the actual device thumbnail is
      // left to a later ticket (see the ticket 15 implementer report); this
      // placeholder still carries the file name and its Availability badge,
      // so the item is honestly present in the grid rather than missing.
      return _DeviceOnlyTile(item: current);
    }

    ImageProvider provider = GalleryImage(
      loader: loader,
      providerId: providerId,
      path: path,
      size: galleryThumbnailSize,
    );
    final width = decodeWidth;
    if (width != null && width > 0) {
      provider = ResizeImage(provider, width: width, allowUpscaling: false);
    }

    return Image(
      image: provider,
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, error, stackTrace) => ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.image_not_supported_outlined,
          size: 20,
          color: theme.colorScheme.outline,
        ),
      ),
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (wasSynchronouslyLoaded || frame != null) {
          return child;
        }
        return ColoredBox(color: theme.colorScheme.surfaceContainerHighest);
      },
    );
  }
}

/// A photo that only exists on the device - nothing to fetch from Seraph.
class _DeviceOnlyTile extends StatelessWidget {
  const _DeviceOnlyTile({required this.item});

  final GalleryItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: item.fileName,
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          Icons.smartphone_outlined,
          size: 20,
          color: theme.colorScheme.outline,
        ),
      ),
    );
  }
}

/// The small, deliberately unobtrusive Availability marker every tile shows
/// (ticket 15: "shown discreetly on the tile") - present but never
/// competing with the photo for attention.
class _AvailabilityBadge extends StatelessWidget {
  const _AvailabilityBadge({required this.availability});

  final GalleryAvailability availability;

  @override
  Widget build(BuildContext context) {
    final IconData icon;
    switch (availability) {
      case GalleryAvailability.deviceOnly:
        icon = Icons.smartphone_outlined;
        break;
      case GalleryAvailability.synced:
        icon = Icons.cloud_done_outlined;
        break;
      case GalleryAvailability.cloudOnly:
        icon = Icons.cloud_outlined;
        break;
    }
    return ExcludeSemantics(
      child: Container(
        key: ValueKey('gallery-availability-badge-${availability.name}'),
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.45),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Icon(icon, size: 11, color: Colors.white),
      ),
    );
  }
}

/// A photo Seraph holds but cannot render. It stays in the grid - the gallery
/// is an inventory of what exists, not of what happens to display - and says
/// why.
class _UnsupportedTile extends StatelessWidget {
  const _UnsupportedTile({required this.item});

  final GalleryItem item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '${item.fileName}\n${item.unsupportedReasonLabel}',
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.broken_image_outlined,
                size: 20,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(height: 4),
              Text(
                item.unsupportedReasonLabel,
                textAlign: TextAlign.center,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.outline),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
