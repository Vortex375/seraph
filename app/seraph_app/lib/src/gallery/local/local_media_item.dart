import 'dart:typed_data';

/// One photo as the platform-specific local-media layer describes it - the
/// platform-neutral shape the Local Source seam hands upward (ticket 15,
/// `.scratch/gallery-mode/issues/15-local-source-scan-and-merged-gallery.md`,
/// and design decision D9 in `docs/gallery-mode-design-notes.md`).
///
/// **Local identity is `(relativePath, displayName, size, dateTakenMillis)`.**
/// [mediaStoreId] is carried only as a same-scan hint - never persisted to the
/// mirror and never consulted to decide whether two scans saw the same photo.
/// A file deleted and recreated, moved between folders, or restored by
/// another app gets a new row id on Android; keying on it would treat the
/// photo as new every time.
class LocalMediaItem {
  const LocalMediaItem({
    required this.relativePath,
    required this.displayName,
    required this.size,
    required this.dateTakenMillis,
    required this.dateModifiedMillis,
    this.mediaStoreId,
  });

  /// Path within the Local Source - e.g. `DCIM/Camera/IMG_0001.jpg` on
  /// Android. What "relative path within the source" means is entirely
  /// platform-specific (see the Local Source seam doc on [LocalSource]); this
  /// class only carries the value, it does not compute it.
  final String relativePath;

  /// The file's own name, without any directory part.
  final String displayName;

  /// File size in bytes.
  final int size;

  /// Epoch MILLISECONDS. `0` when the platform has no capture date for this
  /// file (common for screenshots and received images) - callers fall back
  /// to [dateModifiedMillis], mirroring the server-side fallback chain
  /// (`EXIF DateTimeOriginal -> file modification time`) without repeating
  /// server logic here.
  final int dateTakenMillis;

  /// Epoch MILLISECONDS. Always populated, even when [dateTakenMillis] is
  /// not - the last-resort ordering date, same role as `capturedAtSource:
  /// 'modTime'` on a cloud item.
  final int dateModifiedMillis;

  /// A same-session hint only - see the class doc. Null for any Local Source
  /// implementation that has nothing analogous to a MediaStore row id.
  final int? mediaStoreId;
}

/// The device photo-access grant, as ticket 16 needs to reason about it -
/// never richer than what the platform itself can tell apart.
///
/// Android's own permission API cannot distinguish "never asked" from
/// "explicitly denied" - `checkSelfPermission` reports both as not granted.
/// [denied] therefore covers both; the explanation-before-request UI
/// (`GalleryView`) simply offers the request again each time the gallery
/// opens rather than trying to remember which of the two it was, which
/// keeps this seam honest about what the platform actually knows.
enum LocalPermissionStatus {
  /// No Local Source exists on this platform at all (iOS, desktop, web) -
  /// there is no permission to ask about, and no warning to show either.
  unsupported,

  /// Full library access - the gallery behaves exactly as ticket 15 left it.
  granted,

  /// Android 14's partial grant (`READ_MEDIA_VISUAL_USER_SELECTED` without
  /// `READ_MEDIA_IMAGES`): the app can see only the photos the user
  /// hand-picked. A full scan still runs and still only returns that subset
  /// - MediaStore itself filters the query, this seam does not have to.
  partial,

  /// No access at all - either never asked, or explicitly refused. The
  /// cloud-only gallery must keep working exactly as if no Local Source
  /// existed here (ticket 15's platform-neutrality criterion, extended by
  /// ticket 16 to "declining one permission must not disable the feature").
  denied,
}

/// One incremental scan's answer (ticket 17): the photos changed since
/// [LocalSource.incrementalScan]'s `sinceGeneration` argument, together with
/// the generation to remember as the new watermark.
///
/// [generation] is always populated, even when [items] is empty - a change
/// elsewhere in the library (or simply time passing with nothing to report)
/// still advances the platform's own change counter, and the caller must
/// persist it regardless so the next incremental scan does not re-walk the
/// same range for nothing.
class LocalIncrementalScanResult {
  const LocalIncrementalScanResult({required this.items, required this.generation});

