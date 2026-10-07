import 'dart:convert';

import 'package:latlong2/latlong.dart';

enum SyncStatus { pending, sent, failed }

/// Satu temuan lapangan (titik) beserta atribut dan foto.
class FieldFeature {
  FieldFeature({
    required this.id,
    required this.typeId,
    required this.typeLabel,
    required this.point,
    required this.attributes,
    required this.createdAt,
    required this.updatedAt,
    this.notes,
    this.block,
    this.accuracy,
    this.readings,
    this.positionSource = 'gps',
    this.mapId,
    this.createdBy,
    this.deleted = false,
    this.syncStatus = SyncStatus.pending,
    this.syncError,
    this.photos = const [],
  });

  final String id;
  final String typeId;
  final String typeLabel;
  final LatLng point;
  final Map<String, dynamic> attributes;
  final String? notes;
  final String? block;
  final double? accuracy;
  final int? readings;
  final String positionSource; // gps-avg | gps | manual
  final String? mapId;
  final String? createdBy;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool deleted;
  final SyncStatus syncStatus;
  final String? syncError;
  final List<String> photos; // path file lokal

  Map<String, Object?> get geometry => {
        'type': 'Point',
        'coordinates': [point.longitude, point.latitude],
      };

  Map<String, Object?> toRow() => {
        'id': id,
        'type_id': typeId,
        'type_label': typeLabel,
        'geometry': jsonEncode(geometry),
        'lat': point.latitude,
        'lon': point.longitude,
        'attributes': jsonEncode(attributes),
        'notes': notes,
        'block': block,
        'accuracy': accuracy,
        'readings': readings,
        'position_source': positionSource,
        'map_id': mapId,
        'created_by': createdBy,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
        'deleted': deleted ? 1 : 0,
        'sync_status': syncStatus.name,
        'sync_error': syncError,
      };

  factory FieldFeature.fromRow(Map<String, Object?> r, {List<String> photos = const []}) => FieldFeature(
        id: r['id'] as String,
        typeId: r['type_id'] as String,
        typeLabel: r['type_label'] as String,
        point: LatLng((r['lat'] as num).toDouble(), (r['lon'] as num).toDouble()),
        attributes: (jsonDecode(r['attributes'] as String) as Map).cast<String, dynamic>(),
        notes: r['notes'] as String?,
        block: r['block'] as String?,
        accuracy: (r['accuracy'] as num?)?.toDouble(),
        readings: r['readings'] as int?,
        positionSource: (r['position_source'] as String?) ?? 'gps',
        mapId: r['map_id'] as String?,
        createdBy: r['created_by'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String),
        updatedAt: DateTime.parse(r['updated_at'] as String),
        deleted: (r['deleted'] as int? ?? 0) == 1,
        syncStatus: SyncStatus.values.byName(r['sync_status'] as String),
        syncError: r['sync_error'] as String?,
        photos: photos,
      );
}
