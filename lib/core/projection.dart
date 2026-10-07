import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

/// Proyeksi koordinat yang didukung langsung di HP, tanpa pustaka luar.
///
/// - EPSG:4326 (WGS 84) dan EPSG:4755 (DGN95, dianggap setara WGS 84, selisih < 1 m)
/// - EPSG:3857 (Web Mercator)
/// - EPSG:326zz / 327zz (UTM WGS 84 utara/selatan, semua zona)
/// - EPSG:23830-23845 (DGN95 / Indonesia TM-3, zona 46.2 s/d 54.1)
///
/// CRS lain: konversi dulu di portal/server dengan GDAL (tools/convert_map.py).
abstract class CrsProjection {
  int get epsg;
  String get name;

  /// Koordinat proyeksi (x = easting/lon, y = northing/lat) -> lintang/bujur WGS 84.
  LatLng toLatLng(double x, double y);

  /// Lintang/bujur WGS 84 -> koordinat proyeksi.
  ({double x, double y}) fromLatLng(LatLng p);

  static CrsProjection? fromEpsg(int epsg) {
    if (epsg == 4326 || epsg == 4755) return Geographic(epsg);
    if (epsg == 3857 || epsg == 900913) return const WebMercator();
    if (epsg > 32600 && epsg <= 32660) return TransverseMercator.utm(epsg - 32600, south: false);
    if (epsg > 32700 && epsg <= 32760) return TransverseMercator.utm(epsg - 32700, south: true);
    if (epsg >= 23830 && epsg <= 23845) return TransverseMercator.tm3(epsg);
    return null;
  }
}

class Geographic implements CrsProjection {
  const Geographic(this.epsg);
  @override
  final int epsg;
  @override
  String get name => epsg == 4755 ? 'DGN95 (geografis)' : 'WGS 84 (geografis)';
  @override
  LatLng toLatLng(double x, double y) => LatLng(y, x);
  @override
  ({double x, double y}) fromLatLng(LatLng p) => (x: p.longitude, y: p.latitude);
}

class WebMercator implements CrsProjection {
  const WebMercator();
  static const _r = 6378137.0;
  @override
  int get epsg => 3857;
  @override
  String get name => 'Web Mercator';
  @override
  LatLng toLatLng(double x, double y) {
    final lon = x / _r * 180 / math.pi;
    final lat = (2 * math.atan(math.exp(y / _r)) - math.pi / 2) * 180 / math.pi;
    return LatLng(lat, lon);
  }

  @override
  ({double x, double y}) fromLatLng(LatLng p) {
    final x = _r * p.longitude * math.pi / 180;
    final y = _r * math.log(math.tan(math.pi / 4 + p.latitude * math.pi / 360));
    return (x: x, y: y);
  }
}

/// Transverse Mercator pada elipsoid WGS 84 (rumus Snyder 1987).
/// Akurasi sub-milimeter dalam satu zona UTM/TM-3.
class TransverseMercator implements CrsProjection {
  TransverseMercator({
    required this.epsg,
    required this.name,
    required double lon0Deg,
    required this.k0,
    required this.falseEasting,
    required this.falseNorthing,
  }) : _lon0 = lon0Deg * math.pi / 180;

  factory TransverseMercator.utm(int zone, {required bool south}) => TransverseMercator(
        epsg: (south ? 32700 : 32600) + zone,
        name: 'WGS 84 / UTM $zone${south ? 'S' : 'N'}',
        lon0Deg: -183.0 + 6 * zone,
        k0: 0.9996,
        falseEasting: 500000,
        falseNorthing: south ? 10000000 : 0,
      );

  /// DGN95 / Indonesia TM-3: 23830 = zona 46.2 (meridian tengah 94,5°), lalu tiap 3°.
  factory TransverseMercator.tm3(int epsg) {
    final i = epsg - 23830;
    const zones = ['46.2', '47.1', '47.2', '48.1', '48.2', '49.1', '49.2', '50.1',
      '50.2', '51.1', '51.2', '52.1', '52.2', '53.1', '53.2', '54.1'];
    return TransverseMercator(
      epsg: epsg,
      name: 'DGN95 / Indonesia TM-3 zona ${zones[i]}',
      lon0Deg: 94.5 + 3 * i,
      k0: 0.9999,
      falseEasting: 200000,
      falseNorthing: 1500000,
    );
  }

  @override
  final int epsg;
  @override
  final String name;
  final double k0;
  final double falseEasting;
  final double falseNorthing;
  final double _lon0;

