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
    return ListView(
      children: [
        _sectionHeader('In Seraph'),
        if (_folders.isEmpty)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No gallery folders yet.\n\n'
              'Add a folder to show its photos in Gallery Mode.',
              textAlign: TextAlign.center,
            ),
          )
        else
          ..._folders.map(_buildCloudFolderTile),
        if (_hasLocalSource) ...[
          const Divider(height: 32),
          _sectionHeader('On this device'),
          if (_localFolders.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No photo folders found on this device yet.',
                textAlign: TextAlign.center,
              ),
            )
          else
            ..._localFolders.map(_buildLocalFolderTile),
          const Divider(height: 32),
          // Ticket 18: a third section, present only where the device
          // section itself is - "Configuration is unavailable on platforms
          // without a Local Source implementation, rather than present and
          // broken" is the same criterion for both.
          _sectionHeader('Sync Pairs', onAdd: _addSyncPair),
          if (_syncPairs.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No Sync Pairs yet.\n\n'
                'Add one to back up a device folder to Seraph.',
                textAlign: TextAlign.center,
              ),
            )
          else
            ..._syncPairs.map(_buildSyncPairTile),
        ],
      ],
    );
  }

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
  /// to and how many photos it covers").
  Widget _buildSyncPairTile(SyncPair pair) {
    return ListTile(
      leading: const Icon(Icons.sync_alt),
      title: Text('${pair.localFolderPath} -> ${pair.seraphDisplayPath}'),
      subtitle: Text(
          '${pair.photoCount} photo${pair.photoCount == 1 ? '' : 's'} covered'),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Remove Sync Pair',
        onPressed: () => _removeSyncPair(pair),
      ),
    );
  }
}
