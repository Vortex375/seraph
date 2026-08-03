import 'dart:async';

import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/local/local_source.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_sync_service.dart';

/// The gallery's list, as the grid and the full-screen viewer both see it.
///
/// Everything here is answered from the local mirror. The delta-feed sync
/// runs beside it, never in front of it: opening Gallery Mode reads the
/// mirror and paints, and whatever the server has to say arrives later and
/// refreshes what is already on screen. That is what makes scrolling back
/// through thousands of photos a sequence of indexed SQLite reads rather than
/// a sequence of round trips, and what makes the view open at the same speed
/// on the first launch after an update as on the hundredth.
///
/// Two properties the grid depends on, and why they are here rather than in
/// the widget:
///
/// - **The item count is taken once and then held.** The grid builds
///   [totalCount] tiles from the moment it opens, so a page arriving does not
///   change the list's length or its scroll extent - nothing shifts under the
///   user's thumb. A count only moves on an explicit [reload].
/// - **Pages are sparse, tiles are not.** An index whose page has not loaded
///   yet returns null from [itemAt] and renders as a placeholder of exactly
///   the same size as a loaded tile, so filling it in changes pixels and
///   never geometry.
class GalleryGridController extends GetxController {
  GalleryGridController({
    required this.mirror,
    this.syncService,
    this.localScanService,
    this.pageSize = 120,
  });

  final GalleryMirror mirror;

  /// Optional: a gallery that is only ever read (a test, or a device with no
  /// server configured) works without one.
  final GallerySyncService? syncService;

  /// Optional: drives one full Local Source scan into the mirror alongside
  /// the cloud sync (ticket 15). Null on a platform with no Local Source, or
  /// in a test that has nothing to do with device photos - the device half
  /// of the merged gallery is then simply absent, not broken.
  final LocalScanService? localScanService;

  /// How many items one mirror read pulls in. Comfortably more than a screen
  /// of tiles, so a fast flick usually lands inside an already-loaded page.
  final int pageSize;

  /// Number of items in the gallery, as of the last [reload]. The grid's
  /// item count.
  final RxInt totalCount = 0.obs;

  /// True until the first mirror read completes - a handful of milliseconds,
  /// not a network round trip.
  final RxBool isLoading = true.obs;

  /// True while a delta-feed poll is running in the background.
  final RxBool isSyncing = false.obs;

  /// Set when the last background sync failed. The gallery keeps working from
  /// the mirror regardless - this is information, not an error state.
  final Rxn<String> syncError = Rxn<String>();

  /// The Availability filter currently applied to [totalCount] and every
  /// loaded page - ticket 15's "filtered to items that are not backed up,
  /// and to Cloud only items". Ordering is never affected by this; only
  /// membership.
  final Rx<GalleryAvailabilityFilter> filter =
      Rx<GalleryAvailabilityFilter>(GalleryAvailabilityFilter.all);

  /// How many items are Device only, Synced and Cloud only, over the WHOLE
  /// gallery regardless of [filter] - the "one number to trust" summary.
  final Rx<GalleryAvailabilitySummary> summary = Rx<GalleryAvailabilitySummary>(
    const GalleryAvailabilitySummary(deviceOnly: 0, synced: 0, cloudOnly: 0),
  );

  /// The device photo-access grant, as of the last [reload] - ticket 16's
  /// degraded-mode state. [LocalPermissionStatus.unsupported] when there is
  /// no [localScanService] at all, which is every platform without a Local
  /// Source and every test that has nothing to do with device photos; the
  /// view shows no permission UI in that case, exactly as before this
  /// ticket.
  final Rx<LocalPermissionStatus> localPermission =
      Rx<LocalPermissionStatus>(LocalPermissionStatus.unsupported);

  /// Bumped whenever loaded items change, so views can rebuild without the
  /// item map itself having to be observable.
  final RxInt revision = 0.obs;

  final Map<int, GalleryItem> _items = {};
  final Set<int> _loadedPages = {};
  final Set<int> _pagesInFlight = {};
  final Map<int, DateTime> _dates = {};
  final Set<int> _datesInFlight = {};

  @override
  void onInit() {
    super.onInit();
    unawaited(open());
  }

  /// Reads the mirror and paints. Does not touch the network; [syncNow] does
  /// that, afterwards.
  Future<void> open() async {
    await reload();
    isLoading.value = false;
    unawaited(syncNow());
  }

  /// Re-reads the item count and drops every loaded page, so the next build
  /// re-reads what it needs. Called after a sync, or when the set of Gallery
  /// Source Folders changes.
  ///
  /// Named `reload` rather than `refresh` because [GetxController] already has
  /// a `refresh()` that means "rebuild the widgets bound to me" - a different
  /// thing, and one this must not quietly replace.
  Future<void> reload() async {
    final count = await mirror.totalCount(filter: filter.value);
    _items.clear();
    _loadedPages.clear();
    _dates.clear();
    totalCount.value = count;
    summary.value = await mirror.availabilitySummary();
    localPermission.value = await localScanService?.permissionStatus() ??
        LocalPermissionStatus.unsupported;
    revision.value++;
    await _loadPage(0);
  }

  /// Changes the Availability filter and reloads. A no-op if [value] is
  /// already the active filter, so a repeated tap on the same filter chip
  /// does not re-read the mirror for nothing.
  Future<void> setFilter(GalleryAvailabilityFilter value) async {
    if (filter.value == value) {
      return;
    }
    filter.value = value;
    await reload();
  }

