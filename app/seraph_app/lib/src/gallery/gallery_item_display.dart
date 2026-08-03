import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

/// Where a Gallery Item's copies currently are - exactly one of *Device
/// only*, *Synced*, or *Cloud only* (see `CONTEXT.md`). Computed straight off
/// [GalleryItem.origin] rather than stored separately, so it can never
/// disagree with the row it describes.
enum GalleryAvailability { deviceOnly, synced, cloudOnly }

/// Presentation-level reading of a mirrored [GalleryItem].
///
/// This is deliberately plain logic over a mirror row rather than anything
/// living in a widget: ticket 13 requires gallery logic to be verified at the
/// mirror seam, so everything a tile or the viewer needs to decide - display
/// orientation, which Seraph folder an item lives in, how an undisplayable
/// item explains itself - is computed here and unit-tested against a
/// pre-populated mirror.
extension GalleryItemDisplay on GalleryItem {
  /// This item's Availability - Device only, Synced or Cloud only - read
  /// directly off [origin] (`'device'`, `'both'`, or anything else, which in
  /// practice is always `'cloud'`) with no join and no separate state to
  /// fall out of sync with it.
  GalleryAvailability get availability {
    switch (origin) {
      case 'device':
        return GalleryAvailability.deviceOnly;
      case 'both':
        return GalleryAvailability.synced;
      default:
        return GalleryAvailability.cloudOnly;
    }
  }

  /// [availability], spelled out - what a tile's tooltip and an item's
  /// details show.
  String get availabilityLabel {
    switch (availability) {
      case GalleryAvailability.deviceOnly:
        return 'Device only';
      case GalleryAvailability.synced:
        return 'Synced';
      case GalleryAvailability.cloudOnly:
        return 'Cloud only';
    }
  }

  /// True when the gallery service recorded that this file cannot be
  /// rendered. Such items still appear in the grid - "the gallery is an
  /// honest inventory rather than a filtered one" - with a placeholder
  /// carrying [unsupportedReasonLabel].
  bool get isUnsupported => unsupported.isNotEmpty;

  /// Ticket 20: true when this device has uploaded (or matched) this photo
  /// and is waiting for the delta feed to independently confirm it - CONTEXT
  /// .md's **Verified**, not yet true. [availability] is still [GalleryAvailability.deviceOnly]
  /// here (it must be - the item is not backed up yet, and never claiming
  /// otherwise is the whole point), so the UI reads this separately to show
  /// "in progress" rather than a plain "on this device" - user story 18:
  /// "shown as still in progress rather than as backed up".
  ///
  /// Reads [GalleryItems.uploadState]'s raw values directly (`'uploaded'`/
  /// `'mismatch'`, both truthy here - even a mismatch pending retry is still
  /// "in progress" from the user's point of view) rather than importing
  /// `gallery_mirror.dart`'s private constants, the same convention
  /// [availability] already follows for [origin]'s raw values.
  bool get isAwaitingVerification =>
      origin == 'device' &&
      (uploadState == 'uploaded' || uploadState == 'mismatch');

  /// True when this row carries a device copy - [GalleryAvailability.
  /// deviceOnly] or [GalleryAvailability.synced] - so the grid and the
  /// viewer can ask the Local Source seam (ticket 28,
  /// `.scratch/gallery-mode/issues/28-device-photo-previews.md`) for its
  /// actual pixels via [localRelativePath]/[localDisplayName], rather than
  /// falling straight to a placeholder or the cloud thumbnail.
  ///
  /// Read directly off the same two columns [GalleryMirror] populates
  /// together for both origins (`_upsertLocalItem`), never off [origin]
  /// itself, so this can never disagree with whether there is actually
  /// something to ask the Local Source for.
  bool get hasLocalCopy => localRelativePath != null && localDisplayName != null;

  /// A human-readable version of the server's `unsupported` reason code
  /// (`gallery/gallery/photo_entities.go`, `UnsupportedReason*`). An
  /// unrecognised code is surfaced verbatim rather than swallowed, so a
  /// reason added server-side still tells the user something.
  String get unsupportedReasonLabel {
    switch (unsupported) {
      case '':
        return '';
      case 'format':
        return 'This file format cannot be displayed';
      case 'corrupt':
        return 'This file could not be read - it looks truncated or corrupt';
      default:
        return 'This photo cannot be displayed ($unsupported)';
    }
  }

