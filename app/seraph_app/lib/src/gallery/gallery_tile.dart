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
    final theme = Theme.of(context);
    final current = item;

    if (current == null) {
      return ColoredBox(color: theme.colorScheme.surfaceContainerHighest);
    }

    if (current.isUnsupported) {
      return _UnsupportedTile(item: current);
    }

    final providerId = current.providerId;
    final path = current.path;
    if (providerId == null || path == null) {
      return ColoredBox(color: theme.colorScheme.surfaceContainerHighest);
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
