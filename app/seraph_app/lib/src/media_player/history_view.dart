import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:seraph_app/src/app_bar/app_bar.dart';
import 'package:seraph_app/src/media_player/audio_handler.dart';
import 'package:seraph_app/src/media_player/audio_player_controller.dart';
import 'package:seraph_app/src/media_player/history_label.dart';
import 'package:seraph_app/src/media_player/history_model.dart';
import 'package:seraph_app/src/media_player/media_bottom_bar.dart';

/// The current playlist and the archive of recent ones. Rows expand to their
/// tracks (file names); Play promotes an archived entry and restores it.
class HistoryView extends StatefulWidget {
  static const String routeName = '/history';

  const HistoryView({super.key});

  @override
  State<HistoryView> createState() => _HistoryViewState();
}

class _HistoryViewState extends State<HistoryView> {
  final MyAudioHandler _handler = Get.find();

  @override
  void initState() {
    super.initState();
    _handler.loadHistory();
  }

  Future<void> _play(HistoryState state, int? archiveIndex) async {
    if (archiveIndex != null) {
      await _handler.editHistory((s) => const HistoryModel().promote(s, archiveIndex));
    }
    await _handler.restoreHistoryEntry(_handler.history.value.current!);
    await Get.find<AudioPlayerController>().play();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: seraphAppBar(context, routeName: HistoryView.routeName),
      bottomNavigationBar: const MediaBottomBar(),
      body: StreamBuilder<HistoryState>(
        stream: _handler.history,
        initialData: _handler.history.value,
        builder: (context, snapshot) {
          final state = snapshot.data!;
          final now = DateTime.now();
          if (state.current == null && state.archive.isEmpty) {
            return const Center(child: Text('No recent playlists'));
          }
          return ListView(
            children: [
              if (state.current != null) _row(state, state.current!, null, now),
              for (var i = 0; i < state.archive.length; i++)
                _row(state, state.archive[i], i, now),
            ],
          );
        },
      ),
    );
  }

  Widget _row(HistoryState state, HistoryEntry entry, int? archiveIndex, DateTime now) {
    final isCurrent = archiveIndex == null;
    final tile = ExpansionTile(
      key: PageStorageKey('${entry.lastPlayed}-${entry.paths.length}-${entry.paths.first}'),
      leading: Icon(isCurrent ? Icons.play_circle : Icons.queue_music),
      title: Text(historyLabel(entry, now), overflow: TextOverflow.ellipsis),
      subtitle: isCurrent ? const Text('Current') : null,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('Play'),
              onPressed: () => _play(state, archiveIndex),
            ),
            TextButton.icon(
              icon: const Icon(Icons.playlist_add),
              label: const Text('Add to queue'),
              onPressed: () =>
                  Get.find<AudioPlayerController>().enqueue(entry.paths, playNext: false),
            ),
          ],
        ),
        for (final path in entry.paths)
          ListTile(dense: true, title: Text(p.basename(path), overflow: TextOverflow.ellipsis)),
      ],
    );
    if (isCurrent) {
      return tile;
    }
    return Dismissible(
      key: ValueKey('history-${entry.lastPlayed}-${entry.paths.first}-$archiveIndex'),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Theme.of(context).colorScheme.errorContainer,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        child: const Icon(Icons.delete),
      ),
      onDismissed: (_) =>
          _handler.editHistory((s) => const HistoryModel().delete(s, archiveIndex)),
      child: tile,
    );
  }
}
