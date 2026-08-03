// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'gallery_mirror_database.dart';

// ignore_for_file: type=lint
class $GalleryItemsTable extends GalleryItems
    with TableInfo<$GalleryItemsTable, GalleryItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $GalleryItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _originMeta = const VerificationMeta('origin');
  @override
  late final GeneratedColumn<String> origin = GeneratedColumn<String>(
      'origin', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('cloud'));
  static const VerificationMeta _providerIdMeta =
      const VerificationMeta('providerId');
  @override
  late final GeneratedColumn<String> providerId = GeneratedColumn<String>(
      'provider_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
      'path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _seqMeta = const VerificationMeta('seq');
  @override
  late final GeneratedColumn<int> seq = GeneratedColumn<int>(
      'seq', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _localRelativePathMeta =
      const VerificationMeta('localRelativePath');
  @override
  late final GeneratedColumn<String> localRelativePath =
      GeneratedColumn<String>('local_relative_path', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _localDisplayNameMeta =
      const VerificationMeta('localDisplayName');
  @override
  late final GeneratedColumn<String> localDisplayName = GeneratedColumn<String>(
      'local_display_name', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _localSizeMeta =
      const VerificationMeta('localSize');
  @override
  late final GeneratedColumn<int> localSize = GeneratedColumn<int>(
      'local_size', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _localDateTakenMeta =
      const VerificationMeta('localDateTaken');
  @override
  late final GeneratedColumn<int> localDateTaken = GeneratedColumn<int>(
      'local_date_taken', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _capturedAtMeta =
      const VerificationMeta('capturedAt');
  @override
  late final GeneratedColumn<int> capturedAt = GeneratedColumn<int>(
      'captured_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _capturedAtSourceMeta =
      const VerificationMeta('capturedAtSource');
  @override
  late final GeneratedColumn<String> capturedAtSource = GeneratedColumn<String>(
      'captured_at_source', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<int> width = GeneratedColumn<int>(
      'width', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<int> height = GeneratedColumn<int>(
      'height', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _orientationMeta =
      const VerificationMeta('orientation');
  @override
  late final GeneratedColumn<int> orientation = GeneratedColumn<int>(
      'orientation', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
      'size', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _mimeMeta = const VerificationMeta('mime');
  @override
  late final GeneratedColumn<String> mime = GeneratedColumn<String>(
      'mime', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _unsupportedMeta =
      const VerificationMeta('unsupported');
  @override
  late final GeneratedColumn<String> unsupported = GeneratedColumn<String>(
      'unsupported', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _metadataPendingMeta =
      const VerificationMeta('metadataPending');
  @override
  late final GeneratedColumn<bool> metadataPending = GeneratedColumn<bool>(
      'metadata_pending', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("metadata_pending" IN (0, 1))'),
      defaultValue: const Constant(false));
  @override
  List<GeneratedColumn> get $columns => [
        id,
        origin,
        providerId,
        path,
        seq,
        localRelativePath,
        localDisplayName,
        localSize,
        localDateTaken,
        capturedAt,
        capturedAtSource,
        width,
        height,
        orientation,
        size,
        mime,
        unsupported,
        metadataPending
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'gallery_items';
  @override
  VerificationContext validateIntegrity(Insertable<GalleryItem> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('origin')) {
      context.handle(_originMeta,
          origin.isAcceptableOrUnknown(data['origin']!, _originMeta));
    }
    if (data.containsKey('provider_id')) {
      context.handle(
          _providerIdMeta,
          providerId.isAcceptableOrUnknown(
              data['provider_id']!, _providerIdMeta));
    }
    if (data.containsKey('path')) {
      context.handle(
          _pathMeta, path.isAcceptableOrUnknown(data['path']!, _pathMeta));
    }
    if (data.containsKey('seq')) {
      context.handle(
          _seqMeta, seq.isAcceptableOrUnknown(data['seq']!, _seqMeta));
    }
    if (data.containsKey('local_relative_path')) {
      context.handle(
          _localRelativePathMeta,
          localRelativePath.isAcceptableOrUnknown(
              data['local_relative_path']!, _localRelativePathMeta));
    }
    if (data.containsKey('local_display_name')) {
      context.handle(
          _localDisplayNameMeta,
          localDisplayName.isAcceptableOrUnknown(
              data['local_display_name']!, _localDisplayNameMeta));
    }
    if (data.containsKey('local_size')) {
      context.handle(_localSizeMeta,
          localSize.isAcceptableOrUnknown(data['local_size']!, _localSizeMeta));
    }
    if (data.containsKey('local_date_taken')) {
      context.handle(
          _localDateTakenMeta,
          localDateTaken.isAcceptableOrUnknown(
              data['local_date_taken']!, _localDateTakenMeta));
    }
    if (data.containsKey('captured_at')) {
      context.handle(
          _capturedAtMeta,
          capturedAt.isAcceptableOrUnknown(
              data['captured_at']!, _capturedAtMeta));
    } else if (isInserting) {
      context.missing(_capturedAtMeta);
    }
    if (data.containsKey('captured_at_source')) {
      context.handle(
          _capturedAtSourceMeta,
          capturedAtSource.isAcceptableOrUnknown(
              data['captured_at_source']!, _capturedAtSourceMeta));
    }
    if (data.containsKey('width')) {
      context.handle(
          _widthMeta, width.isAcceptableOrUnknown(data['width']!, _widthMeta));
    }
    if (data.containsKey('height')) {
      context.handle(_heightMeta,
          height.isAcceptableOrUnknown(data['height']!, _heightMeta));
    }
    if (data.containsKey('orientation')) {
      context.handle(
          _orientationMeta,
          orientation.isAcceptableOrUnknown(
              data['orientation']!, _orientationMeta));
    }
    if (data.containsKey('size')) {
      context.handle(
          _sizeMeta, size.isAcceptableOrUnknown(data['size']!, _sizeMeta));
    }
    if (data.containsKey('mime')) {
      context.handle(
          _mimeMeta, mime.isAcceptableOrUnknown(data['mime']!, _mimeMeta));
    }
    if (data.containsKey('unsupported')) {
      context.handle(
          _unsupportedMeta,
          unsupported.isAcceptableOrUnknown(
              data['unsupported']!, _unsupportedMeta));
    }
    if (data.containsKey('metadata_pending')) {
      context.handle(
          _metadataPendingMeta,
          metadataPending.isAcceptableOrUnknown(
              data['metadata_pending']!, _metadataPendingMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {providerId, path},
      ];
  @override
  GalleryItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return GalleryItem(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      origin: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}origin'])!,
      providerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}provider_id']),
      path: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path']),
      seq: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}seq']),
      localRelativePath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}local_relative_path']),
      localDisplayName: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}local_display_name']),
      localSize: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}local_size']),
      localDateTaken: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}local_date_taken']),
      capturedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}captured_at'])!,
      capturedAtSource: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}captured_at_source'])!,
      width: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}width'])!,
      height: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}height'])!,
      orientation: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}orientation'])!,
      size: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}size'])!,
      mime: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}mime'])!,
      unsupported: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}unsupported'])!,
      metadataPending: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}metadata_pending'])!,
    );
  }

  @override
  $GalleryItemsTable createAlias(String alias) {
    return $GalleryItemsTable(attachedDatabase, alias);
  }
}

class GalleryItem extends DataClass implements Insertable<GalleryItem> {
  final int id;

  /// 'cloud', or (from ticket 15 on) 'device' / 'both'. Plain text rather
  /// than a Dart enum mapped column, so a future value does not require a
  /// migration by itself - only new columns do.
  final String origin;

  /// SPACE provider id. Null for a device-only item (none exists yet, but
  /// the column is nullable from the start for that reason).
  final String? providerId;

  /// SPACE path. Null for a device-only item.
  final String? path;

  /// The delta feed sequence this row was last written at. Used only to
  /// decide idempotency of a re-applied page (see
  /// `GallerySyncService.applyPage`); the authoritative "how far has this
  /// device synced" position lives in [SyncCursors], not here.
  final int? seq;
  final String? localRelativePath;
  final String? localDisplayName;
  final int? localSize;
  final int? localDateTaken;

  /// Capture Date in epoch SECONDS (UTC) - the sort key for the merged
  /// gallery view (design decision D5). Seconds, not milliseconds, because
  /// that is what the delta feed carries: the gallery service derives the
  /// value with Go's `time.Time.Unix()` (`gallery/gallery/ingest.go`,
  /// `resolveCaptureDate`) and the mirror stores the wire value unconverted.
  final int capturedAt;
  final String capturedAtSource;
  final int width;
  final int height;