  /// Runs one delta-feed poll and one Local Source scan, then refreshes from
  /// the mirror. The two run side by side - neither waits on the other - and
  /// each fails independently: a local scan error (permission revoked
  /// mid-run, a platform-channel failure) must not stop the cloud sync or
  /// crash the gallery, and vice versa.
  ///
  /// Failure is not fatal and deliberately not thrown: a gallery with no
  /// network, or no device access, shows what the mirror holds, which is the
  /// whole point of there being a mirror.
  Future<void> syncNow() async {
    final service = syncService;
    final scanner = localScanService;
    if ((service == null && scanner == null) || isSyncing.value) {
      return;
    }
    isSyncing.value = true;
    try {
      await Future.wait([
        _runCloudSync(service),
        _runLocalScan(scanner),
      ]);
      await reload();
    } finally {
      isSyncing.value = false;
    }
  }

  Future<void> _runCloudSync(GallerySyncService? service) async {
    if (service == null) {
      return;
    }
    try {
      await service.sync();
      syncError.value = null;
    } catch (e) {
      syncError.value = '$e';
    }
  }

  Future<void> _runLocalScan(LocalScanService? scanner) async {
    if (scanner == null) {
      return;
    }
    try {
      await scanner.scan();
    } catch (_) {
      // Surfacing this to the user - e.g. "can't see the rest of your
      // photos" under a partial permission grant - is ticket 16's job (see
      // [localPermission]). Here the mirror simply keeps whatever the last
      // successful scan produced.
    }
  }

  /// Asks for device photo access - or, under an existing partial grant,
  /// for more of it (Android 14 re-opens its selected-photos picker rather
  /// than the original dialog once some access already exists). A no-op on
  /// a platform with no Local Source.
  ///
  /// The explanation the user is owed (ticket 16's first criterion) is
  /// [GalleryView]'s job, shown before this is ever called - this method is
  /// only the request itself. Always followed by [syncNow], so a newly
  /// granted or widened selection shows up immediately rather than waiting
  /// for the next sync.
  Future<void> requestLocalPermission() async {
    final scanner = localScanService;
    if (scanner == null) {
      return;
    }
    localPermission.value = await scanner.requestPermission();
    await syncNow();
  }

  /// Opens the platform's settings screen for this app's permissions - the
  /// only reliable route from a partial grant to full access on Android. A
  /// no-op on a platform with no Local Source.
  Future<void> openLocalPermissionSettings() async {
    final scanner = localScanService;
    if (scanner == null) {
      return;
    }
    await scanner.openAppSettings();
  }

  /// The item at [index] in Capture Date order, newest first - or null if its
  /// page has not been read yet. Asking for a missing index schedules the
  /// read; the caller is expected to rebuild on [revision].
  GalleryItem? itemAt(int index) {
    final item = _items[index];
    if (item == null) {
      ensureLoaded(index);
    }
    return item;
  }

  /// Schedules a read of the page containing [index], if it is not loaded or
  /// already being read. Safe to call from a build method.
  void ensureLoaded(int index) {
    if (index < 0 || index >= totalCount.value) {
      return;
    }
    final page = index ~/ pageSize;
    if (_loadedPages.contains(page) || _pagesInFlight.contains(page)) {
      return;
    }
    unawaited(_loadPage(page));
  }

  /// Schedules reads covering every index in [first]..[last] inclusive, so a
  /// visible range spanning a page boundary loads both halves.
  void ensureRangeLoaded(int first, int last) {
    if (last < first) {
      return;
    }
    final firstPage = (first < 0 ? 0 : first) ~/ pageSize;
    final lastPage = (last >= totalCount.value ? totalCount.value - 1 : last) ~/
        pageSize;
    for (var page = firstPage; page <= lastPage; page++) {
      ensureLoaded(page * pageSize);
    }
  }

  Future<void> _loadPage(int page) async {
    if (_pagesInFlight.contains(page)) {
      return;
    }
    _pagesInFlight.add(page);
    try {
      final offset = page * pageSize;
      final rows = await mirror.queryItems(
        offset: offset,
        limit: pageSize,
        filter: filter.value,
      );
      for (var i = 0; i < rows.length; i++) {
        _items[offset + i] = rows[i];
        _dates[offset + i] =
            DateTime.fromMillisecondsSinceEpoch(rows[i].capturedAt * 1000);
      }
      _loadedPages.add(page);
      revision.value++;
    } finally {
      _pagesInFlight.remove(page);
    }
  }

  /// The Capture Date at [index], if it is already known - from a loaded page
  /// or from an earlier scrubber lookup.
  DateTime? knownDateAt(int index) => _dates[index];

  /// Asks the mirror for the Capture Date at [index] without loading its
  /// page. This is the scrubber's question: the user is dragging past
  /// thousands of items and wants to know where in history they are, faster
  /// than pages could possibly load.
  Future<DateTime?> dateAt(int index) async {
    final known = _dates[index];
    if (known != null) {
      return known;
    }
    if (index < 0 || index >= totalCount.value) {
      return null;
    }
    if (_datesInFlight.contains(index)) {
      return null;
    }
    _datesInFlight.add(index);
    try {
      final date =
          await mirror.capturedAtAtOffset(index, filter: filter.value);
      if (date != null) {
        _dates[index] = date;
        revision.value++;
      }
      return date;
    } finally {
      _datesInFlight.remove(index);
    }
  }
}
