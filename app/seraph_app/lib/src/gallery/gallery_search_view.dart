import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/gallery_image_loader.dart';
import 'package:seraph_app/src/gallery/gallery_photo_viewer.dart';
import 'package:seraph_app/src/gallery/gallery_search_controller.dart';
import 'package:seraph_app/src/gallery/gallery_tile.dart';
import 'package:seraph_app/src/gallery/local/local_image_loader.dart';

/// AI search over the user's photos: free text and a tag chip, combined. Results are the existing [GalleryTile]s in the server's score
/// order; a tap opens the existing viewer on just those results.
class GallerySearchView extends StatefulWidget {
  static const routeName = '/gallery/search';

  const GallerySearchView({super.key});

  @override
  State<GallerySearchView> createState() => _GallerySearchViewState();
}

class _GallerySearchViewState extends State<GallerySearchView> {
  final GallerySearchController search = Get.find();
  final GalleryImageLoader loader = Get.find();
  final LocalImageLoader localLoader = Get.find();
  final TextEditingController _text = TextEditingController();

  @override
  void initState() {
    super.initState();
    search.loadChips();
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _text,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            hintText: 'Search photos',
            border: InputBorder.none,
          ),
          onChanged: (value) => search.text.value = value,
          onSubmitted: (_) => search.search(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Search',
            onPressed: search.search,
          ),
        ],
      ),
      body: Column(
        children: [
          Obx(() {
            final pending = search.status.value.pending;
            if (pending == 0) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Analysing photos… $pending left',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            );
          }),
          _chips(),
          Expanded(child: _results()),
        ],
      ),
    );
  }

  Widget _chips() {
    return Obx(() {
      return SizedBox(
        height: 48,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          children: [
            for (final t in search.status.value.tags)
              _chip(t, search.tag.value == t, () => search.setTag(t)),
          ],
        ),
      );
    });
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: FilterChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }

  Widget _results() {
    return Obx(() {
      if (search.searching.value) {
        return const Center(child: CircularProgressIndicator());
      }
      final items = search.results.toList();
      if (items.isEmpty) {
        return Center(
          child: Text(search.searched.value ? 'No matching photos' : ''),
        );
      }
      return LayoutBuilder(builder: (context, constraints) {
        final cross = (constraints.maxWidth / 140).round().clamp(2, 1000);
        return GridView.builder(
          padding: EdgeInsets.zero,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) => GestureDetector(
            // named after the search screen: the result list can't survive a
            // reload, so a reloaded URL lands back on search
            onTap: () => Get.to(
                () => GalleryPhotoViewerView(initialIndex: index, items: items),
                routeName: GallerySearchView.routeName),
            child: GalleryTile(
              item: items[index],
              loader: loader,
              localLoader: localLoader,
            ),
          ),
        );
      });
    });
  }
}
