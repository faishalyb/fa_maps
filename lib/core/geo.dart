import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'projection.dart';
import 'settings.dart';

/// Perhitungan geometri sederhana untuk lapangan.
class Geo {
  static const double earthRadius = 6371008.8;

  /// Jarak geodesik (haversine), meter.
  static double distance(LatLng a, LatLng b) {
    final dLat = _rad(b.latitude - a.latitude);
    final dLon = _rad(b.longitude - a.longitude);
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(a.latitude)) * math.cos(_rad(b.latitude)) * math.pow(math.sin(dLon / 2), 2);
    return 2 * earthRadius * math.asin(math.min(1, math.sqrt(h)));
  }

  static double pathLength(List<LatLng> pts) {
    var d = 0.0;
    for (var i = 1; i < pts.length; i++) {
      d += distance(pts[i - 1], pts[i]);
    }
    return d;
  }

  /// Luas poligon (m²). Diproyeksikan ke UTM zona setempat lalu rumus shoelace;
  /// akurat untuk area kebun (hingga puluhan km).
  static double area(List<LatLng> pts) {
    if (pts.length < 3) return 0;
    final utm = UtmCoord.fromLatLng(pts.first);
    final tm = TransverseMercator.utm(utm.zone, south: utm.south);
    final xy = pts.map(tm.fromLatLng).toList();
    var s = 0.0;
    for (var i = 0; i < xy.length; i++) {
      final a = xy[i];
      final b = xy[(i + 1) % xy.length];
      s += a.x * b.y - b.x * a.y;
    }
    return s.abs() / 2;
  }

  /// Titik di dalam poligon (ray casting).
  static bool pointInPolygon(LatLng p, List<LatLng> ring) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final xi = ring[i].longitude, yi = ring[i].latitude;
      final xj = ring[j].longitude, yj = ring[j].latitude;
      final intersect = ((yi > p.latitude) != (yj > p.latitude)) &&
          (p.longitude < (xj - xi) * (p.latitude - yi) / (yj - yi) + xi);
      if (intersect) inside = !inside;
    }
    return inside;
  }

  /// Arah dari [a] ke [b] dalam derajat dari utara (0-360).
  static double bearing(LatLng a, LatLng b) {
    final p1 = _rad(a.latitude), p2 = _rad(b.latitude);
    final dl = _rad(b.longitude - a.longitude);
    final y = math.sin(dl) * math.cos(p2);
    final x = math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Nama arah mata angin singkat (U, TL, T, ...).
  static String compassName(double deg) {
    const names = ['U', 'TL', 'T', 'TG', 'S', 'BD', 'B', 'BL'];
    return names[((deg % 360) / 45).round() % 8];
  }

  static double cosLat(double lat) => math.cos(_rad(lat));

  static double _rad(double d) => d * math.pi / 180;

  static String formatDistance(double m) =>
      m < 1000 ? '${m.toStringAsFixed(0)} m' : '${(m / 1000).toStringAsFixed(2).replaceAll('.', ',')} km';

  static String formatArea(double m2) => m2 < 10000
      ? '${m2.toStringAsFixed(0)} m²'
      : '${(m2 / 10000).toStringAsFixed(2).replaceAll('.', ',')} ha';

  static String formatCoord(LatLng p, [CoordFormat? fmt]) {
    switch (fmt ?? AppSettings.instance.coordFormat) {
      case CoordFormat.decimal:
        return '${p.latitude.toStringAsFixed(6)}, ${p.longitude.toStringAsFixed(6)}';
      case CoordFormat.dms:
        return '${_dms(p.latitude, 'U', 'S')}  ${_dms(p.longitude, 'T', 'B')}';
      case CoordFormat.utm:
        return UtmCoord.fromLatLng(p).toString();
    }
  }

  static String _dms(double v, String pos, String neg) {
    final a = v.abs();
    var d = a.floor();
    var m = ((a - d) * 60).floor();
    var s = ((a - d) * 60 - m) * 60;
    if (s >= 59.95) {
      s = 0;
      m += 1;
    }
    if (m >= 60) {
      m = 0;
      d += 1;
    }
    return '$d°${m.toString().padLeft(2, '0')}\'${s.toStringAsFixed(1).padLeft(4, '0')}" ${v < 0 ? neg : pos}';
  }
}
