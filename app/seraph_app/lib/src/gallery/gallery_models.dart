/// A folder in Seraph whose photos appear in Gallery Mode.
///
/// Gallery Source Folders are held in Space terms - (spaceProviderId, path) -
/// exactly as the user picked them in the folder picker. They belong to the
/// user, not to a device, so the same set appears on every signed-in device.
class GallerySourceFolder {
  const GallerySourceFolder({
    required this.id,
    required this.spaceProviderId,
    required this.path,
    this.rescanRunning = false,
  });

  final String id;
  final String spaceProviderId;
  final String path;

  /// True while a genuine File Provider re-scan of this folder (triggered by
  /// the "Rescan folder" action) is still running. Cleared automatically once
  /// the scan finishes - the app learns this by re-fetching the folder list.
  final bool rescanRunning;

  /// The location as it appears in the file browser, i.e. the space provider
  /// followed by the path within it.
  String get displayPath =>
      path == '/' ? '/$spaceProviderId' : '/$spaceProviderId$path';

  factory GallerySourceFolder.fromJson(Map<String, dynamic> json) {
    return GallerySourceFolder(
      id: json['id'] as String? ?? '',
      spaceProviderId: json['spaceProviderId'] as String? ?? '',
      path: json['path'] as String? ?? '/',
      rescanRunning: json['rescanRunning'] as bool? ?? false,
    );
  }
}

/// One search hit, in Space coordinates - not yet joined to a mirror row.
class GallerySearchHit {
  const GallerySearchHit({
    required this.providerId,
    required this.path,
    required this.score,
  });

  final String providerId;
  final String path;
  final double score;

  factory GallerySearchHit.fromJson(Map<String, dynamic> json) {
    return GallerySearchHit(
      providerId: json['providerId'] as String? ?? '',
      path: json['path'] as String? ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0,
    );
  }

