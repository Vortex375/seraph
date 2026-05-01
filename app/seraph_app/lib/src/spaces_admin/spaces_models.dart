class Space {
  final String? id;
  final String title;
  final String description;
  final List<String> users;
  final List<SpaceFileProvider> fileProviders;

  Space({
    this.id,
    required this.title,
    required this.description,
    required this.users,
    required this.fileProviders,
  });

  factory Space.fromJson(Map<String, dynamic> json) {
    return Space(
      id: (json['Id'] ?? json['_id']) as String?,
      title: (json['title'] as String?) ?? '',
      description: (json['description'] as String?) ?? '',
      users: (json['users'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      fileProviders: (json['fileProviders'] as List<dynamic>?)
              ?.map((e) =>
                  SpaceFileProvider.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() {
    return {
      if (id != null) '_id': id,
      'title': title,
      'description': description,
      'users': users,
      'fileProviders':
          fileProviders.map((fp) => fp.toJson()).toList(),
    };
  }
}

class SpaceFileProvider {
  final String spaceProviderId;
  final String providerId;
  final String path;
  final bool readOnly;

  SpaceFileProvider({
    required this.spaceProviderId,
    required this.providerId,
    required this.path,
    required this.readOnly,
  });

  factory SpaceFileProvider.fromJson(Map<String, dynamic> json) {
    return SpaceFileProvider(
      spaceProviderId: (json['spaceProviderId'] as String?) ?? '',
      providerId: (json['providerId'] as String?) ?? '',
      path: (json['path'] as String?) ?? '',
      readOnly: (json['readOnly'] as bool?) ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'spaceProviderId': spaceProviderId,
      'providerId': providerId,
      'path': path,
      'readOnly': readOnly,
    };
  }
}

class ServiceAnnouncement {
  final String instanceId;
  final String serviceType;
  final Map<String, String> properties;

  ServiceAnnouncement({
    required this.instanceId,
    required this.serviceType,
    required this.properties,
  });

  factory ServiceAnnouncement.fromJson(Map<String, dynamic> json) {
    final props = <String, String>{};
    final rawProps = json['properties'];
    if (rawProps is Map) {
      rawProps.forEach((k, v) {
        props[k.toString()] = v.toString();
      });
    }
    return ServiceAnnouncement(
      instanceId: (json['instanceId'] as String?) ?? '',
      serviceType: (json['serviceType'] as String?) ?? '',
      properties: props,
    );
  }
}
