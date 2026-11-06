import 'package:audio_service/audio_service.dart';

/// A track's tags as served by the gateway's `/audio/tags` (fields absent
/// when the file has no such tag).
class AudioTags {
  const AudioTags({
    this.title,
    this.artist,
    this.album,
    this.albumArtist,
    this.genre,
    this.year,
    this.trackNumber,
    this.discNumber,
    this.hasPicture = false,
  });

  final String? title;
  final String? artist;
  final String? album;
  final String? albumArtist;
  final String? genre;
  final int? year;
  final int? trackNumber;
  final int? discNumber;
  final bool hasPicture;

  factory AudioTags.fromJson(Map<String, dynamic> json) => AudioTags(
        title: json['title'] as String?,
        artist: json['artist'] as String?,
        album: json['album'] as String?,
        albumArtist: json['albumArtist'] as String?,
        genre: json['genre'] as String?,
        year: json['year'] as int?,
        trackNumber: json['trackNumber'] as int?,
        discNumber: json['discNumber'] as int?,
        hasPicture: json['hasPicture'] as bool? ?? false,
      );

  /// [item] with these tags; an untagged title keeps the file name.
  MediaItem applyTo(MediaItem item) => item.copyWith(
        title: title ?? item.title,
        artist: artist ?? albumArtist,
        album: album,
        genre: genre,
        extras: {
          ...?item.extras,
          taggedExtra: true,
          if (year != null) 'year': year,
          if (trackNumber != null) 'trackNumber': trackNumber,
          if (discNumber != null) 'discNumber': discNumber,
        },
      );
}

/// Set in a [MediaItem]'s extras once tags were applied to it.
const taggedExtra = 'tagged';

/// The file path a queue entry was built from (its id is the file URL).
String? mediaItemPath(MediaItem item) => item.extras?['path'] as String?;

/// "2001 · Track 3 · Electronic" for the parts [item] has, or "".
String trackDetails(MediaItem item) => [
      if (item.extras?['year'] case final int year) '$year',
      if (item.extras?['trackNumber'] case final int track) 'Track $track',
      if (item.genre case final String genre) genre,
    ].join(' · ');
