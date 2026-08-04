import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_upload_backend.dart';

/// How [GalleryUploadService.upload] resolved - what the UI (currently the
/// upload button on the full-screen photo viewer, `gallery_photo_viewer.dart`)
/// turns into a message.
enum GalleryUploadResult {
  /// The photo was PUT to a new path. **Not yet Synced** (ticket 20): the
  /// item is recorded as awaiting the delta feed's independent confirmation
  /// - see [GalleryItemDisplay.isAwaitingVerification] in
  /// `gallery_item_display.dart`.
  uploaded,

  /// Nothing was uploaded because content of the same size already occupied
  /// the target path - ticket 19's "size matches, assume it is ours" rule.
  /// **Not yet Synced either** - the same feed-verification gate applies
  /// here as to [uploaded] (ticket 20: not even the upload response, real or
  /// assumed, is proof by itself).
  alreadyPresent,

  /// No Sync Pair covers this item's local folder, so there is no
  /// deterministic remote path to upload to.
  noSyncPair,

  /// The device copy could not be read - deleted, permission revoked, or no
  /// Local Source on this platform at all. **Ticket 25 routes this to the
  /// visible failure list as a PERMANENT failure** ([GallerySyncEngine.run],
  /// `../sync/gallery_sync_engine.dart`) rather than counting it as
  /// attempted-and-done: unlike [deviceFileChanged] below, nothing else ever
  /// re-offers this item usefully on its own, so leaving it silently
  /// uncounted would mean a photo this device can no longer read reads as
  /// backed up forever.
  deviceFileUnavailable,

