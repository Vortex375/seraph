import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';

/// How [GalleryUploadService.upload] resolved - what the UI (currently the
/// upload button on the full-screen photo viewer, `gallery_photo_viewer.dart`)
/// turns into a message.
enum GalleryUploadResult {
  /// The photo was PUT to a new path and the item is now Synced.
  uploaded,

  /// Nothing was uploaded because content of the same size already occupied
  /// the target path - ticket 19's "size matches, assume it is ours" rule.
  /// The item is now Synced regardless.
  alreadyPresent,

  /// No Sync Pair covers this item's local folder, so there is no
  /// deterministic remote path to upload to.
  noSyncPair,

  /// The device copy could not be read - deleted, permission revoked, or no
  /// Local Source on this platform at all.
  deviceFileUnavailable,

  /// The device copy changed size between being scanned and being read for
  /// upload, or the mirror row was no longer the same device item by the
  /// time the upload finished (deleted or replaced by a racing scan). Either
  /// way, ticket 19's "deleted or modified mid-upload is not marked synced"
  /// criterion: nothing here is marked Synced.
  deviceFileChanged,

  /// [item] was not a Device only row to begin with - nothing for this
  /// method to do. Not reachable through the UI, which only offers upload
  /// for Device only items, but kept as an explicit result rather than an
  /// assertion so a caller passing the wrong item gets an answer, not a
  /// crash.
  notApplicable,
}

/// Ticket 19's upload, end to end: press a button on one Device only photo
/// and it lands under its Sync Pair's Seraph folder, at its mirrored relative
/// path - the tracer bullet through the whole upload path. The engine that
/// decides *which* photos to upload and *when* (background scheduling, retry
/// policy, the failure list) is tickets 22/24/25, deliberately not this
/// class; [upload] only ever does what it is told, once, for the one item it
/// is given.
///
/// Composed from three seams that already exist for their own reasons,
/// rather than a new one for each concern this class touches:
/// - [GalleryMirror] for the remote-path function ([GalleryMirror.
///   expectedUploadTarget]) and for recording the outcome ([GalleryMirror.
///   recordUploaded]) - both already live there because they are the same
///   pure function and the same row-write ticket 18's dedup uses.
/// - [LocalSource] for the device copy's bytes ([LocalSource.loadOriginal],
///   already built for ticket 28's full-screen viewer).
/// - [GalleryUploadBackend] for talking to Seraph - narrow specifically so
///   this class's logic (never overwrite, disambiguate, mark synced) can be
///   driven by a stubbed backend in tests, per the ticket's own seam
///   requirement.
class GalleryUploadService {
  GalleryUploadService(this.mirror, this.backend, this.localSource);

  final GalleryMirror mirror;
  final GalleryUploadBackend backend;

  /// Null on a platform with no Local Source (or none configured for this
  /// test) - [upload] then always reports [GalleryUploadResult.
  /// deviceFileUnavailable], the same "behaves as if there is nothing to
  /// upload" stance every other Local-Source-optional class in this seam
  /// takes (see [LocalScanService]).
  final LocalSource? localSource;

  /// A generous ceiling on how many disambiguated names ticket 19's
  /// never-overwrite rule will try before giving up - large enough that no
  /// real collision run ever hits it, small enough that a backend bug
  /// returning "occupied" for every path fails loudly instead of looping
  /// forever.
  static const int maxDisambiguationAttempts = 1000;

