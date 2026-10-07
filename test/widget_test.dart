// Uji ringan tanpa plugin (menggantikan widget_test bawaan `flutter create`).
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:fa_maps/core/format.dart';
import 'package:fa_maps/core/geo.dart';
import 'package:fa_maps/core/settings.dart';

void main() {
  test('Format jarak dan luas', () {
    expect(Geo.formatDistance(640), '640 m');
    expect(Geo.formatDistance(6400), '6,40 km');
    expect(Geo.formatArea(2500), '2500 m²');
    expect(Geo.formatArea(284000), '28,40 ha');
  });

  test('Format koordinat Central Park', () {
    const p = LatLng(-6.177745, 106.791015);
    expect(Geo.formatCoord(p, CoordFormat.utm), 'UTM 48S · 698 177 E · 9 316 814 N');
    expect(Geo.formatCoord(p, CoordFormat.decimal), '-6.177745, 106.791015');
    expect(Geo.formatCoord(p, CoordFormat.dms), startsWith('6°10\''));
  });

  test('Format durasi', () {
    expect(fmtDuration(const Duration(hours: 1, minutes: 42, seconds: 15)), '01:42:15');
  });
}
