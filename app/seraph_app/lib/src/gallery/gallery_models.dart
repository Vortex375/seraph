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

/// The tag names the gallery-ai service classifies photos with
/// (`gallery-ai/galleryai/tags.go` `DefaultTags`). There is no tags endpoint,
/// so the search chips hardcode the same list.
const List<String> galleryAiTags = [
  'people',
  'pet',
  'food',
  'landscape',
  'beach',
  'mountain',
  'city',
  'night',
  'document',
  'screenshot',
  'vehicle',
  'building',
  'flower',
  'sport',
];

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

/// `GET /api/gallery/analysis/status`.
class GalleryAnalysisStatus {
  const GalleryAnalysisStatus({
    this.analysed = 0,
    this.pending = 0,
    this.failed = 0,
  });

  final int analysed;
  final int pending;
  final int failed;

  factory GalleryAnalysisStatus.fromJson(Map<String, dynamic>? json) {
    return GalleryAnalysisStatus(
      analysed: json?['analysed'] as int? ?? 0,
      pending: json?['pending'] as int? ?? 0,
      failed: json?['failed'] as int? ?? 0,
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
  });

  final String id;
  final String name;
  final int photoCount;

  factory GalleryPerson.fromJson(Map<String, dynamic> json) {
    return GalleryPerson(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      photoCount: json['photoCount'] as int? ?? 0,
    );
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

/// The gateway answered 503 `ai-unavailable`: the AI service is not deployed
/// or not reachable, so the app hides its AI features.
class GalleryAiUnavailableException implements Exception {
  const GalleryAiUnavailableException();
}
