import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/folder_picker_dialog.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/local/local_scan_service.dart';
import 'package:seraph_app/src/gallery/local_folder_picker_dialog.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';
import 'package:seraph_app/src/gallery/sync/gallery_backup_schedule_coordinator.dart';
import 'package:seraph_app/src/gallery/sync/gallery_data_sync_controller.dart';
import 'package:seraph_app/src/settings/settings_controller.dart';

/// Which folders feed Gallery Mode - *In Seraph* (what this screen has always
/// shown), on a device with a Local Source, *On this device* (ticket 29):
/// which of the phone's own photo folders are a Local Folder, and (ticket
/// 18) *Sync Pairs*: which device folder uploads to which Seraph folder.
///
/// This used to be all Gallery Mode had; now that the grid itself exists,
/// choosing the folders is configuration and lives behind the gallery rather
/// than in front of it.
class GallerySourceFoldersView extends StatefulWidget {

  static const routeName = '/gallery/folders';

  const GallerySourceFoldersView({super.key});

  @override
  State<GallerySourceFoldersView> createState() =>
      _GallerySourceFoldersViewState();
}

class _GallerySourceFoldersViewState extends State<GallerySourceFoldersView> {
  final GalleryService galleryService = Get.find();

  /// Null in any test/build that never registers a mirror at all - treated
  /// exactly like [_hasLocalSource] being false, so the device section stays
  /// absent rather than erroring.
  final GalleryMirror? _mirror =
      Get.isRegistered<GalleryMirror>() ? Get.find<GalleryMirror>() : null;
  final LocalScanService? _localScanService =
      Get.isRegistered<LocalScanService>()
          ? Get.find<LocalScanService>()
          : null;

  /// Ticket 22: null in any test/build that never registers one - treated
  /// exactly like [_mirror] being null, so the Backup section stays absent
  /// rather than erroring. Even when registered,
  /// [GalleryDataSyncController.isSupported] is what actually decides
  /// whether the section shows anything - see [_buildBody].
  final GalleryDataSyncController? _dataSyncController =
      Get.isRegistered<GalleryDataSyncController>()
          ? Get.find<GalleryDataSyncController>()
          : null;

  /// Ticket 24: null in exactly the same tests/builds [_dataSyncController]
  /// is null in - used both to keep WorkManager's scheduled triggers current
  /// after a Sync Pair changes ([_syncBackupSchedule]) and, together with
  /// [_settingsController], to show the constraint toggles in
  /// [_BackupConstraintsSection].
  final GalleryBackupScheduleCoordinator? _scheduleCoordinator =
      Get.isRegistered<GalleryBackupScheduleCoordinator>()
          ? Get.find<GalleryBackupScheduleCoordinator>()
          : null;

  final SettingsController? _settingsController =
      Get.isRegistered<SettingsController>()
          ? Get.find<SettingsController>()
          : null;

  /// Whether this platform has a Local Source at all (Android, with the
  /// native side present) - the ticket 29 criterion for showing *On this
  /// device* "rather than present and empty". iOS, desktop, web, and any
  /// test that registers no [LocalScanService], all read false here.
  bool get _hasLocalSource => _localScanService?.localSource != null;

  List<GallerySourceFolder> _folders = [];
  List<LocalFolder> _localFolders = [];
  List<SyncPair> _syncPairs = [];
  bool _isLoading = true;
  String? _error;

  // Ids of folders whose rescan we are actively polling for completion, so
  // we can tell the user once RescanRunning flips back to false server-side.
  final Set<String> _watchingRescan = {};
  Timer? _rescanPollTimer;

  @override
  void initState() {
    super.initState();
    _loadFolders();
  }

