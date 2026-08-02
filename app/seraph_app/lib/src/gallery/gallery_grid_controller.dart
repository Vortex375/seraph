import 'dart:async';

import 'package:get/get.dart';
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
    this.pageSize = 120,
  });

  final GalleryMirror mirror;

  /// Optional: a gallery that is only ever read (a test, or a device with no
  /// server configured) works without one.
  final GallerySyncService? syncService;

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
    final count = await mirror.totalCount();
    _items.clear();
    _loadedPages.clear();
    _dates.clear();
    totalCount.value = count;
    revision.value++;
    await _loadPage(0);
  }

  /// Runs one delta-feed poll and refreshes from the mirror afterwards.
  ///
  /// Failure is not fatal and deliberately not thrown: a gallery with no
  /// network shows what the mirror holds, which is the whole point of there
  /// being a mirror.
  Future<void> syncNow() async {
    final service = syncService;
    if (service == null || isSyncing.value) {
      return;
    }
    isSyncing.value = true;
    try {
      await service.sync();
      syncError.value = null;
      await reload();
    } catch (e) {
      syncError.value = '$e';
    } finally {
      isSyncing.value = false;
    }
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
      final rows = await mirror.queryItems(offset: offset, limit: pageSize);
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
      final date = await mirror.capturedAtAtOffset(index);
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
