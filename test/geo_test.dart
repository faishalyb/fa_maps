import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:fa_maps/core/geo.dart';
import 'package:fa_maps/core/geotiff.dart';
import 'package:fa_maps/core/projection.dart';

void main() {
  // Titik acuan: Central Park, Jakarta Barat
  const cp = LatLng(-6.177745, 106.791015);

  group('Proyeksi', () {
    test('UTM 48S Central Park sesuai generator data contoh', () {
      final u = UtmCoord.fromLatLng(cp);
      expect(u.zone, 48);
      expect(u.south, isTrue);
      expect(u.easting, closeTo(698177.21, 0.05));
      expect(u.northing, closeTo(9316813.64, 0.05));
    });

    test('UTM bolak-balik < 1 mm', () {
      final tm = TransverseMercator.utm(48, south: true);
      final xy = tm.fromLatLng(cp);
      final back = tm.toLatLng(xy.x, xy.y);
      expect(Geo.distance(cp, back), lessThan(0.001));
    });

    test('Meridian tengah zona 48: lintang -6, bujur 105', () {
      final xy = TransverseMercator.utm(48, south: true).fromLatLng(const LatLng(-6, 105));
      expect(xy.x, closeTo(500000, 0.001));
      expect(xy.y, closeTo(9336795.43, 0.05));
    });

    test('Web Mercator bolak-balik', () {
      const wm = WebMercator();
      final xy = wm.fromLatLng(cp);
      final back = wm.toLatLng(xy.x, xy.y);
      expect(back.latitude, closeTo(cp.latitude, 1e-9));
      expect(back.longitude, closeTo(cp.longitude, 1e-9));
    });

    test('EPSG yang didukung', () {
      expect(CrsProjection.fromEpsg(32748), isA<TransverseMercator>());
      expect(CrsProjection.fromEpsg(32650), isA<TransverseMercator>());
      expect(CrsProjection.fromEpsg(23834)!.name, contains('48.2'));
      expect(CrsProjection.fromEpsg(4326), isA<Geographic>());
      expect(CrsProjection.fromEpsg(2193), isNull);
    });
  });

  group('Geometri', () {
    test('Luas persegi 100 x 100 m = 1 ha', () {
      final tm = TransverseMercator.utm(48, south: true);
      final o = tm.fromLatLng(cp);
      final ring = [
        tm.toLatLng(o.x, o.y),
        tm.toLatLng(o.x + 100, o.y),
        tm.toLatLng(o.x + 100, o.y + 100),
        tm.toLatLng(o.x, o.y + 100),
      ];
      expect(Geo.area(ring), closeTo(10000, 1));
      expect(Geo.pathLength(ring), closeTo(300, 0.5));
    });

    test('Titik di dalam poligon', () {
      const ring = [LatLng(0, 0), LatLng(0, 1), LatLng(1, 1), LatLng(1, 0)];
      expect(Geo.pointInPolygon(const LatLng(0.5, 0.5), ring), isTrue);
      expect(Geo.pointInPolygon(const LatLng(1.5, 0.5), ring), isFalse);
    });
  });

  group('GeoTIFF contoh', () {
    final file = File('assets/samples/central_park_uji.tif');

    test('Tag georeferensi terbaca', () {
      final info = GeoTiffParser.parse(file.readAsBytesSync());
      expect(info.width, 1700);
      expect(info.height, 1700);
      expect(info.epsg, 32748);
      final tl = info.pixelToModel(0, 0);
      expect(tl.x, 697300);
      expect(tl.y, 9317700);
    });

    test('Pusat Central Park jatuh di piksel yang benar', () {
      final info = GeoTiffParser.parse(file.readAsBytesSync());
      final u = UtmCoord.fromLatLng(cp);
      // 1 m/piksel: kolom = E - E0, baris = N0 - N
      expect(u.easting - info.affine[2], closeTo(877.2, 0.1));
      expect(info.affine[5] - u.northing, closeTo(886.4, 0.1));
    });
  });
}
