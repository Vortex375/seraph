import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/file_browser/file_service.dart';
import 'package:seraph_app/src/media_player/audio_tags.dart';

/// [item]'s album art as a [size] square, or a placeholder while it loads and
/// when the file has none (the preview answers an error).
class AlbumArt extends StatelessWidget {
  const AlbumArt({super.key, required this.item, required this.size});

  final MediaItem? item;
  final double size;

  @override
  Widget build(BuildContext context) {
    final path = item == null ? null : mediaItemPath(item!);
    final placeholder = Container(
      width: size,
      height: size,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Icon(Icons.music_note, size: size / 2,
          color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
    if (path == null) {
      return placeholder;
    }
    final FileService fileService = Get.find();
    return ClipRRect(
      borderRadius: BorderRadius.circular(size > 64 ? 12 : 4),
      child: Image.network(
        fileService.getAlbumArtUrl(path),
        // the URL is the key: a new track gets a new image, not a fade
        key: ValueKey(path),
        headers: fileService.getRequestHeadersSync(),
        width: size,
        height: size,
        fit: BoxFit.cover,
        loadingBuilder: (context, child, progress) => progress == null ? child : placeholder,
        errorBuilder: (context, error, stackTrace) => placeholder,
      ),
    );
  }
}