  static List<GallerySearchHit> listFromJson(Map<String, dynamic>? json) {
    final raw = json?['items'];
    if (raw is! List) return [];
    return raw
        .map((e) => GallerySearchHit.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}

/// `GET /api/gallery/analysis/status`. [tags] are the tag names the server
/// is configured with, the values search accepts as `tag`.
class GalleryAnalysisStatus {
  const GalleryAnalysisStatus({
    this.analysed = 0,
    this.pending = 0,
    this.failed = 0,
    this.tags = const [],
  });

  final int analysed;
  final int pending;
  final int failed;
  final List<String> tags;

  factory GalleryAnalysisStatus.fromJson(Map<String, dynamic>? json) {
    return GalleryAnalysisStatus(
      analysed: json?['analysed'] as int? ?? 0,
      pending: json?['pending'] as int? ?? 0,
      failed: json?['failed'] as int? ?? 0,
      tags: (json?['tags'] as List?)?.whereType<String>().toList() ?? const [],
    );
  }
}

/// A recognised person from `GET /api/gallery/people`. An empty [name] means
/// the person has not been named yet.
class GalleryPerson {
  const GalleryPerson({
    required this.id,
    required this.name,
    required this.photoCount,
    this.cover,
  });

  final String id;
  final String name;
  final int photoCount;

  /// The face to show for this person; null when the server sent none.
  final GalleryPersonCover? cover;

  factory GalleryPerson.fromJson(Map<String, dynamic> json) {
    final cover = json['cover'];
    return GalleryPerson(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      photoCount: json['photoCount'] as int? ?? 0,
      cover: cover is Map<String, dynamic>
          ? GalleryPersonCover.fromJson(cover)
          : null,
    );
  }

  GalleryPerson withName(String name) =>
      GalleryPerson(id: id, name: name, photoCount: photoCount, cover: cover);

  /// One entry per name: clusters sharing a name are one person, shown as the
  /// biggest of them with the photo counts summed. Unnamed clusters stay apart.
  static List<GalleryPerson> mergeByName(List<GalleryPerson> people) {
    final byName = <String, GalleryPerson>{};
    final out = <GalleryPerson>[];
    for (final p in people) {
      final first = p.name.isEmpty ? null : byName[p.name];
      if (first == null) {
        if (p.name.isNotEmpty) byName[p.name] = p;
        out.add(p);
        continue;
      }
      final i = out.indexOf(first);
      final big = p.photoCount > first.photoCount ? p : first;
      final merged = GalleryPerson(
          id: big.id,
          name: p.name,
          photoCount: first.photoCount + p.photoCount,
          cover: big.cover);
      byName[p.name] = merged;
      out[i] = merged;
    }
    return out;
  }

  /// Named people first (by name), then unnamed ones by photo count.
  static List<GalleryPerson> listFromJson(Map<String, dynamic>? json) {
    final raw = json?['people'];
    if (raw is! List) return [];
    final people = raw
        .map((e) => GalleryPerson.fromJson(e as Map<String, dynamic>))
        .toList();
    people.sort((a, b) {
      if (a.name.isEmpty != b.name.isEmpty) return a.name.isEmpty ? 1 : -1;
      if (a.name.isNotEmpty) return a.name.compareTo(b.name);
      return b.photoCount.compareTo(a.photoCount);
    });
    return people;
  }
}

/// A face's box, normalised 0..1 relative to the photo as displayed.
class GalleryFaceBox {
  const GalleryFaceBox(this.x1, this.y1, this.x2, this.y2);

  final double x1, y1, x2, y2;
}

/// The photo (Space coordinates) and face box a person's avatar is cropped from.
class GalleryPersonCover {
  const GalleryPersonCover({
    required this.providerId,
    required this.path,
    required this.box,
  });

  final String providerId;
  final String path;
  final GalleryFaceBox box;

  factory GalleryPersonCover.fromJson(Map<String, dynamic> json) {
    final b = json['box'];
    double n(String k) => b is Map ? (b[k] as num?)?.toDouble() ?? 0 : 0;
    return GalleryPersonCover(
      providerId: json['providerId'] as String? ?? '',
      path: json['path'] as String? ?? '',
      box: GalleryFaceBox(n('x1'), n('y1'), n('x2'), n('y2')),
    );
  }
}

/// One classifier tag of a photo, from `GET /api/gallery/photos/analysis`.
class GalleryPhotoTag {
  const GalleryPhotoTag(this.tag, this.score);

  final String tag;
  final double score;
}

/// A face found in a photo. [box] is normalised to the displayed photo;
/// [personId] is null while the face is unassigned.
class GalleryPhotoFace {
  const GalleryPhotoFace({
    required this.id,
    required this.box,
    this.personId,
    this.personName = '',
    this.manual = false,
  });

  final String id;
  final GalleryFaceBox box;
  final String? personId;
  final String personName;
  final bool manual;

  factory GalleryPhotoFace.fromJson(Map<String, dynamic> json) {
    final b = json['box'];
    double n(String k) => b is Map ? (b[k] as num?)?.toDouble() ?? 0 : 0;
    return GalleryPhotoFace(
      id: json['id'] as String? ?? '',
      box: GalleryFaceBox(n('x1'), n('y1'), n('x2'), n('y2')),
      personId: json['personId'] as String?,
      personName: json['personName'] as String? ?? '',
      manual: json['manual'] as bool? ?? false,
    );
  }
}

/// `GET /api/gallery/photos/analysis`: [analysed] is false until the AI
/// service has processed the photo.
class GalleryPhotoAnalysis {
  const GalleryPhotoAnalysis({
    this.analysed = false,
    this.analysisError = '',
    this.tags = const [],
    this.faces = const [],
  });

  final bool analysed;
  final String analysisError;
  final List<GalleryPhotoTag> tags;
  final List<GalleryPhotoFace> faces;

  factory GalleryPhotoAnalysis.fromJson(Map<String, dynamic>? json) {
    final tags = json?['tags'];
    final faces = json?['faces'];
    return GalleryPhotoAnalysis(
      analysed: json?['analysed'] as bool? ?? false,
      analysisError: json?['analysisError'] as String? ?? '',
      tags: tags is List
          ? [
              for (final t in tags.cast<Map<String, dynamic>>())
                GalleryPhotoTag(t['tag'] as String? ?? '',
                    (t['score'] as num?)?.toDouble() ?? 0)
            ]
          : const [],
      faces: faces is List
          ? [
              for (final f in faces)
                GalleryPhotoFace.fromJson(f as Map<String, dynamic>)
            ]
          : const [],
    );
  }
}

/// The gateway answered 503 `ai-unavailable`: the AI service is not deployed
/// or not reachable, so the app hides its AI features.
class GalleryAiUnavailableException implements Exception {
  const GalleryAiUnavailableException();
}
