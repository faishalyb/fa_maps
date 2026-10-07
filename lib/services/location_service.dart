import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../core/settings.dart';

/// Satu sumber posisi GPS untuk seluruh aplikasi (peta, form, rekam track).
/// GPS bekerja tanpa sinyal seluler; yang dibutuhkan hanya langit terbuka.
class LocationService extends ChangeNotifier {
  LocationService._();
  static final LocationService instance = LocationService._();

  Position? position;
  double? heading; // derajat dari utara, null bila tidak ada kompas
  String? error;
  bool running = false;
  bool _background = false;

  final _controller = StreamController<Position>.broadcast();
  Stream<Position> get positions => _controller.stream;

  StreamSubscription<Position>? _sub;
  StreamSubscription<CompassEvent>? _compass;

  LatLng? get latLng => position == null ? null : LatLng(position!.latitude, position!.longitude);

  Future<bool> ensurePermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      error = 'Lokasi (GPS) HP mati. Aktifkan di pengaturan HP.';
      notifyListeners();
      return false;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied || perm == LocationPermission.deniedForever) {
      error = 'Izin lokasi ditolak. Buka pengaturan aplikasi untuk mengizinkan.';
      notifyListeners();
      return false;
    }
    error = null;
    return true;
  }

  /// [background] = true saat rekam track: Android memakai foreground service
  /// (notifikasi tetap) agar GPS tidak dihentikan saat layar terkunci.
  Future<void> start({bool background = false}) async {
    if (running && background == _background) return;
    if (!await ensurePermission()) return;
    await _sub?.cancel();
    _background = background;
    _sub = Geolocator.getPositionStream(locationSettings: _settings(background)).listen(
      (p) {
        position = p;
        error = null;
        _controller.add(p);
        notifyListeners();
      },
      onError: (Object e) {
        error = 'GPS: $e';
        notifyListeners();
      },
    );
    running = true;
    _compass ??= FlutterCompass.events?.listen((e) {
      final h = e.heading;
      if (h == null) return;
      // kurangi rebuild: abaikan perubahan < 3 derajat
      if (heading == null || (h - heading!).abs() > 3) {
        heading = h;
        notifyListeners();
      }
    });
    notifyListeners();
  }

  LocationSettings _settings(bool background) {
    if (Platform.isAndroid) {
      return AndroidSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
        intervalDuration: const Duration(seconds: 1),
        foregroundNotificationConfig: background
            ? const ForegroundNotificationConfig(
                notificationTitle: 'FA Maps merekam track',
                notificationText: 'GPS tetap aktif saat layar dikunci',
                enableWakeLock: true,
              )
            : null,
      );
    }
    if (Platform.isIOS) {
      return AppleSettings(
        accuracy: LocationAccuracy.best,
        activityType: ActivityType.otherNavigation,
        distanceFilter: 0,
        pauseLocationUpdatesAutomatically: false,
        showBackgroundLocationIndicator: background,
        allowBackgroundLocationUpdates: background,
      );
    }
    return const LocationSettings(accuracy: LocationAccuracy.best);
  }
}

/// Hasil rata-rata GPS.
class AveragedFix {
  const AveragedFix(this.point, this.readings, this.meanAccuracy, this.spread);
  final LatLng point;
  final int readings;
  final double meanAccuracy; // rata-rata akurasi yang dilaporkan GPS (m)
  final double spread; // simpangan baku sebaran titik (m)

  /// Akurasi yang disimpan: nilai terbesar dari keduanya (konservatif).
  double get accuracy => math.max(meanAccuracy / math.sqrt(readings), spread);
}

/// Mengumpulkan N bacaan GPS, membuang bacaan buruk, lalu merata-rata.
class GpsAverager extends ChangeNotifier {
  GpsAverager({required this.target});
  final int target;
  final List<Position> samples = [];
  int rejected = 0;
  StreamSubscription<Position>? _sub;
  final _done = Completer<AveragedFix?>();
  Future<AveragedFix?> get result => _done.future;
  bool get finished => _done.isCompleted;

  Future<void> start() async {
    await LocationService.instance.start();
    final maxAcc = AppSettings.instance.maxAccuracy;
    _sub = LocationService.instance.positions.listen((p) {
      if (p.accuracy > maxAcc) {
        rejected++;
        notifyListeners();
        return;
      }
      samples.add(p);
      notifyListeners();
      if (samples.length >= target) finish();
    });
  }

  AveragedFix? get current => _compute();

  void finish() {
    if (_done.isCompleted) return;
    _sub?.cancel();
    _done.complete(_compute());
    notifyListeners();
  }

  AveragedFix? _compute() {
    if (samples.isEmpty) return null;
    // buang pencilan: > 2x median jarak ke titik tengah awal
    var lat = samples.map((s) => s.latitude).reduce((a, b) => a + b) / samples.length;
    var lon = samples.map((s) => s.longitude).reduce((a, b) => a + b) / samples.length;
    final c0 = LatLng(lat, lon);
    final d = samples.map((s) => Geo.distance(c0, LatLng(s.latitude, s.longitude))).toList()..sort();
    final median = d[d.length ~/ 2];
    final kept = samples
        .where((s) => samples.length < 5 || Geo.distance(c0, LatLng(s.latitude, s.longitude)) <= math.max(2 * median, 1))
        .toList();
    lat = kept.map((s) => s.latitude).reduce((a, b) => a + b) / kept.length;
    lon = kept.map((s) => s.longitude).reduce((a, b) => a + b) / kept.length;
    final c = LatLng(lat, lon);
    final meanAcc = kept.map((s) => s.accuracy).reduce((a, b) => a + b) / kept.length;
    final variance =
        kept.map((s) => math.pow(Geo.distance(c, LatLng(s.latitude, s.longitude)), 2)).reduce((a, b) => a + b) /
            kept.length;
    return AveragedFix(c, kept.length, meanAcc, math.sqrt(variance));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
