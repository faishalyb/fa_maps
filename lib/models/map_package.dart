import 'dart:convert';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

enum MapKind { mbtiles, raster }

/// Satu peta offline di HP: paket MBTiles dari portal, atau GeoTIFF yang
/// diimpor langsung (disimpan sebagai gambar + 4 sudut).
class MapPackage {
  MapPackage({
    required this.id,
    required this.name,
    required this.kind,
    required this.path,
    required this.west,
    required this.south,
    required this.east,
    required this.north,
    required this.createdAt,
    this.sourceName,
    this.crs,
    this.minZoom,
    this.maxZoom,
    this.corners,
    this.sizeBytes = 0,
    this.description,
    this.mapVersion,
    this.visible = true,
    this.opacity = 1,
  });

  final String id;
  String name;
  final MapKind kind;
  final String path;
  final String? sourceName;
  final String? crs;
  final double west, south, east, north;
  final int? minZoom, maxZoom;

  /// Hanya raster: [kiri-atas, kiri-bawah, kanan-bawah, kanan-atas]
  final List<LatLng>? corners;
  final int sizeBytes;
  final String? description;
  final String? mapVersion;
  bool visible;
  double opacity;
  final DateTime createdAt;

  LatLngBounds get bounds => LatLngBounds(LatLng(south, west), LatLng(north, east));

  bool contains(LatLng p) =>
      p.latitude >= south && p.latitude <= north && p.longitude >= west && p.longitude <= east;

  String get kindLabel => kind == MapKind.mbtiles ? 'MBTiles' : 'GeoTIFF';

  Map<String, Object?> toRow() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'path': path,
        'source_name': sourceName,
        'crs': crs,
        'west': west,
        'south': south,
        'east': east,
        'north': north,
        'min_zoom': minZoom,
        'max_zoom': maxZoom,
        'corners': corners == null
            ? null
            : jsonEncode(corners!.map((c) => [c.latitude, c.longitude]).toList()),
        'size_bytes': sizeBytes,
        'description': description,
        'map_version': mapVersion,
        'visible': visible ? 1 : 0,
        'opacity': opacity,
        'created_at': createdAt.toIso8601String(),
      };

  factory MapPackage.fromRow(Map<String, Object?> r) {
    List<LatLng>? corners;
    final c = r['corners'] as String?;
    if (c != null && c.isNotEmpty) {
      corners = (jsonDecode(c) as List)
          .map((e) => LatLng((e[0] as num).toDouble(), (e[1] as num).toDouble()))
          .toList();
    }
    return MapPackage(
      id: r['id'] as String,
      name: r['name'] as String,
      kind: MapKind.values.byName(r['kind'] as String),
      path: r['path'] as String,
      sourceName: r['source_name'] as String?,
      crs: r['crs'] as String?,
      west: (r['west'] as num).toDouble(),
      south: (r['south'] as num).toDouble(),
      east: (r['east'] as num).toDouble(),
      north: (r['north'] as num).toDouble(),
      minZoom: r['min_zoom'] as int?,
      maxZoom: r['max_zoom'] as int?,
      corners: corners,
      sizeBytes: (r['size_bytes'] as int?) ?? 0,
      description: r['description'] as String?,
      mapVersion: r['map_version'] as String?,
      visible: (r['visible'] as int? ?? 1) == 1,
      opacity: (r['opacity'] as num? ?? 1).toDouble(),
      createdAt: DateTime.parse(r['created_at'] as String),
    );
  }
}
