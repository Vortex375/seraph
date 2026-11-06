import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/media_player/audio_tags.dart';

void main() {
  const file = MediaItem(id: 'https://s/dav/p/m/01.mp3', title: '01.mp3', extras: {'path': '/m/01.mp3'});

  test('applies parsed tags and keeps the path', () {
    final tags = AudioTags.fromJson({
      'title': 'Jóga',
      'artist': 'Björk',
      'album': 'Homogenic',
      'genre': 'Electronic',
      'year': 1997,
      'trackNumber': 3,
    });
    final item = tags.applyTo(file);

    expect(item.title, 'Jóga');
    expect(item.artist, 'Björk');
    expect(item.album, 'Homogenic');
    expect(mediaItemPath(item), '/m/01.mp3');
    expect(item.extras?[taggedExtra], true);
    expect(trackDetails(item), '1997 · Track 3 · Electronic');
  });

  test('an untagged file keeps its file name and has no details', () {
    final item = AudioTags.fromJson({}).applyTo(file);

    expect(item.title, '01.mp3');
    expect(item.artist, isNull);
    expect(item.extras?[taggedExtra], true);
    expect(trackDetails(item), '');
  });

  test('album artist stands in for a missing artist', () {
    expect(AudioTags.fromJson({'albumArtist': 'Various'}).applyTo(file).artist, 'Various');
  });
}
