import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';

/// What [GalleryEraseService.erase] did.
///
/// [erased] items lost their Seraph copy (and, where [trashRequested] and not
/// [cancelled], their device copy went to the trash). [failure] is the
/// message of the remote deletion that stopped the run; the items from that
/// one on were left completely untouched.
class EraseResult {
  const EraseResult({
    required this.erased,
    this.cancelled = false,
    this.failure,
  });

  final int erased;

  /// The user dismissed the device-deletion dialog: the Seraph copies are
  /// gone, the device copies are still there and will not be re-uploaded.
  final bool cancelled;

  final String? failure;
}

/// Ticket 27: Erase - removes a photo from Seraph and the device in one
/// deliberate action (D17).
///
/// **Order matters.** Per item: (1) write the erase tombstone, (2) delete the
/// Seraph copy. Only once the remote deletions are done does anything local
/// change: (3) the mirror rows are dropped and (4) the device copies go to
/// the Android trash behind one dialog for the whole batch. A remote failure
/// undoes that item's tombstone and stops the run before touching anything
/// local for it - the Seraph copy is the unrecoverable half, so it goes
/// first and a failure there must leave the photo exactly as it was.
///
/// The tombstone is what makes the ordering safe: if the dialog is
/// cancelled, or the photo is restored from the trash later, its reappearing
/// device copy is an erased Device only row ([GalleryItems.erased]) that is
/// never uploaded, until [GalleryMirror.backUpAgain].
class GalleryEraseService {
  GalleryEraseService(this.mirror, this.backend, this.localScanService);

  final GalleryMirror mirror;
  final GalleryUploadBackend backend;
  final LocalScanService? localScanService;

  Future<EraseResult> erase(Iterable<int> itemIds) async {
    final rows = await mirror.itemsByIds(itemIds);
    final done = <GalleryItem>[];
    String? failure;

    // ponytail: sequential, stop at the first failure; a batch of thousands
    // is one DELETE round trip each - parallelise if that becomes slow.
    for (final row in rows) {
      await mirror.addEraseTombstone(row);
      try {
        final target = _remoteTarget(row);
        if (target != null) {
          await backend.remove(target.$1, target.$2);
        }
      } on GalleryUploadException catch (e) {
        await mirror.removeEraseTombstone(row);
        failure = e.message;
        break;
      }
      done.add(row);
    }

    if (done.isEmpty) {
      return EraseResult(erased: 0, failure: failure);
    }

    await mirror.deleteItems(done.map((r) => r.id));

    final onDevice = [
      for (final r in done)
        if (r.localRelativePath != null &&
            r.localDisplayName != null &&
            r.localSize != null &&
            r.localDateTaken != null)
          LocalMediaItem(
            relativePath: r.localRelativePath!,
            displayName: r.localDisplayName!,
            size: r.localSize!,
            dateTakenMillis: r.localDateTaken!,
            dateModifiedMillis: 0,
          ),
    ];

    var cancelled = false;
    final source = localScanService?.localSource;
    if (source != null && onDevice.isNotEmpty) {
      cancelled = !await source.trash(onDevice);
      // Either way the scan reconciles the mirror with the device: trashed
      // copies are gone, a cancelled one comes back as an erased row.
      await localScanService!.scan();
    }

    return EraseResult(erased: done.length, cancelled: cancelled, failure: failure);
  }

  /// Where [row]'s Seraph copy lives: its cloud identity, or - for a Device
  /// only row mid-upload - the target an upload was already sent to.
  static (String, String)? _remoteTarget(GalleryItem row) {
    if (row.providerId != null && row.path != null) {
      return (row.providerId!, row.path!);
    }
    if (row.uploadTargetProviderId != null && row.uploadTargetPath != null) {
      return (row.uploadTargetProviderId!, row.uploadTargetPath!);
    }
    return null;
  }
}
