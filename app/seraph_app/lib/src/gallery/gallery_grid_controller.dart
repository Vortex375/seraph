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
///
/// **Ticket 29's sync cadence** lives entirely in [syncNow] and the private
/// helpers it calls, because this is the one place both the cloud poll and
/// the Local Source scan are already orchestrated together:
///
/// - [syncNow] itself is throttled ([syncThrottleWindow]) so that GetX's
///   `fenix: true` recreating this controller on every navigation back to
///   the gallery (see `initial_binding.dart`) does not mean every navigation
///   re-runs a full sync - the mirror is already current from the last one.
/// - Underneath that throttle, the Local Source scan is [LocalScanService.
///   incrementalScan] rather than [LocalScanService.scan] unless a full scan
///   has never run, is overdue by [fullScanBackstopInterval], or the caller
///   asked for one - see [_fullScanIsDue]'s doc for why those three
///   conditions and no others.
class GalleryGridController extends GetxController {
  GalleryGridController({
    required this.mirror,
    this.syncService,
    this.localScanService,
    this.pageSize = 120,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final GalleryMirror mirror;

  /// Ticket 29's clock seam: everything below that reasons about elapsed
  /// time (the sync throttle, the full-scan backstop) reads this instead of
  /// calling [DateTime.now] directly, so a test can drive both without
  /// actually waiting out a 60-second throttle or a 6-hour backstop.
  final DateTime Function() _now;

  /// How long a completed [syncNow] suppresses the next unforced one -
  /// ticket 29's throttle. 60 seconds is short enough that a user who
  /// genuinely wants to check again (the refresh button, which always
  /// forces) never feels blocked, and long enough that GetX recreating this
  /// controller on every navigation back to the gallery does not turn
  /// "glance at another tab and come back" into another full round trip.
  static const Duration syncThrottleWindow = Duration(seconds: 60);

  /// How long a full Local Source scan is allowed to go un-repeated before
  /// [syncNow] forces one anyway, throttle or no - ticket 29's backstop.
  /// See [_fullScanIsDue]'s doc for the tradeoff this interval is the
  /// visible cost of.
  static const Duration fullScanBackstopInterval = Duration(hours: 6);

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

  /// In-memory cache of [GalleryMirror.lastSyncedAt], primed once by [open]
  /// and kept current by [syncNow] itself. This exists solely so [syncNow]'s
  /// throttle check can be synchronous: [open] fires [syncNow] with
  /// `unawaited`, precisely so opening the gallery never blocks on a sync
  /// (see that call site's own comment), and [isSyncing] must still flip to
  /// `true` before [open] itself returns, exactly as it did before ticket 29
  /// - a caller awaiting [open] and immediately checking [isSyncing]
  /// (`gallery_grid_controller_test.dart`'s "opening does not wait for the
  /// delta feed") must keep seeing that. An `await` on the throttle's own
  /// mirror read, sitting between the call and that flip, would reintroduce
  /// exactly the race this cache exists to close - reading it from memory
  /// instead keeps the decision, and the flip, synchronous.
  int? _cachedLastSyncedAtMillis;

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
    // Primes the throttle cache - see [_cachedLastSyncedAtMillis]'s doc for
    // why this has to happen here, awaited, rather than inside [syncNow]
    // itself. One more indexed, local read alongside everything [reload]
    // already does; nothing here touches the network.
    _cachedLastSyncedAtMillis ??= await mirror.lastSyncedAt();
    // Ticket 17: the content-observer trigger only ever needs to be armed
    // once per controller lifetime, and [open] - unlike [onInit] - is what
    // both production (via [onInit]) and every mirror-seam test actually
    // call, so this is where it lives rather than in [onInit] itself.
    // [LocalScanService.watchForChanges] is idempotent, so a second [open]
    // (there is not one today, but nothing here relies on that) would not
    // double-subscribe.
    localScanService?.watchForChanges(() => unawaited(reload()));
    unawaited(syncNow());
  }

  @override
  void onClose() {
    // Releases ticket 17's observer subscription with this controller's own
    // lifecycle, so it never outlives the grid that asked for it - see
    // [LocalScanService.stopWatchingForChanges]'s doc for why leaving this
    // subscribed would be a leak.
    localScanService?.stopWatchingForChanges();
    super.onClose();
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
  ///
  /// **Ticket 29's throttle:** unless [force] is set, a call within
  /// [syncThrottleWindow] of the last completed sync returns immediately -
  /// no cloud request, no Local Source touched, [isSyncing] never flips.
  /// This is what makes GetX recreating this controller on every navigation
  /// back to the gallery (`fenix: true`, see the class doc) cheap: the
  /// mirror is already current, and re-reading it in [reload] is a fast
  /// indexed query regardless, but a *new* poll and scan on every glance
  /// back at the gallery is exactly the 30-second stall this ticket exists
  /// to remove. [force] is for the two callers that must bypass this
  /// unconditionally: the app bar's refresh button and
  /// [requestLocalPermission] (a newly granted or widened selection must
  /// show up immediately, never wait out the window).
  ///
  /// Forcing also always runs a full Local Source scan rather than
  /// [LocalScanService.incrementalScan] - see [_fullScanIsDue]'s doc for why
  /// "the caller asked for a fresh look" belongs on that list alongside cold
  /// start and the backstop interval.
  Future<void> syncNow({bool force = false}) async {
    final service = syncService;
    final scanner = localScanService;
    if ((service == null && scanner == null) || isSyncing.value) {
      return;
    }

    final now = _now();
    if (!force) {
      // Reads the in-memory cache, never the mirror directly - see
      // [_cachedLastSyncedAtMillis]'s doc for why this decision must stay
      // synchronous. [open] primes it before this can ever run unset; the
      // fallback below only matters for a [syncNow] called on a controller
      // that was somehow never opened, which is not a path production takes.
      final lastSyncedAt =
          _cachedLastSyncedAtMillis ??= await mirror.lastSyncedAt();
      final elapsed = now.millisecondsSinceEpoch - lastSyncedAt;
      if (lastSyncedAt != 0 && elapsed < syncThrottleWindow.inMilliseconds) {
        return;
      }
    }

    isSyncing.value = true;
    try {
      final runFullScan = force || await _fullScanIsDue(scanner);
      await Future.wait([
        _runCloudSync(service),
        _runLocalScan(scanner, full: runFullScan),
      ]);
      // Reading the mirror back and persisting the throttle watermark are
      // themselves guarded, on top of [_runCloudSync]/[_runLocalScan] each
      // already guarding their own work: this method's whole contract is
      // "failure is not fatal and deliberately not thrown" (see the class
      // doc above), and an unawaited [syncNow] (exactly how [open] calls it)
      // has no caller left to catch an exception escaping here - it would
      // surface as an unhandled error with nothing to show for it, rather
      // than the mirror simply keeping whatever the cloud/local steps above
      // just produced.
      try {
        await reload();
        await mirror.recordSyncedAt(now.millisecondsSinceEpoch);
        _cachedLastSyncedAtMillis = now.millisecondsSinceEpoch;
      } catch (_) {
        // Next call's throttle check falls back to whatever
        // [_cachedLastSyncedAtMillis] already held (unchanged here), so a
        // transient failure right at this last step costs a sync's worth of
        // one throttle-window latency, never correctness.
      }
    } finally {
      isSyncing.value = false;
    }
  }

  /// Ticket 16's "changing the grant while the app is running is picked up
  /// without requiring a restart", reconciled with ticket 29's throttle:
  /// [GalleryView]'s resume handler calls this instead of [syncNow]
  /// directly, because the throttle alone has no way to know the device
  /// photo-access grant changed while the app was backgrounded - it only
  /// ever looks at elapsed time. This re-reads [LocalScanService.
  /// permissionStatus] itself, compares it against [localPermission] (the
  /// grant as of the last completed sync), and forces - bypassing the
  /// throttle and running a full scan - exactly when they differ. Returning
  /// from system Settings, or the extended-selection picker, with a new
  /// grant is therefore never swallowed by a resume that happens to land
  /// inside the throttle window; a resume with no grant change is throttled
  /// exactly like any other [syncNow] call.
  Future<void> syncOnResume() async {
    final scanner = localScanService;
    if (scanner == null) {
      await syncNow();
      return;
    }
    final currentPermission = await scanner.permissionStatus();
    final permissionChanged = currentPermission != localPermission.value;
    await syncNow(force: permissionChanged);
  }

  /// Whether [syncNow] should run [LocalScanService.scan] (full) rather than
  /// [LocalScanService.incrementalScan] this time - true when, and only
  /// when no full scan has ever completed, or the last one predates
  /// [fullScanBackstopInterval]. [GalleryMirror.lastFullScanAt] answers
  /// both at once: `0` covers a genuine cold start *and* an app upgraded
  /// from before ticket 29's watermark existed (no row at all), and either
  /// way the right answer is "run one now".
  ///
  /// **Deliberately not also checking [GalleryMirror.localGeneration] for
  /// `0`**, even though the ticket this method implements
  /// (`.scratch/gallery-mode/issues/29-gallery-sync-latency-on-open-and-resume.md`)
  /// names that as its cold-start signal: [LocalScanService.scan] primes
  /// that watermark from [LocalSource.currentGeneration] after every full
  /// scan, including the very first one, and nothing about this codebase
  /// guarantees a platform's generation counter is ever non-zero - a fresh
  /// MediaStore instance reporting `0`, or a test's fake source left at its
  /// default, both prime the watermark AT `0` after a full scan that
  /// genuinely happened. Treating `0` there as "never scanned" would then
  /// force a full scan on *every* subsequent sync forever on such a
  /// platform - silently defeating this entire ticket for it. This
  /// ticket's own watermark, set only by a full scan actually completing
  /// (see [GalleryMirror.recordFullScanAt]'s doc), does not have that
  /// failure mode.
  ///
  /// This is ticket 17's governing rule turned into an actual schedule
  /// rather than removed: a full scan is still the only path that ever
  /// removes or demotes a device row (see [GalleryMirror.applyLocalScan]),
  /// so a device photo deleted outside the app can linger in the mirror -
  /// wrongly shown as still present - until whichever of these fires first,
  /// or a forced sync runs one sooner. That staleness window, at most
  /// [fullScanBackstopInterval], is this ticket's accepted tradeoff for not
  /// paying a full MediaStore scan's cost on every gallery open and resume;
  /// [LocalScanService.incrementalScan] cannot see deletions at all (its own
  /// doc explains why), so nothing short of a full scan could ever close
  /// this window to zero without giving up the latency win entirely.
  Future<bool> _fullScanIsDue(LocalScanService? scanner) async {
    if (scanner == null) {
      return false;
    }
    final lastFullScanAt = await mirror.lastFullScanAt();
    if (lastFullScanAt == 0) {
      return true;
    }
    final elapsed = _now().millisecondsSinceEpoch - lastFullScanAt;
    return elapsed >= fullScanBackstopInterval.inMilliseconds;
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

  Future<void> _runLocalScan(LocalScanService? scanner,
      {required bool full}) async {
    if (scanner == null) {
      return;
    }
    try {
      if (full) {
        await scanner.scan();
        await mirror.recordFullScanAt(_now().millisecondsSinceEpoch);
      } else {
        await scanner.incrementalScan();
      }
    } catch (_) {
      // Surfacing this to the user - e.g. "can't see the rest of your
      // photos" under a partial permission grant - is ticket 16's job (see
      // [localPermission]). Here the mirror simply keeps whatever the last
      // successful scan produced. A failed full scan also does not record
      // [GalleryMirror.recordFullScanAt] - see that method's doc for why.
    }
  }

  /// Asks for device photo access - or, under an existing partial grant,
  /// for more of it (Android 14 re-opens its selected-photos picker rather
  /// than the original dialog once some access already exists). A no-op on
  /// a platform with no Local Source.
  ///
  /// The explanation the user is owed (ticket 16's first criterion) is
  /// [GalleryView]'s job, shown before this is ever called - this method is
  /// only the request itself. Always followed by a forced [syncNow], so a
  /// newly granted or widened selection shows up immediately - bypassing
  /// both ticket 29's throttle and its incremental-scan default - rather
  /// than waiting for the next unforced sync.
  Future<void> requestLocalPermission() async {
    final scanner = localScanService;
    if (scanner == null) {
      return;
    }
    localPermission.value = await scanner.requestPermission();
    await syncNow(force: true);
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
    final lastPage =
        (last >= totalCount.value ? totalCount.value - 1 : last) ~/ pageSize;
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
      final date = await mirror.capturedAtAtOffset(index, filter: filter.value);
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
