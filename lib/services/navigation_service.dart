import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import '../core/geo.dart';
import '../core/routing.dart';
import '../models/reference_layer.dart';
import 'location_service.dart';
import 'map_repository.dart';

enum RouteMode { blockEdges, straight }

class NavTarget {
  NavTarget(this.block);
  final RefPolygon block;
  String get label => block.label;
  LatLng get point => block.centerPoint;
}

/// Navigasi ke titik tengah blok. Rute bawaan menyusuri pinggiran blok
/// (jalan antar-blok); bisa diganti garis lurus. Semua berjalan offline.
class NavigationService extends ChangeNotifier {
  NavigationService._();
  static final NavigationService instance = NavigationService._();

  static const double arriveRadius = 15; // m dari titik tengah = tiba
  static const double offRouteDistance = 40; // m keluar rute = hitung ulang

  NavTarget? target;
  RouteMode mode = RouteMode.blockEdges;
  bool active = false;
  bool arrived = false;
  bool computing = false;
  String? note;

  List<LatLng> route = [];
  double routeLength = 0;

  // kemajuan
  double remaining = 0;
  double toNextTurn = 0;
  LatLng? nextPoint;
  double offRoute = 0;

  BlockRouter? _router;
  String _routerKey = '';
  StreamSubscription<Position>? _sub;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);

  /// Pilih blok tujuan (dari hasil pencarian). Belum mulai navigasi.
  void setTarget(RefPolygon block) {
    stop(keepTarget: false);
    target = NavTarget(block);
    note = null;
    notifyListeners();
  }

  Future<void> start({RouteMode? routeMode}) async {
    if (target == null) return;
    if (routeMode != null) mode = routeMode;
    active = true;
    arrived = false;
    await LocationService.instance.start();
    _sub ??= LocationService.instance.positions.listen(_onPosition);
    await recompute();
  }

  Future<void> setMode(RouteMode m) async {
    mode = m;
    notifyListeners();
    if (active) await recompute();
  }

  void stop({bool keepTarget = true}) {
    _sub?.cancel();
    _sub = null;
    active = false;
    arrived = false;
    route = [];
    routeLength = 0;
    nextPoint = null;
    if (!keepTarget) target = null;
    notifyListeners();
  }

  void clear() => stop(keepTarget: false);

  Future<BlockRouter?> _ensureRouter() async {
    final layers = MapRepository.instance.refLayers.where((l) => l.visible).toList();
    final key = layers.map((l) => l.id).join(',');
    if (layers.isEmpty) return null;
    if (_router != null && key == _routerKey) return _router;
    final rings = [for (final l in layers) for (final p in l.polygons) p.outer];
    final lines = [for (final l in layers) ...l.lines];
    // dibangun di isolate terpisah agar UI tidak tersendat untuk estate besar
    _router = await compute(_buildRouter, (rings, lines));
    _routerKey = key;
    return _router;
  }

  Future<void> recompute() async {
    final t = target;
    final here = LocationService.instance.latLng;
    if (t == null) return;
    if (here == null) {
      note = 'Menunggu sinyal GPS…';
      notifyListeners();
      return;
    }
    computing = true;
    notifyListeners();
    try {
      if (mode == RouteMode.straight || t.block.contains(here)) {
        route = [here, t.point];
        routeLength = Geo.distance(here, t.point);
        note = mode == RouteMode.straight ? null : 'Anda sudah di dalam blok: lurus ke titik tengah';
      } else {
        final router = await _ensureRouter();
        final r = router?.route(here, t.point, t.block.outer);
        if (r == null) {
          route = [here, t.point];
          routeLength = Geo.distance(here, t.point);
          note = 'Posisi jauh dari jaringan pinggir blok: memakai garis lurus';
        } else {
          route = r.points;
          routeLength = r.length;
          note = null;
        }
      }
      _lastReroute = DateTime.now();
      _updateProgress(here);
    } finally {
      computing = false;
      notifyListeners();
    }
  }

  void _onPosition(Position p) {
    if (!active || target == null) return;
    final here = LatLng(p.latitude, p.longitude);
    if (Geo.distance(here, target!.point) <= arriveRadius) {
      arrived = true;
      remaining = 0;
      notifyListeners();
      return;
    }
    _updateProgress(here);
    final rerouteDue = DateTime.now().difference(_lastReroute) > const Duration(seconds: 15);
    if (offRoute > offRouteDistance && rerouteDue && !computing) {
      recompute();
    } else {
      notifyListeners();
    }
  }

  /// Proyeksikan posisi ke rute: sisa jarak, belokan berikutnya, jarak keluar rute.
  void _updateProgress(LatLng here) {
    if (route.length < 2) return;
    var bestI = 0;
    var bestD = double.infinity;
    var bestQ = route.first;
    for (var i = 0; i + 1 < route.length; i++) {
      final q = _nearestOnSegment(here, route[i], route[i + 1]);
      final d = Geo.distance(here, q);
      if (d < bestD) {
        bestD = d;
        bestI = i;
        bestQ = q;
      }
    }
    offRoute = bestD;
    var rem = Geo.distance(bestQ, route[bestI + 1]);
    for (var i = bestI + 1; i + 1 < route.length; i++) {
      rem += Geo.distance(route[i], route[i + 1]);
    }
    remaining = rem + bestD;
    // belokan berikutnya: titik rute pertama di depan dengan perubahan arah > 25°
    var j = bestI + 1;
    while (j < route.length - 1) {
      final b1 = Geo.bearing(route[j - 1], route[j]);
      final b2 = Geo.bearing(route[j], route[j + 1]);
      final turn = ((b2 - b1 + 540) % 360) - 180;
      if (turn.abs() > 25) break;
      j++;
    }
    nextPoint = route[j];
    toNextTurn = Geo.distance(here, nextPoint!);
  }

  /// Sudut belok di [nextPoint] (negatif = kiri, positif = kanan), null bila tujuan.
  double? get nextTurnAngle {
    final np = nextPoint;
    if (np == null) return null;
    final j = route.indexOf(np);
    if (j <= 0 || j >= route.length - 1) return null;
    final b1 = Geo.bearing(route[j - 1], route[j]);
    final b2 = Geo.bearing(route[j], route[j + 1]);
    return ((b2 - b1 + 540) % 360) - 180;
  }

  /// Fungsi statis untuk compute(): hanya data poligon yang dikirim ke isolate.
  static BlockRouter _buildRouter((List<List<LatLng>>, List<List<LatLng>>) args) =>
      BlockRouter.build(args.$1, lines: args.$2);

  static LatLng _nearestOnSegment(LatLng p, LatLng a, LatLng b) {
    final k = Geo.cosLat(a.latitude);
    final ax = a.longitude * k, ay = a.latitude, bx = b.longitude * k, by = b.latitude;
    final px = p.longitude * k, py = p.latitude;
    final dx = bx - ax, dy = by - ay;
    final l2 = dx * dx + dy * dy;
    var t = l2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / l2;
    t = t.clamp(0.0, 1.0).toDouble();
    return LatLng(ay + t * dy, (ax + t * dx) / k);
  }
}
