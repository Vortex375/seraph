// Dart mirror of the gallery service's delta-feed wire types
// (`gallery/gallery/messages.go`: `GalleryDeltaItem`, `GalleryDeltaResponse`),
// as returned by `GET /api/gallery/delta` on the api-gateway
// (`api-gateway/gallery/gallery.go`).

/// One changed row in the delta feed: either the current state of a photo
/// ([tombstone] false) or notice that it has been removed ([tombstone] true).
///
/// Identity is ([providerId], [path]) - SPACE coordinates, the same ones the
/// gallery listing API returns - so a mirror keyed off listing results and a
/// mirror keyed off delta results agree on identity.
class GalleryDeltaItem {
  const GalleryDeltaItem({
    required this.providerId,
    required this.path,
    required this.seq,
    required this.tombstone,
    this.capturedAt = 0,
    this.capturedAtSource = '',
    this.capturedAtOffset,
    this.lat,
    this.lon,
    this.width = 0,
    this.height = 0,
    this.orientation = 0,
    this.size = 0,
    this.mime = '',
    this.unsupported = '',
    this.metadataPending = false,
    this.placeCountryCode = '',
    this.placeCountry = '',
    this.placeAdmin1Code = '',
    this.placeAdmin1 = '',
    this.placeLocalityId = 0,
    this.placeLocality = '',
  });

  final String providerId;
  final String path;
  final int seq;
  final bool tombstone;

  final int capturedAt;
  final String capturedAtSource;

  /// Seconds east of UTC at the place of capture, when the photo itself
  /// recorded one (ADR 0003); null when unknown. [capturedAt] is a true
  /// instant whenever this is non-null.
  final int? capturedAtOffset;

  /// The photo's WGS84 coordinates, null when there is no usable GPS fix.
  final double? lat;
  final double? lon;

  final int width;
  final int height;
  final int orientation;
  final int size;
  final String mime;
  final String unsupported;
  final bool metadataPending;

  /// The Place (CONTEXT.md), flattened exactly as the server flattens it:
  /// empty strings / 0 when nothing resolved.
  final String placeCountryCode;
  final String placeCountry;
  final String placeAdmin1Code;
  final String placeAdmin1;
  final int placeLocalityId;
  final String placeLocality;

  factory GalleryDeltaItem.fromJson(Map<String, dynamic> json) {
    return GalleryDeltaItem(
      providerId: json['providerId'] as String? ?? '',
      path: json['path'] as String? ?? '',
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      tombstone: json['tombstone'] as bool? ?? false,
      capturedAt: (json['capturedAt'] as num?)?.toInt() ?? 0,
      capturedAtSource: json['capturedAtSource'] as String? ?? '',
      capturedAtOffset: (json['capturedAtOffset'] as num?)?.toInt(),
      lat: (json['lat'] as num?)?.toDouble(),
      lon: (json['lon'] as num?)?.toDouble(),
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      orientation: (json['orientation'] as num?)?.toInt() ?? 0,
      size: (json['size'] as num?)?.toInt() ?? 0,
      mime: json['mime'] as String? ?? '',
      unsupported: json['unsupported'] as String? ?? '',
      metadataPending: json['metadataPending'] as bool? ?? false,
      placeCountryCode: json['placeCountryCode'] as String? ?? '',
      placeCountry: json['placeCountry'] as String? ?? '',
      placeAdmin1Code: json['placeAdmin1Code'] as String? ?? '',
      placeAdmin1: json['placeAdmin1'] as String? ?? '',
      placeLocalityId: (json['placeLocalityId'] as num?)?.toInt() ?? 0,
      placeLocality: json['placeLocality'] as String? ?? '',
    );
  }
}

/// One page of delta feed results.
///
/// [nextCursor] continues the CURRENT page scan when [hasMore] is true - pass
/// it back as the next request's `cursor` together with the SAME `since` used
/// to obtain it. [nextSince] is only meaningful once [hasMore] is false: the
/// sequence value to use as the NEXT poll's `since`, once this page (and
/// every prior page of the same poll) has been applied.
class GalleryDeltaResponse {
  const GalleryDeltaResponse({
    required this.items,
    required this.nextCursor,
    required this.hasMore,
    required this.nextSince,
  });

  final List<GalleryDeltaItem> items;
  final String nextCursor;
  final bool hasMore;
  final int nextSince;

  factory GalleryDeltaResponse.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return GalleryDeltaResponse(
      items: rawItems is List
          ? rawItems
              .map((e) => GalleryDeltaItem.fromJson(e as Map<String, dynamic>))
              .toList()
          : const [],
      nextCursor: json['nextCursor'] as String? ?? '',
      hasMore: json['hasMore'] as bool? ?? false,
      nextSince: (json['nextSince'] as num?)?.toInt() ?? 0,
    );
  }
}
