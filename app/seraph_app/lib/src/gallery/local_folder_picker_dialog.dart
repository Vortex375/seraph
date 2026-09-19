import 'package:flutter/material.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';

/// Ticket 18's device-side half of the Sync Pair picker: lets the user pick
/// the Local Source a new Sync Pair uploads from, from the same folders the
/// *On this device* section already lists ([GalleryMirror.listLocalFolders])
/// - so a folder can only be picked here if the device has already seen at
/// least one photo in it, exactly like that section's own list. There is
/// nothing to browse into - a MediaStore `RELATIVE_PATH` is already the full
/// folder identifier, unlike a Seraph path, which is why this dialog has no
/// up/down navigation the way [FolderPickerDialog] (`folder_picker_dialog
/// .dart`) does for the cloud side.
///
/// Folders already covered by another Sync Pair are shown but disabled,
/// with the reason inline, rather than omitted - so the user sees why a
/// folder is missing from their options instead of wondering if the scan
/// simply has not found it yet.
class LocalFolderPickerDialog extends StatefulWidget {
  const LocalFolderPickerDialog({super.key, required this.mirror});

  final GalleryMirror mirror;

  @override
  State<LocalFolderPickerDialog> createState() =>
      _LocalFolderPickerDialogState();
}

class _LocalFolderPickerDialogState extends State<LocalFolderPickerDialog> {
  List<LocalFolder> _folders = [];
  Set<String> _alreadyPaired = {};
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final folders = await widget.mirror.listLocalFolders();
      final pairs = await widget.mirror.listSyncPairs();
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _alreadyPaired = pairs.map((p) => p.localFolderPath).toSet();
      });
    } catch (e) {
      _error = 'Failed to load device folders: $e';
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  /// A folder already covered by another pair if it is exactly one, or a
  /// parent/child of one - matches [GalleryMirror.createSyncPair]'s own
  /// overlap check, so a folder disabled here is never one the create call
  /// would then go on to refuse for a different reason.
  bool _isCoveredByExistingPair(String folderPath) {
    for (final paired in _alreadyPaired) {
      if (folderPath == paired ||
          folderPath.startsWith(paired) ||
          paired.startsWith(folderPath)) {
        return true;
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select device folder'),
      content: SizedBox(
        width: double.maxFinite,
        height: 400,
        child: _buildContent(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
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
            FilledButton(onPressed: _load, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_folders.isEmpty) {
      return const Center(
        child: Text('No photo folders found on this device yet.'),
      );
    }

    return ListView.builder(
      itemCount: _folders.length,
      itemBuilder: (context, index) {
        final folder = _folders[index];
        final covered = _isCoveredByExistingPair(folder.path);
        return ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: Text(folder.path),
          subtitle: Text(covered
              ? 'Already used by another Sync Pair'
              : '${folder.photoCount} photo${folder.photoCount == 1 ? '' : 's'}'),
          enabled: !covered,
          onTap: covered
              ? null
              : () => Navigator.of(context).pop(folder.path),
        );
      },
    );
  }
}
