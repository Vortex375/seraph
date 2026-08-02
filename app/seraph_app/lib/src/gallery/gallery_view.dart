
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/gallery/folder_picker_dialog.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_service.dart';

/// Gallery Mode.
///
/// For now this shows only the Gallery Source Folders - the folders in Seraph
/// whose photos will appear here. The photo grid itself follows later.
class GalleryView extends StatefulWidget {

  static const routeName = '/gallery';

  const GalleryView({super.key});

  @override
  State<GalleryView> createState() => _GalleryViewState();
}

class _GalleryViewState extends State<GalleryView> {
  final GalleryService galleryService = Get.find();

  List<GallerySourceFolder> _folders = [];
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

      for (final id in _watchingRescan.toList()) {
        final match = folders.where((f) => f.id == id);
        final stillRunning = match.isNotEmpty && match.first.rescanRunning;
        if (!stillRunning) {
          _watchingRescan.remove(id);
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
      appBar: seraphAppBar(context,
        name: 'Gallery',
        routeName: GalleryView.routeName,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: _loadFolders,
          ),
        ]
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

    if (_folders.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            'No gallery folders yet.\n\n'
            'Add a folder to show its photos in Gallery Mode.',
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return ListView.builder(
      itemCount: _folders.length,
      itemBuilder: (context, index) {
        final folder = _folders[index];
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
      },
    );
  }
}