  final List<LocalMediaItem> items;
  final int generation;
}

/// The device-side half of a Sync Pair (see `CONTEXT.md`): wherever photos
/// come from on this device, together with a relative path for each one. On
/// Android that is external storage's shared media collection and the paths
/// beneath it; the term stays deliberately vague about *how* a device
/// organises photos, because not every platform has folders (see D7 - iOS'
/// `PHAsset` library has none).
///
/// **This is the seam ticket 15 exists to draw**: everything above it -
/// the mirror, the merged gallery, Availability - is platform-neutral: it
/// consumes [LocalMediaItem] values and knows nothing about MediaStore,
/// `PHAsset`, or any other platform API. Only [LocalSource] implementations
/// (currently just `AndroidLocalSource`) know how their platform stores
/// photos.
abstract class LocalSource {
  /// The correctness anchor (ticket 15): one projection-only, full listing of
  /// every photo currently visible to the app under whatever permission grant
  /// it holds - id, date taken, date modified, size, relative path and
  /// display name only. Meant to run at app start and periodically, and to be
  /// sub-second for 10,000 images; a client observer or generation-based
  /// incremental scan (ticket 17, not this one) may run more often but must
  /// never be the only thing standing between a photo and its backup status -
  /// this is what guarantees that.
  ///
  /// Returns an empty list rather than throwing when the platform cannot
  /// currently produce photos - permission not granted, or no Local Source
  /// implementation exists here at all - so a scan that cannot run behaves
  /// exactly like a platform with no Local Source (ticket 15's platform-
  /// neutrality criterion), never like an error. Under [LocalPermissionStatus.
  /// partial] this still returns whatever subset the user selected - it is
  /// not empty just because access is incomplete.
  Future<List<LocalMediaItem>> fullScan();

  /// Ticket 17's fast path: only the photos whose MediaStore generation
  /// counter (Android's `GENERATION_MODIFIED`/`MediaStore.getGeneration`,
  /// unconditionally available at this app's minimum SDK) exceeds
  /// [sinceGeneration], together with the generation to persist as the new
  /// watermark. Deliberately reports only additions and modifications -
  /// never deletions: a row simply is not there to report a generation for
  /// once it is gone, so noticing a vanished photo stays [fullScan]'s job
  /// alone (the correctness anchor, ticket 15). A caller must never treat
  /// this as a substitute for periodic full scans, only as a latency
  /// shortcut on top of them.
  ///
  /// Returns an empty [LocalIncrementalScanResult.items] with
  /// [LocalIncrementalScanResult.generation] equal to [sinceGeneration] when
  /// the platform cannot currently produce photos (permission not granted,
  /// no Local Source) - the same "behaves as if nothing happened" shape
  /// [fullScan] uses, so a caller never has to special-case failure here
  /// either.
  Future<LocalIncrementalScanResult> incrementalScan(int sinceGeneration);

  /// The platform's own current generation counter, with no query against
  /// the library at all - used once, right after a [fullScan], to prime
  /// [incrementalScan]'s watermark at "now" rather than "the beginning", so
  /// the fast path's first run after a full scan has nothing left to
  /// (redundantly, if harmlessly) replay.
  Future<int> currentGeneration();

  /// Ticket 17's content observer: a trigger-only, payload-free signal that
  /// *something* in the library may have changed. Consumers must respond by
  /// running [incrementalScan] (or, on the next periodic pass, [fullScan]) -
  /// never by trusting the event's mere arrival as meaning any specific
  /// photo now exists. Missed or coalesced events must only ever cost
  /// latency: see the governing rule on [LocalSource]'s own class doc via
  /// ticket 17
  /// (`.scratch/gallery-mode/issues/17-incremental-scan-and-observer.md`) -
  /// "no photo's backup status may ever depend on having received a
  /// notification".
  ///
  /// A broadcast stream: nothing here guarantees only one listener, though
  /// in practice [LocalScanService] is the only subscriber. Never emits on a
  /// platform with no underlying observer mechanism - there simply are no
  /// events, which is indistinguishable from (and exactly as safe as) every
  /// notification having been missed.
  Stream<void> get changes;

