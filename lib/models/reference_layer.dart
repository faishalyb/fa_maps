import 'dart:convert';
import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../core/geo.dart';

class RefPolygon {
  RefPolygon(this.label, this.outer, this.properties);
  final String label;
  final List<LatLng> outer;
  final Map<String, dynamic> properties;

  late final double _w = outer.map((p) => p.longitude).reduce((a, b) => a < b ? a : b);
  late final double _e = outer.map((p) => p.longitude).reduce((a, b) => a > b ? a : b);
  late final double _s = outer.map((p) => p.latitude).reduce((a, b) => a < b ? a : b);
  late final double _n = outer.map((p) => p.latitude).reduce((a, b) => a > b ? a : b);

  bool contains(LatLng p) {
    if (p.longitude < _w || p.longitude > _e || p.latitude < _s || p.latitude > _n) return false;
    return Geo.pointInPolygon(p, outer);
  }

  /// Titik tengah blok untuk penanda & tujuan navigasi.
  /// Centroid luas; bila jatuh di luar blok (blok cekung, mis. bentuk L),
  /// dipakai titik di dalam blok yang paling jauh dari tepi.
  late final LatLng centerPoint = _computeCenter();

  LatLng _computeCenter() {
    final pts = outer.length > 1 && outer.first == outer.last ? outer.sublist(0, outer.length - 1) : outer;
    if (pts.length < 3) return center;
    final lat0 = pts.first.latitude;
    final k = math.cos(lat0 * math.pi / 180);
    var a = 0.0, cx = 0.0, cy = 0.0;
    for (var i = 0; i < pts.length; i++) {
      final p = pts[i], q = pts[(i + 1) % pts.length];
      final x0 = p.longitude * k, y0 = p.latitude, x1 = q.longitude * k, y1 = q.latitude;
      final cr = x0 * y1 - x1 * y0;
      a += cr;
      cx += (x0 + x1) * cr;
      cy += (y0 + y1) * cr;
    }
    if (a.abs() < 1e-14) return center;
    final c = LatLng(cy / (3 * a), cx / (3 * a) / k);
    if (contains(c)) return c;
    // cari titik dalam yang paling jauh dari tepi (grid 30 x 30)
    LatLng? best;
    var bestD = -1.0;
    for (var i = 1; i < 30; i++) {
      for (var j = 1; j < 30; j++) {
        final p = LatLng(_s + (_n - _s) * i / 30, _w + (_e - _w) * j / 30);
        if (!Geo.pointInPolygon(p, outer)) continue;
        final d = _edgeDistance(p, pts, k);
        if (d > bestD) {
          bestD = d;
          best = p;
        }
      }
    }
    return best ?? center;
  }

  static double _edgeDistance(LatLng p, List<LatLng> pts, double k) {
    var m = double.infinity;
    final px = p.longitude * k, py = p.latitude;
    for (var i = 0; i < pts.length; i++) {
      final a = pts[i], b = pts[(i + 1) % pts.length];
      final ax = a.longitude * k, ay = a.latitude, bx = b.longitude * k, by = b.latitude;
      final dx = bx - ax, dy = by - ay;
      final l2 = dx * dx + dy * dy;
      var t = l2 == 0 ? 0.0 : ((px - ax) * dx + (py - ay) * dy) / l2;
      t = t.clamp(0.0, 1.0).toDouble();
      final ex = ax + t * dx - px, ey = ay + t * dy - py;
      m = math.min(m, ex * ex + ey * ey);
    }
    return m;
  }

  LatLngBoundsLite get bounds => LatLngBoundsLite(_s, _w, _n, _e);

  LatLng get center {
    var lat = 0.0, lon = 0.0;
    final pts = outer.length > 1 && outer.first == outer.last ? outer.sublist(0, outer.length - 1) : outer;
    for (final p in pts) {
      lat += p.latitude;
      lon += p.longitude;
    }
    return LatLng(lat / pts.length, lon / pts.length);
  }
}

class LatLngBoundsLite {
  const LatLngBoundsLite(this.south, this.west, this.north, this.east);
  final double south, west, north, east;
}

/// Lapisan referensi vektor (mis. batas blok) dari GeoJSON.
class ReferenceLayer {
  ReferenceLayer({
    required this.id,
    required this.name,
    required this.path,
    required this.createdAt,
    this.labelField,
    this.visible = true,
    this.polygons = const [],
    this.lines = const [],
  });

  final String id;
  final String name;
  final String path;
  final String? labelField;
  bool visible;
  final DateTime createdAt;
  List<RefPolygon> polygons;
  List<List<LatLng>> lines;

  static const labelCandidates = ['blok', 'block', 'kode_blok', 'name', 'nama', 'label', 'id'];

  /// Membaca FeatureCollection: Polygon, MultiPolygon, LineString, MultiLineString.
  static ({List<RefPolygon> polygons, List<List<LatLng>> lines, String? labelField}) parseGeoJson(String text) {
    final data = jsonDecode(text) as Map<String, dynamic>;
    final feats = data['type'] == 'FeatureCollection'
        ? (data['features'] as List).cast<Map<String, dynamic>>()
        : [data];
    final polys = <RefPolygon>[];
    final lines = <List<LatLng>>[];
    String? labelField;

    List<LatLng> ring(List coords) =>
        coords.map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())).toList();

    for (final f in feats) {
      final props = (f['properties'] as Map?)?.cast<String, dynamic>() ?? {};
      labelField ??= labelCandidates.firstWhere((k) => props.containsKey(k), orElse: () => '');
      if (labelField.isEmpty) labelField = null;
      final label = labelField == null ? '' : '${props[labelField] ?? ''}';
      final g = f['geometry'] as Map<String, dynamic>?;
      if (g == null) continue;
      final coords = g['coordinates'] as List;
      switch (g['type']) {
        case 'Polygon':
          polys.add(RefPolygon(label, ring(coords.first as List), props));
          break;
        case 'MultiPolygon':
          for (final p in coords) {
            polys.add(RefPolygon(label, ring((p as List).first as List), props));
          }
          break;
        case 'LineString':
          lines.add(ring(coords));
          break;
        case 'MultiLineString':
          for (final l in coords) {
            lines.add(ring(l as List));
          }
          break;
      }
    }
    return (polygons: polys, lines: lines, labelField: labelField);
  }

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'path': path,
        'label_field': labelField,
        'visible': visible ? 1 : 0,
        'created_at': createdAt.toIso8601String(),
      };

  factory ReferenceLayer.fromRow(Map<String, Object?> r) => ReferenceLayer(
        id: r['id'] as String,
        name: r['name'] as String,
        path: r['path'] as String,
        labelField: r['label_field'] as String?,
        visible: (r['visible'] as int? ?? 1) == 1,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
}
