import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:uuid/uuid.dart';

import '../core/db.dart';
import '../core/geo.dart';
import '../core/settings.dart';
import 'feature_repository.dart';
import 'location_service.dart';

/// Merekam jalur (track) dari GPS. Tiap titik langsung ditulis ke SQLite,
/// jadi tidak ada data hilang bila aplikasi tertutup atau baterai habis.
class TrackRecorder extends ChangeNotifier {
  TrackRecorder._();
  static final TrackRecorder instance = TrackRecorder._();

  String? trackId;
  String name = '';
  DateTime? startedAt;
  bool paused = false;
  final List<LatLng> points = [];
  double distance = 0;
  StreamSubscription<Position>? _sub;

  bool get recording => trackId != null;
  Duration get elapsed => startedAt == null ? Duration.zero : DateTime.now().difference(startedAt!);

  Future<void> start(String trackName) async {
    if (recording) return;
    final id = const Uuid().v4();
    final now = DateTime.now();
    await AppDatabase.instance.db.insert('tracks', {
      'id': id,
      'name': trackName,
      'started_at': now.toIso8601String(),
      'created_by': AppSettings.instance.userName,
      'sync_status': 'pending',
    });
    trackId = id;
    FeatureRepository.instance.activeTrackId = id;
    name = trackName;
    startedAt = now;
    paused = false;
    points.clear();
    distance = 0;
    await LocationService.instance.start(background: true);
    _sub = LocationService.instance.positions.listen(_onPosition);
    notifyListeners();
  }

  Future<void> _onPosition(Position p) async {
    if (paused || trackId == null) return;
    if (p.accuracy > AppSettings.instance.maxAccuracy) return;
    final ll = LatLng(p.latitude, p.longitude);
    if (points.isNotEmpty) {
      final d = Geo.distance(points.last, ll);
      // abaikan getaran GPS saat diam (< 3 m atau < akurasi/2)
      if (d < 3 || d < p.accuracy / 2) return;
      distance += d;
    }
    points.add(ll);
    await AppDatabase.instance.db.insert('track_points', {
      'track_id': trackId,
      'lat': p.latitude,
      'lon': p.longitude,
      'alt': p.altitude,
      'accuracy': p.accuracy,
      'time': p.timestamp.toIso8601String(),
    });
    notifyListeners();
  }

  void togglePause() {
    paused = !paused;
    notifyListeners();
  }

  Future<void> stop() async {
    if (!recording) return;
    await _sub?.cancel();
    _sub = null;
    await AppDatabase.instance.db.update(
      'tracks',
      {
        'ended_at': DateTime.now().toIso8601String(),
        'distance_m': distance,
        'point_count': points.length,
      },
      where: 'id = ?',
      whereArgs: [trackId],
    );
    trackId = null;
    FeatureRepository.instance.activeTrackId = null;
    startedAt = null;
    points.clear();
    distance = 0;
    await LocationService.instance.start(background: false);
    await FeatureRepository.instance.load();
    notifyListeners();
  }
}