  @override
  void dispose() {
    _rescanPollTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadFolders() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      _folders = await galleryService.listSourceFolders();
      if (_hasLocalSource) {
        _localFolders = await _mirror!.listLocalFolders();
        _syncPairs = await _mirror.listSyncPairs();
      }
    } catch (e) {
      _error = 'Failed to load gallery folders: $e';
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// Flips [folder]'s selection and re-reads the mirror's folder list, then
  /// tells the grid to re-read the mirror too - ticket 29's "reflects
  /// immediately without a rescan": [GalleryGridController.reload] only
  /// re-reads what [GalleryMirror] already has, unlike [_resyncGallery]'s
  /// [GalleryGridController.syncNow], which would run a real (and here
  /// entirely unnecessary) Local Source scan and delta-feed poll.
  Future<void> _toggleLocalFolder(LocalFolder folder, bool selected) async {
    final mirror = _mirror;
    if (mirror == null) {
      return;
    }
    await mirror.setLocalFolderSelected(folder.path, selected);
    final updated = await mirror.listLocalFolders();
    if (!mounted) {
      return;
    }
    setState(() {
      _localFolders = updated;
    });
    if (Get.isRegistered<GalleryGridController>()) {
      unawaited(Get.find<GalleryGridController>().reload());
    }
  }

  /// The set of source folders decides what the gallery contains, so a change
  /// here has to reach the grid. Re-syncing is what turns a newly added
  /// folder's backfill into rows in the local mirror.
  void _resyncGallery() {
    if (Get.isRegistered<GalleryGridController>()) {
      unawaited(Get.find<GalleryGridController>().syncNow());
    }
  }

  Future<void> _addFolder() async {
    final picked = await showDialog<PickedFolder>(
      context: context,
      builder: (context) => const FolderPickerDialog(),
    );

    if (picked == null) {
      return;
    }

    try {
      await galleryService.addSourceFolder(picked.spaceProviderId, picked.path);
    } catch (e) {
      _showMessage('Failed to add folder: $e');
      return;
    }
    await _loadFolders();
    _resyncGallery();
  }

  Future<void> _removeFolder(GallerySourceFolder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove folder?'),
        content: Text(
            'Photos in ${folder.displayPath} will no longer appear in Gallery Mode. '
            'No files are deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true) {
      return;
    }

    try {
      await galleryService.removeSourceFolder(folder.id);
    } catch (e) {
      _showMessage('Failed to remove folder: $e');
      return;
    }
    await _loadFolders();
    _resyncGallery();
  }

  /// Ticket 18: picks a device folder (from what the mirror already knows -
  /// [LocalFolderPickerDialog]), then a Seraph folder (the same
  /// [FolderPickerDialog] *In Seraph* uses), adds the Seraph side as a
  /// Gallery Source Folder, then creates the Sync Pair itself.
  ///
  /// The Gallery Source Folder call runs first: it is idempotent and
  /// harmless to leave in place even if the pair creation that follows it
  /// fails, whereas creating a local Sync Pair the server side never learned
  /// about would be a state this screen could not represent honestly.
  Future<void> _addSyncPair() async {
    final mirror = _mirror;
    if (mirror == null) {
      return;
    }

    final localFolderPath = await showDialog<String>(
      context: context,
      builder: (context) => LocalFolderPickerDialog(mirror: mirror),
    );
    if (localFolderPath == null || !mounted) {
      return;
    }

    final picked = await showDialog<PickedFolder>(
      context: context,
      builder: (context) => const FolderPickerDialog(),
    );
    if (picked == null) {
      return;
    }

    try {
      await galleryService.addSourceFolder(picked.spaceProviderId, picked.path);
    } catch (e) {
      _showMessage('Failed to add folder: $e');
      return;
    }

    try {
      await mirror.createSyncPair(
        localFolderPath: localFolderPath,
        spaceProviderId: picked.spaceProviderId,
        path: picked.path,
      );
    } on SyncPairConflictException {
      _showMessage(
          '$localFolderPath is already used by another Sync Pair - a '
          'device folder can only back up to one place.');
      return;
    } catch (e) {
      _showMessage('Failed to create Sync Pair: $e');
      return;
    }

    await _loadFolders();
    _resyncGallery();
    unawaited(_syncBackupSchedule());
  }

  /// Ticket 24: re-evaluates what WorkManager has scheduled after anything
  /// that can change the answer - a Sync Pair created, removed or
  /// retargeted. Never awaited by its callers: rescheduling talks to the
  /// platform's WorkManager plugin, which this screen's own responsiveness
  /// should never wait on, and a failure here has no useful UI action to
  /// take beyond what the next call already retries.
  Future<void> _syncBackupSchedule() async {
    await _scheduleCoordinator?.syncSchedule();
  }

  Future<void> _removeSyncPair(SyncPair pair) async {
    final mirror = _mirror;
    if (mirror == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove Sync Pair?'),
        content: Text(
            '${pair.localFolderPath} will stop uploading to ${pair.seraphDisplayPath}. '
            'Photos already there stay put, and ${pair.seraphDisplayPath} stays '
            'in Gallery folders.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    await mirror.removeSyncPair(pair.id);
    await _loadFolders();
    unawaited(_syncBackupSchedule());
  }

  /// Ticket 21: retargeting, spelled out in the UI exactly as the spec
  /// requires - "delete-pair-plus-create-pair" - rather than left for the
  /// user to notice they can do by removing and re-adding by hand.
  ///
  /// Picks a new Seraph folder, states plainly what will and will not
  /// happen (photos already at [pair]'s current target stay there; only new
  /// photos go to the new one) and only THEN performs the two calls: add
  /// the new folder as a Gallery Source Folder, remove the old pair
  /// ([GalleryMirror.removeSyncPair] keeps it as a historical target - see
  /// that method's doc - it is not simply gone), create the new one for the
  /// SAME Local Source. The new Gallery Source Folder call runs first, for
  /// the same reason [_addSyncPair] orders it first: idempotent and
  /// harmless to leave in place even if a later step fails, whereas a local
  /// pair pointing at a folder the server never learned about is a state
  /// this screen could not represent honestly.
  Future<void> _retargetSyncPair(SyncPair pair) async {
    final mirror = _mirror;
    if (mirror == null) {
      return;
    }

    final picked = await showDialog<PickedFolder>(
      context: context,
      builder: (context) => const FolderPickerDialog(),
    );
    if (picked == null || !mounted) {
      return;
    }
    final newDisplayPath = picked.path == '/'
        ? '/${picked.spaceProviderId}'
        : '/${picked.spaceProviderId}${picked.path}';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Retarget Sync Pair?'),
        content: Text(
            '${pair.localFolderPath} will back up to $newDisplayPath from now on.\n\n'
            'Photos already backed up to ${pair.seraphDisplayPath} stay exactly '
            'where they are - only NEW photos go to $newDisplayPath.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Retarget'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }

    try {
      await galleryService.addSourceFolder(picked.spaceProviderId, picked.path);
    } catch (e) {
      _showMessage('Failed to add folder: $e');
      return;
    }

    await mirror.removeSyncPair(pair.id);
    try {
      await mirror.createSyncPair(
        localFolderPath: pair.localFolderPath,
        spaceProviderId: picked.spaceProviderId,
        path: picked.path,
      );
    } catch (e) {
      _showMessage('Failed to create the new Sync Pair: $e');
      await _loadFolders();
      return;
    }

    await _loadFolders();
    _resyncGallery();
    unawaited(_syncBackupSchedule());
  }

  /// Triggers a genuine File Provider re-scan of [folder] and starts polling
  /// so the user learns both that it started and when it finished - the
  /// server itself only reports current state (RescanRunning), so "finished"
  /// is observed by polling until it flips back to false rather than any
  /// push notification.
  Future<void> _rescanFolder(GallerySourceFolder folder) async {
    try {
      await galleryService.rescanSourceFolder(folder.id);
    } catch (e) {
      _showMessage('Failed to start rescan: $e');
      return;
    }
    _showMessage('Rescanning ${folder.displayPath}…');
    _watchingRescan.add(folder.id);
    await _loadFolders();
    _scheduleRescanPoll();
  }

  /// Polls listSourceFolders every few seconds while any folder in
  /// _watchingRescan still reports RescanRunning, so the "rescan finished"
  /// message appears without the user needing to manually refresh.
  void _scheduleRescanPoll() {
    _rescanPollTimer?.cancel();
    if (_watchingRescan.isEmpty) {
      return;
    }
    _rescanPollTimer = Timer(const Duration(seconds: 3), () async {
      if (!mounted) {
        return;
      }
      List<GallerySourceFolder> folders;
      try {
        folders = await galleryService.listSourceFolders();
      } catch (_) {
        // transient failure: try again on the next tick rather than giving up
        _scheduleRescanPoll();
        return;
      }
      if (!mounted) {
        return;
      }

      var anyFinished = false;
      for (final id in _watchingRescan.toList()) {
        final match = folders.where((f) => f.id == id);
        final stillRunning = match.isNotEmpty && match.first.rescanRunning;
        if (!stillRunning) {
          _watchingRescan.remove(id);
          anyFinished = true;
          final displayPath =
              match.isNotEmpty ? match.first.displayPath : null;
          _showMessage(displayPath != null
              ? 'Rescan of $displayPath finished.'
              : 'Rescan finished.');
        }
      }

      setState(() {
        _folders = folders;
      });

      if (anyFinished) {
        _resyncGallery();
      }

      _scheduleRescanPoll();
    });
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gallery folders'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadFolders,
          ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: _addFolder,
        tooltip: 'Add folder',
        child: const Icon(Icons.create_new_folder),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _loadFolders,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    // Two sections (ticket 29): *In Seraph* (unconditional - this is what the
    // screen has always shown) and, only where this device has a Local
    // Source, *On this device*. The device section is omitted entirely
    // rather than shown empty when there is no Local Source at all - the
    // criterion is "no Local Source", not "no folders yet".
    //
    // A CustomScrollView (not a ListView) so the Backup failure list can be
    // a virtualized SliverList - a ListView would build the whole failure
    // Card (every row, in one Column, in one frame) the moment the card
    // scrolled into view, which freezes the page once failures reach the
    // thousands. Slivers let only the rows actually on screen build.
    return CustomScrollView(
      slivers: [
        _sliverBox(_sectionHeader('In Seraph')),
        if (_folders.isEmpty)
          _sliverBox(const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No gallery folders yet.\n\n'
              'Add a folder to show its photos in Gallery Mode.',
              textAlign: TextAlign.center,
            ),
          ))
        else
          SliverList(
            delegate: SliverChildListDelegate(
                _folders.map(_buildCloudFolderTile).toList()),
          ),
        if (_hasLocalSource) ...[
          _sliverBox(const Divider(height: 32)),
          _sliverBox(_sectionHeader('On this device')),
          if (_localFolders.isEmpty)
            _sliverBox(const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No photo folders found on this device yet.',
                textAlign: TextAlign.center,
              ),
            ))
          else
            SliverList(
              delegate: SliverChildListDelegate(
                  _localFolders.map(_buildLocalFolderTile).toList()),
            ),
          _sliverBox(const Divider(height: 32)),
          // Ticket 18: a third section, present only where the device
          // section itself is - "Configuration is unavailable on platforms
          // without a Local Source implementation, rather than present and
          // broken" is the same criterion for both.
          _sliverBox(_sectionHeader('Sync Pairs', onAdd: _addSyncPair)),
          if (_syncPairs.isEmpty)
            _sliverBox(const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No Sync Pairs yet.\n\n'
                'Add one to back up a device folder to Seraph.',
                textAlign: TextAlign.center,
              ),
            ))
          else
            SliverList(
              delegate: SliverChildListDelegate(
                  _syncPairs.map(_buildSyncPairTile).toList()),
            ),
          // Ticket 22: the headless engine's start/pause and progress -
          // present only where Sync Pairs itself is (same "no Local Source,
          // no section" rule), since there is nothing to back up without
          // one, and hidden by _BackupSection itself
          // (GalleryDataSyncController.isSupported) rather than here, so a
          // test that never registers the controller sees exactly what a
          // platform with no Local Source sees.
          if (_dataSyncController != null) ...[
            _sliverBox(const Divider(height: 32)),
            _sliverBox(_BackupSection(controller: _dataSyncController)),
            // Ticket 25: the visible failure list - shown right under the
            // Backup card itself is, present only where that card is, since
            // there is nothing to fail without one. Returned as a sliver
            // (see _FailureListSection) so a list of thousands of failures
            // never builds in a single frame.
            _FailureListSection(controller: _dataSyncController),
          ],
          // Ticket 24: the constraints governing the SCHEDULED (unattended)
          // runs WorkManager triggers - distinct from the manual start/pause
          // above, which the user is looking at the screen for anyway. Shown
          // alongside it under the same "no Local Source, no section" rule,
          // gated on the settings controller being registered rather than on
          // the coordinator, since the toggles themselves only write
          // settings - [_syncBackupSchedule] is what actually needs the
          // coordinator, and is a no-op without one.
          if (_dataSyncController != null && _settingsController != null) ...[
            _sliverBox(const SizedBox(height: 8)),
            _sliverBox(_BackupConstraintsSection(
              settings: _settingsController,
              onChanged: _syncBackupSchedule,
            )),
          ],
        ],
      ],
    );
  }

  /// Wraps a single box widget as a sliver for the [CustomScrollView] above.
  Widget _sliverBox(Widget child) => SliverToBoxAdapter(child: child);

  Widget _sectionHeader(String title, {VoidCallback? onAdd}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold),
            ),
          ),
          if (onAdd != null)
            IconButton(
              icon: const Icon(Icons.add_circle_outline),
              tooltip: 'Add Sync Pair',
              onPressed: onAdd,
            ),
        ],
      ),
    );
  }

  Widget _buildCloudFolderTile(GallerySourceFolder folder) {
    return ListTile(
      leading: const Icon(Icons.photo_library),
      title: Text(folder.displayPath),
      subtitle: folder.rescanRunning ? const Text('Rescanning…') : null,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (folder.rescanRunning)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.sync),
              tooltip: 'Rescan folder',
              onPressed: () => _rescanFolder(folder),
            ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove',
            onPressed: () => _removeFolder(folder),
          ),
        ],
      ),
    );
  }

  /// One row of the *On this device* section: the folder's own path, how
  /// many device photos it holds (user story 106 - "choosing from evidence
  /// rather than from a folder name"), and a switch that selects or
  /// deselects it. A deselected folder stays right here, in the same list,
  /// so re-selecting it is always one tap away (user story 108) - nothing
  /// about this tile ever removes a row from [_localFolders].
  Widget _buildLocalFolderTile(LocalFolder folder) {
    return ListTile(
      leading: const Icon(Icons.folder_outlined),
      title: Text(folder.path),
      subtitle: Text(
          '${folder.photoCount} photo${folder.photoCount == 1 ? '' : 's'}'),
      trailing: Switch(
        value: folder.selected,
        onChanged: (value) => _toggleLocalFolder(folder, value),
      ),
    );
  }

  /// One Sync Pair (ticket 18): what it maps to - the device folder and the
  /// Seraph folder it uploads to - and how many photos it currently covers,
  /// per the acceptance criterion ("the pairs list shows what each pair maps
  /// to and how many photos it covers"). Ticket 21 adds retarget alongside
  /// remove - both change where FUTURE photos go, neither ever touches a
  /// photo already backed up.
  Widget _buildSyncPairTile(SyncPair pair) {
    return ListTile(
      leading: const Icon(Icons.sync_alt),
      title: Text('${pair.localFolderPath} -> ${pair.seraphDisplayPath}'),
      subtitle: Text(
          '${pair.photoCount} photo${pair.photoCount == 1 ? '' : 's'} covered'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.drive_file_move_outline),
            tooltip: 'Retarget Sync Pair',
            onPressed: () => _retargetSyncPair(pair),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove Sync Pair',
            onPressed: () => _removeSyncPair(pair),
          ),
        ],
      ),
    );
  }
}