  /// The device copy changed size between being scanned and being read for
  /// upload, or the mirror row was no longer the same device item by the
  /// time the upload finished (deleted or replaced by a racing scan). Either
  /// way, ticket 19's "deleted or modified mid-upload is not marked synced"
  /// criterion: nothing here is marked Synced. **Deliberately left alone by
  /// ticket 25** - the row's [GalleryItems.uploadState] stays null, so the
  /// very next scan/run offers it again on its own; a racing scan or a
  /// same-second edit resolves itself without any failure-bucket bookkeeping.
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
///   this class's logic (never overwrite, disambiguate, record the pending
///   upload) can be driven by a stubbed backend in tests, per the ticket's
///   own seam requirement.
///
/// **Never marks an item Verified/Synced itself** (ticket 20): [upload]'s
/// job ends at recording what it did ([GalleryMirror.recordUploaded]) so the
/// delta feed can independently confirm it later ([GalleryMirror.applyPage]).
/// [retryMismatchedUpload] is this class's other half of ticket 20 - the one
/// case an upload gets undone and redone without the user asking.
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
  /// collision), no upload at all on a same-size collision (recorded as
  /// pending verification directly), no client-side staging (one PUT
  /// straight to the final candidate path), and no recording anything unless
  /// the device copy read for upload is still exactly the one the mirror row
  /// describes once the PUT (or the same-size short-circuit) completes.
  ///
  /// **Never marks [item] Verified/Synced** (ticket 20) - [GalleryUploadResult.
  /// uploaded] and [GalleryUploadResult.alreadyPresent] both mean "recorded,
  /// now awaiting the delta feed's independent confirmation", not "done".
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
        final marked = await mirror.recordUploaded(
            item, providerId, candidatePath,
            viaPut: true);
        return marked
            ? GalleryUploadResult.uploaded
            : GalleryUploadResult.deviceFileChanged;
      }

      if (existingSize == bytes.length) {
        // Occupied by content of the same size - assume it is ours (ticket
        // 19's rule; the one accepted false positive is a same-length edit,
        // named explicitly in the ticket). No upload happens at all. Recorded
        // with viaPut: false - this device never wrote that file, only
        // assumed it, which matters if the feed later disagrees (ticket 20:
        // see [retryMismatchedUpload]).
        final marked = await mirror.recordUploaded(
            item, providerId, candidatePath,
            viaPut: false);
        return marked
            ? GalleryUploadResult.alreadyPresent
            : GalleryUploadResult.deviceFileChanged;
      }

      // Occupied by different content - never overwrite; try the next
      // disambiguated name at the same target folder.
    }

    // Ticket 25: PERMANENT, not transient - a thousand collisions in a row
    // is a naming/logic problem, not a network hiccup, and would only churn
    // through the exact same statSize calls again on a backoff retry.
    throw const GalleryUploadException(
      'Could not find a free name for this photo after many attempts.',
      bucket: GalleryUploadFailureBucket.permanent,
    );
  }

  /// Works through one item [GalleryMirror.itemsNeedingUploadRetry] reported
  /// - a device row whose verification came back CONTRADICTING what this
  /// device expected - and reacts according to how that pending state got
  /// there in the first place (ticket 20's rework; see the class doc on
  /// [GalleryItems.uploadState] in `gallery_mirror_database.dart` for the
  /// four states this reads):
  ///
  /// - **A real PUT** ([GalleryItem.uploadState] `'mismatch'`): the remote
  ///   file at [GalleryItem.uploadTargetProviderId]/[GalleryItem.
  ///   uploadTargetPath] IS this device's own upload, so it is safe to
  ///   delete - the one case the app deletes something remotely on its own -
  ///   and the upload is retried from scratch through [upload], which
  ///   re-derives the target, re-reads the device copy, and re-runs the full
  ///   never-overwrite/disambiguation logic as if this were the first
  ///   attempt. Deleting first matters: without it, the retry's own `PUT`
  ///   would find the (still-present, wrong-length) file occupying the
  ///   target path and disambiguate into a second file next to the
  ///   untrusted one instead of replacing it.
  /// - **The ticket-19 "assume it's ours" shortcut** ([GalleryItem.
  ///   uploadState] `'assumedMismatch'`): this device never PUT anything to
  ///   that path - it only assumed a pre-existing, same-size file was its
  ///   own. A contradicting feed length disproves that assumption; it is
  ///   never grounds to delete a file this device did not write. Nothing is
  ///   deleted. Instead this falls back to ticket 19's different-size
  ///   collision rule the shortcut skipped past the first time: disambiguate
  ///   straight to the next candidate name (never retrying the same,
  ///   now-distrusted path) and await verification of THAT path -
  ///   [_retryAsDisambiguated].
  ///
  /// A caller works through [GalleryMirror.itemsNeedingUploadRetry] to find
  /// which items need this - not automatic, and not scheduled, from this
  /// class: ticket 20 is the verification mechanism, not the engine that
  /// decides when to run it (tickets 22/24).
  Future<GalleryUploadResult> retryMismatchedUpload(GalleryItem item) async {
    if (item.uploadState == 'assumedMismatch') {
      return _retryAsDisambiguated(item);
    }

    final targetProviderId = item.uploadTargetProviderId;
    final targetPath = item.uploadTargetPath;
    if (targetProviderId != null && targetPath != null) {
      await backend.remove(targetProviderId, targetPath);
    }
    return upload(item);
  }

  /// The "assumed it's ours" recovery half of [retryMismatchedUpload]: same
  /// device-read and validation steps as [upload], but the disambiguation
  /// loop starts at attempt 1, never attempt 0 (the base candidate path).
  /// Attempt 0 is exactly the path the feed just disproved this device's
  /// claim to, so trying it again - same-size shortcut included - would
  /// only repeat the wrong assumption; skipping straight to disambiguation
  /// is ticket 19's ordinary different-size collision rule, applied here
  /// because the feed has now supplied the "different size" evidence the
  /// original stat-based check missed. The file at the base path is never
  /// touched, read, or deleted.
  Future<GalleryUploadResult> _retryAsDisambiguated(GalleryItem item) async {
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

    final bytes = await source.loadOriginal(
      relativePath: relativePath,
      displayName: displayName,
    );
    if (bytes == null) {
      return GalleryUploadResult.deviceFileUnavailable;
    }
    if (item.localSize != null && bytes.length != item.localSize) {
      return GalleryUploadResult.deviceFileChanged;
    }

    final providerId = target.$1;
    final basePath = target.$2;

    for (var attempt = 1; attempt <= maxDisambiguationAttempts; attempt++) {
      final candidatePath = _disambiguatedPath(basePath, attempt);
      final existingSize = await backend.statSize(providerId, candidatePath);

      if (existingSize == null) {
        await backend.put(providerId, candidatePath, bytes);
        final marked = await mirror.recordUploaded(
            item, providerId, candidatePath,
            viaPut: true);
        return marked
            ? GalleryUploadResult.uploaded
            : GalleryUploadResult.deviceFileChanged;
      }

      if (existingSize == bytes.length) {
        final marked = await mirror.recordUploaded(
            item, providerId, candidatePath,
            viaPut: false);
        return marked
            ? GalleryUploadResult.alreadyPresent
            : GalleryUploadResult.deviceFileChanged;
      }

      // Occupied by different content - never overwrite; try the next
      // disambiguated name.
    }

    // Ticket 25: PERMANENT, not transient - a thousand collisions in a row
    // is a naming/logic problem, not a network hiccup, and would only churn
    // through the exact same statSize calls again on a backoff retry.
    throw const GalleryUploadException(
      'Could not find a free name for this photo after many attempts.',
      bucket: GalleryUploadFailureBucket.permanent,
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
