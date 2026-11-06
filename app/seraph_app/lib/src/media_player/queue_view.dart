import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';

/// The playing queue: tap a row to jump, drag the handle to reorder, swipe a
/// row away to remove it. Rows show the file name until ticket 04 adds tags.
class QueueView extends StatefulWidget {
  const QueueView({super.key});

  @override
  State<QueueView> createState() => _QueueViewState();
}

class _QueueViewState extends State<QueueView> {
  static const double _rowExtent = 56;

  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    final index = Get.find<AudioPlayerController>().currentIndex.value;
    _scrollController = ScrollController(
      initialScrollOffset: index > 0 ? index * _rowExtent : 0,
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<AudioPlayerController>();

    return Obx(() {
      final items = controller.queueItems;
      final current = controller.currentIndex.value;
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Row(
              children: [
                Text('Queue', style: Theme.of(context).textTheme.titleLarge),
                const Spacer(),
                Text('${items.length} tracks',
                    style: Theme.of(context).textTheme.bodyMedium),
              ],
            ),
          ),
          Expanded(
            child: items.isEmpty
                ? const Center(child: Text('The queue is empty'))
                : ReorderableListView.builder(
                    scrollController: _scrollController,
                    buildDefaultDragHandles: false,
                    itemExtent: _rowExtent,
                    itemCount: items.length,
                    onReorderItem: (oldIndex, newIndex) {
                      controller.move(oldIndex, newIndex);
                    },
                    itemBuilder: (context, index) {
                      final item = items[index];
                      final playing = index == current;
                      var occurrence = 0;
                      for (var i = 0; i < index; i++) {
                        if (items[i].id == item.id) {
                          occurrence++;
                        }
                      }
                      return Dismissible(
                        key: ValueKey('queue-${item.id}-$occurrence'),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: Theme.of(context).colorScheme.errorContainer,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 24),
                          child: const Icon(Icons.delete),
                        ),
                        onDismissed: (_) async {
                          await controller.removeAt(index);
                          if (mounted && controller.queueItems.isEmpty) {
                            Navigator.of(this.context).pop();
                          }
                        },
                        child: ListTile(
                          selected: playing,
                          selectedTileColor:
                              Theme.of(context).colorScheme.surfaceContainerHighest,
                          leading: Icon(playing ? Icons.volume_up : Icons.music_note),
                          title: Text(item.title, overflow: TextOverflow.ellipsis),
                          onTap: () => controller.skipTo(index),
                          trailing: ReorderableDragStartListener(
                            index: index,
                            child: const Padding(
                              padding: EdgeInsets.all(8),
                              child: Icon(Icons.drag_handle),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    });
  }
}