  /// Added in schema v2, exercising the migration mechanism: EXIF
  /// orientation (1-8), defaulting to 0 ("unknown/not set") for rows written
  /// before this column existed.
  final int orientation;
  final int size;
  final String mime;
  final String unsupported;
  final bool metadataPending;
  const GalleryItem(
      {required this.id,
      required this.origin,
      this.providerId,
      this.path,
      this.seq,
      this.localRelativePath,
      this.localDisplayName,
      this.localSize,
      this.localDateTaken,
      required this.capturedAt,
      required this.capturedAtSource,
      required this.width,
      required this.height,
      required this.orientation,
      required this.size,
      required this.mime,
      required this.unsupported,
      required this.metadataPending});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['origin'] = Variable<String>(origin);
    if (!nullToAbsent || providerId != null) {
      map['provider_id'] = Variable<String>(providerId);
    }
    if (!nullToAbsent || path != null) {
      map['path'] = Variable<String>(path);
    }
    if (!nullToAbsent || seq != null) {
      map['seq'] = Variable<int>(seq);
    }
    if (!nullToAbsent || localRelativePath != null) {
      map['local_relative_path'] = Variable<String>(localRelativePath);
    }
    if (!nullToAbsent || localDisplayName != null) {
      map['local_display_name'] = Variable<String>(localDisplayName);
    }
    if (!nullToAbsent || localSize != null) {
      map['local_size'] = Variable<int>(localSize);
    }
    if (!nullToAbsent || localDateTaken != null) {
      map['local_date_taken'] = Variable<int>(localDateTaken);
    }
    map['captured_at'] = Variable<int>(capturedAt);
    map['captured_at_source'] = Variable<String>(capturedAtSource);
    map['width'] = Variable<int>(width);
    map['height'] = Variable<int>(height);
    map['orientation'] = Variable<int>(orientation);
    map['size'] = Variable<int>(size);
    map['mime'] = Variable<String>(mime);
    map['unsupported'] = Variable<String>(unsupported);
    map['metadata_pending'] = Variable<bool>(metadataPending);
    return map;
  }

  GalleryItemsCompanion toCompanion(bool nullToAbsent) {
    return GalleryItemsCompanion(
      id: Value(id),
      origin: Value(origin),
      providerId: providerId == null && nullToAbsent
          ? const Value.absent()
          : Value(providerId),
      path: path == null && nullToAbsent ? const Value.absent() : Value(path),
      seq: seq == null && nullToAbsent ? const Value.absent() : Value(seq),
      localRelativePath: localRelativePath == null && nullToAbsent
          ? const Value.absent()
          : Value(localRelativePath),
      localDisplayName: localDisplayName == null && nullToAbsent
          ? const Value.absent()
          : Value(localDisplayName),
      localSize: localSize == null && nullToAbsent
          ? const Value.absent()
          : Value(localSize),
      localDateTaken: localDateTaken == null && nullToAbsent
          ? const Value.absent()
          : Value(localDateTaken),
      capturedAt: Value(capturedAt),
      capturedAtSource: Value(capturedAtSource),
      width: Value(width),
      height: Value(height),
      orientation: Value(orientation),
      size: Value(size),
      mime: Value(mime),
      unsupported: Value(unsupported),
      metadataPending: Value(metadataPending),
    );
  }

  factory GalleryItem.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return GalleryItem(
      id: serializer.fromJson<int>(json['id']),
      origin: serializer.fromJson<String>(json['origin']),
      providerId: serializer.fromJson<String?>(json['providerId']),
      path: serializer.fromJson<String?>(json['path']),
      seq: serializer.fromJson<int?>(json['seq']),
      localRelativePath:
          serializer.fromJson<String?>(json['localRelativePath']),
      localDisplayName: serializer.fromJson<String?>(json['localDisplayName']),
      localSize: serializer.fromJson<int?>(json['localSize']),
      localDateTaken: serializer.fromJson<int?>(json['localDateTaken']),
      capturedAt: serializer.fromJson<int>(json['capturedAt']),
      capturedAtSource: serializer.fromJson<String>(json['capturedAtSource']),
      width: serializer.fromJson<int>(json['width']),
      height: serializer.fromJson<int>(json['height']),
      orientation: serializer.fromJson<int>(json['orientation']),
      size: serializer.fromJson<int>(json['size']),
      mime: serializer.fromJson<String>(json['mime']),
      unsupported: serializer.fromJson<String>(json['unsupported']),
      metadataPending: serializer.fromJson<bool>(json['metadataPending']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'origin': serializer.toJson<String>(origin),
      'providerId': serializer.toJson<String?>(providerId),
      'path': serializer.toJson<String?>(path),
      'seq': serializer.toJson<int?>(seq),
      'localRelativePath': serializer.toJson<String?>(localRelativePath),
      'localDisplayName': serializer.toJson<String?>(localDisplayName),
      'localSize': serializer.toJson<int?>(localSize),
      'localDateTaken': serializer.toJson<int?>(localDateTaken),
      'capturedAt': serializer.toJson<int>(capturedAt),
      'capturedAtSource': serializer.toJson<String>(capturedAtSource),
      'width': serializer.toJson<int>(width),
      'height': serializer.toJson<int>(height),
      'orientation': serializer.toJson<int>(orientation),
      'size': serializer.toJson<int>(size),
      'mime': serializer.toJson<String>(mime),
      'unsupported': serializer.toJson<String>(unsupported),
      'metadataPending': serializer.toJson<bool>(metadataPending),
    };
  }

  GalleryItem copyWith(
          {int? id,
          String? origin,
          Value<String?> providerId = const Value.absent(),
          Value<String?> path = const Value.absent(),
          Value<int?> seq = const Value.absent(),
          Value<String?> localRelativePath = const Value.absent(),
          Value<String?> localDisplayName = const Value.absent(),
          Value<int?> localSize = const Value.absent(),
          Value<int?> localDateTaken = const Value.absent(),
          int? capturedAt,
          String? capturedAtSource,
          int? width,
          int? height,
          int? orientation,
          int? size,
          String? mime,
          String? unsupported,
          bool? metadataPending}) =>
      GalleryItem(
        id: id ?? this.id,
        origin: origin ?? this.origin,
        providerId: providerId.present ? providerId.value : this.providerId,
        path: path.present ? path.value : this.path,
        seq: seq.present ? seq.value : this.seq,
        localRelativePath: localRelativePath.present
            ? localRelativePath.value
            : this.localRelativePath,
        localDisplayName: localDisplayName.present
            ? localDisplayName.value
            : this.localDisplayName,
        localSize: localSize.present ? localSize.value : this.localSize,
        localDateTaken:
            localDateTaken.present ? localDateTaken.value : this.localDateTaken,
        capturedAt: capturedAt ?? this.capturedAt,
        capturedAtSource: capturedAtSource ?? this.capturedAtSource,
        width: width ?? this.width,
        height: height ?? this.height,
        orientation: orientation ?? this.orientation,
        size: size ?? this.size,
        mime: mime ?? this.mime,
        unsupported: unsupported ?? this.unsupported,
        metadataPending: metadataPending ?? this.metadataPending,
      );
  GalleryItem copyWithCompanion(GalleryItemsCompanion data) {
    return GalleryItem(
      id: data.id.present ? data.id.value : this.id,
      origin: data.origin.present ? data.origin.value : this.origin,
      providerId:
          data.providerId.present ? data.providerId.value : this.providerId,
      path: data.path.present ? data.path.value : this.path,
      seq: data.seq.present ? data.seq.value : this.seq,
      localRelativePath: data.localRelativePath.present
          ? data.localRelativePath.value
          : this.localRelativePath,
      localDisplayName: data.localDisplayName.present
          ? data.localDisplayName.value
          : this.localDisplayName,
      localSize: data.localSize.present ? data.localSize.value : this.localSize,
      localDateTaken: data.localDateTaken.present
          ? data.localDateTaken.value
          : this.localDateTaken,
      capturedAt:
          data.capturedAt.present ? data.capturedAt.value : this.capturedAt,
      capturedAtSource: data.capturedAtSource.present
          ? data.capturedAtSource.value
          : this.capturedAtSource,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      orientation:
          data.orientation.present ? data.orientation.value : this.orientation,
      size: data.size.present ? data.size.value : this.size,
      mime: data.mime.present ? data.mime.value : this.mime,
      unsupported:
          data.unsupported.present ? data.unsupported.value : this.unsupported,
      metadataPending: data.metadataPending.present
          ? data.metadataPending.value
          : this.metadataPending,
    );
  }

  @override
  String toString() {
    return (StringBuffer('GalleryItem(')
          ..write('id: $id, ')
          ..write('origin: $origin, ')
          ..write('providerId: $providerId, ')
          ..write('path: $path, ')
          ..write('seq: $seq, ')
          ..write('localRelativePath: $localRelativePath, ')
          ..write('localDisplayName: $localDisplayName, ')
          ..write('localSize: $localSize, ')
          ..write('localDateTaken: $localDateTaken, ')
          ..write('capturedAt: $capturedAt, ')
          ..write('capturedAtSource: $capturedAtSource, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('orientation: $orientation, ')
          ..write('size: $size, ')
          ..write('mime: $mime, ')
          ..write('unsupported: $unsupported, ')
          ..write('metadataPending: $metadataPending')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      origin,
      providerId,
      path,
      seq,
      localRelativePath,
      localDisplayName,
      localSize,
      localDateTaken,
      capturedAt,
      capturedAtSource,
      width,
      height,
      orientation,
      size,
      mime,
      unsupported,
      metadataPending);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is GalleryItem &&
          other.id == this.id &&
          other.origin == this.origin &&
          other.providerId == this.providerId &&
          other.path == this.path &&
          other.seq == this.seq &&
          other.localRelativePath == this.localRelativePath &&
          other.localDisplayName == this.localDisplayName &&
          other.localSize == this.localSize &&
          other.localDateTaken == this.localDateTaken &&
          other.capturedAt == this.capturedAt &&
          other.capturedAtSource == this.capturedAtSource &&
          other.width == this.width &&
          other.height == this.height &&
          other.orientation == this.orientation &&
          other.size == this.size &&
          other.mime == this.mime &&
          other.unsupported == this.unsupported &&
          other.metadataPending == this.metadataPending);
}

