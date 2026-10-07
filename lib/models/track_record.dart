import 'package:latlong2/latlong.dart';

import 'field_feature.dart';

class TrackPoint {
  const TrackPoint(this.point, this.time, {this.altitude, this.accuracy});
  final LatLng point;
  final DateTime time;
  final double? altitude;
  final double? accuracy;
}

class TrackRecord {
  TrackRecord({
    required this.id,
    required this.name,
    required this.startedAt,
    this.endedAt,
    this.distanceM = 0,
    this.pointCount = 0,
    this.createdBy,
    this.syncStatus = SyncStatus.pending,
    this.syncError,
  });

  final String id;
  final String name;
  final DateTime startedAt;
  final DateTime? endedAt;
  final double distanceM;
  final int pointCount;
  final String? createdBy;
  final SyncStatus syncStatus;
  final String? syncError;

  Duration get duration => (endedAt ?? DateTime.now()).difference(startedAt);

  factory TrackRecord.fromRow(Map<String, Object?> r) => TrackRecord(
        id: r['id'] as String,
        name: r['name'] as String,
        startedAt: DateTime.parse(r['started_at'] as String),
        endedAt: r['ended_at'] == null ? null : DateTime.parse(r['ended_at'] as String),
        distanceM: (r['distance_m'] as num? ?? 0).toDouble(),
        pointCount: (r['point_count'] as int?) ?? 0,
        createdBy: r['created_by'] as String?,
        syncStatus: SyncStatus.values.byName(r['sync_status'] as String),
        syncError: r['sync_error'] as String?,
      );
}
