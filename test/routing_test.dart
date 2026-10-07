import 'dart:io';

import 'package:fa_maps/core/geo.dart';
import 'package:fa_maps/core/routing.dart';
import 'package:fa_maps/models/reference_layer.dart';
import 'package:fa_maps/services/map_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

void main() {
  final parsed = ReferenceLayer.parseGeoJson(
      File('assets/samples/blok_uji_central_park.geojson').readAsStringSync());
  final blocks = parsed.polygons;
  RefPolygon block(String name) => blocks.firstWhere((b) => b.label == name);
  final router = BlockRouter.build([for (final b in blocks) b.outer]);
  // ±150 m dari Central Park (di dalam radius 200 m)
  const start = LatLng(-6.176545, 106.791915);

  test('Jaringan pinggir blok terbentuk', () {
    expect(blocks.length, 42);
    expect(router.nodeCount, greaterThan(160));
    expect(router.edgeCount, greaterThan(300));
  });

  test('Titik tengah blok berada di dalam blok', () {
    for (final b in blocks) {
      expect(b.contains(b.centerPoint), isTrue, reason: b.label);
    }
  });

  test('Rute ke UJI-A1 menyusuri pinggir blok', () {
    final target = block('UJI-A1');
    final r = router.route(start, target.centerPoint, target.outer);
    expect(r, isNotNull);
    final straight = Geo.distance(start, target.centerPoint);
    expect(r!.length, greaterThan(straight));
    expect(r.length, lessThan(straight * 1.6));
    expect(Geo.distance(r.points.first, start), lessThan(0.01));
    expect(Geo.distance(r.points.last, target.centerPoint), lessThan(0.01));
    // titik antara (bukan awal/akhir) harus berada di tepi salah satu blok (<= 2 m)
    for (final p in r.points.sublist(1, r.points.length - 1)) {
      expect(blocks.any((b) => _distToRing(p, b.outer) <= 2.0), isTrue, reason: '$p');
    }
  });

  test('Pencarian blok longgar', () {
    expect(MapRepository.normalizeBlock('uji-c04'), 'UJIC4');
    expect(MapRepository.normalizeBlock('UJI C4'), 'UJIC4');
    expect(MapRepository.normalizeBlock('c4'), 'C4');
  });
}

double _distToRing(LatLng p, List<LatLng> ring) {
  var m = double.infinity;
  for (var i = 0; i + 1 < ring.length; i++) {
    final a = ring[i], b = ring[i + 1];
    for (var k = 0; k <= 50; k++) {
      final t = k / 50;
      final q = LatLng(a.latitude + (b.latitude - a.latitude) * t, a.longitude + (b.longitude - a.longitude) * t);
      final d = Geo.distance(p, q);
      if (d < m) m = d;
    }
  }
  return m;
}
