import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';

/// Drives one full Local Source scan into the mirror - the device-side twin
/// of `GallerySyncService`, which does the same job for the cloud delta feed.
///
/// This is the full media-store scan the ticket calls the correctness
/// anchor, run at app start and again whenever [GalleryGridController]
/// (`gallery_grid_controller.dart`) refreshes the gallery. It is
/// deliberately the ONLY device change-detection mechanism this ticket
/// builds: the generation-based incremental scan and the content observer
/// (design decision D9, tiers 2 and 3) are ticket 17's faster paths and must
/// not be anticipated here - correctness must never depend on them.
class LocalScanService {
  LocalScanService(this.mirror, {LocalSource? localSource})
      : localSource = localSource ?? createLocalSource();

  final GalleryMirror mirror;

  /// Null on every platform without a Local Source - iOS, desktop, web, or
  /// an Android device with no photo-access grant. [scan] is then a no-op,
  /// which is exactly "the gallery behaves as it did before this ticket"
  /// (ticket 15's platform-neutrality criterion) rather than a special case
  /// callers need to branch on.
  final LocalSource? localSource;

  /// Runs one full scan and applies it to the mirror. Safe to call
  /// repeatedly - a scan that finds nothing new does nothing, and a photo
  /// already known by its local identity is left alone (see
  /// [GalleryMirror.applyLocalScan]).
  Future<void> scan() async {
    final source = localSource;
    if (source == null) {
      return;
    }
    final items = await source.fullScan();
    await mirror.applyLocalScan(items);
  }
}