  static const _a = 6378137.0;
  static const _f = 1 / 298.257223563;
  static const _e2 = _f * (2 - _f);
  static const _ep2 = _e2 / (1 - _e2);

  static double _meridianArc(double phi) {
    const e4 = _e2 * _e2, e6 = e4 * _e2;
    return _a *
        ((1 - _e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi -
            (3 * _e2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * math.sin(2 * phi) +
            (15 * e4 / 256 + 45 * e6 / 1024) * math.sin(4 * phi) -
            (35 * e6 / 3072) * math.sin(6 * phi));
  }

  @override
  ({double x, double y}) fromLatLng(LatLng p) {
    final phi = p.latitude * math.pi / 180;
    final lam = p.longitude * math.pi / 180;
    final sinP = math.sin(phi), cosP = math.cos(phi), tanP = math.tan(phi);
    final n = _a / math.sqrt(1 - _e2 * sinP * sinP);
    final t = tanP * tanP;
    final c = _ep2 * cosP * cosP;
    final a = cosP * (lam - _lon0);
    final m = _meridianArc(phi);
    final x = k0 * n * (a + (1 - t + c) * math.pow(a, 3) / 6 +
            (5 - 18 * t + t * t + 72 * c - 58 * _ep2) * math.pow(a, 5) / 120) +
        falseEasting;
    final y = k0 *
            (m +
                n * tanP *
                    (a * a / 2 +
                        (5 - t + 9 * c + 4 * c * c) * math.pow(a, 4) / 24 +
                        (61 - 58 * t + t * t + 600 * c - 330 * _ep2) * math.pow(a, 6) / 720)) +
        falseNorthing;
    return (x: x, y: y);
  }

  @override
  LatLng toLatLng(double x, double y) {
    final xx = x - falseEasting;
    final yy = y - falseNorthing;
    const e4 = _e2 * _e2, e6 = e4 * _e2;
    final m = yy / k0;
    final mu = m / (_a * (1 - _e2 / 4 - 3 * e4 / 64 - 5 * e6 / 256));
    final e1 = (1 - math.sqrt(1 - _e2)) / (1 + math.sqrt(1 - _e2));
    final phi1 = mu +
        (3 * e1 / 2 - 27 * math.pow(e1, 3) / 32) * math.sin(2 * mu) +
        (21 * e1 * e1 / 16 - 55 * math.pow(e1, 4) / 32) * math.sin(4 * mu) +
        (151 * math.pow(e1, 3) / 96) * math.sin(6 * mu) +
        (1097 * math.pow(e1, 4) / 512) * math.sin(8 * mu);
    final sin1 = math.sin(phi1), cos1 = math.cos(phi1), tan1 = math.tan(phi1);
    final n1 = _a / math.sqrt(1 - _e2 * sin1 * sin1);
    final t1 = tan1 * tan1;
    final c1 = _ep2 * cos1 * cos1;
    final r1 = _a * (1 - _e2) / math.pow(1 - _e2 * sin1 * sin1, 1.5);
    final d = xx / (n1 * k0);
    final lat = phi1 -
        (n1 * tan1 / r1) *
            (d * d / 2 -
                (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * _ep2) * math.pow(d, 4) / 24 +
                (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * _ep2 - 3 * c1 * c1) * math.pow(d, 6) / 720);
    final lon = _lon0 +
        (d -
                (1 + 2 * t1 + c1) * math.pow(d, 3) / 6 +
                (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * _ep2 + 24 * t1 * t1) * math.pow(d, 5) / 120) /
            cos1;
    return LatLng(lat * 180 / math.pi, lon * 180 / math.pi);
  }
}

/// Koordinat UTM untuk tampilan (zona otomatis dari bujur).
class UtmCoord {
  const UtmCoord(this.zone, this.south, this.easting, this.northing);
  final int zone;
  final bool south;
  final double easting;
  final double northing;

  factory UtmCoord.fromLatLng(LatLng p) {
    final zone = (((p.longitude + 180) / 6).floor() + 1).clamp(1, 60).toInt();
    final south = p.latitude < 0;
    final r = TransverseMercator.utm(zone, south: south).fromLatLng(p);
    return UtmCoord(zone, south, r.x, r.y);
  }

  @override
  String toString() =>
      'UTM $zone${south ? 'S' : 'N'} · ${_group(easting)} E · ${_group(northing)} N';

  static String _group(double v) {
    final s = v.round().toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(' ');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
