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
}
