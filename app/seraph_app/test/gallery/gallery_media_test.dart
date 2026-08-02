import 'package:flutter_test/flutter_test.dart';
import 'package:seraph_app/src/gallery/gallery_media.dart';

void main() {
  group('GalleryMediaUrls', () {
    const urls = GalleryMediaUrls('https://seraph.test');

    test('thumbnails come from the existing preview endpoint', () {
      final url = urls.thumbnail('space-a', '/Photos/a.jpg', 512);

      expect(url, startsWith('https://seraph.test/preview?p='));
      expect(url, endsWith('&w=512&h=512'));

      // The endpoint's "p" parameter is "<spaceProviderId><path>" - the exact
      // pair the gallery API returns, which is why no new media endpoint is
      // needed.
      final p = Uri.parse(url).queryParameters['p'];
      expect(p, '/space-a/Photos/a.jpg');
    });

    test('full resolution comes from the existing WebDAV read path', () {
      expect(
        urls.fullResolution('space-a', '/Photos/a.jpg'),
        'https://seraph.test/dav/p/space-a/Photos/a.jpg',
      );
    });

    test('a path with spaces and other awkward characters is encoded', () {
      final thumb = urls.thumbnail('space a', '/Holidays/Crete 2019/a&b.jpg', 512);
      expect(Uri.parse(thumb).queryParameters['p'],
          '/space a/Holidays/Crete 2019/a&b.jpg');

      final full = urls.fullResolution('space-a', '/Crete 2019/a&b.jpg');
      expect(full, 'https://seraph.test/dav/p/space-a/Crete%202019/a%26b.jpg');
      // ...and it survives a round trip through a URL parser.
      expect(Uri.parse(full).pathSegments,
          ['dav', 'p', 'space-a', 'Crete 2019', 'a&b.jpg']);
    });

    test('a server URL with a trailing slash does not produce a double slash',
        () {
      const trailing = GalleryMediaUrls('https://seraph.test/');
      expect(trailing.fullResolution('space-a', '/a.jpg'),
          'https://seraph.test/dav/p/space-a/a.jpg');
      expect(trailing.thumbnail('space-a', '/a.jpg', 512),
          startsWith('https://seraph.test/preview?p='));
    });
  });
}
