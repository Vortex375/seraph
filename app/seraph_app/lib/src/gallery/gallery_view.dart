
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

  @override
  void initState() {
    super.initState();
    _loadFolders();
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
          trailing: IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Remove',
            onPressed: () => _removeFolder(folder),
          ),
        );
      },
    );
  }
}