/// Ticket 22: start/pause a backup run and watch its progress - "how many
/// photos remain and roughly how much data" (this ticket's own criterion),
/// mirrored in the Android notification the run also drives
/// (`gallery_sync_task_handler.dart`).
///
/// Reads everything from [GalleryDataSyncController.state], which is itself
/// nothing but a timer polling [GalleryMirror.syncRunState] - this widget
/// never talks to the engine or the platform service directly beyond
/// [GalleryDataSyncController.start]/[pause], and never assumes anything
/// about a run's progress beyond what the mirror currently says.
class _BackupSection extends StatelessWidget {
  const _BackupSection({required this.controller});

  final GalleryDataSyncController controller;

  @override
  Widget build(BuildContext context) {
    if (!controller.isSupported) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Obx(() {
        final state = controller.state.value;
        final remaining =
            (state.totalItems - state.completedItems - state.failedItems)
                .clamp(0, state.totalItems);
        final remainingMb =
            ((state.totalBytes - state.completedBytes) / (1024 * 1024))
                .clamp(0, double.infinity);
        final isRunning = state.status == syncStatusRunning;
        final isPaused = state.status == syncStatusPaused;

        String statusText;
        switch (state.status) {
          case syncStatusRunning:
            statusText = '$remaining photo${remaining == 1 ? '' : 's'} left '
                '(~${remainingMb.toStringAsFixed(1)} MB)';
            break;
          case syncStatusPaused:
            statusText = remaining > 0
                ? 'Paused - $remaining photo${remaining == 1 ? '' : 's'} left'
                : 'Paused';
            break;
          case syncStatusError:
            statusText = state.lastError ?? 'Backup could not start.';
            break;
          case syncStatusBackoff:
            // Ticket 25: distinct from both syncStatusError ("something
            // needs the user's attention") and syncStatusPaused ("the user
            // asked to stop") - nothing is misconfigured, and this WILL
            // retry itself once the cooldown passes.
            statusText = 'Seraph is not responding - retrying '
                'automatically.';
            break;
          case syncStatusCompleted:
            statusText = state.totalItems == 0
                ? 'Everything is backed up.'
                : 'Backup complete - ${state.completedItems} photo'
                    '${state.completedItems == 1 ? '' : 's'} sent'
                    '${state.failedItems > 0 ? ', ${state.failedItems} failed' : ''}.';
            break;
          default:
            statusText = 'Backup has not run yet.';
        }

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('Backup', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text(statusText, style: theme.textTheme.bodySmall),
                      // Ticket 24: "the time of the last successful pass is
                      // visible in the app, so silence is distinguishable
                      // from success" - shown regardless of [state.status],
                      // since the whole point is to still say something
                      // useful while a scheduled run is silently NOT
                      // happening (a constraint that never clears, a killed
                      // process) rather than only while one is in progress.
                      Text(
                        _lastBackupText(state.lastSuccessAt),
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.hintColor),
                      ),
                      if (state.totalItems > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: LinearProgressIndicator(
                            value: state.totalItems == 0
                                ? 0
                                : (state.completedItems + state.failedItems) /
                                    state.totalItems,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (isRunning)
                  IconButton(
                    icon: const Icon(Icons.pause_circle_outline),
                    tooltip: 'Pause backup',
                    onPressed: controller.pause,
                  )
                else
                  IconButton(
                    icon: const Icon(Icons.cloud_upload_outlined),
                    tooltip: isPaused ? 'Resume backup' : 'Start backup',
                    onPressed: controller.startBackup,
                  ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

/// Ticket 25's visible failure list: every item [GalleryDataSyncController.
/// failedItems] currently reports (a permanent failure - read-only Space,
/// out of storage, or similar - [GallerySyncEngine] gave up retrying on its
/// own), with the reason and a Retry action. Absent entirely when the list
/// is empty, the same "nothing to show, show nothing" convention the rest of
/// this screen's optional sections use - a failure list is not something a
/// user should have to check and find reassuringly blank.
///
/// Returned as a sliver, not a box: the list is virtualized via
/// [SliverList] + [SliverChildBuilderDelegate] so that only the rows
/// actually on screen are built. The failure list can grow to thousands of
/// items when many uploads permanently fail; a non-virtualized Column would
/// build every row in a single frame the moment the section scrolled into
/// view, freezing the page (Android shows the "unresponsive app" dialog).
/// The card-style background is preserved via [DecoratedSliver], which
/// paints behind the virtualized sliver's extent just as a [Card] would.
class _FailureListSection extends StatelessWidget {
  const _FailureListSection({required this.controller});

  final GalleryDataSyncController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Obx(() {
      final items = controller.failedItems;
      if (items.isEmpty) {
        return const SliverToBoxAdapter(child: SizedBox.shrink());
      }
      return SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: DecoratedSliver(
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(12),
          ),
          sliver: SliverPadding(
            padding: const EdgeInsets.all(12),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => index == 0
                    ? _buildHeader(theme, items.length)
                    : _buildFailureRow(theme, items[index - 1]),
                childCount: items.length + 1,
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildHeader(ThemeData theme, int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        'Backup failed for $count photo${count == 1 ? '' : 's'}',
        style: theme.textTheme.titleSmall,
      ),
    );
  }

  Widget _buildFailureRow(ThemeData theme, GalleryItem item) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  item.localDisplayName ?? 'Unknown photo',
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  item.uploadFailureReason ??
                      'Backup failed for an unknown reason.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => controller.retryFailedItem(item),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// "Never" for a fresh install/pair that has never once finished a run,
/// otherwise a short relative-time rendering of [lastSuccessAt] - deliberately
/// not just "since the app was last opened", because the whole point (ticket
/// 24's own criterion) is that this stays accurate for a run that happened
/// with the app closed.
String _lastBackupText(int? lastSuccessAt) {
  if (lastSuccessAt == null) {
    return 'Last backup: never';
  }
  final when = DateTime.fromMillisecondsSinceEpoch(lastSuccessAt);
  final age = DateTime.now().difference(when);
  final String relative;
  if (age.inMinutes < 1) {
    relative = 'just now';
  } else if (age.inMinutes < 60) {
    relative = '${age.inMinutes} min ago';
  } else if (age.inHours < 24) {
    relative = '${age.inHours} h ago';
  } else {
    relative = '${age.inDays} d ago';
  }
  return 'Last backup: $relative';
}

/// Ticket 24's constraint toggles: "the user can require unmetered network,
/// charging, and a battery threshold, and those choices are honoured" (this
/// ticket's own criterion). Purely a settings editor - it writes
/// [SettingsController] and calls [onChanged], never talks to
/// [GalleryBackupScheduler] itself, which is what keeps this widget testable
/// without a real WorkManager and keeps "what gets scheduled" in exactly one
/// place ([GalleryBackupScheduleCoordinator]).
class _BackupConstraintsSection extends StatelessWidget {
  const _BackupConstraintsSection({
    required this.settings,
    required this.onChanged,
  });

  final SettingsController settings;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text('Scheduled backup', style: theme.textTheme.titleSmall),
            ),
            Obx(() => SwitchListTile(
                  dense: true,
                  title: const Text('Wi-Fi / unmetered only'),
                  subtitle: const Text('Never use mobile data'),
                  value: settings.backupRequireUnmeteredNetwork.value,
                  onChanged: (value) {
                    settings.setBackupRequireUnmeteredNetwork(value);
                    unawaited(onChanged());
                  },
                )),
            Obx(() => SwitchListTile(
                  dense: true,
                  title: const Text('Only while charging'),
                  value: settings.backupRequireCharging.value,
                  onChanged: (value) {
                    settings.setBackupRequireCharging(value);
                    unawaited(onChanged());
                  },
                )),
            Obx(() => SwitchListTile(
                  dense: true,
                  title: const Text('Pause when battery is low'),
                  value: settings.backupRequireBatteryNotLow.value,
                  onChanged: (value) {
                    settings.setBackupRequireBatteryNotLow(value);
                    unawaited(onChanged());
                  },
                )),
          ],
        ),
      ),
    );
  }
}
