import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_item_display.dart';
import 'package:seraph_app/src/gallery/gallery_people_view.dart';
import 'package:seraph_app/src/gallery/gallery_search_controller.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

/// Where an [imageSize] photo lands when laid out like `BoxFit.contain`,
/// centred in a [boxSize] area.
Rect containedImageRect(Size imageSize, Size boxSize) {
  if (imageSize.isEmpty || boxSize.isEmpty) return Rect.zero;
  final scale =
      boxSize.width / imageSize.width < boxSize.height / imageSize.height
          ? boxSize.width / imageSize.width
          : boxSize.height / imageSize.height;
  final w = imageSize.width * scale;
  final h = imageSize.height * scale;
  return Rect.fromLTWH((boxSize.width - w) / 2, (boxSize.height - h) / 2, w, h);
}

/// A face's normalised [box] mapped into [imageRect] (the displayed photo).
Rect faceOverlayRect(GalleryFaceBox box, Rect imageRect) => Rect.fromLTRB(
      imageRect.left + box.x1 * imageRect.width,
      imageRect.top + box.y1 * imageRect.height,
      imageRect.left + box.x2 * imageRect.width,
      imageRect.top + box.y2 * imageRect.height,
    );

/// The face boxes to draw over one photo (Space coordinates identify it).
class GalleryFaceOverlay {
  const GalleryFaceOverlay(this.providerId, this.path, this.faces);

  final String providerId;
  final String path;
  final List<GalleryPhotoFace> faces;
}

/// Draws the face rectangles over [item]'s page. Hidden while zoomed in: the
/// overlay does not follow the zoom transform.
class GalleryFaceBoxOverlay extends StatelessWidget {
  const GalleryFaceBoxOverlay({
    super.key,
    required this.item,
    required this.overlay,
    required this.isZoomedIn,
  });

  final GalleryItem item;
  final ValueListenable<GalleryFaceOverlay?> overlay;
  final ValueListenable<bool> isZoomedIn;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ListenableBuilder(
        listenable: Listenable.merge([overlay, isZoomedIn]),
        builder: (context, _) {
          final o = overlay.value;
          if (o == null ||
              isZoomedIn.value ||
              o.providerId != item.providerId ||
              o.path != item.path ||
              item.displayWidth <= 0 ||
              item.displayHeight <= 0) {
            return const SizedBox.shrink();
          }
          return LayoutBuilder(
            builder: (context, c) {
              final image = containedImageRect(
                  Size(item.displayWidth.toDouble(),
                      item.displayHeight.toDouble()),
                  c.biggest);
              return CustomPaint(
                size: c.biggest,
                painter: _BoxPainter(
                    [for (final f in o.faces) faceOverlayRect(f.box, image)]),
              );
            },
          );
        },
      ),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter(this.rects);

  final List<Rect> rects;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.amberAccent;
    for (final r in rects) {
      canvas.drawRect(r, paint);
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) => old.rects != rects;
}

/// Tags and faces in the photo details sheet. Renders nothing for a
/// device-only photo, when the AI service is unavailable, or on any failure.
class GalleryPhotoAnalysisSection extends StatefulWidget {
  const GalleryPhotoAnalysisSection(
      {super.key, required this.item, this.overlay});

  final GalleryItem item;
  final ValueNotifier<GalleryFaceOverlay?>? overlay;

  @override
  State<GalleryPhotoAnalysisSection> createState() =>
      _GalleryPhotoAnalysisSectionState();
}

class _GalleryPhotoAnalysisSectionState
    extends State<GalleryPhotoAnalysisSection> {
  GallerySearchController? _search;
  GalleryPhotoAnalysis? _analysis;

  @override
  void initState() {
    super.initState();
    if (widget.item.providerId == null ||
        widget.item.path == null ||
        !Get.isRegistered<GallerySearchController>()) {
      return;
    }
    _search = Get.find<GallerySearchController>();
    _search!.loadChips();
    _load();
  }

  Future<void> _load() async {
    final item = widget.item;
    try {
      final a =
          await _search!.service.photoAnalysis(item.providerId!, item.path!);
      if (!mounted) return;
      setState(() => _analysis = a);
      widget.overlay?.value =
          GalleryFaceOverlay(item.providerId!, item.path!, a.faces);
    } on GalleryAiUnavailableException {
      _search!.available.value = false;
    } catch (_) {}
  }

  Future<void> _assign(GalleryPhotoFace face,
      {String? personId, String? newPersonName}) async {
    if (await _search!.assignFace(face.id,
        personId: personId, newPersonName: newPersonName)) {
      await _load();
    }
  }

  Future<void> _onFaceTap(GalleryPhotoFace face) async {
    final people = _search!.people.toList();
    final choice = await showModalBottomSheet<(String, String?)>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            leading: const Icon(Icons.person_add_alt_outlined),
            title: const Text('New person...'),
            onTap: () => Navigator.pop(context, ('new', null)),
          ),
          if (face.personId != null)
            ListTile(
              leading: const Icon(Icons.person_remove_outlined),
              title: const Text('Remove from person'),
              onTap: () => Navigator.pop(context, ('remove', null)),
            ),
          for (final p in people)
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: Text(p.name.isEmpty ? 'Unnamed' : p.name),
              onTap: () => Navigator.pop(context, ('person', p.id)),
            ),
        ]),
      ),
    );
    if (choice == null || !mounted) return;
    switch (choice.$1) {
      case 'person':
        await _assign(face, personId: choice.$2);
      case 'remove':
        await _assign(face);
      case 'new':
        final name = await _askName();
        if (name != null && name.isNotEmpty) {
          await _assign(face, newPersonName: name);
        }
    }
  }

  Future<String?> _askName() {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New person'),
        content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  @override
  Widget build(BuildContext context) {
    final search = _search;
    final a = _analysis;
    if (search == null || a == null) return const SizedBox.shrink();
    return Obx(() {
      if (search.available.value == false) return const SizedBox.shrink();
      if (!a.analysed) {
        return const ListTile(
          leading: Icon(Icons.auto_awesome_outlined),
          title: Text('Analysis pending'),
        );
      }
      final loader = Get.isRegistered<GalleryImageLoader>()
          ? Get.find<GalleryImageLoader>()
          : null;
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (a.tags.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(spacing: 8, runSpacing: 4, children: [
              for (final t in a.tags) Chip(label: Text(t.tag)),
            ]),
          ),
        if (a.faces.isNotEmpty && loader != null)
          SizedBox(
            height: 104,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [for (final f in a.faces) _faceTile(f, loader)],
            ),
          ),
      ]);
    });
  }

  Widget _faceTile(GalleryPhotoFace f, GalleryImageLoader loader) {
    return InkWell(
      onTap: () => _onFaceTap(f),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: SizedBox(
          width: 72,
          child: Column(children: [
            SizedBox(
              width: 64,
              height: 64,
              child: ClipOval(
                child: FaceAvatar(
                  loader: loader,
                  person: GalleryPerson(
                    id: f.personId ?? '',
                    name: f.personName,
                    photoCount: 0,
                    cover: GalleryPersonCover(
                        providerId: widget.item.providerId!,
                        path: widget.item.path!,
                        box: f.box),
                  ),
                ),
              ),
            ),
            Text(f.personName.isEmpty ? 'Unnamed' : f.personName,
                maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
      ),
    );
  }
}
