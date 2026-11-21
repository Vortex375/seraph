import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_search_controller.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';

/// The square region (in pixels) of an [imageWidth] x [imageHeight] photo to
/// draw as a face avatar: centred on [box] (normalised 0..1), [margin] of the
/// face's longer side added around it, and shifted/shrunk to stay inside the
/// photo so edge faces are not stretched.
Rect faceCropRect(GalleryFaceBox box, double imageWidth, double imageHeight,
    {double margin = 0.4}) {
  final w = (box.x2 - box.x1) * imageWidth;
  final h = (box.y2 - box.y1) * imageHeight;
  final cx = (box.x1 + box.x2) / 2 * imageWidth;
  final cy = (box.y1 + box.y2) / 2 * imageHeight;
  final side = ((w > h ? w : h) * (1 + 2 * margin))
      .clamp(1.0, imageWidth < imageHeight ? imageWidth : imageHeight);
  final left = (cx - side / 2).clamp(0.0, imageWidth - side);
  final top = (cy - side / 2).clamp(0.0, imageHeight - side);
  return Rect.fromLTWH(left, top, side, side);
}

/// People in the user's photos: a grid of face crops; tap filters the main grid to
/// that person and returns to it, the edit icon renames.
class GalleryPeopleView extends StatefulWidget {
  const GalleryPeopleView({super.key});

  @override
  State<GalleryPeopleView> createState() => _GalleryPeopleViewState();
}

class _GalleryPeopleViewState extends State<GalleryPeopleView> {
  final GallerySearchController search = Get.find();
  final GalleryImageLoader loader = Get.find();

  @override
  void initState() {
    super.initState();
    search.loadChips();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('People')),
      body: Obx(() {
        final people = search.people.toList();
        if (people.isEmpty) return const Center(child: Text('No people yet'));
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 160,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 0.78,
          ),
          itemCount: people.length,
          itemBuilder: (context, i) => _tile(context, people[i]),
        );
      }),
    );
  }

  Widget _tile(BuildContext context, GalleryPerson p) {
    final label = p.name.isEmpty ? 'Unnamed' : p.name;
    return InkWell(
      onTap: () async {
        final nav = Navigator.of(context);
        final messenger = ScaffoldMessenger.of(context);
        if (await search.filterByPerson(Get.find(), p)) {
          nav.pop();
        } else {
          messenger.showSnackBar(
              const SnackBar(content: Text('Could not load that person')));
        }
      },
      child: Column(
        children: [
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: ClipOval(child: FaceAvatar(person: p, loader: loader)),
            ),
          ),
          Row(children: [
            Expanded(
              child: Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center),
            ),
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 16,
                tooltip: 'Rename',
                icon: const Icon(Icons.edit),
                onPressed: () => _rename(context, p),
              ),
            ),
          ]),
          Text('${p.photoCount} photos',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, GalleryPerson p) async {
    final controller = TextEditingController(text: p.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename person'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Name'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    if (!await search.renamePerson(p.id, name) && mounted) {
      ScaffoldMessenger.of(this.context)
          .showSnackBar(const SnackBar(content: Text('Could not rename')));
    }
  }
}

/// A person's face: the cover photo's thumbnail cropped to the face box.
class FaceAvatar extends StatefulWidget {
  const FaceAvatar({super.key, required this.person, required this.loader});

  final GalleryPerson person;
  final GalleryImageLoader loader;

  @override
  State<FaceAvatar> createState() => _FaceAvatarState();
}

class _FaceAvatarState extends State<FaceAvatar> {
  ImageStream? _stream;
  ImageStreamListener? _listener;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    final cover = widget.person.cover;
    if (cover == null) return;
    _stream = GalleryImage(
      loader: widget.loader,
      providerId: cover.providerId,
      path: cover.path,
      size: galleryThumbnailSize,
    ).resolve(ImageConfiguration.empty);
    _listener = ImageStreamListener((info, _) {
      if (mounted) setState(() => _image = info.image);
    }, onError: (_, __) {});
    _stream!.addListener(_listener!);
  }

  @override
  void dispose() {
    if (_listener != null) _stream?.removeListener(_listener!);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    final box = widget.person.cover?.box;
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: image == null || box == null
          ? const Icon(Icons.person)
          : CustomPaint(
              painter: _FacePainter(
                  image,
                  faceCropRect(
                      box, image.width.toDouble(), image.height.toDouble())),
            ),
    );
  }
}

class _FacePainter extends CustomPainter {
  _FacePainter(this.image, this.src);

  final ui.Image image;
  final Rect src;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(image, src, Offset.zero & size,
        Paint()..filterQuality = FilterQuality.medium);
  }

  @override
  bool shouldRepaint(_FacePainter old) => old.image != image || old.src != src;
}
