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
  static const VerificationMeta _uploadStateMeta =
      const VerificationMeta('uploadState');
  @override
  late final GeneratedColumn<String> uploadState = GeneratedColumn<String>(
      'upload_state', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _uploadTargetProviderIdMeta =
      const VerificationMeta('uploadTargetProviderId');
  @override
  late final GeneratedColumn<String> uploadTargetProviderId =
      GeneratedColumn<String>('upload_target_provider_id', aliasedName, true,
          type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _uploadTargetPathMeta =
      const VerificationMeta('uploadTargetPath');
  @override
  late final GeneratedColumn<String> uploadTargetPath = GeneratedColumn<String>(
      'upload_target_path', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
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
        metadataPending,
        uploadState,
        uploadTargetProviderId,
        uploadTargetPath
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
    if (data.containsKey('upload_state')) {
      context.handle(
          _uploadStateMeta,
          uploadState.isAcceptableOrUnknown(
              data['upload_state']!, _uploadStateMeta));
    }
    if (data.containsKey('upload_target_provider_id')) {
      context.handle(
          _uploadTargetProviderIdMeta,
          uploadTargetProviderId.isAcceptableOrUnknown(
              data['upload_target_provider_id']!, _uploadTargetProviderIdMeta));
    }
    if (data.containsKey('upload_target_path')) {
      context.handle(
          _uploadTargetPathMeta,
          uploadTargetPath.isAcceptableOrUnknown(
              data['upload_target_path']!, _uploadTargetPathMeta));
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
      uploadState: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}upload_state']),
      uploadTargetProviderId: attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}upload_target_provider_id']),
      uploadTargetPath: attachedDatabase.typeMapping.read(
          DriftSqlType.string, data['${effectivePrefix}upload_target_path']),
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

  /// Null when no upload is currently pending verification for this row -
  /// which is every row except a `device` one [GalleryMirror.recordUploaded]
  /// has written to. Four non-null values, one of two pairs depending on
  /// HOW the row got here (ticket 20's rework - the distinction matters
  /// because only one of the two may ever have its remote file deleted):
  ///
  /// - `'uploaded'` - a real PUT succeeded; [GalleryMirror.applyPage] is
  ///   watching the feed for confirmation at ([uploadTargetProviderId],
  ///   [uploadTargetPath]).
  /// - `'assumed'` - the ticket-19 "same size, assume it's ours" shortcut
  ///   fired instead: nothing was PUT, this device merely believes a
  ///   pre-existing file at the target path is its own content.
  /// - `'mismatch'` - a row that was `'uploaded'`, but the feed reported a
  ///   length that contradicts what this device sent. The remote file IS
  ///   this device's own upload, so it cannot be trusted and
  ///   [GalleryUploadService.retryMismatchedUpload] deletes it and retries.
  /// - `'assumedMismatch'` - a row that was `'assumed'`, but the feed
  ///   contradicted it. This device never wrote that file, so the mismatch
  ///   only disproves the assumption - it is never permission to delete
  ///   someone else's content. [GalleryUploadService.retryMismatchedUpload]
  ///   falls back to ticket 19's different-size collision rule instead:
  ///   disambiguate to a new name, leaving the file exactly as it was.
  ///
  /// Cleared back to null the moment verification actually succeeds - at
  /// that point [origin] has already flipped to `both`, which is what makes
  /// "Synced" true; this column exists only to gate that flip on the feed
  /// rather than on the upload response (CONTEXT.md's **Verified**, D10 in
  /// `docs/gallery-mode-design-notes.md`). Plain text, not a Dart enum
  /// column, for the same reason [origin] is.
  final String? uploadState;

  /// The exact (providerId, path) [GalleryUploadService.upload] PUT to, or
  /// found already occupied by this device's own content - **the path the
  /// photo actually went to, not a recipe for deriving it** (ticket 19),
  /// which matters here specifically because a disambiguated upload's real
  /// path cannot be recomputed from the Sync Pair alone. Set together with
  /// [uploadState] by [GalleryMirror.recordUploaded]; read back by
  /// [GalleryMirror.applyPage] to recognise the delta feed independently
  /// reporting this exact file. Both null whenever [uploadState] is.
  final String? uploadTargetProviderId;
  final String? uploadTargetPath;
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
      required this.metadataPending,
      this.uploadState,
      this.uploadTargetProviderId,
      this.uploadTargetPath});
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
    if (!nullToAbsent || uploadState != null) {
      map['upload_state'] = Variable<String>(uploadState);
    }
    if (!nullToAbsent || uploadTargetProviderId != null) {
      map['upload_target_provider_id'] =
          Variable<String>(uploadTargetProviderId);
    }
    if (!nullToAbsent || uploadTargetPath != null) {
      map['upload_target_path'] = Variable<String>(uploadTargetPath);
    }
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
      uploadState: uploadState == null && nullToAbsent
          ? const Value.absent()
          : Value(uploadState),
      uploadTargetProviderId: uploadTargetProviderId == null && nullToAbsent
          ? const Value.absent()
          : Value(uploadTargetProviderId),
      uploadTargetPath: uploadTargetPath == null && nullToAbsent
          ? const Value.absent()
          : Value(uploadTargetPath),
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
      uploadState: serializer.fromJson<String?>(json['uploadState']),
      uploadTargetProviderId:
          serializer.fromJson<String?>(json['uploadTargetProviderId']),
      uploadTargetPath: serializer.fromJson<String?>(json['uploadTargetPath']),
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
      'uploadState': serializer.toJson<String?>(uploadState),
      'uploadTargetProviderId':
          serializer.toJson<String?>(uploadTargetProviderId),
      'uploadTargetPath': serializer.toJson<String?>(uploadTargetPath),
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
          bool? metadataPending,
          Value<String?> uploadState = const Value.absent(),
          Value<String?> uploadTargetProviderId = const Value.absent(),
          Value<String?> uploadTargetPath = const Value.absent()}) =>
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
        uploadState: uploadState.present ? uploadState.value : this.uploadState,
        uploadTargetProviderId: uploadTargetProviderId.present
            ? uploadTargetProviderId.value
            : this.uploadTargetProviderId,
        uploadTargetPath: uploadTargetPath.present
            ? uploadTargetPath.value
            : this.uploadTargetPath,
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
      uploadState:
          data.uploadState.present ? data.uploadState.value : this.uploadState,
      uploadTargetProviderId: data.uploadTargetProviderId.present
          ? data.uploadTargetProviderId.value
          : this.uploadTargetProviderId,
      uploadTargetPath: data.uploadTargetPath.present
          ? data.uploadTargetPath.value
          : this.uploadTargetPath,
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
          ..write('metadataPending: $metadataPending, ')
          ..write('uploadState: $uploadState, ')
          ..write('uploadTargetProviderId: $uploadTargetProviderId, ')
          ..write('uploadTargetPath: $uploadTargetPath')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
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
        metadataPending,
        uploadState,
        uploadTargetProviderId,
        uploadTargetPath
      ]);
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
          other.metadataPending == this.metadataPending &&
          other.uploadState == this.uploadState &&
          other.uploadTargetProviderId == this.uploadTargetProviderId &&
          other.uploadTargetPath == this.uploadTargetPath);
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
  final Value<String?> uploadState;
  final Value<String?> uploadTargetProviderId;
  final Value<String?> uploadTargetPath;
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
    this.uploadState = const Value.absent(),
    this.uploadTargetProviderId = const Value.absent(),
    this.uploadTargetPath = const Value.absent(),
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
    this.uploadState = const Value.absent(),
    this.uploadTargetProviderId = const Value.absent(),
    this.uploadTargetPath = const Value.absent(),
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
    Expression<String>? uploadState,
    Expression<String>? uploadTargetProviderId,
    Expression<String>? uploadTargetPath,
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
      if (uploadState != null) 'upload_state': uploadState,
      if (uploadTargetProviderId != null)
        'upload_target_provider_id': uploadTargetProviderId,
      if (uploadTargetPath != null) 'upload_target_path': uploadTargetPath,
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
      Value<bool>? metadataPending,
      Value<String?>? uploadState,
      Value<String?>? uploadTargetProviderId,
      Value<String?>? uploadTargetPath}) {
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
      uploadState: uploadState ?? this.uploadState,
      uploadTargetProviderId:
          uploadTargetProviderId ?? this.uploadTargetProviderId,
      uploadTargetPath: uploadTargetPath ?? this.uploadTargetPath,
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
    if (uploadState.present) {
      map['upload_state'] = Variable<String>(uploadState.value);
    }
    if (uploadTargetProviderId.present) {
      map['upload_target_provider_id'] =
          Variable<String>(uploadTargetProviderId.value);
    }
    if (uploadTargetPath.present) {
      map['upload_target_path'] = Variable<String>(uploadTargetPath.value);
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
          ..write('metadataPending: $metadataPending, ')
          ..write('uploadState: $uploadState, ')
          ..write('uploadTargetProviderId: $uploadTargetProviderId, ')
          ..write('uploadTargetPath: $uploadTargetPath')
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
  static const VerificationMeta _removedAtMeta =
      const VerificationMeta('removedAt');
  @override
  late final GeneratedColumn<int> removedAt = GeneratedColumn<int>(
      'removed_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, localFolderPath, spaceProviderId, path, createdAt, removedAt];
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
    if (data.containsKey('removed_at')) {
      context.handle(_removedAtMeta,
          removedAt.isAcceptableOrUnknown(data['removed_at']!, _removedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
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
      removedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}removed_at']),
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
  /// automatically becomes a Gallery Source Folder). This is THIS row's
  /// target - current if [removedAt] is null, historical otherwise; see the
  /// class doc for how the two are used differently.
  final String spaceProviderId;
  final String path;

  /// Epoch milliseconds this pair was created - used only to order
  /// [GalleryMirror.listSyncPairs] (oldest first, so the list does not
  /// reorder itself as photo counts change).
  final int createdAt;

  /// Null while this pair is active (the normal state for every row before
  /// ticket 21). Set to the epoch milliseconds [GalleryMirror.removeSyncPair]
  /// ran at otherwise - the row is kept, never deleted, purely as a
  /// historical target for dedup/reconcile lookups (see the class doc).
  /// [GalleryMirror.listSyncPairs] (the UI's list) and every "current
  /// target" computation filter this to null; dedup/reconcile lookups do
  /// not filter on it at all.
  final int? removedAt;
  const SyncPairRow(
      {required this.id,
      required this.localFolderPath,
      required this.spaceProviderId,
      required this.path,
      required this.createdAt,
      this.removedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['local_folder_path'] = Variable<String>(localFolderPath);
    map['space_provider_id'] = Variable<String>(spaceProviderId);
    map['path'] = Variable<String>(path);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || removedAt != null) {
      map['removed_at'] = Variable<int>(removedAt);
    }
    return map;
  }

  SyncPairsCompanion toCompanion(bool nullToAbsent) {
    return SyncPairsCompanion(
      id: Value(id),
      localFolderPath: Value(localFolderPath),
      spaceProviderId: Value(spaceProviderId),
      path: Value(path),
      createdAt: Value(createdAt),
      removedAt: removedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(removedAt),
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
      removedAt: serializer.fromJson<int?>(json['removedAt']),
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
      'removedAt': serializer.toJson<int?>(removedAt),
    };
  }

  SyncPairRow copyWith(
          {int? id,
          String? localFolderPath,
          String? spaceProviderId,
          String? path,
          int? createdAt,
          Value<int?> removedAt = const Value.absent()}) =>
      SyncPairRow(
        id: id ?? this.id,
        localFolderPath: localFolderPath ?? this.localFolderPath,
        spaceProviderId: spaceProviderId ?? this.spaceProviderId,
        path: path ?? this.path,
        createdAt: createdAt ?? this.createdAt,
        removedAt: removedAt.present ? removedAt.value : this.removedAt,
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
      removedAt: data.removedAt.present ? data.removedAt.value : this.removedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncPairRow(')
          ..write('id: $id, ')
          ..write('localFolderPath: $localFolderPath, ')
          ..write('spaceProviderId: $spaceProviderId, ')
          ..write('path: $path, ')
          ..write('createdAt: $createdAt, ')
          ..write('removedAt: $removedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, localFolderPath, spaceProviderId, path, createdAt, removedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncPairRow &&
          other.id == this.id &&
          other.localFolderPath == this.localFolderPath &&
          other.spaceProviderId == this.spaceProviderId &&
          other.path == this.path &&
          other.createdAt == this.createdAt &&
          other.removedAt == this.removedAt);
}

class SyncPairsCompanion extends UpdateCompanion<SyncPairRow> {
  final Value<int> id;
  final Value<String> localFolderPath;
  final Value<String> spaceProviderId;
  final Value<String> path;
  final Value<int> createdAt;
  final Value<int?> removedAt;
  const SyncPairsCompanion({
    this.id = const Value.absent(),
    this.localFolderPath = const Value.absent(),
    this.spaceProviderId = const Value.absent(),
    this.path = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.removedAt = const Value.absent(),
  });
  SyncPairsCompanion.insert({
    this.id = const Value.absent(),
    required String localFolderPath,
    required String spaceProviderId,
    required String path,
    this.createdAt = const Value.absent(),
    this.removedAt = const Value.absent(),
  })  : localFolderPath = Value(localFolderPath),
        spaceProviderId = Value(spaceProviderId),
        path = Value(path);
  static Insertable<SyncPairRow> custom({
    Expression<int>? id,
    Expression<String>? localFolderPath,
    Expression<String>? spaceProviderId,
    Expression<String>? path,
    Expression<int>? createdAt,
    Expression<int>? removedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (localFolderPath != null) 'local_folder_path': localFolderPath,
      if (spaceProviderId != null) 'space_provider_id': spaceProviderId,
      if (path != null) 'path': path,
      if (createdAt != null) 'created_at': createdAt,
      if (removedAt != null) 'removed_at': removedAt,
    });
  }

  SyncPairsCompanion copyWith(
      {Value<int>? id,
      Value<String>? localFolderPath,
      Value<String>? spaceProviderId,
      Value<String>? path,
      Value<int>? createdAt,
      Value<int?>? removedAt}) {
    return SyncPairsCompanion(
      id: id ?? this.id,
      localFolderPath: localFolderPath ?? this.localFolderPath,
      spaceProviderId: spaceProviderId ?? this.spaceProviderId,
      path: path ?? this.path,
      createdAt: createdAt ?? this.createdAt,
      removedAt: removedAt ?? this.removedAt,
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
    if (removedAt.present) {
      map['removed_at'] = Variable<int>(removedAt.value);
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
          ..write('createdAt: $createdAt, ')
          ..write('removedAt: $removedAt')
          ..write(')'))
        .toString();
  }
}

class $SyncRunStateTable extends SyncRunState
    with TableInfo<$SyncRunStateTable, SyncRunStateData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncRunStateTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
      'status', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _totalItemsMeta =
      const VerificationMeta('totalItems');
  @override
  late final GeneratedColumn<int> totalItems = GeneratedColumn<int>(
      'total_items', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _completedItemsMeta =
      const VerificationMeta('completedItems');
  @override
  late final GeneratedColumn<int> completedItems = GeneratedColumn<int>(
      'completed_items', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _failedItemsMeta =
      const VerificationMeta('failedItems');
  @override
  late final GeneratedColumn<int> failedItems = GeneratedColumn<int>(
      'failed_items', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _totalBytesMeta =
      const VerificationMeta('totalBytes');
  @override
  late final GeneratedColumn<int> totalBytes = GeneratedColumn<int>(
      'total_bytes', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _completedBytesMeta =
      const VerificationMeta('completedBytes');
  @override
  late final GeneratedColumn<int> completedBytes = GeneratedColumn<int>(
      'completed_bytes', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastErrorMeta =
      const VerificationMeta('lastError');
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
      'last_error', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultValue: const Constant(0));
  static const VerificationMeta _lastSuccessAtMeta =
      const VerificationMeta('lastSuccessAt');
  @override
  late final GeneratedColumn<int> lastSuccessAt = GeneratedColumn<int>(
      'last_success_at', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        status,
        totalItems,
        completedItems,
        failedItems,
        totalBytes,
        completedBytes,
        lastError,
        updatedAt,
        lastSuccessAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_run_state';
  @override
  VerificationContext validateIntegrity(Insertable<SyncRunStateData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta,
          status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('total_items')) {
      context.handle(
          _totalItemsMeta,
          totalItems.isAcceptableOrUnknown(
              data['total_items']!, _totalItemsMeta));
    }
    if (data.containsKey('completed_items')) {
      context.handle(
          _completedItemsMeta,
          completedItems.isAcceptableOrUnknown(
              data['completed_items']!, _completedItemsMeta));
    }
    if (data.containsKey('failed_items')) {
      context.handle(
          _failedItemsMeta,
          failedItems.isAcceptableOrUnknown(
              data['failed_items']!, _failedItemsMeta));
    }
    if (data.containsKey('total_bytes')) {
      context.handle(
          _totalBytesMeta,
          totalBytes.isAcceptableOrUnknown(
              data['total_bytes']!, _totalBytesMeta));
    }
    if (data.containsKey('completed_bytes')) {
      context.handle(
          _completedBytesMeta,
          completedBytes.isAcceptableOrUnknown(
              data['completed_bytes']!, _completedBytesMeta));
    }
    if (data.containsKey('last_error')) {
      context.handle(_lastErrorMeta,
          lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    if (data.containsKey('last_success_at')) {
      context.handle(
          _lastSuccessAtMeta,
          lastSuccessAt.isAcceptableOrUnknown(
              data['last_success_at']!, _lastSuccessAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncRunStateData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncRunStateData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      status: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      totalItems: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_items'])!,
      completedItems: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}completed_items'])!,
      failedItems: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}failed_items'])!,
      totalBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}total_bytes'])!,
      completedBytes: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}completed_bytes'])!,
      lastError: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}last_error']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}updated_at'])!,
      lastSuccessAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}last_success_at']),
    );
  }

  @override
  $SyncRunStateTable createAlias(String alias) {
    return $SyncRunStateTable(attachedDatabase, alias);
  }
}

class SyncRunStateData extends DataClass
    implements Insertable<SyncRunStateData> {
  final String id;

  /// One of [GalleryMirror.syncStatusIdle]/[syncStatusRunning]/
  /// [syncStatusPaused]/[syncStatusCompleted]/[syncStatusError] - plain text,
  /// not a Dart enum column, for the same forward-compatibility reason
  /// [GalleryItems.origin] is.
  final String status;

  /// How many items [GallerySyncEngine.run] queued for this run in total -
  /// retries (ticket 20's mismatched uploads) and fresh backlog alike. Fixed
  /// for the run's lifetime; only [completedItems] and [failedItems] move.
  final int totalItems;

  /// How many of [totalItems] have been attempted (successfully or not) so
  /// far - what "photos remaining" (this ticket's own progress criterion) is
  /// `totalItems - completedItems - failedItems` from.
  final int completedItems;

  /// How many of [totalItems] threw rather than completing - counted
  /// separately from [completedItems] so a run that hit failures does not
  /// silently read as fully done. A visible, actionable failure list is
  /// ticket 25's job; this is only the count.
  final int failedItems;

  /// The approximate total byte volume [totalItems] represents - "roughly
  /// how much data" (this ticket's own progress criterion), summed from each
  /// item's local file size once, up front, not re-measured per item.
  final int totalBytes;

  /// Bytes actually moved so far - only items that resulted in a real PUT or
  /// the ticket-19 same-size short-circuit add to this; an item skipped for
  /// any other reason (no Sync Pair, device file gone) advances
  /// [completedItems] without moving this.
  final int completedBytes;

  /// The most recent per-item failure's message, or null - a single value,
  /// not a log, because a real failure list (ticket 25) is out of this
  /// ticket's scope; this exists only so the UI has something more useful to
  /// show than a bare failure count while that ticket is still ahead.
  final String? lastError;

  /// Epoch milliseconds this row was last written - what
  /// [GalleryDataSyncController] uses to notice a `running` row has gone
  /// stale (see its own reconciliation doc) if it is ever extended to time
  /// out a run whose process vanished without the courtesy of a final write.
  final int updatedAt;

  /// Ticket 24: epoch milliseconds the most recent run that reached
  /// [GalleryMirror.syncStatusCompleted] finished at, or null if no run ever
  /// has. **Never regresses** - [GalleryMirror.writeSyncRunState] carries the
  /// previous value forward on every write that is not itself a completed
  /// run, so a `running`/`paused`/`error` write never clears it. This is
  /// what makes "silence distinguishable from success" (the ticket's own
  /// wording) possible: an unattended scheduled run that silently stops
  /// firing (a killed process, a revoked permission, a constraint that never
  /// clears) leaves this timestamp visibly going stale in the UI, rather
  /// than the UI having no way to tell "quietly up to date" from "quietly
  /// not running at all".
  final int? lastSuccessAt;
  const SyncRunStateData(
      {required this.id,
      required this.status,
      required this.totalItems,
      required this.completedItems,
      required this.failedItems,
      required this.totalBytes,
      required this.completedBytes,
      this.lastError,
      required this.updatedAt,
      this.lastSuccessAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['status'] = Variable<String>(status);
    map['total_items'] = Variable<int>(totalItems);
    map['completed_items'] = Variable<int>(completedItems);
    map['failed_items'] = Variable<int>(failedItems);
    map['total_bytes'] = Variable<int>(totalBytes);
    map['completed_bytes'] = Variable<int>(completedBytes);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || lastSuccessAt != null) {
      map['last_success_at'] = Variable<int>(lastSuccessAt);
    }
    return map;
  }

  SyncRunStateCompanion toCompanion(bool nullToAbsent) {
    return SyncRunStateCompanion(
      id: Value(id),
      status: Value(status),
      totalItems: Value(totalItems),
      completedItems: Value(completedItems),
      failedItems: Value(failedItems),
      totalBytes: Value(totalBytes),
      completedBytes: Value(completedBytes),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
      updatedAt: Value(updatedAt),
      lastSuccessAt: lastSuccessAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastSuccessAt),
    );
  }

  factory SyncRunStateData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncRunStateData(
      id: serializer.fromJson<String>(json['id']),
      status: serializer.fromJson<String>(json['status']),
      totalItems: serializer.fromJson<int>(json['totalItems']),
      completedItems: serializer.fromJson<int>(json['completedItems']),
      failedItems: serializer.fromJson<int>(json['failedItems']),
      totalBytes: serializer.fromJson<int>(json['totalBytes']),
      completedBytes: serializer.fromJson<int>(json['completedBytes']),
      lastError: serializer.fromJson<String?>(json['lastError']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      lastSuccessAt: serializer.fromJson<int?>(json['lastSuccessAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'status': serializer.toJson<String>(status),
      'totalItems': serializer.toJson<int>(totalItems),
      'completedItems': serializer.toJson<int>(completedItems),
      'failedItems': serializer.toJson<int>(failedItems),
      'totalBytes': serializer.toJson<int>(totalBytes),
      'completedBytes': serializer.toJson<int>(completedBytes),
      'lastError': serializer.toJson<String?>(lastError),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'lastSuccessAt': serializer.toJson<int?>(lastSuccessAt),
    };
  }

  SyncRunStateData copyWith(
          {String? id,
          String? status,
          int? totalItems,
          int? completedItems,
          int? failedItems,
          int? totalBytes,
          int? completedBytes,
          Value<String?> lastError = const Value.absent(),
          int? updatedAt,
          Value<int?> lastSuccessAt = const Value.absent()}) =>
      SyncRunStateData(
        id: id ?? this.id,
        status: status ?? this.status,
        totalItems: totalItems ?? this.totalItems,
        completedItems: completedItems ?? this.completedItems,
        failedItems: failedItems ?? this.failedItems,
        totalBytes: totalBytes ?? this.totalBytes,
        completedBytes: completedBytes ?? this.completedBytes,
        lastError: lastError.present ? lastError.value : this.lastError,
        updatedAt: updatedAt ?? this.updatedAt,
        lastSuccessAt:
            lastSuccessAt.present ? lastSuccessAt.value : this.lastSuccessAt,
      );
  SyncRunStateData copyWithCompanion(SyncRunStateCompanion data) {
    return SyncRunStateData(
      id: data.id.present ? data.id.value : this.id,
      status: data.status.present ? data.status.value : this.status,
      totalItems:
          data.totalItems.present ? data.totalItems.value : this.totalItems,
      completedItems: data.completedItems.present
          ? data.completedItems.value
          : this.completedItems,
      failedItems:
          data.failedItems.present ? data.failedItems.value : this.failedItems,
      totalBytes:
          data.totalBytes.present ? data.totalBytes.value : this.totalBytes,
      completedBytes: data.completedBytes.present
          ? data.completedBytes.value
          : this.completedBytes,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      lastSuccessAt: data.lastSuccessAt.present
          ? data.lastSuccessAt.value
          : this.lastSuccessAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncRunStateData(')
          ..write('id: $id, ')
          ..write('status: $status, ')
          ..write('totalItems: $totalItems, ')
          ..write('completedItems: $completedItems, ')
          ..write('failedItems: $failedItems, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('completedBytes: $completedBytes, ')
          ..write('lastError: $lastError, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('lastSuccessAt: $lastSuccessAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id,
      status,
      totalItems,
      completedItems,
      failedItems,
      totalBytes,
      completedBytes,
      lastError,
      updatedAt,
      lastSuccessAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncRunStateData &&
          other.id == this.id &&
          other.status == this.status &&
          other.totalItems == this.totalItems &&
          other.completedItems == this.completedItems &&
          other.failedItems == this.failedItems &&
          other.totalBytes == this.totalBytes &&
          other.completedBytes == this.completedBytes &&
          other.lastError == this.lastError &&
          other.updatedAt == this.updatedAt &&
          other.lastSuccessAt == this.lastSuccessAt);
}

class SyncRunStateCompanion extends UpdateCompanion<SyncRunStateData> {
  final Value<String> id;
  final Value<String> status;
  final Value<int> totalItems;
  final Value<int> completedItems;
  final Value<int> failedItems;
  final Value<int> totalBytes;
  final Value<int> completedBytes;
  final Value<String?> lastError;
  final Value<int> updatedAt;
  final Value<int?> lastSuccessAt;
  final Value<int> rowid;
  const SyncRunStateCompanion({
    this.id = const Value.absent(),
    this.status = const Value.absent(),
    this.totalItems = const Value.absent(),
    this.completedItems = const Value.absent(),
    this.failedItems = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.completedBytes = const Value.absent(),
    this.lastError = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.lastSuccessAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncRunStateCompanion.insert({
    required String id,
    required String status,
    this.totalItems = const Value.absent(),
    this.completedItems = const Value.absent(),
    this.failedItems = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.completedBytes = const Value.absent(),
    this.lastError = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.lastSuccessAt = const Value.absent(),
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        status = Value(status);
  static Insertable<SyncRunStateData> custom({
    Expression<String>? id,
    Expression<String>? status,
    Expression<int>? totalItems,
    Expression<int>? completedItems,
    Expression<int>? failedItems,
    Expression<int>? totalBytes,
    Expression<int>? completedBytes,
    Expression<String>? lastError,
    Expression<int>? updatedAt,
    Expression<int>? lastSuccessAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (status != null) 'status': status,
      if (totalItems != null) 'total_items': totalItems,
      if (completedItems != null) 'completed_items': completedItems,
      if (failedItems != null) 'failed_items': failedItems,
      if (totalBytes != null) 'total_bytes': totalBytes,
      if (completedBytes != null) 'completed_bytes': completedBytes,
      if (lastError != null) 'last_error': lastError,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (lastSuccessAt != null) 'last_success_at': lastSuccessAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncRunStateCompanion copyWith(
      {Value<String>? id,
      Value<String>? status,
      Value<int>? totalItems,
      Value<int>? completedItems,
      Value<int>? failedItems,
      Value<int>? totalBytes,
      Value<int>? completedBytes,
      Value<String?>? lastError,
      Value<int>? updatedAt,
      Value<int?>? lastSuccessAt,
      Value<int>? rowid}) {
    return SyncRunStateCompanion(
      id: id ?? this.id,
      status: status ?? this.status,
      totalItems: totalItems ?? this.totalItems,
      completedItems: completedItems ?? this.completedItems,
      failedItems: failedItems ?? this.failedItems,
      totalBytes: totalBytes ?? this.totalBytes,
      completedBytes: completedBytes ?? this.completedBytes,
      lastError: lastError ?? this.lastError,
      updatedAt: updatedAt ?? this.updatedAt,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (totalItems.present) {
      map['total_items'] = Variable<int>(totalItems.value);
    }
    if (completedItems.present) {
      map['completed_items'] = Variable<int>(completedItems.value);
    }
    if (failedItems.present) {
      map['failed_items'] = Variable<int>(failedItems.value);
    }
    if (totalBytes.present) {
      map['total_bytes'] = Variable<int>(totalBytes.value);
    }
    if (completedBytes.present) {
      map['completed_bytes'] = Variable<int>(completedBytes.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (lastSuccessAt.present) {
      map['last_success_at'] = Variable<int>(lastSuccessAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncRunStateCompanion(')
          ..write('id: $id, ')
          ..write('status: $status, ')
          ..write('totalItems: $totalItems, ')
          ..write('completedItems: $completedItems, ')
          ..write('failedItems: $failedItems, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('completedBytes: $completedBytes, ')
          ..write('lastError: $lastError, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('lastSuccessAt: $lastSuccessAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $TokenRefreshLockTable extends TokenRefreshLock
    with TableInfo<$TokenRefreshLockTable, TokenRefreshLockData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TokenRefreshLockTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _holderMeta = const VerificationMeta('holder');
  @override
  late final GeneratedColumn<String> holder = GeneratedColumn<String>(
      'holder', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _acquiredAtMeta =
      const VerificationMeta('acquiredAt');
  @override
  late final GeneratedColumn<int> acquiredAt = GeneratedColumn<int>(
      'acquired_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _expiresAtMeta =
      const VerificationMeta('expiresAt');
  @override
  late final GeneratedColumn<int> expiresAt = GeneratedColumn<int>(
      'expires_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, holder, acquiredAt, expiresAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'token_refresh_lock';
  @override
  VerificationContext validateIntegrity(
      Insertable<TokenRefreshLockData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('holder')) {
      context.handle(_holderMeta,
          holder.isAcceptableOrUnknown(data['holder']!, _holderMeta));
    } else if (isInserting) {
      context.missing(_holderMeta);
    }
    if (data.containsKey('acquired_at')) {
      context.handle(
          _acquiredAtMeta,
          acquiredAt.isAcceptableOrUnknown(
              data['acquired_at']!, _acquiredAtMeta));
    } else if (isInserting) {
      context.missing(_acquiredAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(_expiresAtMeta,
          expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta));
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TokenRefreshLockData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TokenRefreshLockData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      holder: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}holder'])!,
      acquiredAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}acquired_at'])!,
      expiresAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}expires_at'])!,
    );
  }

  @override
  $TokenRefreshLockTable createAlias(String alias) {
    return $TokenRefreshLockTable(attachedDatabase, alias);
  }
}

class TokenRefreshLockData extends DataClass
    implements Insertable<TokenRefreshLockData> {
  final String id;

  /// Which isolate currently holds (or most recently held) the lock -
  /// `'ui'` or `'headless'`, see the constants next to `refreshTokenWithLock`
  /// in `../sync/token_refresh_coordination.dart`. Diagnostic only, per the
  /// class doc.
  final String holder;

  /// Epoch milliseconds the current holder acquired the lock at.
  final int acquiredAt;

  /// Epoch milliseconds the current lease expires at - past this point the
  /// lock is free for another acquire regardless of whether
  /// [GalleryMirror.releaseTokenRefreshLock] was ever called (see the class
  /// doc's "lease-based" note).
  final int expiresAt;
  const TokenRefreshLockData(
      {required this.id,
      required this.holder,
      required this.acquiredAt,
      required this.expiresAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['holder'] = Variable<String>(holder);
    map['acquired_at'] = Variable<int>(acquiredAt);
    map['expires_at'] = Variable<int>(expiresAt);
    return map;
  }

  TokenRefreshLockCompanion toCompanion(bool nullToAbsent) {
    return TokenRefreshLockCompanion(
      id: Value(id),
      holder: Value(holder),
      acquiredAt: Value(acquiredAt),
      expiresAt: Value(expiresAt),
    );
  }

  factory TokenRefreshLockData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TokenRefreshLockData(
      id: serializer.fromJson<String>(json['id']),
      holder: serializer.fromJson<String>(json['holder']),
      acquiredAt: serializer.fromJson<int>(json['acquiredAt']),
      expiresAt: serializer.fromJson<int>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'holder': serializer.toJson<String>(holder),
      'acquiredAt': serializer.toJson<int>(acquiredAt),
      'expiresAt': serializer.toJson<int>(expiresAt),
    };
  }

  TokenRefreshLockData copyWith(
          {String? id, String? holder, int? acquiredAt, int? expiresAt}) =>
      TokenRefreshLockData(
        id: id ?? this.id,
        holder: holder ?? this.holder,
        acquiredAt: acquiredAt ?? this.acquiredAt,
        expiresAt: expiresAt ?? this.expiresAt,
      );
  TokenRefreshLockData copyWithCompanion(TokenRefreshLockCompanion data) {
    return TokenRefreshLockData(
      id: data.id.present ? data.id.value : this.id,
      holder: data.holder.present ? data.holder.value : this.holder,
      acquiredAt:
          data.acquiredAt.present ? data.acquiredAt.value : this.acquiredAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TokenRefreshLockData(')
          ..write('id: $id, ')
          ..write('holder: $holder, ')
          ..write('acquiredAt: $acquiredAt, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, holder, acquiredAt, expiresAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TokenRefreshLockData &&
          other.id == this.id &&
          other.holder == this.holder &&
          other.acquiredAt == this.acquiredAt &&
          other.expiresAt == this.expiresAt);
}

class TokenRefreshLockCompanion extends UpdateCompanion<TokenRefreshLockData> {
  final Value<String> id;
  final Value<String> holder;
  final Value<int> acquiredAt;
  final Value<int> expiresAt;
  final Value<int> rowid;
  const TokenRefreshLockCompanion({
    this.id = const Value.absent(),
    this.holder = const Value.absent(),
    this.acquiredAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TokenRefreshLockCompanion.insert({
    required String id,
    required String holder,
    required int acquiredAt,
    required int expiresAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        holder = Value(holder),
        acquiredAt = Value(acquiredAt),
        expiresAt = Value(expiresAt);
  static Insertable<TokenRefreshLockData> custom({
    Expression<String>? id,
    Expression<String>? holder,
    Expression<int>? acquiredAt,
    Expression<int>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (holder != null) 'holder': holder,
      if (acquiredAt != null) 'acquired_at': acquiredAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TokenRefreshLockCompanion copyWith(
      {Value<String>? id,
      Value<String>? holder,
      Value<int>? acquiredAt,
      Value<int>? expiresAt,
      Value<int>? rowid}) {
    return TokenRefreshLockCompanion(
      id: id ?? this.id,
      holder: holder ?? this.holder,
      acquiredAt: acquiredAt ?? this.acquiredAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (holder.present) {
      map['holder'] = Variable<String>(holder.value);
    }
    if (acquiredAt.present) {
      map['acquired_at'] = Variable<int>(acquiredAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<int>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TokenRefreshLockCompanion(')
          ..write('id: $id, ')
          ..write('holder: $holder, ')
          ..write('acquiredAt: $acquiredAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SyncRunLockTable extends SyncRunLock
    with TableInfo<$SyncRunLockTable, SyncRunLockData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncRunLockTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
      'id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _holderMeta = const VerificationMeta('holder');
  @override
  late final GeneratedColumn<String> holder = GeneratedColumn<String>(
      'holder', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _acquiredAtMeta =
      const VerificationMeta('acquiredAt');
  @override
  late final GeneratedColumn<int> acquiredAt = GeneratedColumn<int>(
      'acquired_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _expiresAtMeta =
      const VerificationMeta('expiresAt');
  @override
  late final GeneratedColumn<int> expiresAt = GeneratedColumn<int>(
      'expires_at', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, holder, acquiredAt, expiresAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_run_lock';
  @override
  VerificationContext validateIntegrity(Insertable<SyncRunLockData> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('holder')) {
      context.handle(_holderMeta,
          holder.isAcceptableOrUnknown(data['holder']!, _holderMeta));
    } else if (isInserting) {
      context.missing(_holderMeta);
    }
    if (data.containsKey('acquired_at')) {
      context.handle(
          _acquiredAtMeta,
          acquiredAt.isAcceptableOrUnknown(
              data['acquired_at']!, _acquiredAtMeta));
    } else if (isInserting) {
      context.missing(_acquiredAtMeta);
    }
    if (data.containsKey('expires_at')) {
      context.handle(_expiresAtMeta,
          expiresAt.isAcceptableOrUnknown(data['expires_at']!, _expiresAtMeta));
    } else if (isInserting) {
      context.missing(_expiresAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncRunLockData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncRunLockData(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      holder: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}holder'])!,
      acquiredAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}acquired_at'])!,
      expiresAt: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}expires_at'])!,
    );
  }

  @override
  $SyncRunLockTable createAlias(String alias) {
    return $SyncRunLockTable(attachedDatabase, alias);
  }
}

class SyncRunLockData extends DataClass implements Insertable<SyncRunLockData> {
  final String id;

  /// Which entrypoint currently holds (or most recently held) the lock -
  /// see `syncRunLockHolderForegroundService`/`syncRunLockHolderWorkManager`
  /// in `../sync/gallery_headless_sync.dart`. Diagnostic only - acquisition
  /// never depends on who is asking, only on whether the lease is free or
  /// already held by that same holder.
  final String holder;

  /// Epoch milliseconds the current holder (most recently) acquired or
  /// renewed the lock at.
  final int acquiredAt;

  /// Epoch milliseconds the current lease expires at - past this point the
  /// lock is free for another (different) holder to acquire, regardless of
  /// whether [GalleryMirror.releaseSyncRunLock] was ever called.
  final int expiresAt;
  const SyncRunLockData(
      {required this.id,
      required this.holder,
      required this.acquiredAt,
      required this.expiresAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['holder'] = Variable<String>(holder);
    map['acquired_at'] = Variable<int>(acquiredAt);
    map['expires_at'] = Variable<int>(expiresAt);
    return map;
  }

  SyncRunLockCompanion toCompanion(bool nullToAbsent) {
    return SyncRunLockCompanion(
      id: Value(id),
      holder: Value(holder),
      acquiredAt: Value(acquiredAt),
      expiresAt: Value(expiresAt),
    );
  }

  factory SyncRunLockData.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncRunLockData(
      id: serializer.fromJson<String>(json['id']),
      holder: serializer.fromJson<String>(json['holder']),
      acquiredAt: serializer.fromJson<int>(json['acquiredAt']),
      expiresAt: serializer.fromJson<int>(json['expiresAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'holder': serializer.toJson<String>(holder),
      'acquiredAt': serializer.toJson<int>(acquiredAt),
      'expiresAt': serializer.toJson<int>(expiresAt),
    };
  }

  SyncRunLockData copyWith(
          {String? id, String? holder, int? acquiredAt, int? expiresAt}) =>
      SyncRunLockData(
        id: id ?? this.id,
        holder: holder ?? this.holder,
        acquiredAt: acquiredAt ?? this.acquiredAt,
        expiresAt: expiresAt ?? this.expiresAt,
      );
  SyncRunLockData copyWithCompanion(SyncRunLockCompanion data) {
    return SyncRunLockData(
      id: data.id.present ? data.id.value : this.id,
      holder: data.holder.present ? data.holder.value : this.holder,
      acquiredAt:
          data.acquiredAt.present ? data.acquiredAt.value : this.acquiredAt,
      expiresAt: data.expiresAt.present ? data.expiresAt.value : this.expiresAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncRunLockData(')
          ..write('id: $id, ')
          ..write('holder: $holder, ')
          ..write('acquiredAt: $acquiredAt, ')
          ..write('expiresAt: $expiresAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, holder, acquiredAt, expiresAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncRunLockData &&
          other.id == this.id &&
          other.holder == this.holder &&
          other.acquiredAt == this.acquiredAt &&
          other.expiresAt == this.expiresAt);
}

class SyncRunLockCompanion extends UpdateCompanion<SyncRunLockData> {
  final Value<String> id;
  final Value<String> holder;
  final Value<int> acquiredAt;
  final Value<int> expiresAt;
  final Value<int> rowid;
  const SyncRunLockCompanion({
    this.id = const Value.absent(),
    this.holder = const Value.absent(),
    this.acquiredAt = const Value.absent(),
    this.expiresAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncRunLockCompanion.insert({
    required String id,
    required String holder,
    required int acquiredAt,
    required int expiresAt,
    this.rowid = const Value.absent(),
  })  : id = Value(id),
        holder = Value(holder),
        acquiredAt = Value(acquiredAt),
        expiresAt = Value(expiresAt);
  static Insertable<SyncRunLockData> custom({
    Expression<String>? id,
    Expression<String>? holder,
    Expression<int>? acquiredAt,
    Expression<int>? expiresAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (holder != null) 'holder': holder,
      if (acquiredAt != null) 'acquired_at': acquiredAt,
      if (expiresAt != null) 'expires_at': expiresAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncRunLockCompanion copyWith(
      {Value<String>? id,
      Value<String>? holder,
      Value<int>? acquiredAt,
      Value<int>? expiresAt,
      Value<int>? rowid}) {
    return SyncRunLockCompanion(
      id: id ?? this.id,
      holder: holder ?? this.holder,
      acquiredAt: acquiredAt ?? this.acquiredAt,
      expiresAt: expiresAt ?? this.expiresAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (holder.present) {
      map['holder'] = Variable<String>(holder.value);
    }
    if (acquiredAt.present) {
      map['acquired_at'] = Variable<int>(acquiredAt.value);
    }
    if (expiresAt.present) {
      map['expires_at'] = Variable<int>(expiresAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncRunLockCompanion(')
          ..write('id: $id, ')
          ..write('holder: $holder, ')
          ..write('acquiredAt: $acquiredAt, ')
          ..write('expiresAt: $expiresAt, ')
          ..write('rowid: $rowid')
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
  late final $SyncRunStateTable syncRunState = $SyncRunStateTable(this);
  late final $TokenRefreshLockTable tokenRefreshLock =
      $TokenRefreshLockTable(this);
  late final $SyncRunLockTable syncRunLock = $SyncRunLockTable(this);
  late final Index idxGalleryItemsLocalIdentity = Index(
      'idx_gallery_items_local_identity',
      'CREATE INDEX idx_gallery_items_local_identity ON gallery_items (local_relative_path, local_display_name, local_size, local_date_taken)');
  late final Index idxGalleryItemsOriginSizeCapturedAt = Index(
      'idx_gallery_items_origin_size_captured_at',
      'CREATE INDEX idx_gallery_items_origin_size_captured_at ON gallery_items (origin, size, captured_at)');
  late final Index idxGalleryItemsCapturedAtId = Index(
      'idx_gallery_items_captured_at_id',
      'CREATE INDEX idx_gallery_items_captured_at_id ON gallery_items (captured_at, id)');
  late final Index idxGalleryItemsUploadTarget = Index(
      'idx_gallery_items_upload_target',
      'CREATE INDEX idx_gallery_items_upload_target ON gallery_items (upload_target_provider_id, upload_target_path)');
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
        syncRunState,
        tokenRefreshLock,
        syncRunLock,
        idxGalleryItemsLocalIdentity,
        idxGalleryItemsOriginSizeCapturedAt,
        idxGalleryItemsCapturedAtId,
        idxGalleryItemsUploadTarget
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
  Value<String?> uploadState,
  Value<String?> uploadTargetProviderId,
  Value<String?> uploadTargetPath,
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
  Value<String?> uploadState,
  Value<String?> uploadTargetProviderId,
  Value<String?> uploadTargetPath,
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

  ColumnFilters<String> get uploadState => $composableBuilder(
      column: $table.uploadState, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uploadTargetProviderId => $composableBuilder(
      column: $table.uploadTargetProviderId,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uploadTargetPath => $composableBuilder(
      column: $table.uploadTargetPath,
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

  ColumnOrderings<String> get uploadState => $composableBuilder(
      column: $table.uploadState, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uploadTargetProviderId => $composableBuilder(
      column: $table.uploadTargetProviderId,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uploadTargetPath => $composableBuilder(
      column: $table.uploadTargetPath,
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

  GeneratedColumn<String> get uploadState => $composableBuilder(
      column: $table.uploadState, builder: (column) => column);

  GeneratedColumn<String> get uploadTargetProviderId => $composableBuilder(
      column: $table.uploadTargetProviderId, builder: (column) => column);

  GeneratedColumn<String> get uploadTargetPath => $composableBuilder(
      column: $table.uploadTargetPath, builder: (column) => column);
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
            Value<String?> uploadState = const Value.absent(),
            Value<String?> uploadTargetProviderId = const Value.absent(),
            Value<String?> uploadTargetPath = const Value.absent(),
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
            uploadState: uploadState,
            uploadTargetProviderId: uploadTargetProviderId,
            uploadTargetPath: uploadTargetPath,
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
            Value<String?> uploadState = const Value.absent(),
            Value<String?> uploadTargetProviderId = const Value.absent(),
            Value<String?> uploadTargetPath = const Value.absent(),
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
            uploadState: uploadState,
            uploadTargetProviderId: uploadTargetProviderId,
            uploadTargetPath: uploadTargetPath,
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
  Value<int?> removedAt,
});
typedef $$SyncPairsTableUpdateCompanionBuilder = SyncPairsCompanion Function({
  Value<int> id,
  Value<String> localFolderPath,
  Value<String> spaceProviderId,
  Value<String> path,
  Value<int> createdAt,
  Value<int?> removedAt,
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

  ColumnFilters<int> get removedAt => $composableBuilder(
      column: $table.removedAt, builder: (column) => ColumnFilters(column));
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

  ColumnOrderings<int> get removedAt => $composableBuilder(
      column: $table.removedAt, builder: (column) => ColumnOrderings(column));
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

  GeneratedColumn<int> get removedAt =>
      $composableBuilder(column: $table.removedAt, builder: (column) => column);
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
            Value<int?> removedAt = const Value.absent(),
          }) =>
              SyncPairsCompanion(
            id: id,
            localFolderPath: localFolderPath,
            spaceProviderId: spaceProviderId,
            path: path,
            createdAt: createdAt,
            removedAt: removedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String localFolderPath,
            required String spaceProviderId,
            required String path,
            Value<int> createdAt = const Value.absent(),
            Value<int?> removedAt = const Value.absent(),
          }) =>
              SyncPairsCompanion.insert(
            id: id,
            localFolderPath: localFolderPath,
            spaceProviderId: spaceProviderId,
            path: path,
            createdAt: createdAt,
            removedAt: removedAt,
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
typedef $$SyncRunStateTableCreateCompanionBuilder = SyncRunStateCompanion
    Function({
  required String id,
  required String status,
  Value<int> totalItems,
  Value<int> completedItems,
  Value<int> failedItems,
  Value<int> totalBytes,
  Value<int> completedBytes,
  Value<String?> lastError,
  Value<int> updatedAt,
  Value<int?> lastSuccessAt,
  Value<int> rowid,
});
typedef $$SyncRunStateTableUpdateCompanionBuilder = SyncRunStateCompanion
    Function({
  Value<String> id,
  Value<String> status,
  Value<int> totalItems,
  Value<int> completedItems,
  Value<int> failedItems,
  Value<int> totalBytes,
  Value<int> completedBytes,
  Value<String?> lastError,
  Value<int> updatedAt,
  Value<int?> lastSuccessAt,
  Value<int> rowid,
});

class $$SyncRunStateTableFilterComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncRunStateTable> {
  $$SyncRunStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get totalItems => $composableBuilder(
      column: $table.totalItems, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get completedItems => $composableBuilder(
      column: $table.completedItems,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get failedItems => $composableBuilder(
      column: $table.failedItems, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get totalBytes => $composableBuilder(
      column: $table.totalBytes, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get completedBytes => $composableBuilder(
      column: $table.completedBytes,
      builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get lastError => $composableBuilder(
      column: $table.lastError, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get lastSuccessAt => $composableBuilder(
      column: $table.lastSuccessAt, builder: (column) => ColumnFilters(column));
}

class $$SyncRunStateTableOrderingComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncRunStateTable> {
  $$SyncRunStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status => $composableBuilder(
      column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get totalItems => $composableBuilder(
      column: $table.totalItems, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get completedItems => $composableBuilder(
      column: $table.completedItems,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get failedItems => $composableBuilder(
      column: $table.failedItems, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get totalBytes => $composableBuilder(
      column: $table.totalBytes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get completedBytes => $composableBuilder(
      column: $table.completedBytes,
      builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get lastError => $composableBuilder(
      column: $table.lastError, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get lastSuccessAt => $composableBuilder(
      column: $table.lastSuccessAt,
      builder: (column) => ColumnOrderings(column));
}

class $$SyncRunStateTableAnnotationComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncRunStateTable> {
  $$SyncRunStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get totalItems => $composableBuilder(
      column: $table.totalItems, builder: (column) => column);

  GeneratedColumn<int> get completedItems => $composableBuilder(
      column: $table.completedItems, builder: (column) => column);

  GeneratedColumn<int> get failedItems => $composableBuilder(
      column: $table.failedItems, builder: (column) => column);

  GeneratedColumn<int> get totalBytes => $composableBuilder(
      column: $table.totalBytes, builder: (column) => column);

  GeneratedColumn<int> get completedBytes => $composableBuilder(
      column: $table.completedBytes, builder: (column) => column);

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get lastSuccessAt => $composableBuilder(
      column: $table.lastSuccessAt, builder: (column) => column);
}

class $$SyncRunStateTableTableManager extends RootTableManager<
    _$GalleryMirrorDatabase,
    $SyncRunStateTable,
    SyncRunStateData,
    $$SyncRunStateTableFilterComposer,
    $$SyncRunStateTableOrderingComposer,
    $$SyncRunStateTableAnnotationComposer,
    $$SyncRunStateTableCreateCompanionBuilder,
    $$SyncRunStateTableUpdateCompanionBuilder,
    (
      SyncRunStateData,
      BaseReferences<_$GalleryMirrorDatabase, $SyncRunStateTable,
          SyncRunStateData>
    ),
    SyncRunStateData,
    PrefetchHooks Function()> {
  $$SyncRunStateTableTableManager(
      _$GalleryMirrorDatabase db, $SyncRunStateTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncRunStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncRunStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncRunStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> status = const Value.absent(),
            Value<int> totalItems = const Value.absent(),
            Value<int> completedItems = const Value.absent(),
            Value<int> failedItems = const Value.absent(),
            Value<int> totalBytes = const Value.absent(),
            Value<int> completedBytes = const Value.absent(),
            Value<String?> lastError = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int?> lastSuccessAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncRunStateCompanion(
            id: id,
            status: status,
            totalItems: totalItems,
            completedItems: completedItems,
            failedItems: failedItems,
            totalBytes: totalBytes,
            completedBytes: completedBytes,
            lastError: lastError,
            updatedAt: updatedAt,
            lastSuccessAt: lastSuccessAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String status,
            Value<int> totalItems = const Value.absent(),
            Value<int> completedItems = const Value.absent(),
            Value<int> failedItems = const Value.absent(),
            Value<int> totalBytes = const Value.absent(),
            Value<int> completedBytes = const Value.absent(),
            Value<String?> lastError = const Value.absent(),
            Value<int> updatedAt = const Value.absent(),
            Value<int?> lastSuccessAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncRunStateCompanion.insert(
            id: id,
            status: status,
            totalItems: totalItems,
            completedItems: completedItems,
            failedItems: failedItems,
            totalBytes: totalBytes,
            completedBytes: completedBytes,
            lastError: lastError,
            updatedAt: updatedAt,
            lastSuccessAt: lastSuccessAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncRunStateTableProcessedTableManager = ProcessedTableManager<
    _$GalleryMirrorDatabase,
    $SyncRunStateTable,
    SyncRunStateData,
    $$SyncRunStateTableFilterComposer,
    $$SyncRunStateTableOrderingComposer,
    $$SyncRunStateTableAnnotationComposer,
    $$SyncRunStateTableCreateCompanionBuilder,
    $$SyncRunStateTableUpdateCompanionBuilder,
    (
      SyncRunStateData,
      BaseReferences<_$GalleryMirrorDatabase, $SyncRunStateTable,
          SyncRunStateData>
    ),
    SyncRunStateData,
    PrefetchHooks Function()>;
typedef $$TokenRefreshLockTableCreateCompanionBuilder
    = TokenRefreshLockCompanion Function({
  required String id,
  required String holder,
  required int acquiredAt,
  required int expiresAt,
  Value<int> rowid,
});
typedef $$TokenRefreshLockTableUpdateCompanionBuilder
    = TokenRefreshLockCompanion Function({
  Value<String> id,
  Value<String> holder,
  Value<int> acquiredAt,
  Value<int> expiresAt,
  Value<int> rowid,
});

class $$TokenRefreshLockTableFilterComposer
    extends Composer<_$GalleryMirrorDatabase, $TokenRefreshLockTable> {
  $$TokenRefreshLockTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get holder => $composableBuilder(
      column: $table.holder, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get acquiredAt => $composableBuilder(
      column: $table.acquiredAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnFilters(column));
}

class $$TokenRefreshLockTableOrderingComposer
    extends Composer<_$GalleryMirrorDatabase, $TokenRefreshLockTable> {
  $$TokenRefreshLockTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get holder => $composableBuilder(
      column: $table.holder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get acquiredAt => $composableBuilder(
      column: $table.acquiredAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnOrderings(column));
}

class $$TokenRefreshLockTableAnnotationComposer
    extends Composer<_$GalleryMirrorDatabase, $TokenRefreshLockTable> {
  $$TokenRefreshLockTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get holder =>
      $composableBuilder(column: $table.holder, builder: (column) => column);

  GeneratedColumn<int> get acquiredAt => $composableBuilder(
      column: $table.acquiredAt, builder: (column) => column);

  GeneratedColumn<int> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);
}

class $$TokenRefreshLockTableTableManager extends RootTableManager<
    _$GalleryMirrorDatabase,
    $TokenRefreshLockTable,
    TokenRefreshLockData,
    $$TokenRefreshLockTableFilterComposer,
    $$TokenRefreshLockTableOrderingComposer,
    $$TokenRefreshLockTableAnnotationComposer,
    $$TokenRefreshLockTableCreateCompanionBuilder,
    $$TokenRefreshLockTableUpdateCompanionBuilder,
    (
      TokenRefreshLockData,
      BaseReferences<_$GalleryMirrorDatabase, $TokenRefreshLockTable,
          TokenRefreshLockData>
    ),
    TokenRefreshLockData,
    PrefetchHooks Function()> {
  $$TokenRefreshLockTableTableManager(
      _$GalleryMirrorDatabase db, $TokenRefreshLockTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TokenRefreshLockTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TokenRefreshLockTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TokenRefreshLockTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> holder = const Value.absent(),
            Value<int> acquiredAt = const Value.absent(),
            Value<int> expiresAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              TokenRefreshLockCompanion(
            id: id,
            holder: holder,
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String holder,
            required int acquiredAt,
            required int expiresAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              TokenRefreshLockCompanion.insert(
            id: id,
            holder: holder,
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TokenRefreshLockTableProcessedTableManager = ProcessedTableManager<
    _$GalleryMirrorDatabase,
    $TokenRefreshLockTable,
    TokenRefreshLockData,
    $$TokenRefreshLockTableFilterComposer,
    $$TokenRefreshLockTableOrderingComposer,
    $$TokenRefreshLockTableAnnotationComposer,
    $$TokenRefreshLockTableCreateCompanionBuilder,
    $$TokenRefreshLockTableUpdateCompanionBuilder,
    (
      TokenRefreshLockData,
      BaseReferences<_$GalleryMirrorDatabase, $TokenRefreshLockTable,
          TokenRefreshLockData>
    ),
    TokenRefreshLockData,
    PrefetchHooks Function()>;
typedef $$SyncRunLockTableCreateCompanionBuilder = SyncRunLockCompanion
    Function({
  required String id,
  required String holder,
  required int acquiredAt,
  required int expiresAt,
  Value<int> rowid,
});
typedef $$SyncRunLockTableUpdateCompanionBuilder = SyncRunLockCompanion
    Function({
  Value<String> id,
  Value<String> holder,
  Value<int> acquiredAt,
  Value<int> expiresAt,
  Value<int> rowid,
});

class $$SyncRunLockTableFilterComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncRunLockTable> {
  $$SyncRunLockTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get holder => $composableBuilder(
      column: $table.holder, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get acquiredAt => $composableBuilder(
      column: $table.acquiredAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnFilters(column));
}

class $$SyncRunLockTableOrderingComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncRunLockTable> {
  $$SyncRunLockTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get holder => $composableBuilder(
      column: $table.holder, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get acquiredAt => $composableBuilder(
      column: $table.acquiredAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get expiresAt => $composableBuilder(
      column: $table.expiresAt, builder: (column) => ColumnOrderings(column));
}

class $$SyncRunLockTableAnnotationComposer
    extends Composer<_$GalleryMirrorDatabase, $SyncRunLockTable> {
  $$SyncRunLockTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get holder =>
      $composableBuilder(column: $table.holder, builder: (column) => column);

  GeneratedColumn<int> get acquiredAt => $composableBuilder(
      column: $table.acquiredAt, builder: (column) => column);

  GeneratedColumn<int> get expiresAt =>
      $composableBuilder(column: $table.expiresAt, builder: (column) => column);
}

class $$SyncRunLockTableTableManager extends RootTableManager<
    _$GalleryMirrorDatabase,
    $SyncRunLockTable,
    SyncRunLockData,
    $$SyncRunLockTableFilterComposer,
    $$SyncRunLockTableOrderingComposer,
    $$SyncRunLockTableAnnotationComposer,
    $$SyncRunLockTableCreateCompanionBuilder,
    $$SyncRunLockTableUpdateCompanionBuilder,
    (
      SyncRunLockData,
      BaseReferences<_$GalleryMirrorDatabase, $SyncRunLockTable,
          SyncRunLockData>
    ),
    SyncRunLockData,
    PrefetchHooks Function()> {
  $$SyncRunLockTableTableManager(
      _$GalleryMirrorDatabase db, $SyncRunLockTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncRunLockTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncRunLockTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncRunLockTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<String> holder = const Value.absent(),
            Value<int> acquiredAt = const Value.absent(),
            Value<int> expiresAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncRunLockCompanion(
            id: id,
            holder: holder,
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String id,
            required String holder,
            required int acquiredAt,
            required int expiresAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              SyncRunLockCompanion.insert(
            id: id,
            holder: holder,
            acquiredAt: acquiredAt,
            expiresAt: expiresAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SyncRunLockTableProcessedTableManager = ProcessedTableManager<
    _$GalleryMirrorDatabase,
    $SyncRunLockTable,
    SyncRunLockData,
    $$SyncRunLockTableFilterComposer,
    $$SyncRunLockTableOrderingComposer,
    $$SyncRunLockTableAnnotationComposer,
    $$SyncRunLockTableCreateCompanionBuilder,
    $$SyncRunLockTableUpdateCompanionBuilder,
    (
      SyncRunLockData,
      BaseReferences<_$GalleryMirrorDatabase, $SyncRunLockTable,
          SyncRunLockData>
    ),
    SyncRunLockData,
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
  $$SyncRunStateTableTableManager get syncRunState =>
      $$SyncRunStateTableTableManager(_db, _db.syncRunState);
  $$TokenRefreshLockTableTableManager get tokenRefreshLock =>
      $$TokenRefreshLockTableTableManager(_db, _db.tokenRefreshLock);
  $$SyncRunLockTableTableManager get syncRunLock =>
      $$SyncRunLockTableTableManager(_db, _db.syncRunLock);
}
