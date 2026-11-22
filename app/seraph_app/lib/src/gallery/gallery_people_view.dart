import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_search_controller.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';
import 'package:seraph_app/src/gallery/gallery_view.dart';

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
  static const routeName = '/gallery/people';

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
        if (await search.applyAi(Get.find(), person: p)) {
          // opened by URL there is no grid underneath to return to
          nav.canPop() ? nav.pop() : Get.offNamed(GalleryView.routeName);
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
    // names already in use by other clusters: typing one makes this cluster the same person
    final names = {
      for (final o in search.people)
        if (o.id != p.id && o.name.isNotEmpty) o.name
    }.toList()
      ..sort();
    var text = p.name;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename person'),
        content: SizedBox(
          width: 300,
          child: Autocomplete<String>(
            initialValue: TextEditingValue(text: p.name),
            optionsBuilder: (v) {
              final q = v.text.trim().toLowerCase();
              return q.isEmpty
                  ? const Iterable<String>.empty()
                  : names.where((n) => n.toLowerCase().contains(q));
            },
            onSelected: (v) => text = v,
            fieldViewBuilder: (context, controller, focus, submit) => TextField(
              controller: controller,
              focusNode: focus,
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Name'),
              onChanged: (v) => text = v,
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, text),
              child: const Text('Save')),
        ],
      ),
    );
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
    _resolve();
  }

  // the State is reused when a list reorders or filters, so follow the cover
  @override
  void didUpdateWidget(FaceAvatar old) {
    super.didUpdateWidget(old);
    final a = old.person.cover, b = widget.person.cover;
    if (a?.providerId != b?.providerId || a?.path != b?.path) {
      _release();
      _image = null;
      _resolve();
    }
  }

  void _resolve() {
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

  void _release() {
    if (_listener != null) _stream?.removeListener(_listener!);
    _stream = _listener = null;
  }

  @override
  void dispose() {
    _release();
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
              // fill whatever box we get; a childless CustomPaint is 0x0
              // under loose constraints (a Chip's avatar slot)
              size: Size.infinite,
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