  /// The current grant, without prompting for it. Ticket 16's degraded-mode
  /// warning and its "everything is backed up" guard both read this rather
  /// than inferring the grant from how many photos [fullScan] returned - an
  /// empty selection under a partial grant must not be mistaken for denial.
  Future<LocalPermissionStatus> permissionStatus();

  /// Asks the platform for access, or - if a partial grant already exists -
  /// re-opens whatever the platform offers for changing it (Android 14 shows
  /// its selected-photos picker again rather than the original three-way
  /// dialog once a partial grant is already in place). Resolves to the grant
  /// that results, so the caller never has to poll [permissionStatus]
  /// separately to find out what the user just did.
  Future<LocalPermissionStatus> requestPermission();

  /// Opens the platform's own settings screen for this app's permissions -
  /// the only reliable route from a partial grant to full access on Android,
  /// since [requestPermission] re-shown after a partial grant offers more
  /// selection, not a way back to "allow all".
  Future<void> openAppSettings();

  /// Ticket 28's grid thumbnail: the actual pixel bytes for the photo
  /// identified by [relativePath]/[displayName], sized close to
  /// [width]x[height] rather than decoded at full resolution and scaled
  /// down - on Android this is exactly `ContentResolver.loadThumbnail`,
  /// which also uses the system thumbnail cache.
  ///
  /// Identified by the same durable local identity fields the mirror
  /// persists ([relativePath], [displayName]) rather than
  /// [LocalMediaItem.mediaStoreId] - the id is only a same-scan hint (see
  /// the class doc above) and is never persisted, so by render time - which
  /// can be long after the scan that found this photo - it may already
  /// point at the wrong row or none at all. Re-resolving from the durable
  /// identity on every call is what makes a changed id, or a file moved and
  /// recreated between scan and render, resolve correctly instead of
  /// silently reading the wrong (or a deleted) file.
  ///
  /// Returns null - never throws - when the photo cannot currently be
  /// produced: permission revoked since the scan, the file deleted between
  /// scan and render, a corrupt file the platform's own decoder rejects, or
  /// no Local Source at all. Ticket 28's "failure is per-item and quiet":
  /// the caller's job is to fall back to a placeholder (or, for a Synced
  /// item, the cloud thumbnail) for that one item, never to treat this as
  /// an error that should propagate.
  Future<Uint8List?> loadThumbnail({
    required String relativePath,
    required String displayName,
    required int width,
    required int height,
  });

  /// Ticket 28's full-screen viewer: the original file's bytes, at full
  /// resolution. Same identity and the same quiet-failure contract as
  /// [loadThumbnail] - null, never a thrown error, when the photo cannot
  /// currently be read.
  Future<Uint8List?> loadOriginal({
    required String relativePath,
    required String displayName,
  });

  /// Releases whatever platform resources this instance holds - on Android,
  /// the method-channel handler backing [changes] and the [changes]
  /// controller itself.
  ///
  /// `setMethodCallHandler` is a single global slot per channel name:
  /// constructing a second [LocalSource] against the same channel without
  /// disposing the first silently steals its handler, and the first's
  /// [changes] stream then simply stops emitting forever - no error, nothing
  /// to observe. Calling [dispose] first turns that into a clean, observable
  /// stream close instead. [LocalScanService] (`local_scan_service.dart`)
  /// calls this from its own disposal path so a caller that creates more
  /// than one Local Source over its lifetime never hits the silent case.
  ///
  /// Must be safe to call more than once, and must leave [changes] unable to
  /// emit again afterward - a disposed source is inert, not merely
  /// "probably not going to be used again".
  void dispose();
}
