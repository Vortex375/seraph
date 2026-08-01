import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:webdav_client/webdav_client.dart';

/// The folder the user picked, in Space terms.
class PickedFolder {
  const PickedFolder(this.spaceProviderId, this.path);

  final String spaceProviderId;
  final String path;
}

/// Lets the user pick a folder by browsing the same tree the file browser
/// shows, using the same [FileService] to list directories.
///
/// The first path segment is the space provider; everything below it is the
/// path within that space. The picked folder is returned in those Space terms,
/// exactly as picked, so the server never has to translate it.
class FolderPickerDialog extends StatefulWidget {
  const FolderPickerDialog({super.key});

  @override
  State<FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<FolderPickerDialog> {
  final FileService fileService = Get.find();

  String _path = '';
  List<File> _folders = [];
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
      // the file browser lists the root as the empty path, so match it exactly
      final files = await fileService.readDir(_path);
      final folders = files.where((f) => f.isDir ?? false).toList();
      folders.sort((a, b) => (a.name ?? '').compareTo(b.name ?? ''));
      _folders = folders;
    } catch (e) {
      _error = 'Failed to load folders: $e';
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _enter(String name) {
    setState(() {
      _path = '$_path/$name';
    });
    _loadFolders();
  }

  void _goUp() {
    final split = _path.split('/');
    setState(() {
      _path = split.length <= 1 ? '' : split.sublist(0, split.length - 1).join('/');
    });
    _loadFolders();
  }

  /// Splits the browsed path into the space provider and the path within it.
  PickedFolder? _currentSelection() {
    final split = _path.split('/').where((s) => s.isNotEmpty).toList();
    if (split.isEmpty) {
      // the root lists spaces, not folders - nothing to select here
      return null;
    }
    final spaceProviderId = split.first;
    final rest = split.sublist(1);
    return PickedFolder(spaceProviderId, rest.isEmpty ? '/' : '/${rest.join('/')}');
  }

  @override
  Widget build(BuildContext context) {
    final selection = _currentSelection();

    return AlertDialog(
      title: const Text('Select Folder'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_upward),
                  tooltip: 'Up',
                  onPressed: _path.isEmpty ? null : _goUp,
                ),
                Expanded(
                  child: Text(
                    _path.isEmpty ? '/' : _path,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Divider(height: 1),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed:
              selection == null ? null : () => Navigator.of(context).pop(selection),
          child: const Text('Select'),
        ),
      ],
    );
  }

  Widget _buildContent() {
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
      return const Center(child: Text('No folders here'));
    }

    return ListView.builder(
      itemCount: _folders.length,
      itemBuilder: (context, index) {
        final folder = _folders[index];
        final name = folder.name ?? '';
        return ListTile(
          leading: const Icon(Icons.folder),
          title: Text(name),
          onTap: () => _enter(name),
        );
      },
    );
  }
}
