import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/db.dart';
import '../models/field_feature.dart';
import '../models/track_record.dart';

/// Data lapangan: temuan (titik + foto) dan track. Semua tersimpan di SQLite.
class FeatureRepository extends ChangeNotifier {
  FeatureRepository._();
  static final FeatureRepository instance = FeatureRepository._();

  Database get _db => AppDatabase.instance.db;

  /// Temuan yang tampil (tidak terhapus).
  List<FieldFeature> features = [];
  List<TrackRecord> tracks = [];

  /// Geometri track tersimpan (dimuat untuk 30 track terakhir).
  Map<String, List<LatLng>> trackLines = {};

  int pendingFeatures = 0;
  int pendingTracks = 0;
  int failedCount = 0;
  int get pendingCount => pendingFeatures + pendingTracks;

  Future<void> load() async {
    await _closeDanglingTracks();
    final rows = await _db.query('features', where: 'deleted = 0', orderBy: 'created_at DESC');
    final att = await _db.query('attachments', orderBy: 'created_at');
    final photos = <String, List<String>>{};
    for (final a in att) {
      photos.putIfAbsent(a['feature_id'] as String, () => []).add(a['path'] as String);
    }
    features = rows.map((r) => FieldFeature.fromRow(r, photos: photos[r['id']] ?? const [])).toList();

    final trows = await _db.query('tracks', orderBy: 'started_at DESC');
    tracks = trows.map(TrackRecord.fromRow).toList();
    trackLines = {};
    for (final t in tracks.take(30)) {
      trackLines[t.id] = (await trackPoints(t.id)).map((e) => e.point).toList();
    }
    await _refreshCounts();
    notifyListeners();
  }

  Future<void> _refreshCounts() async {
    int count(List<Map<String, Object?>> r) => (r.first['c'] as int?) ?? 0;
    pendingFeatures =
        count(await _db.rawQuery("SELECT COUNT(*) AS c FROM features WHERE sync_status != 'sent'"));
    pendingTracks = count(await _db
        .rawQuery("SELECT COUNT(*) AS c FROM tracks WHERE sync_status != 'sent' AND ended_at IS NOT NULL"));
    failedCount = count(await _db.rawQuery(
        "SELECT (SELECT COUNT(*) FROM features WHERE sync_status = 'failed') + "
        "(SELECT COUNT(*) FROM tracks WHERE sync_status = 'failed') AS c"));
  }

  /// Track yang tidak sempat ditutup (aplikasi dimatikan paksa) ditutup otomatis.
  Future<void> _closeDanglingTracks() async {
    await _db.execute('''
      UPDATE tracks SET ended_at = COALESCE(
        (SELECT MAX(time) FROM track_points WHERE track_id = tracks.id), started_at)
      WHERE ended_at IS NULL AND id != ?''', [_activeTrackId ?? '']);
  }

  String? _activeTrackId;
  set activeTrackId(String? id) => _activeTrackId = id;

  Future<Directory> _photoDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, 'photos'));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// Simpan temuan + salin foto ke folder aplikasi, dalam satu transaksi.
  Future<FieldFeature> saveFeature({
    required String typeId,
    required String typeLabel,
    required LatLng point,
    required Map<String, dynamic> attributes,
    String? notes,
    String? block,
    double? accuracy,
    int? readings,
    required String positionSource,
    String? mapId,
    String? createdBy,
    List<String> photoPaths = const [],
  }) async {
    final now = DateTime.now();
    final id = const Uuid().v4();
    final dir = await _photoDir();
    final stored = <String>[];
    for (final src in photoPaths) {
      final dest = p.join(dir.path, '${const Uuid().v4()}${p.extension(src).isEmpty ? '.jpg' : p.extension(src)}');
      await File(src).copy(dest);
      stored.add(dest);
    }
    final f = FieldFeature(
      id: id,
      typeId: typeId,
      typeLabel: typeLabel,
      point: point,
      attributes: attributes,
      notes: notes,
      block: block,
      accuracy: accuracy,
      readings: readings,
      positionSource: positionSource,
      mapId: mapId,
      createdBy: createdBy,
      createdAt: now,
      updatedAt: now,
      photos: stored,
    );
    await _db.transaction((txn) async {
      await txn.insert('features', f.toRow());
      for (final s in stored) {
        await txn.insert('attachments', {
          'id': const Uuid().v4(),
          'feature_id': id,
          'path': s,
          'size_bytes': File(s).lengthSync(),
          'created_at': now.toIso8601String(),
        });
      }
    });
    await load();
    return f;
  }

  /// Hapus lunak: ditandai terhapus dan ikut dikirim ke server.
  Future<void> deleteFeature(FieldFeature f) async {
    await _db.update(
      'features',
      {'deleted': 1, 'sync_status': 'pending', 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [f.id],
    );
    await load();
  }

  Future<void> deleteTrack(TrackRecord t) async {
    await _db.delete('tracks', where: 'id = ?', whereArgs: [t.id]);
    await load();
  }

  Future<List<TrackPoint>> trackPoints(String trackId) async {
    final rows = await _db.query('track_points', where: 'track_id = ?', whereArgs: [trackId], orderBy: 'id');
    return rows
        .map((r) => TrackPoint(
              LatLng((r['lat'] as num).toDouble(), (r['lon'] as num).toDouble()),
              DateTime.parse(r['time'] as String),
              altitude: (r['alt'] as num?)?.toDouble(),
              accuracy: (r['accuracy'] as num?)?.toDouble(),
            ))
        .toList();
  }

  // ---- dipakai SyncService ----

  Future<List<FieldFeature>> pendingFeatureList() async {
    final rows = await _db.query('features', where: "sync_status != 'sent'", orderBy: 'created_at');
    final out = <FieldFeature>[];
    for (final r in rows) {
      final att = await _db.query('attachments', where: 'feature_id = ?', whereArgs: [r['id']]);
      out.add(FieldFeature.fromRow(r, photos: att.map((a) => a['path'] as String).toList()));
    }
    return out;
  }

  Future<List<TrackRecord>> pendingTrackList() async {
    final rows =
        await _db.query('tracks', where: "sync_status != 'sent' AND ended_at IS NOT NULL", orderBy: 'started_at');
    return rows.map(TrackRecord.fromRow).toList();
  }

  Future<void> markFeatures(List<String> ids, SyncStatus status, {String? error}) async {
    final b = _db.batch();
    for (final id in ids) {
      b.update('features', {'sync_status': status.name, 'sync_error': error}, where: 'id = ?', whereArgs: [id]);
    }
    await b.commit(noResult: true);
  }

  Future<void> markTracks(List<String> ids, SyncStatus status, {String? error}) async {
    final b = _db.batch();
    for (final id in ids) {
      b.update('tracks', {'sync_status': status.name, 'sync_error': error}, where: 'id = ?', whereArgs: [id]);
    }
    await b.commit(noResult: true);
  }
}
