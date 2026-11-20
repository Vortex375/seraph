import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:get_storage/get_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:seraph_app/src/media_player/history_model.dart';

/// The history state under one get_storage key. Its own box: the handler is
/// created before SettingsController opens the settings box.
class HistoryStore {
  static const _key = 'playlistHistory';

  final GetStorage _box;

  HistoryStore._(this._box);

  static Future<HistoryStore> open() async {
    final box = GetStorage('SeraphPlaylistHistory',
        kIsWeb ? null : (await getApplicationSupportDirectory()).path);
    await box.initStorage;
    return HistoryStore._(box);
  }

  HistoryState read() {
    final raw = _box.read<String>(_key);
    if (raw == null) {
      return const HistoryState();
    }
    try {
      return HistoryState.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (err) {
      developer.log("unreadable playlist history: $err", name: 'seraph.media_player');
      return const HistoryState();
    }
  }

  Future<void> write(HistoryState state) => _box.write(_key, jsonEncode(state.toJson()));

  Future<void> clear() => _box.remove(_key);
}