  /// Uploads [item] - which must be a Device only row - to its Sync Pair's
  /// Seraph folder, at its mirrored relative path, following ticket 19's
  /// rules: no overwrite (disambiguate on a same-path, different-size
  /// collision), no upload at all on a same-size collision (marked Synced
  /// directly), no client-side staging (one PUT straight to the final
  /// candidate path), and no marking Synced unless the device copy read for
  /// upload is still exactly the one the mirror row describes once the PUT
  /// (or the same-size short-circuit) completes.
  ///
  /// Throws [GalleryUploadException] for a backend failure the caller cannot
  /// route around itself - a read-only Space chief among them - so the UI
  /// gets a comprehensible reason rather than the item silently staying
  /// un-backed-up with nothing said about why.
  Future<GalleryUploadResult> upload(GalleryItem item) async {
    if (item.origin != 'device') {
      return GalleryUploadResult.notApplicable;
    }

    final source = localSource;
    final relativePath = item.localRelativePath;
    final displayName = item.localDisplayName;
    if (source == null || relativePath == null || displayName == null) {
      return GalleryUploadResult.deviceFileUnavailable;
    }

    final target = await mirror.expectedUploadTarget(item);
    if (target == null) {
      return GalleryUploadResult.noSyncPair;
    }

    // Read the device copy's bytes before touching the network at all - the
    // same bytes are what gets PUT, unmodified, which is what makes the
    // Seraph copy byte-identical to the device copy (no Dart-side
    // transformation happens anywhere on this path).
    final bytes = await source.loadOriginal(
      relativePath: relativePath,
      displayName: displayName,
    );
    if (bytes == null) {
      // Deleted, or the platform can no longer read it - ticket 19's
      // "deleted mid-upload is not marked synced", caught before any network
      // call is even made.
      return GalleryUploadResult.deviceFileUnavailable;
    }
    if (item.localSize != null && bytes.length != item.localSize) {
      // Modified in place since the scan that produced this row - same
      // criterion, the other half of it.
      return GalleryUploadResult.deviceFileChanged;
    }

    final providerId = target.$1;
    final basePath = target.$2;

    for (var attempt = 0; attempt <= maxDisambiguationAttempts; attempt++) {
      final candidatePath =
          attempt == 0 ? basePath : _disambiguatedPath(basePath, attempt);
      final existingSize = await backend.statSize(providerId, candidatePath);

      if (existingSize == null) {
        // Nothing at this path - safe to publish there directly. Straight to
        // the final path, no staging name and no MOVE (ADR 0002's amendment:
        // server-side atomic PUT already makes this path either absent or
        // complete for every client).
        await backend.put(providerId, candidatePath, bytes);
        final marked = await mirror.recordUploaded(item, providerId, candidatePath);
        return marked
            ? GalleryUploadResult.uploaded
            : GalleryUploadResult.deviceFileChanged;
      }

      if (existingSize == bytes.length) {
        // Occupied by content of the same size - assume it is ours (ticket
        // 19's rule; the one accepted false positive is a same-length edit,
        // named explicitly in the ticket). No upload happens at all.
        final marked = await mirror.recordUploaded(item, providerId, candidatePath);
        return marked
            ? GalleryUploadResult.alreadyPresent
            : GalleryUploadResult.deviceFileChanged;
      }

      // Occupied by different content - never overwrite; try the next
      // disambiguated name at the same target folder.
    }

    throw const GalleryUploadException(
      'Could not find a free name for this photo after many attempts.',
    );
  }

  /// `IMG_0001.jpg` -> `IMG_0001 (2).jpg` for [attempt] == 2 - inserted
  /// before the extension (if any) so the disambiguated file still opens as
  /// the same type, and parenthesised rather than under-scored so it reads,
  /// at a glance in the file browser, as "not the original name a camera or
  /// this Sync Pair would have produced" rather than as a plausible one.
  String _disambiguatedPath(String path, int attempt) {
    final slash = path.lastIndexOf('/');
    final dir = slash < 0 ? '' : path.substring(0, slash + 1);
    final name = slash < 0 ? path : path.substring(slash + 1);
    final dot = name.lastIndexOf('.');
    final stem = dot <= 0 ? name : name.substring(0, dot);
    final ext = dot <= 0 ? '' : name.substring(dot);
    return '$dir$stem ($attempt)$ext';
  }
}
