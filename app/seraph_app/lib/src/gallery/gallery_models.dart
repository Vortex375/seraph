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
  });

  final String id;
  final String spaceProviderId;
  final String path;

  /// The location as it appears in the file browser, i.e. the space provider
  /// followed by the path within it.
  String get displayPath => path == '/' ? '/$spaceProviderId' : '/$spaceProviderId$path';

  factory GallerySourceFolder.fromJson(Map<String, dynamic> json) {
    return GallerySourceFolder(
      id: json['id'] as String? ?? '',
      spaceProviderId: json['spaceProviderId'] as String? ?? '',
      path: json['path'] as String? ?? '/',
    );
  }
}
