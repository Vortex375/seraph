import 'dart:async';

import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror_database.dart';

/// State behind AI search in Gallery Mode: the query (free text, one tag, one
/// person), the results joined to the local mirror, and whether the server
/// offers AI at all.
class GallerySearchController extends GetxController {
  GallerySearchController(this.service, this.mirror);

  final GalleryService service;
  final GalleryMirror mirror;

  /// null until probed; false when the server answered `ai-unavailable`.
  final Rxn<bool> available = Rxn<bool>();
  final RxList<GalleryPerson> people = <GalleryPerson>[].obs;
  final Rx<GalleryAnalysisStatus> status = const GalleryAnalysisStatus().obs;
  final RxList<GalleryItem> results = <GalleryItem>[].obs;
  final RxBool searching = false.obs;
  final RxBool searched = false.obs;

  final RxString text = ''.obs;
  final Rxn<String> tag = Rxn<String>();
  final Rxn<String> personId = Rxn<String>();

  int _generation = 0;

  /// Probes the AI endpoints once per call: the entry is shown only when the
  /// answer is not `ai-unavailable`. Call on every Gallery Mode open.
  Future<void> probe() async {
    try {
      status.value = await service.analysisStatus();
      available.value = true;
    } on GalleryAiUnavailableException {
      available.value = false;
    } catch (_) {
      // transient failure: leave the previous answer in place
    }
  }

  /// Loads the chips' people and the analysis progress.
  Future<void> loadChips() async {
    try {
      status.value = await service.analysisStatus();
      people.value = await service.people();
    } on GalleryAiUnavailableException {
      available.value = false;
    } catch (_) {}
  }

  Future<void> search() async {
    final generation = ++_generation;
    if (text.value.trim().isEmpty &&
        tag.value == null &&
        personId.value == null) {
      results.clear();
      searched.value = false;
      searching.value = false;
      return;
    }
    searching.value = true;
    try {
      final hits = await service.search(
          q: text.value.trim(), tag: tag.value, personId: personId.value);
      final items = await mirror
          .itemsBySpaceKeys([for (final h in hits) (h.providerId, h.path)]);
      if (generation != _generation) return;
      results.value = items;
    } on GalleryAiUnavailableException {
      available.value = false;
    } catch (_) {
      if (generation != _generation) return;
      results.clear();
    } finally {
      if (generation == _generation) {
        searched.value = true;
        searching.value = false;
      }
    }
  }

  /// Renames a person; the shared [people] list drives both the People grid
  /// and the search chips. Returns false on failure.
  Future<bool> renamePerson(String id, String name) async {
    try {
      final updated = await service.renamePerson(id, name.trim());
      people.value = [
        for (final p in people) p.id == id ? p.withName(updated.name) : p
      ];
      return true;
    } on GalleryAiUnavailableException {
      available.value = false;
    } catch (_) {}
    return false;
  }

  /// Search for exactly one person's photos (the People screen's tap).
  void showPerson(String id) {
    text.value = '';
    tag.value = null;
    personId.value = id;
    unawaited(search());
  }

  void setTag(String? value) {
    tag.value = tag.value == value ? null : value;
    unawaited(search());
  }

  void setPerson(String? value) {
    personId.value = personId.value == value ? null : value;
    unawaited(search());
  }
}
