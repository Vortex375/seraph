import 'package:flutter/material.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/local/local_image_loader.dart';
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
    required this.localLoader,
    this.decodeWidth,
  });

  final GalleryItem? item;
  final GalleryImageLoader loader;

  /// Ticket 28: loads a device photo's actual pixels through the Local
  /// Source seam. Always given - it degrades to "nothing to show" on its
  /// own on a platform with no Local Source, so tiles never have to branch
  /// on whether one exists.
  final LocalImageLoader localLoader;

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
          child: _AvailabilityBadge(
            availability: current.availability,
            // Ticket 20, user story 18: an item this device has uploaded but
            // the delta feed has not yet confirmed reads as still in
            // progress, never as backed up - [current.availability] is
            // already [GalleryAvailability.deviceOnly] here (it has to be),
            // so this is purely which icon the badge shows, not a fourth
            // Availability value.
            awaitingVerification: current.isAwaitingVerification,
          ),
        ),
      ],
    );
  }

  Widget _content(BuildContext context, GalleryItem current) {
    if (current.isUnsupported) {
      return _UnsupportedTile(item: current);
    }

    final providerId = current.providerId;
    final path = current.path;
    final hasCloud = providerId != null && path != null;
    final hasLocal = current.hasLocalCopy;

    if (!hasCloud) {
      // Device only: nothing has been fetched from Seraph for this item -
      // there is nothing to fetch. Ticket 28 renders its actual pixels
      // through the Local Source seam; a device photo without local fields
      // at all should not happen (see GalleryItemDisplay.hasLocalCopy's
      // doc), but this stays an honest placeholder rather than a crash if
      // it ever did.
      if (!hasLocal) {
        return _DeviceOnlyTile(item: current);
      }
      return _localThumbnail(
        context,
        current,
        errorBuilder: (context, error, stackTrace) =>
            _DeviceOnlyTile(item: current),
      );
    }

    final cloudThumbnail = _cloudThumbnail(context, providerId, path);
    if (!hasLocal) {
      return cloudThumbnail;
    }
    // Synced: the device copy needs no network and renders instantly, so it
    // is preferred - falling back to the cloud thumbnail only when the
    // device copy cannot currently be read (ticket 28).
    return _localThumbnail(
      context,
      current,
      errorBuilder: (context, error, stackTrace) => cloudThumbnail,
    );
  }

  Widget _cloudThumbnail(BuildContext context, String providerId, String path) {
    final theme = Theme.of(context);
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

  /// The device copy, requested at tile size rather than decoded full-size
  /// and scaled down (ticket 28) - [decodeWidth] is already the tile's own
  /// device-pixel width, computed by [GalleryView]'s layout, so it is
  /// passed straight through as both the requested width and height rather
  /// than wrapped in a [ResizeImage] the way the cloud thumbnail is: there
  /// is no already-fetched 512px image to shrink here, only a native call
  /// this makes ask for the right size to begin with.
  Widget _localThumbnail(
    BuildContext context,
    GalleryItem current, {
    required ImageErrorWidgetBuilder errorBuilder,
  }) {
    final theme = Theme.of(context);
    final width = decodeWidth;
    final tileSize = (width != null && width > 0) ? width : galleryThumbnailSize;

    return Image(
      image: LocalGalleryImage(
        loader: localLoader,
        relativePath: current.localRelativePath!,
        displayName: current.localDisplayName!,
        width: tileSize,
        height: tileSize,
      ),
      fit: BoxFit.cover,
      gaplessPlayback: true,
      filterQuality: FilterQuality.medium,
      errorBuilder: errorBuilder,
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
  const _AvailabilityBadge({
    required this.availability,
    this.awaitingVerification = false,
  });

  final GalleryAvailability availability;

  /// Ticket 20: overrides the plain Device only icon with an in-progress one
  /// - never applies to [GalleryAvailability.synced]/[GalleryAvailability.
  /// cloudOnly], since only an unverified Device only item can be mid-upload.
  final bool awaitingVerification;

  @override
  Widget build(BuildContext context) {
    if (availability == GalleryAvailability.deviceOnly &&
        awaitingVerification) {
      return ExcludeSemantics(
        child: Container(
          key: const ValueKey('gallery-availability-badge-uploading'),
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Icon(Icons.cloud_sync_outlined,
              size: 11, color: Colors.white),
        ),
      );
    }

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