  /// True when the EXIF orientation is one of the quarter-turn values (5-8),
  /// so the pixels as stored are transposed relative to how the photo is
  /// meant to be seen.
  ///
  /// The stored [width]/[height] come from decoding the file's header and are
  /// therefore the RAW, unrotated dimensions. Both places that hand us actual
  /// pixels already apply the rotation - the thumbnailer decodes with
  /// `imaging.AutoOrientation(true)`, and Flutter's own image codec honours
  /// the EXIF orientation tag when decoding the original file - so nothing
  /// here rotates pixels a second time. What DOES need fixing up client-side
  /// is the aspect ratio we reserve for an image before its bytes arrive,
  /// which is what [displayWidth]/[displayHeight] are for.
  bool get isQuarterTurned => orientation >= 5 && orientation <= 8;

  /// Pixel width as the photo is displayed, i.e. after EXIF rotation.
  int get displayWidth => isQuarterTurned ? height : width;

  /// Pixel height as the photo is displayed, i.e. after EXIF rotation.
  int get displayHeight => isQuarterTurned ? width : height;

  /// Displayed aspect ratio, or null when the dimensions are unknown (an
  /// unsupported file, or an item still awaiting byte-level extraction).
  double? get displayAspectRatio {
    if (displayWidth <= 0 || displayHeight <= 0) {
      return null;
    }
    return displayWidth / displayHeight;
  }

  /// The item's Capture Date.
  ///
  /// The wire value is epoch SECONDS - the gallery service derives it with
  /// `time.Time.Unix()` (`gallery/gallery/ingest.go`, `resolveCaptureDate`)
  /// and the mirror stores what the feed sent, unconverted.
  DateTime get capturedAtDateTime =>
      DateTime.fromMillisecondsSinceEpoch(capturedAt * 1000);

  /// True when the Capture Date came from the photo's own EXIF
  /// DateTimeOriginal rather than from a fallback rung of the chain, so the
  /// UI can present a real capture date differently from a guess.
  bool get hasExifCaptureDate => capturedAtSource == 'exif';

  /// How the Capture Date was arrived at, in words - shown in an item's
  /// details so a fallback date is not mistaken for a real one.
  String get captureDateSourceLabel {
    switch (capturedAtSource) {
      case 'exif':
        return 'Taken (from the photo)';
      case 'modTime':
        return 'File modified (no date in the photo)';
      case 'indexed':
        return 'First seen by Seraph (no date available)';
      default:
        return 'Date';
    }
  }

  /// The file's own name, without any directory part.
  ///
  /// Falls back to [localDisplayName] for a Device only item, which has no
  /// [path] at all - MediaStore's display name is exactly this value already,
  /// so there is nothing to strip a directory off of.
  String get fileName {
    final p = path;
    if (p == null) {
      return localDisplayName ?? '';
    }
    final slash = p.lastIndexOf('/');
    return slash < 0 ? p : p.substring(slash + 1);
  }

  /// The directory this item lives in, as a path within its space.
  String get folderPath {
    final p = path ?? '';
    final slash = p.lastIndexOf('/');
    if (slash <= 0) {
      return '/';
    }
    return p.substring(0, slash);
  }

  /// Which Seraph folder this photo lives in, spelled exactly the way the
  /// file browser spells it - space provider followed by the path inside it -
  /// so the user can go and find the file again there or over WebDAV.
  String get folderDisplayPath {
    final provider = providerId ?? '';
    final folder = folderPath;
    return folder == '/' ? '/$provider' : '/$provider$folder';
  }

  /// The item's full location, provider included: what the preview and
  /// download endpoints take as their `p` parameter.
  String get spaceDisplayPath => '/${providerId ?? ''}${path ?? ''}';
}

const List<String> _monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// "August 2026" - the heading shown as the user scrolls, and the label the
/// date scrubber shows while being dragged. Month granularity is what
/// "roughly where in history the user is" asks for: finer headings churn on
/// every flick, coarser ones lose a year's worth of resolution.
String galleryMonthLabel(DateTime date) =>
    '${_monthNames[date.month - 1]} ${date.year}';

/// "12 August 2026" - a single item's date, for its details.
String galleryDayLabel(DateTime date) =>
    '${date.day} ${_monthNames[date.month - 1]} ${date.year}';
