import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

/// Permintaan dari layar lain agar peta berpindah ke area/titik tertentu.
class MapFocus {
  MapFocus._();
  static final ValueNotifier<MapFocusRequest?> request = ValueNotifier(null);

  static void bounds(LatLngBounds b) => request.value = MapFocusRequest(bounds: b);
  static void point(LatLng p, {double zoom = 18}) => request.value = MapFocusRequest(point: p, zoom: zoom);
}

class MapFocusRequest {
  MapFocusRequest({this.bounds, this.point, this.zoom = 18});
  final LatLngBounds? bounds;
  final LatLng? point;
  final double zoom;
}
