import 'package:get/get.dart';
import 'package:seraph_app/src/gallery/gallery_grid_controller.dart';
import 'package:seraph_app/src/gallery/gallery_models.dart';
import 'package:seraph_app/src/gallery/gallery_service.dart';
import 'package:seraph_app/src/gallery/mirror/gallery_mirror.dart';

/// State behind AI search in Gallery Mode: whether the server offers AI, the people and analysis status, and applying the AI filter.
class GallerySearchController extends GetxController {
  GallerySearchController(this.service, this.mirror);

  final GalleryService service;
  final GalleryMirror mirror;

  /// null until probed; false when the server answered `ai-unavailable`.
  final Rxn<bool> available = Rxn<bool>();
  final RxList<GalleryPerson> people = <GalleryPerson>[].obs;
  final Rx<GalleryAnalysisStatus> status = const GalleryAnalysisStatus().obs;

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

  /// Loads the people (for the People screen and dialog) and the analysis progress.
  Future<void> loadChips() async {
    try {
      status.value = await service.analysisStatus();
      people.value = await service.people();
    } on GalleryAiUnavailableException {
      available.value = false;
    } catch (_) {}
  }

  /// Renames a person; the shared [people] list drives the People grid
  /// and dialog. Returns false on failure.
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

  /// Assigns a face (see [GalleryService.assignFace]) and refreshes the shared
  /// [people] list so the People screen follows. Returns false
  /// on failure.
  Future<bool> assignFace(String faceId,
      {String? personId, String? newPersonName}) async {
    try {
      await service.assignFace(faceId,
          personId: personId, newPersonName: newPersonName);
      people.value = await service.people();
      return true;
    } on GalleryAiUnavailableException {
      available.value = false;
    } catch (_) {}
    return false;
  }

  /// Sets the AI part of [grid]'s filter to the full combination of [text],
  /// [tag] and [person] (the caller passes all three, changed in one place):
  /// ONE server request carrying every non-null part, because the server
  /// combines them. With all three null the part is simply cleared, no
  /// request. Returns false on failure (the filter is left as it was); a
  /// call superseded by a newer one returns true and changes nothing.
  Future<bool> applyAi(GalleryGridController grid,
      {String? text, String? tag, GalleryPerson? person}) async {
    final generation = ++_generation;
    if (text == null && tag == null && person == null) {
      await grid.setFilter(grid.filter.value.copyWith(clearAi: true));
      return true;
    }
    try {
      // ponytail: capped at 1000 hits (search max limit); page the search or send the local filter if a library exceeds it
      final hits = await service.search(
          q: text ?? '', tag: tag, personId: person?.id, limit: 1000);
      if (generation != _generation) return true;
      await grid.setFilter(grid.filter.value.copyWith(
          ai: GalleryAiFilter(
              text: text,
              tag: tag,
              person: person,
              keys: [for (final h in hits) (h.providerId, h.path)])));
      return true;
    } on GalleryAiUnavailableException {
      available.value = false;
    } catch (_) {}
    return false;
  }
}