class GalleryItemsCompanion extends UpdateCompanion<GalleryItem> {
  final Value<int> id;
  final Value<String> origin;
  final Value<String?> providerId;
  final Value<String?> path;
  final Value<int?> seq;
  final Value<String?> localRelativePath;
  final Value<String?> localDisplayName;
  final Value<int?> localSize;
  final Value<int?> localDateTaken;
  final Value<int> capturedAt;
  final Value<String> capturedAtSource;
  final Value<int> width;
  final Value<int> height;
  final Value<int> orientation;
  final Value<int> size;
  final Value<String> mime;
  final Value<String> unsupported;
  final Value<bool> metadataPending;
  const GalleryItemsCompanion({
    this.id = const Value.absent(),
    this.origin = const Value.absent(),
    this.providerId = const Value.absent(),
    this.path = const Value.absent(),
    this.seq = const Value.absent(),
    this.localRelativePath = const Value.absent(),
    this.localDisplayName = const Value.absent(),
    this.localSize = const Value.absent(),
    this.localDateTaken = const Value.absent(),
    this.capturedAt = const Value.absent(),
    this.capturedAtSource = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.orientation = const Value.absent(),
    this.size = const Value.absent(),
    this.mime = const Value.absent(),
    this.unsupported = const Value.absent(),
    this.metadataPending = const Value.absent(),
  });
  GalleryItemsCompanion.insert({
    this.id = const Value.absent(),
    this.origin = const Value.absent(),
    this.providerId = const Value.absent(),
    this.path = const Value.absent(),
    this.seq = const Value.absent(),
    this.localRelativePath = const Value.absent(),
    this.localDisplayName = const Value.absent(),
    this.localSize = const Value.absent(),
    this.localDateTaken = const Value.absent(),
    required int capturedAt,
    this.capturedAtSource = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.orientation = const Value.absent(),
    this.size = const Value.absent(),
    this.mime = const Value.absent(),
    this.unsupported = const Value.absent(),
    this.metadataPending = const Value.absent(),
  }) : capturedAt = Value(capturedAt);
  static Insertable<GalleryItem> custom({
    Expression<int>? id,
    Expression<String>? origin,
    Expression<String>? providerId,
    Expression<String>? path,
    Expression<int>? seq,
    Expression<String>? localRelativePath,
    Expression<String>? localDisplayName,
    Expression<int>? localSize,
    Expression<int>? localDateTaken,
    Expression<int>? capturedAt,
    Expression<String>? capturedAtSource,
    Expression<int>? width,
    Expression<int>? height,
    Expression<int>? orientation,
    Expression<int>? size,
    Expression<String>? mime,
    Expression<String>? unsupported,
    Expression<bool>? metadataPending,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (origin != null) 'origin': origin,
      if (providerId != null) 'provider_id': providerId,
      if (path != null) 'path': path,
      if (seq != null) 'seq': seq,
      if (localRelativePath != null) 'local_relative_path': localRelativePath,
      if (localDisplayName != null) 'local_display_name': localDisplayName,
      if (localSize != null) 'local_size': localSize,
      if (localDateTaken != null) 'local_date_taken': localDateTaken,
      if (capturedAt != null) 'captured_at': capturedAt,
      if (capturedAtSource != null) 'captured_at_source': capturedAtSource,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (orientation != null) 'orientation': orientation,
      if (size != null) 'size': size,
      if (mime != null) 'mime': mime,
      if (unsupported != null) 'unsupported': unsupported,
      if (metadataPending != null) 'metadata_pending': metadataPending,
    });
  }

  GalleryItemsCompanion copyWith(
      {Value<int>? id,
      Value<String>? origin,
      Value<String?>? providerId,
      Value<String?>? path,
      Value<int?>? seq,
      Value<String?>? localRelativePath,
      Value<String?>? localDisplayName,
      Value<int?>? localSize,
      Value<int?>? localDateTaken,
      Value<int>? capturedAt,
      Value<String>? capturedAtSource,
      Value<int>? width,
      Value<int>? height,
      Value<int>? orientation,
      Value<int>? size,
      Value<String>? mime,
      Value<String>? unsupported,
      Value<bool>? metadataPending}) {
    return GalleryItemsCompanion(
      id: id ?? this.id,
      origin: origin ?? this.origin,
      providerId: providerId ?? this.providerId,
      path: path ?? this.path,
      seq: seq ?? this.seq,
      localRelativePath: localRelativePath ?? this.localRelativePath,
      localDisplayName: localDisplayName ?? this.localDisplayName,
      localSize: localSize ?? this.localSize,
      localDateTaken: localDateTaken ?? this.localDateTaken,
      capturedAt: capturedAt ?? this.capturedAt,
      capturedAtSource: capturedAtSource ?? this.capturedAtSource,
      width: width ?? this.width,
      height: height ?? this.height,
      orientation: orientation ?? this.orientation,
      size: size ?? this.size,
      mime: mime ?? this.mime,
      unsupported: unsupported ?? this.unsupported,
      metadataPending: metadataPending ?? this.metadataPending,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (origin.present) {
      map['origin'] = Variable<String>(origin.value);
    }
    if (providerId.present) {
      map['provider_id'] = Variable<String>(providerId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (seq.present) {
      map['seq'] = Variable<int>(seq.value);
    }
    if (localRelativePath.present) {
      map['local_relative_path'] = Variable<String>(localRelativePath.value);
    }
    if (localDisplayName.present) {
      map['local_display_name'] = Variable<String>(localDisplayName.value);
    }
    if (localSize.present) {
      map['local_size'] = Variable<int>(localSize.value);
    }
    if (localDateTaken.present) {
      map['local_date_taken'] = Variable<int>(localDateTaken.value);
    }
    if (capturedAt.present) {
      map['captured_at'] = Variable<int>(capturedAt.value);
    }
    if (capturedAtSource.present) {
      map['captured_at_source'] = Variable<String>(capturedAtSource.value);
    }
    if (width.present) {
      map['width'] = Variable<int>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<int>(height.value);
    }
    if (orientation.present) {
      map['orientation'] = Variable<int>(orientation.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (mime.present) {
      map['mime'] = Variable<String>(mime.value);
    }
    if (unsupported.present) {
      map['unsupported'] = Variable<String>(unsupported.value);
    }
    if (metadataPending.present) {
      map['metadata_pending'] = Variable<bool>(metadataPending.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('GalleryItemsCompanion(')
          ..write('id: $id, ')
          ..write('origin: $origin, ')
          ..write('providerId: $providerId, ')
          ..write('path: $path, ')
          ..write('seq: $seq, ')
          ..write('localRelativePath: $localRelativePath, ')
          ..write('localDisplayName: $localDisplayName, ')
          ..write('localSize: $localSize, ')
          ..write('localDateTaken: $localDateTaken, ')
          ..write('capturedAt: $capturedAt, ')
          ..write('capturedAtSource: $capturedAtSource, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('orientation: $orientation, ')
          ..write('size: $size, ')
          ..write('mime: $mime, ')
          ..write('unsupported: $unsupported, ')
          ..write('metadataPending: $metadataPending')
          ..write(')'))
        .toString();
  }
}

class $SyncCursorsTable extends SyncCursors
    with TableInfo<$SyncCursorsTable, SyncCursor> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncCursorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
      'source', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sinceMeta = const VerificationMeta('since');
  @override
  late final GeneratedColumn<int> since = GeneratedColumn<int>(
      'since', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _pendingCursorMeta =
      const VerificationMeta('pendingCursor');
  @override
  late final GeneratedColumn<String> pendingCursor = GeneratedColumn<String>(
      'pending_cursor', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [source, since, pendingCursor];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_cursors';
  @override
  VerificationContext validateIntegrity(Insertable<SyncCursor> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('source')) {
      context.handle(_sourceMeta,
          source.isAcceptableOrUnknown(data['source']!, _sourceMeta));
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('since')) {
      context.handle(
          _sinceMeta, since.isAcceptableOrUnknown(data['since']!, _sinceMeta));
    }
    if (data.containsKey('pending_cursor')) {
      context.handle(
          _pendingCursorMeta,
          pendingCursor.isAcceptableOrUnknown(
              data['pending_cursor']!, _pendingCursorMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {source};
  @override
  SyncCursor map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncCursor(
      source: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source'])!,
      since: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}since'])!,
      pendingCursor: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}pending_cursor']),
    );
  }

  @override
  $SyncCursorsTable createAlias(String alias) {
    return $SyncCursorsTable(attachedDatabase, alias);
  }
}

class SyncCursor extends DataClass implements Insertable<SyncCursor> {
  final String source;
  final int since;
  final String? pendingCursor;
  const SyncCursor(
      {required this.source, required this.since, this.pendingCursor});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['source'] = Variable<String>(source);
    map['since'] = Variable<int>(since);
    if (!nullToAbsent || pendingCursor != null) {
      map['pending_cursor'] = Variable<String>(pendingCursor);
    }
    return map;
  }

  SyncCursorsCompanion toCompanion(bool nullToAbsent) {
    return SyncCursorsCompanion(
      source: Value(source),
      since: Value(since),
      pendingCursor: pendingCursor == null && nullToAbsent
          ? const Value.absent()
          : Value(pendingCursor),
    );
  }

  factory SyncCursor.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncCursor(
      source: serializer.fromJson<String>(json['source']),
      since: serializer.fromJson<int>(json['since']),
      pendingCursor: serializer.fromJson<String?>(json['pendingCursor']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'source': serializer.toJson<String>(source),
      'since': serializer.toJson<int>(since),
      'pendingCursor': serializer.toJson<String?>(pendingCursor),
    };
  }

  SyncCursor copyWith(
          {String? source,
          int? since,
          Value<String?> pendingCursor = const Value.absent()}) =>
      SyncCursor(
        source: source ?? this.source,
        since: since ?? this.since,
        pendingCursor:
            pendingCursor.present ? pendingCursor.value : this.pendingCursor,
      );
  SyncCursor copyWithCompanion(SyncCursorsCompanion data) {
    return SyncCursor(
      source: data.source.present ? data.source.value : this.source,
      since: data.since.present ? data.since.value : this.since,
      pendingCursor: data.pendingCursor.present
          ? data.pendingCursor.value
          : this.pendingCursor,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncCursor(')
          ..write('source: $source, ')
          ..write('since: $since, ')
          ..write('pendingCursor: $pendingCursor')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(source, since, pendingCursor);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncCursor &&
          other.source == this.source &&
          other.since == this.since &&
          other.pendingCursor == this.pendingCursor);
}

class SyncCursorsCompanion extends UpdateCompanion<SyncCursor> {
  final Value<String> source;
  final Value<int> since;
  final Value<String?> pendingCursor;
  final Value<int> rowid;
  const SyncCursorsCompanion({
    this.source = const Value.absent(),
    this.since = const Value.absent(),
    this.pendingCursor = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncCursorsCompanion.insert({
    required String source,
    this.since = const Value.absent(),
    this.pendingCursor = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : source = Value(source);
  static Insertable<SyncCursor> custom({
    Expression<String>? source,
    Expression<int>? since,
    Expression<String>? pendingCursor,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (source != null) 'source': source,
      if (since != null) 'since': since,
      if (pendingCursor != null) 'pending_cursor': pendingCursor,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncCursorsCompanion copyWith(
      {Value<String>? source,
      Value<int>? since,
      Value<String?>? pendingCursor,
      Value<int>? rowid}) {
    return SyncCursorsCompanion(
      source: source ?? this.source,
      since: since ?? this.since,
      pendingCursor: pendingCursor ?? this.pendingCursor,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (since.present) {
      map['since'] = Variable<int>(since.value);
    }
    if (pendingCursor.present) {
      map['pending_cursor'] = Variable<String>(pendingCursor.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncCursorsCompanion(')
          ..write('source: $source, ')
          ..write('since: $since, ')
          ..write('pendingCursor: $pendingCursor, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $CachedThumbnailsTable extends CachedThumbnails
    with TableInfo<$CachedThumbnailsTable, CachedThumbnail> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $CachedThumbnailsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _providerIdMeta =
      const VerificationMeta('providerId');
  @override
  late final GeneratedColumn<String> providerId = GeneratedColumn<String>(
      'provider_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
      'path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
      'size', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
      'bytes', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _fetchedAtMeta =
      const VerificationMeta('fetchedAt');
  @override
  late final GeneratedColumn<int> fetchedAt = GeneratedColumn<int>(
      'fetched_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [providerId, path, size, bytes, fetchedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'cached_thumbnails';
  @override
  VerificationContext validateIntegrity(Insertable<CachedThumbnail> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('provider_id')) {
      context.handle(
          _providerIdMeta,
          providerId.isAcceptableOrUnknown(
              data['provider_id']!, _providerIdMeta));
    } else if (isInserting) {
      context.missing(_providerIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
          _pathMeta, path.isAcceptableOrUnknown(data['path']!, _pathMeta));
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('size')) {
      context.handle(
          _sizeMeta, size.isAcceptableOrUnknown(data['size']!, _sizeMeta));
    } else if (isInserting) {
      context.missing(_sizeMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(
          _bytesMeta, bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta));
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    if (data.containsKey('fetched_at')) {
      context.handle(_fetchedAtMeta,
          fetchedAt.isAcceptableOrUnknown(data['fetched_at']!, _fetchedAtMeta));
    } else if (isInserting) {
      context.missing(_fetchedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {providerId, path, size};
  @override
  CachedThumbnail map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return CachedThumbnail(
      providerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}provider_id'])!,
      path: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!,
      size: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}size'])!,
      bytes: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}bytes'])!,
      fetchedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}fetched_at'])!,
    );
  }

  @override
  $CachedThumbnailsTable createAlias(String alias) {
    return $CachedThumbnailsTable(attachedDatabase, alias);
  }
}

class CachedThumbnail extends DataClass implements Insertable<CachedThumbnail> {
  final String providerId;
  final String path;

  /// The `w`/`h` value the preview endpoint was asked for. The endpoint snaps
  /// to its own size ladder, so this is the requested size, not necessarily
  /// the returned pixel size.
  final int size;
  final Uint8List bytes;

  /// Epoch milliseconds this entry was written, used for oldest-first
  /// eviction.
  final int fetchedAt;
  const CachedThumbnail(
      {required this.providerId,
      required this.path,
      required this.size,
      required this.bytes,
      required this.fetchedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['provider_id'] = Variable<String>(providerId);
    map['path'] = Variable<String>(path);
    map['size'] = Variable<int>(size);
    map['bytes'] = Variable<Uint8List>(bytes);
    map['fetched_at'] = Variable<int>(fetchedAt);
    return map;
  }

  CachedThumbnailsCompanion toCompanion(bool nullToAbsent) {
    return CachedThumbnailsCompanion(
      providerId: Value(providerId),
      path: Value(path),
      size: Value(size),
      bytes: Value(bytes),
      fetchedAt: Value(fetchedAt),
    );
  }

  factory CachedThumbnail.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return CachedThumbnail(
      providerId: serializer.fromJson<String>(json['providerId']),
      path: serializer.fromJson<String>(json['path']),
      size: serializer.fromJson<int>(json['size']),
      bytes: serializer.fromJson<Uint8List>(json['bytes']),
      fetchedAt: serializer.fromJson<int>(json['fetchedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'providerId': serializer.toJson<String>(providerId),
      'path': serializer.toJson<String>(path),
      'size': serializer.toJson<int>(size),
      'bytes': serializer.toJson<Uint8List>(bytes),
      'fetchedAt': serializer.toJson<int>(fetchedAt),
    };
  }

  CachedThumbnail copyWith(
          {String? providerId,
          String? path,
          int? size,
          Uint8List? bytes,
          int? fetchedAt}) =>
      CachedThumbnail(
        providerId: providerId ?? this.providerId,
        path: path ?? this.path,
        size: size ?? this.size,
        bytes: bytes ?? this.bytes,
        fetchedAt: fetchedAt ?? this.fetchedAt,
      );
  CachedThumbnail copyWithCompanion(CachedThumbnailsCompanion data) {
    return CachedThumbnail(
      providerId:
          data.providerId.present ? data.providerId.value : this.providerId,
      path: data.path.present ? data.path.value : this.path,
      size: data.size.present ? data.size.value : this.size,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      fetchedAt: data.fetchedAt.present ? data.fetchedAt.value : this.fetchedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('CachedThumbnail(')
          ..write('providerId: $providerId, ')
          ..write('path: $path, ')
          ..write('size: $size, ')
          ..write('bytes: $bytes, ')
          ..write('fetchedAt: $fetchedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      providerId, path, size, $driftBlobEquality.hash(bytes), fetchedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is CachedThumbnail &&
          other.providerId == this.providerId &&
          other.path == this.path &&
          other.size == this.size &&
          $driftBlobEquality.equals(other.bytes, this.bytes) &&
          other.fetchedAt == this.fetchedAt);
}

class CachedThumbnailsCompanion extends UpdateCompanion<CachedThumbnail> {
  final Value<String> providerId;
  final Value<String> path;
  final Value<int> size;
  final Value<Uint8List> bytes;
  final Value<int> fetchedAt;
  final Value<int> rowid;
  const CachedThumbnailsCompanion({
    this.providerId = const Value.absent(),
    this.path = const Value.absent(),
    this.size = const Value.absent(),
    this.bytes = const Value.absent(),
    this.fetchedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  CachedThumbnailsCompanion.insert({
    required String providerId,
    required String path,
    required int size,
    required Uint8List bytes,
    required int fetchedAt,
    this.rowid = const Value.absent(),
  })  : providerId = Value(providerId),
        path = Value(path),
        size = Value(size),
        bytes = Value(bytes),
        fetchedAt = Value(fetchedAt);
  static Insertable<CachedThumbnail> custom({
    Expression<String>? providerId,
    Expression<String>? path,
    Expression<int>? size,
    Expression<Uint8List>? bytes,
    Expression<int>? fetchedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (providerId != null) 'provider_id': providerId,
      if (path != null) 'path': path,
      if (size != null) 'size': size,
      if (bytes != null) 'bytes': bytes,
      if (fetchedAt != null) 'fetched_at': fetchedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  CachedThumbnailsCompanion copyWith(
      {Value<String>? providerId,
      Value<String>? path,
      Value<int>? size,
      Value<Uint8List>? bytes,
      Value<int>? fetchedAt,
      Value<int>? rowid}) {
    return CachedThumbnailsCompanion(
      providerId: providerId ?? this.providerId,
      path: path ?? this.path,
      size: size ?? this.size,
      bytes: bytes ?? this.bytes,
      fetchedAt: fetchedAt ?? this.fetchedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (providerId.present) {
      map['provider_id'] = Variable<String>(providerId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (fetchedAt.present) {
      map['fetched_at'] = Variable<int>(fetchedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('CachedThumbnailsCompanion(')
          ..write('providerId: $providerId, ')
          ..write('path: $path, ')
          ..write('size: $size, ')
          ..write('bytes: $bytes, ')
          ..write('fetchedAt: $fetchedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalFolderSelectionsTable extends LocalFolderSelections
    with TableInfo<$LocalFolderSelectionsTable, LocalFolderSelection> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalFolderSelectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _folderPathMeta =
      const VerificationMeta('folderPath');
  @override
  late final GeneratedColumn<String> folderPath = GeneratedColumn<String>(
      'folder_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _selectedMeta =
      const VerificationMeta('selected');
  @override
  late final GeneratedColumn<bool> selected = GeneratedColumn<bool>(
      'selected', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("selected" IN (0, 1))'));
  @override
  List<GeneratedColumn> get $columns => [folderPath, selected];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_folder_selections';
  @override
  VerificationContext validateIntegrity(
      Insertable<LocalFolderSelection> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('folder_path')) {
      context.handle(
          _folderPathMeta,
          folderPath.isAcceptableOrUnknown(
              data['folder_path']!, _folderPathMeta));
    } else if (isInserting) {
      context.missing(_folderPathMeta);
    }
    if (data.containsKey('selected')) {
      context.handle(_selectedMeta,
          selected.isAcceptableOrUnknown(data['selected']!, _selectedMeta));
    } else if (isInserting) {
      context.missing(_selectedMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {folderPath};
  @override
  LocalFolderSelection map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalFolderSelection(
      folderPath: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}folder_path'])!,
      selected: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}selected'])!,
    );
  }

  @override
  $LocalFolderSelectionsTable createAlias(String alias) {
    return $LocalFolderSelectionsTable(attachedDatabase, alias);
  }
}

class LocalFolderSelection extends DataClass
    implements Insertable<LocalFolderSelection> {
  /// The device's own folder identifier - on Android, MediaStore's
  /// `RELATIVE_PATH` value (e.g. `DCIM/Camera/`), exactly the string
  /// [GalleryItems.localRelativePath] stores - so folder enumeration and
  /// selection lookup are a plain equality match, no normalisation needed.
  final String folderPath;
  final bool selected;
  const LocalFolderSelection(
      {required this.folderPath, required this.selected});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['folder_path'] = Variable<String>(folderPath);
    map['selected'] = Variable<bool>(selected);
    return map;
  }

  LocalFolderSelectionsCompanion toCompanion(bool nullToAbsent) {
    return LocalFolderSelectionsCompanion(
      folderPath: Value(folderPath),
      selected: Value(selected),
    );
  }

  factory LocalFolderSelection.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalFolderSelection(
      folderPath: serializer.fromJson<String>(json['folderPath']),
      selected: serializer.fromJson<bool>(json['selected']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'folderPath': serializer.toJson<String>(folderPath),
      'selected': serializer.toJson<bool>(selected),
    };
  }

  LocalFolderSelection copyWith({String? folderPath, bool? selected}) =>
      LocalFolderSelection(
        folderPath: folderPath ?? this.folderPath,
        selected: selected ?? this.selected,
      );
  LocalFolderSelection copyWithCompanion(LocalFolderSelectionsCompanion data) {
    return LocalFolderSelection(
      folderPath:
          data.folderPath.present ? data.folderPath.value : this.folderPath,
      selected: data.selected.present ? data.selected.value : this.selected,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalFolderSelection(')
          ..write('folderPath: $folderPath, ')
          ..write('selected: $selected')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(folderPath, selected);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalFolderSelection &&
          other.folderPath == this.folderPath &&
          other.selected == this.selected);
}

class LocalFolderSelectionsCompanion
    extends UpdateCompanion<LocalFolderSelection> {
  final Value<String> folderPath;
  final Value<bool> selected;
  final Value<int> rowid;
  const LocalFolderSelectionsCompanion({
    this.folderPath = const Value.absent(),
    this.selected = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalFolderSelectionsCompanion.insert({
    required String folderPath,
    required bool selected,
    this.rowid = const Value.absent(),
  })  : folderPath = Value(folderPath),
        selected = Value(selected);
  static Insertable<LocalFolderSelection> custom({
    Expression<String>? folderPath,
    Expression<bool>? selected,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (folderPath != null) 'folder_path': folderPath,
      if (selected != null) 'selected': selected,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalFolderSelectionsCompanion copyWith(
      {Value<String>? folderPath, Value<bool>? selected, Value<int>? rowid}) {
    return LocalFolderSelectionsCompanion(
      folderPath: folderPath ?? this.folderPath,
      selected: selected ?? this.selected,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (folderPath.present) {
      map['folder_path'] = Variable<String>(folderPath.value);
    }
    if (selected.present) {
      map['selected'] = Variable<bool>(selected.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalFolderSelectionsCompanion(')
          ..write('folderPath: $folderPath, ')
          ..write('selected: $selected, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncPairsTable extends SyncPairs
    with TableInfo<$SyncPairsTable, SyncPairRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncPairsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _localFolderPathMeta =
      const VerificationMeta('localFolderPath');
  @override
  late final GeneratedColumn<String> localFolderPath = GeneratedColumn<String>(
      'local_folder_path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _spaceProviderIdMeta =
      const VerificationMeta('spaceProviderId');
  @override
  late final GeneratedColumn<String> spaceProviderId = GeneratedColumn<String>(
      'space_provider_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
      'path', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
      'created_at', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  @override
  List<GeneratedColumn> get $columns =>
      [id, localFolderPath, spaceProviderId, path, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_pairs';
  @override
  VerificationContext validateIntegrity(Insertable<SyncPairRow> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('local_folder_path')) {
      context.handle(
          _localFolderPathMeta,
          localFolderPath.isAcceptableOrUnknown(
              data['local_folder_path']!, _localFolderPathMeta));
    } else if (isInserting) {
      context.missing(_localFolderPathMeta);
    }
    if (data.containsKey('space_provider_id')) {
      context.handle(
          _spaceProviderIdMeta,
          spaceProviderId.isAcceptableOrUnknown(
              data['space_provider_id']!, _spaceProviderIdMeta));
    } else if (isInserting) {
      context.missing(_spaceProviderIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
          _pathMeta, path.isAcceptableOrUnknown(data['path']!, _pathMeta));
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
        {localFolderPath},
      ];
  @override
  SyncPairRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncPairRow(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      localFolderPath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}local_folder_path'])!,
      spaceProviderId: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}space_provider_id'])!,
      path: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}path'])!,
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $SyncPairsTable createAlias(String alias) {
    return $SyncPairsTable(attachedDatabase, alias);
  }
}

class SyncPairRow extends DataClass implements Insertable<SyncPairRow> {
  final int id;

  /// The device-side Local Source - on Android, MediaStore's `RELATIVE_PATH`
  /// for the folder (e.g. `DCIM/Camera/`), exactly the string
  /// [GalleryItems.localRelativePath] and [LocalFolderSelections.folderPath]
  /// use, so "which folder" means the same thing everywhere in the mirror.
  /// Coverage of a subfolder is a plain string-prefix test against this
  /// value (both always trailing-slash-terminated, so `DCIM/Camera/` can
  /// never falsely prefix-match `DCIM/Camera2/`).
  final String localFolderPath;

  /// The Seraph folder side, in Space terms - the same
  /// (spaceProviderId, path) pair [GallerySourceFolder] uses, since this
  /// folder IS one (ticket 18's rule: a Sync Pair's Seraph folder
  /// automatically becomes a Gallery Source Folder).
  final String spaceProviderId;
  final String path;

  /// Epoch milliseconds this pair was created - used only to order
  /// [GalleryMirror.listSyncPairs] (oldest first, so the list does not
  /// reorder itself as photo counts change).
  final int createdAt;
  const SyncPairRow(
      {required this.id,
      required this.localFolderPath,
      required this.spaceProviderId,
      required this.path,
      required this.createdAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['local_folder_path'] = Variable<String>(localFolderPath);
    map['space_provider_id'] = Variable<String>(spaceProviderId);
    map['path'] = Variable<String>(path);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  SyncPairsCompanion toCompanion(bool nullToAbsent) {
    return SyncPairsCompanion(
      id: Value(id),
      localFolderPath: Value(localFolderPath),
      spaceProviderId: Value(spaceProviderId),
      path: Value(path),
      createdAt: Value(createdAt),
    );
  }

  factory SyncPairRow.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncPairRow(
      id: serializer.fromJson<int>(json['id']),
      localFolderPath: serializer.fromJson<String>(json['localFolderPath']),
      spaceProviderId: serializer.fromJson<String>(json['spaceProviderId']),
      path: serializer.fromJson<String>(json['path']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'localFolderPath': serializer.toJson<String>(localFolderPath),
      'spaceProviderId': serializer.toJson<String>(spaceProviderId),
      'path': serializer.toJson<String>(path),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  SyncPairRow copyWith(
          {int? id,
          String? localFolderPath,
          String? spaceProviderId,
          String? path,
          int? createdAt}) =>
      SyncPairRow(
        id: id ?? this.id,
        localFolderPath: localFolderPath ?? this.localFolderPath,
        spaceProviderId: spaceProviderId ?? this.spaceProviderId,
        path: path ?? this.path,
        createdAt: createdAt ?? this.createdAt,
      );
  SyncPairRow copyWithCompanion(SyncPairsCompanion data) {
    return SyncPairRow(
      id: data.id.present ? data.id.value : this.id,
      localFolderPath: data.localFolderPath.present
          ? data.localFolderPath.value
          : this.localFolderPath,
      spaceProviderId: data.spaceProviderId.present
          ? data.spaceProviderId.value
          : this.spaceProviderId,
      path: data.path.present ? data.path.value : this.path,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncPairRow(')
          ..write('id: $id, ')
          ..write('localFolderPath: $localFolderPath, ')
          ..write('spaceProviderId: $spaceProviderId, ')
          ..write('path: $path, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, localFolderPath, spaceProviderId, path, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncPairRow &&
          other.id == this.id &&
          other.localFolderPath == this.localFolderPath &&
          other.spaceProviderId == this.spaceProviderId &&
          other.path == this.path &&
          other.createdAt == this.createdAt);
}

class SyncPairsCompanion extends UpdateCompanion<SyncPairRow> {
  final Value<int> id;
  final Value<String> localFolderPath;
  final Value<String> spaceProviderId;
  final Value<String> path;
  final Value<int> createdAt;
  const SyncPairsCompanion({
    this.id = const Value.absent(),
    this.localFolderPath = const Value.absent(),
    this.spaceProviderId = const Value.absent(),
    this.path = const Value.absent(),
    this.createdAt = const Value.absent(),
  });
  SyncPairsCompanion.insert({
    this.id = const Value.absent(),
    required String localFolderPath,
    required String spaceProviderId,
    required String path,
    this.createdAt = const Value.absent(),
  })  : localFolderPath = Value(localFolderPath),
        spaceProviderId = Value(spaceProviderId),
        path = Value(path);
  static Insertable<SyncPairRow> custom({
    Expression<int>? id,
    Expression<String>? localFolderPath,
    Expression<String>? spaceProviderId,
    Expression<String>? path,
    Expression<int>? createdAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (localFolderPath != null) 'local_folder_path': localFolderPath,
      if (spaceProviderId != null) 'space_provider_id': spaceProviderId,
      if (path != null) 'path': path,
      if (createdAt != null) 'created_at': createdAt,
    });
  }

  SyncPairsCompanion copyWith(
      {Value<int>? id,
      Value<String>? localFolderPath,
      Value<String>? spaceProviderId,
      Value<String>? path,
      Value<int>? createdAt}) {
    return SyncPairsCompanion(
      id: id ?? this.id,
      localFolderPath: localFolderPath ?? this.localFolderPath,
      spaceProviderId: spaceProviderId ?? this.spaceProviderId,
      path: path ?? this.path,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (localFolderPath.present) {
      map['local_folder_path'] = Variable<String>(localFolderPath.value);
    }
    if (spaceProviderId.present) {
      map['space_provider_id'] = Variable<String>(spaceProviderId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncPairsCompanion(')
          ..write('id: $id, ')
          ..write('localFolderPath: $localFolderPath, ')
          ..write('spaceProviderId: $spaceProviderId, ')
          ..write('path: $path, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }
}

abstract class _$GalleryMirrorDatabase extends GeneratedDatabase {
  _$GalleryMirrorDatabase(QueryExecutor e) : super(e);
  $GalleryMirrorDatabaseManager get managers =>
      $GalleryMirrorDatabaseManager(this);
  late final $GalleryItemsTable galleryItems = $GalleryItemsTable(this);
  late final $SyncCursorsTable syncCursors = $SyncCursorsTable(this);
  late final $CachedThumbnailsTable cachedThumbnails =
      $CachedThumbnailsTable(this);
  late final $LocalFolderSelectionsTable localFolderSelections =
      $LocalFolderSelectionsTable(this);
  late final $SyncPairsTable syncPairs = $SyncPairsTable(this);
  late final Index idxGalleryItemsLocalIdentity = Index(
      'idx_gallery_items_local_identity',
      'CREATE INDEX idx_gallery_items_local_identity ON gallery_items (local_relative_path, local_display_name, local_size, local_date_taken)');
  late final Index idxGalleryItemsOriginSizeCapturedAt = Index(
      'idx_gallery_items_origin_size_captured_at',
      'CREATE INDEX idx_gallery_items_origin_size_captured_at ON gallery_items (origin, size, captured_at)');
  late final Index idxGalleryItemsCapturedAtId = Index(
      'idx_gallery_items_captured_at_id',
      'CREATE INDEX idx_gallery_items_captured_at_id ON gallery_items (captured_at, id)');
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        galleryItems,
        syncCursors,
        cachedThumbnails,
        localFolderSelections,
        syncPairs,
        idxGalleryItemsLocalIdentity,
        idxGalleryItemsOriginSizeCapturedAt,
        idxGalleryItemsCapturedAtId
      ];
}

typedef $$GalleryItemsTableCreateCompanionBuilder = GalleryItemsCompanion
    Function({
  Value<int> id,
  Value<String> origin,
  Value<String?> providerId,
  Value<String?> path,
  Value<int?> seq,
  Value<String?> localRelativePath,
  Value<String?> localDisplayName,
  Value<int?> localSize,
  Value<int?> localDateTaken,
  required int capturedAt,
  Value<String> capturedAtSource,
  Value<int> width,
  Value<int> height,
  Value<int> orientation,
  Value<int> size,
  Value<String> mime,
  Value<String> unsupported,
  Value<bool> metadataPending,
});
typedef $$GalleryItemsTableUpdateCompanionBuilder = GalleryItemsCompanion
    Function({
  Value<int> id,
  Value<String> origin,
  Value<String?> providerId,
  Value<String?> path,
  Value<int?> seq,
  Value<String?> localRelativePath,
  Value<String?> localDisplayName,
  Value<int?> localSize,
  Value<int?> localDateTaken,
  Value<int> capturedAt,
  Value<String> capturedAtSource,
  Value<int> width,
  Value<int> height,
  Value<int> orientation,
  Value<int> size,
  Value<String> mime,
  Value<String> unsupported,
  Value<bool> metadataPending,
});

class $$GalleryItemsTableFilterComposer
    extends Composer<_$GalleryMirrorDatabase, $GalleryItemsTable> {
  $$GalleryItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get origin => $composableBuilder(
      column: $table.origin, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get providerId => $composableBuilder(
      column: $table.providerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get seq => $composableBuilder(
      column: $table.seq, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localRelativePath => $composableBuilder(
      column: $table.localRelativePath,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localDisplayName => $composableBuilder(
      column: $table.localDisplayName,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get localSize => $composableBuilder(
      column: $table.localSize, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get localDateTaken => $composableBuilder(
      column: $table.localDateTaken,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get capturedAt => $composableBuilder(
      column: $table.capturedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get capturedAtSource => $composableBuilder(
      column: $table.capturedAtSource,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get width => $composableBuilder(
      column: $table.width, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get height => $composableBuilder(
      column: $table.height, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get orientation => $composableBuilder(
      column: $table.orientation, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mime => $composableBuilder(
      column: $table.mime, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get unsupported => $composableBuilder(
      column: $table.unsupported, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get metadataPending => $composableBuilder(
      column: $table.metadataPending,
      builder: (column) => ColumnFilters(column));
}

class $$GalleryItemsTableOrderingComposer
    extends Composer<_$GalleryMirrorDatabase, $GalleryItemsTable> {
  $$GalleryItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get origin => $composableBuilder(
      column: $table.origin, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get providerId => $composableBuilder(
      column: $table.providerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get seq => $composableBuilder(
      column: $table.seq, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localRelativePath => $composableBuilder(
      column: $table.localRelativePath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localDisplayName => $composableBuilder(
      column: $table.localDisplayName,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get localSize => $composableBuilder(
      column: $table.localSize, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get localDateTaken => $composableBuilder(
      column: $table.localDateTaken,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get capturedAt => $composableBuilder(
      column: $table.capturedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get capturedAtSource => $composableBuilder(
      column: $table.capturedAtSource,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get width => $composableBuilder(
      column: $table.width, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get height => $composableBuilder(
      column: $table.height, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get orientation => $composableBuilder(
      column: $table.orientation, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mime => $composableBuilder(
      column: $table.mime, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get unsupported => $composableBuilder(
      column: $table.unsupported, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get metadataPending => $composableBuilder(
      column: $table.metadataPending,
      builder: (column) => ColumnOrderings(column));
}

class $$GalleryItemsTableAnnotationComposer
    extends Composer<_$GalleryMirrorDatabase, $GalleryItemsTable> {
  $$GalleryItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get origin =>
      $composableBuilder(column: $table.origin, builder: (column) => column);

  GeneratedColumn<String> get providerId => $composableBuilder(
      column: $table.providerId, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get seq =>
      $composableBuilder(column: $table.seq, builder: (column) => column);

  GeneratedColumn<String> get localRelativePath => $composableBuilder(
      column: $table.localRelativePath, builder: (column) => column);

  GeneratedColumn<String> get localDisplayName => $composableBuilder(
      column: $table.localDisplayName, builder: (column) => column);

  GeneratedColumn<int> get localSize =>
      $composableBuilder(column: $table.localSize, builder: (column) => column);

  GeneratedColumn<int> get localDateTaken => $composableBuilder(
      column: $table.localDateTaken, builder: (column) => column);

  GeneratedColumn<int> get capturedAt => $composableBuilder(
      column: $table.capturedAt, builder: (column) => column);

  GeneratedColumn<String> get capturedAtSource => $composableBuilder(
      column: $table.capturedAtSource, builder: (column) => column);

  GeneratedColumn<int> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<int> get orientation => $composableBuilder(
      column: $table.orientation, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<String> get mime =>
      $composableBuilder(column: $table.mime, builder: (column) => column);

  GeneratedColumn<String> get unsupported => $composableBuilder(
      column: $table.unsupported, builder: (column) => column);

  GeneratedColumn<bool> get metadataPending => $composableBuilder(
      column: $table.metadataPending, builder: (column) => column);
}

class $$GalleryItemsTableTableManager extends RootTableManager<
    _$GalleryMirrorDatabase,
    $GalleryItemsTable,
    GalleryItem,
    $$GalleryItemsTableFilterComposer,
    $$GalleryItemsTableOrderingComposer,
    $$GalleryItemsTableAnnotationComposer,
    $$GalleryItemsTableCreateCompanionBuilder,
    $$GalleryItemsTableUpdateCompanionBuilder,
    (
      GalleryItem,
      BaseReferences<_$GalleryMirrorDatabase, $GalleryItemsTable, GalleryItem>
    ),
    GalleryItem,
    PrefetchHooks Function()> {
  $$GalleryItemsTableTableManager(
      _$GalleryMirrorDatabase db, $GalleryItemsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$GalleryItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$GalleryItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$GalleryItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> origin = const Value.absent(),
            Value<String?> providerId = const Value.absent(),
            Value<String?> path = const Value.absent(),
            Value<int?> seq = const Value.absent(),
            Value<String?> localRelativePath = const Value.absent(),
            Value<String?> localDisplayName = const Value.absent(),
            Value<int?> localSize = const Value.absent(),
            Value<int?> localDateTaken = const Value.absent(),
            Value<int> capturedAt = const Value.absent(),
            Value<String> capturedAtSource = const Value.absent(),
            Value<int> width = const Value.absent(),
            Value<int> height = const Value.absent(),
            Value<int> orientation = const Value.absent(),
            Value<int> size = const Value.absent(),
            Value<String> mime = const Value.absent(),
            Value<String> unsupported = const Value.absent(),
            Value<bool> metadataPending = const Value.absent(),
          }) =>
              GalleryItemsCompanion(
            id: id,
            origin: origin,
            providerId: providerId,
            path: path,
            seq: seq,
            localRelativePath: localRelativePath,
            localDisplayName: localDisplayName,
            localSize: localSize,
            localDateTaken: localDateTaken,
            capturedAt: capturedAt,
            capturedAtSource: capturedAtSource,
            width: width,
            height: height,
            orientation: orientation,
            size: size,
            mime: mime,
            unsupported: unsupported,
            metadataPending: metadataPending,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> origin = const Value.absent(),
            Value<String?> providerId = const Value.absent(),
            Value<String?> path = const Value.absent(),
            Value<int?> seq = const Value.absent(),
            Value<String?> localRelativePath = const Value.absent(),
            Value<String?> localDisplayName = const Value.absent(),
            Value<int?> localSize = const Value.absent(),
            Value<int?> localDateTaken = const Value.absent(),
            required int capturedAt,
            Value<String> capturedAtSource = const Value.absent(),
            Value<int> width = const Value.absent(),
            Value<int> height = const Value.absent(),
            Value<int> orientation = const Value.absent(),
            Value<int> size = const Value.absent(),
            Value<String> mime = const Value.absent(),
            Value<String> unsupported = const Value.absent(),
            Value<bool> metadataPending = const Value.absent(),
          }) =>
              GalleryItemsCompanion.insert(
            id: id,
            origin: origin,
            providerId: providerId,
            path: path,
            seq: seq,
            localRelativePath: localRelativePath,
            localDisplayName: localDisplayName,
            localSize: localSize,
            localDateTaken: localDateTaken,
            capturedAt: capturedAt,
            capturedAtSource: capturedAtSource,
            width: width,
            height: height,
            orientation: orientation,
            size: size,
            mime: mime,
            unsupported: unsupported,
            metadataPending: metadataPending,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$GalleryItemsTableProcessedTableManager = ProcessedTableManager<
    _$GalleryMirrorDatabase,
    $GalleryItemsTable,
    GalleryItem,
    $$GalleryItemsTableFilterComposer,
    $$GalleryItemsTableOrderingComposer,
    $$GalleryItemsTableAnnotationComposer,
    $$GalleryItemsTableCreateCompanionBuilder,
    $$GalleryItemsTableUpdateCompanionBuilder,
    (
      GalleryItem,
      BaseReferences<_$GalleryMirrorDatabase, $GalleryItemsTable, GalleryItem>
    ),
    GalleryItem,
    PrefetchHooks Function()>;
typedef $$SyncCursorsTableCreateCompanionBuilder = SyncCursorsCompanion
    Function({
  required String source,
  Value<int> since,
  Value<String?> pendingCursor,
  Value<int> rowid,
});
typedef $$SyncCursorsTableUpdateCompanionBuilder = SyncCursorsCompanion
    Function({
  Value<String> source,
  Value<int> since,
  Value<String?> pendingCursor,
  Value<int> rowid,
});

class $$SyncCursorsTableFilterComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get since => $composableBuilder(
      column: $table.since, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get pendingCursor => $composableBuilder(
      column: $table.pendingCursor, builder: (column) => ColumnFilters(column));
}

class $$SyncCursorsTableOrderingComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get since => $composableBuilder(
      column: $table.since, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get pendingCursor => $composableBuilder(
      column: $table.pendingCursor,
      builder: (column) => ColumnOrderings(column));
}

class $$SyncCursorsTableAnnotationComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncCursorsTable> {
  $$SyncCursorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<int> get since =>
      $composableBuilder(column: $table.since, builder: (column) => column);

  GeneratedColumn<String> get pendingCursor => $composableBuilder(
      column: $table.pendingCursor, builder: (column) => column);
}

class $$SyncCursorsTableTableManager extends RootTableManager<
    _$GalleryMirrorDatabase,
    $SyncCursorsTable,
    SyncCursor,
    $$SyncCursorsTableFilterComposer,
    $$SyncCursorsTableOrderingComposer,
    $$SyncCursorsTableAnnotationComposer,
    $$SyncCursorsTableCreateCompanionBuilder,
    $$SyncCursorsTableUpdateCompanionBuilder,
    (
      SyncCursor,
      BaseReferences<_$GalleryMirrorDatabase, $SyncCursorsTable, SyncCursor>
    ),
    SyncCursor,
    PrefetchHooks Function()> {
  $$SyncCursorsTableTableManager(
      _$GalleryMirrorDatabase db, $SyncCursorsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncCursorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncCursorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncCursorsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> source = const Value.absent(),
            Value<int> since = const Value.absent(),
            Value<String?> pendingCursor = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncCursorsCompanion(
            source: source,
            since: since,
            pendingCursor: pendingCursor,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String source,
            Value<int> since = const Value.absent(),
            Value<String?> pendingCursor = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncCursorsCompanion.insert(
            source: source,
            since: since,
            pendingCursor: pendingCursor,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncCursorsTableProcessedTableManager = ProcessedTableManager<
    _$GalleryMirrorDatabase,
    $SyncCursorsTable,
    SyncCursor,
    $$SyncCursorsTableFilterComposer,
    $$SyncCursorsTableOrderingComposer,
    $$SyncCursorsTableAnnotationComposer,
    $$SyncCursorsTableCreateCompanionBuilder,
    $$SyncCursorsTableUpdateCompanionBuilder,
    (
      SyncCursor,
      BaseReferences<_$GalleryMirrorDatabase, $SyncCursorsTable, SyncCursor>
    ),
    SyncCursor,
    PrefetchHooks Function()>;
typedef $$CachedThumbnailsTableCreateCompanionBuilder
    = CachedThumbnailsCompanion Function({
  required String providerId,
  required String path,
  required int size,
  required Uint8List bytes,
  required int fetchedAt,
  Value<int> rowid,
});
typedef $$CachedThumbnailsTableUpdateCompanionBuilder
    = CachedThumbnailsCompanion Function({
  Value<String> providerId,
  Value<String> path,
  Value<int> size,
  Value<Uint8List> bytes,
  Value<int> fetchedAt,
  Value<int> rowid,
});

class $$CachedThumbnailsTableFilterComposer
    extends Composer<_$GalleryMirrorDatabase, $CachedThumbnailsTable> {
  $$CachedThumbnailsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get providerId => $composableBuilder(
      column: $table.providerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get bytes => $composableBuilder(
      column: $table.bytes, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnFilters(column));
}

class $$CachedThumbnailsTableOrderingComposer
    extends Composer<_$GalleryMirrorDatabase, $CachedThumbnailsTable> {
  $$CachedThumbnailsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get providerId => $composableBuilder(
      column: $table.providerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get size => $composableBuilder(
      column: $table.size, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get bytes => $composableBuilder(
      column: $table.bytes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get fetchedAt => $composableBuilder(
      column: $table.fetchedAt, builder: (column) => ColumnOrderings(column));
}

class $$CachedThumbnailsTableAnnotationComposer
    extends Composer<_$GalleryMirrorDatabase, $CachedThumbnailsTable> {
  $$CachedThumbnailsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get providerId => $composableBuilder(
      column: $table.providerId, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<int> get fetchedAt =>
      $composableBuilder(column: $table.fetchedAt, builder: (column) => column);
}

class $$CachedThumbnailsTableTableManager extends RootTableManager<
    _$GalleryMirrorDatabase,
    $CachedThumbnailsTable,
    CachedThumbnail,
    $$CachedThumbnailsTableFilterComposer,
    $$CachedThumbnailsTableOrderingComposer,
    $$CachedThumbnailsTableAnnotationComposer,
    $$CachedThumbnailsTableCreateCompanionBuilder,
    $$CachedThumbnailsTableUpdateCompanionBuilder,
    (
      CachedThumbnail,
      BaseReferences<_$GalleryMirrorDatabase, $CachedThumbnailsTable,
          CachedThumbnail>
    ),
    CachedThumbnail,
    PrefetchHooks Function()> {
  $$CachedThumbnailsTableTableManager(
      _$GalleryMirrorDatabase db, $CachedThumbnailsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$CachedThumbnailsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$CachedThumbnailsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$CachedThumbnailsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> providerId = const Value.absent(),
            Value<String> path = const Value.absent(),
            Value<int> size = const Value.absent(),
            Value<Uint8List> bytes = const Value.absent(),
            Value<int> fetchedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              CachedThumbnailsCompanion(
            providerId: providerId,
            path: path,
            size: size,
            bytes: bytes,
            fetchedAt: fetchedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String providerId,
            required String path,
            required int size,
            required Uint8List bytes,
            required int fetchedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              CachedThumbnailsCompanion.insert(
            providerId: providerId,
            path: path,
            size: size,
            bytes: bytes,
            fetchedAt: fetchedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$CachedThumbnailsTableProcessedTableManager = ProcessedTableManager<
    _$GalleryMirrorDatabase,
    $CachedThumbnailsTable,
    CachedThumbnail,
    $$CachedThumbnailsTableFilterComposer,
    $$CachedThumbnailsTableOrderingComposer,
    $$CachedThumbnailsTableAnnotationComposer,
    $$CachedThumbnailsTableCreateCompanionBuilder,
    $$CachedThumbnailsTableUpdateCompanionBuilder,
    (
      CachedThumbnail,
      BaseReferences<_$GalleryMirrorDatabase, $CachedThumbnailsTable,
          CachedThumbnail>
    ),
    CachedThumbnail,
    PrefetchHooks Function()>;
typedef $$LocalFolderSelectionsTableCreateCompanionBuilder
    = LocalFolderSelectionsCompanion Function({
  required String folderPath,
  required bool selected,
  Value<int> rowid,
});
typedef $$LocalFolderSelectionsTableUpdateCompanionBuilder
    = LocalFolderSelectionsCompanion Function({
  Value<String> folderPath,
  Value<bool> selected,
  Value<int> rowid,
});

class $$LocalFolderSelectionsTableFilterComposer
    extends Composer<_$GalleryMirrorDatabase, $LocalFolderSelectionsTable> {
  $$LocalFolderSelectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get folderPath => $composableBuilder(
      column: $table.folderPath, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get selected => $composableBuilder(
      column: $table.selected, builder: (column) => ColumnFilters(column));
}

class $$LocalFolderSelectionsTableOrderingComposer
    extends Composer<_$GalleryMirrorDatabase, $LocalFolderSelectionsTable> {
  $$LocalFolderSelectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get folderPath => $composableBuilder(
      column: $table.folderPath, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get selected => $composableBuilder(
      column: $table.selected, builder: (column) => ColumnOrderings(column));
}

class $$LocalFolderSelectionsTableAnnotationComposer
    extends Composer<_$GalleryMirrorDatabase, $LocalFolderSelectionsTable> {
  $$LocalFolderSelectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get folderPath => $composableBuilder(
      column: $table.folderPath, builder: (column) => column);

  GeneratedColumn<bool> get selected =>
      $composableBuilder(column: $table.selected, builder: (column) => column);
}

class $$LocalFolderSelectionsTableTableManager extends RootTableManager<
    _$GalleryMirrorDatabase,
    $LocalFolderSelectionsTable,
    LocalFolderSelection,
    $$LocalFolderSelectionsTableFilterComposer,
    $$LocalFolderSelectionsTableOrderingComposer,
    $$LocalFolderSelectionsTableAnnotationComposer,
    $$LocalFolderSelectionsTableCreateCompanionBuilder,
    $$LocalFolderSelectionsTableUpdateCompanionBuilder,
    (
      LocalFolderSelection,
      BaseReferences<_$GalleryMirrorDatabase, $LocalFolderSelectionsTable,
          LocalFolderSelection>
    ),
    LocalFolderSelection,
    PrefetchHooks Function()> {
  $$LocalFolderSelectionsTableTableManager(
      _$GalleryMirrorDatabase db, $LocalFolderSelectionsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalFolderSelectionsTableFilterComposer(
                  $db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalFolderSelectionsTableOrderingComposer(
                  $db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalFolderSelectionsTableAnnotationComposer(
                  $db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> folderPath = const Value.absent(),
            Value<bool> selected = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalFolderSelectionsCompanion(
            folderPath: folderPath,
            selected: selected,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String folderPath,
            required bool selected,
            Value<int> rowid = const Value.absent(),
          }) =>
              LocalFolderSelectionsCompanion.insert(
            folderPath: folderPath,
            selected: selected,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$LocalFolderSelectionsTableProcessedTableManager
    = ProcessedTableManager<
        _$GalleryMirrorDatabase,
        $LocalFolderSelectionsTable,
        LocalFolderSelection,
        $$LocalFolderSelectionsTableFilterComposer,
        $$LocalFolderSelectionsTableOrderingComposer,
        $$LocalFolderSelectionsTableAnnotationComposer,
        $$LocalFolderSelectionsTableCreateCompanionBuilder,
        $$LocalFolderSelectionsTableUpdateCompanionBuilder,
        (
          LocalFolderSelection,
          BaseReferences<_$GalleryMirrorDatabase, $LocalFolderSelectionsTable,
              LocalFolderSelection>
        ),
        LocalFolderSelection,
        PrefetchHooks Function()>;
typedef $$SyncPairsTableCreateCompanionBuilder = SyncPairsCompanion Function({
  Value<int> id,
  required String localFolderPath,
  required String spaceProviderId,
  required String path,
  Value<int> createdAt,
});
typedef $$SyncPairsTableUpdateCompanionBuilder = SyncPairsCompanion Function({
  Value<int> id,
  Value<String> localFolderPath,
  Value<String> spaceProviderId,
  Value<String> path,
  Value<int> createdAt,
});

class $$SyncPairsTableFilterComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncPairsTable> {
  $$SyncPairsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get localFolderPath => $composableBuilder(
      column: $table.localFolderPath,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get spaceProviderId => $composableBuilder(
      column: $table.spaceProviderId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));
}

class $$SyncPairsTableOrderingComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncPairsTable> {
  $$SyncPairsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get localFolderPath => $composableBuilder(
      column: $table.localFolderPath,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get spaceProviderId => $composableBuilder(
      column: $table.spaceProviderId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get path => $composableBuilder(
      column: $table.path, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));
}

class $$SyncPairsTableAnnotationComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncPairsTable> {
  $$SyncPairsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get localFolderPath => $composableBuilder(
      column: $table.localFolderPath, builder: (column) => column);

  GeneratedColumn<String> get spaceProviderId => $composableBuilder(
      column: $table.spaceProviderId, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$SyncPairsTableTableManager extends RootTableManager<
    _$GalleryMirrorDatabase,
    $SyncPairsTable,
    SyncPairRow,
    $$SyncPairsTableFilterComposer,
    $$SyncPairsTableOrderingComposer,
    $$SyncPairsTableAnnotationComposer,
    $$SyncPairsTableCreateCompanionBuilder,
    $$SyncPairsTableUpdateCompanionBuilder,
    (
      SyncPairRow,
      BaseReferences<_$GalleryMirrorDatabase, $SyncPairsTable, SyncPairRow>
    ),
    SyncPairRow,
    PrefetchHooks Function()> {
  $$SyncPairsTableTableManager(
      _$GalleryMirrorDatabase db, $SyncPairsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncPairsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncPairsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncPairsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> localFolderPath = const Value.absent(),
            Value<String> spaceProviderId = const Value.absent(),
            Value<String> path = const Value.absent(),
            Value<int> createdAt = const Value.absent(),
          }) =>
              SyncPairsCompanion(
            id: id,
            localFolderPath: localFolderPath,
            spaceProviderId: spaceProviderId,
            path: path,
            createdAt: createdAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String localFolderPath,
            required String spaceProviderId,
            required String path,
            Value<int> createdAt = const Value.absent(),
          }) =>
              SyncPairsCompanion.insert(
            id: id,
            localFolderPath: localFolderPath,
            spaceProviderId: spaceProviderId,
            path: path,
            createdAt: createdAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncPairsTableProcessedTableManager = ProcessedTableManager<
    _$GalleryMirrorDatabase,
    $SyncPairsTable,
    SyncPairRow,
    $$SyncPairsTableFilterComposer,
    $$SyncPairsTableOrderingComposer,
    $$SyncPairsTableAnnotationComposer,
    $$SyncPairsTableCreateCompanionBuilder,
    $$SyncPairsTableUpdateCompanionBuilder,
    (
      SyncPairRow,
      BaseReferences<_$GalleryMirrorDatabase, $SyncPairsTable, SyncPairRow>
    ),
    SyncPairRow,
    PrefetchHooks Function()>;

class $GalleryMirrorDatabaseManager {
  final _$GalleryMirrorDatabase _db;
  $GalleryMirrorDatabaseManager(this._db);
  $$GalleryItemsTableTableManager get galleryItems =>
      $$GalleryItemsTableTableManager(_db, _db.galleryItems);
  $$SyncCursorsTableTableManager get syncCursors =>
      $$SyncCursorsTableTableManager(_db, _db.syncCursors);
  $$CachedThumbnailsTableTableManager get cachedThumbnails =>
      $$CachedThumbnailsTableTableManager(_db, _db.cachedThumbnails);
  $$LocalFolderSelectionsTableTableManager get localFolderSelections =>
      $$LocalFolderSelectionsTableTableManager(_db, _db.localFolderSelections);
  $$SyncPairsTableTableManager get syncPairs =>
      $$SyncPairsTableTableManager(_db, _db.syncPairs);
}
