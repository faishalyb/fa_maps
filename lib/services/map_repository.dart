import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../core/db.dart';
import '../core/geotiff.dart';
import '../core/mbtiles.dart';
import '../models/map_package.dart';
import '../models/reference_layer.dart';

class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Katalog peta offline di HP + lapisan referensi (GeoJSON).
class MapRepository extends ChangeNotifier {
  MapRepository._();
  static final MapRepository instance = MapRepository._();

  List<MapPackage> maps = [];
  List<ReferenceLayer> refLayers = [];
  bool busy = false;
  String? busyMessage;

  Database get _db => AppDatabase.instance.db;

  List<MapPackage> get visibleMaps => maps.where((m) => m.visible).toList();

  Future<Directory> _dir(String name) async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, name));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  Future<void> load() async {
    final rows = await _db.query('maps', orderBy: 'created_at');
    maps = rows.map(MapPackage.fromRow).where((m) => File(m.path).existsSync()).toList();
    final refRows = await _db.query('ref_layers', orderBy: 'created_at');
    refLayers = [];
    for (final r in refRows) {
      final layer = ReferenceLayer.fromRow(r);
      final f = File(layer.path);
      if (!f.existsSync()) continue;
      try {
        final parsed = ReferenceLayer.parseGeoJson(await f.readAsString());
        layer.polygons = parsed.polygons;
        layer.lines = parsed.lines;
        refLayers.add(layer);
      } catch (_) {
        // file rusak: lewati
      }
    }
    notifyListeners();
  }

  void _setBusy(String? msg) {
    busy = msg != null;
    busyMessage = msg;
    notifyListeners();
  }

  /// Impor file dari HP berdasarkan ekstensinya.
  Future<String> importFile(String path, {String? displayName}) async {
    final ext = p.extension(path).toLowerCase();
    final base = displayName ?? p.basenameWithoutExtension(path);
    switch (ext) {
      case '.mbtiles':
        final m = await _importMbtiles(path, base);
        return 'Peta "${m.name}" siap dipakai offline';
      case '.tif':
      case '.tiff':
        final m = await _importGeoTiff(path, base);
        return 'GeoTIFF "${m.name}" siap dipakai (${m.crs})';
      case '.geojson':
      case '.json':
        final l = await _importGeoJson(path, base);
        return 'Lapisan "${l.name}" ditambahkan (${l.polygons.length} poligon)';
      case '.pdf':
        throw ImportException(
            'GeoPDF diproses oleh tim GIS di portal/server (tools/convert_map.py) menjadi MBTiles, '
            'lalu diunduh ke HP. Impor GeoPDF langsung di HP direncanakan di fase 3.');
      default:
        throw ImportException('Format $ext belum didukung. Gunakan .mbtiles, .tif/.tiff, atau .geojson');
    }
  }

  Future<MapPackage> _importMbtiles(String src, String name) async {
    _setBusy('Menyalin paket peta…');
    try {
      final id = const Uuid().v4();
      final dest = p.join((await _dir('maps')).path, '$id.mbtiles');
      await File(src).copy(dest);
      final a = await MbTilesArchive.open(dest);
      final b = await a.bounds();
      if (b == null) {
        await MbTilesArchive.close(dest);
        await File(dest).delete();
        throw ImportException('File MBTiles tidak berisi tile.');
      }
      final m = MapPackage(
        id: id,
        name: a.metadata['name']?.isNotEmpty == true ? a.metadata['name']! : name,
        kind: MapKind.mbtiles,
        path: dest,
        sourceName: p.basename(src),
        crs: a.metadata['source_crs'] ?? 'EPSG:3857',
        west: b[0],
        south: b[1],
        east: b[2],
        north: b[3],
        minZoom: a.minZoom,
        maxZoom: a.maxZoom,
        sizeBytes: File(dest).lengthSync(),
        description: a.metadata['description'],
        mapVersion: a.metadata['map_version'] ?? a.metadata['version'],
        createdAt: DateTime.now(),
      );
      await _db.insert('maps', m.toRow());
      maps.add(m);
      return m;
    } finally {
      _setBusy(null);
    }
  }

  Future<MapPackage> _importGeoTiff(String src, String name) async {
    _setBusy('Membaca GeoTIFF dan menyiapkan peta…');
    try {
      final id = const Uuid().v4();
      final dest = p.join((await _dir('maps')).path, '$id.jpg');
      final RasterImportResult r;
      try {
        r = await GeoTiffImporter.import(src, dest);
      } on FormatException catch (e) {
        throw ImportException(e.message);
      } catch (e) {
        throw ImportException('Gagal membaca GeoTIFF: $e');
      }
      final lats = r.corners.map((c) => c.latitude);
      final lons = r.corners.map((c) => c.longitude);
      final m = MapPackage(
        id: id,
        name: name,
        kind: MapKind.raster,
        path: dest,
        sourceName: p.basename(src),
        crs: 'EPSG:${r.epsg}',
        west: lons.reduce(math.min),
        south: lats.reduce(math.min),
        east: lons.reduce(math.max),
        north: lats.reduce(math.max),
        corners: r.corners,
        sizeBytes: File(dest).lengthSync(),
        description: '${r.crsName} · ${r.sourceWidth}×${r.sourceHeight} px · '
            '${r.pixelSize.toStringAsFixed(2)} unit/px'
            '${r.outputWidth < r.sourceWidth ? ' (diperkecil ke ${r.outputWidth} px di HP)' : ''}',
        createdAt: DateTime.now(),
      );
      await _db.insert('maps', m.toRow());
      maps.add(m);
      return m;
    } finally {
      _setBusy(null);
    }
  }

  Future<ReferenceLayer> _importGeoJson(String src, String name) async {
    final text = await File(src).readAsString();
    final parsed = ReferenceLayer.parseGeoJson(text);
    if (parsed.polygons.isEmpty && parsed.lines.isEmpty) {
      throw ImportException('GeoJSON tidak berisi poligon atau garis.');
    }
    final id = const Uuid().v4();
    final dest = p.join((await _dir('layers')).path, '$id.geojson');
    await File(dest).writeAsString(text);
    final layer = ReferenceLayer(
      id: id,
      name: name,
      path: dest,
      labelField: parsed.labelField,
      createdAt: DateTime.now(),
      polygons: parsed.polygons,
      lines: parsed.lines,
    );
    await _db.insert('ref_layers', layer.toRow());
    refLayers.add(layer);
    notifyListeners();
    return layer;
  }

  /// Memuat data contoh sekitar Central Park dari assets aplikasi.
  Future<List<String>> loadSamples() async {
    final tmp = await getTemporaryDirectory();
    final msgs = <String>[];
    const samples = {
      'central_park_uji.mbtiles': 'Peta uji Central Park (MBTiles)',
      'central_park_uji.tif': 'Peta uji Central Park (GeoTIFF)',
      'blok_uji_central_park.geojson': 'Blok uji Central Park',
    };
    for (final e in samples.entries) {
      final data = await rootBundle.load('assets/samples/${e.key}');
      final f = File(p.join(tmp.path, e.key));
      await f.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      msgs.add(await importFile(f.path, displayName: e.value));
    }
    // GeoTIFF dan MBTiles berisi peta yang sama: tampilkan MBTiles saja dulu.
    final tif = maps.where((m) => m.kind == MapKind.raster && m.sourceName == 'central_park_uji.tif');
    for (final m in tif) {
      await setVisible(m, false);
    }
    return msgs;
  }

  Future<void> setVisible(MapPackage m, bool v) async {
    m.visible = v;
    await _db.update('maps', {'visible': v ? 1 : 0}, where: 'id = ?', whereArgs: [m.id]);
    notifyListeners();
  }

  Future<void> setOpacity(MapPackage m, double v) async {
    m.opacity = v;
    await _db.update('maps', {'opacity': v}, where: 'id = ?', whereArgs: [m.id]);
    notifyListeners();
  }

  Future<void> rename(MapPackage m, String name) async {
    m.name = name;
    await _db.update('maps', {'name': name}, where: 'id = ?', whereArgs: [m.id]);
    notifyListeners();
  }

  Future<void> delete(MapPackage m) async {
    if (m.kind == MapKind.mbtiles) await MbTilesArchive.close(m.path);
    final f = File(m.path);
    if (f.existsSync()) await f.delete();
    await _db.delete('maps', where: 'id = ?', whereArgs: [m.id]);
    maps.remove(m);
    notifyListeners();
  }

  Future<void> setLayerVisible(ReferenceLayer l, bool v) async {
    l.visible = v;
    await _db.update('ref_layers', {'visible': v ? 1 : 0}, where: 'id = ?', whereArgs: [l.id]);
    notifyListeners();
  }

  Future<void> deleteLayer(ReferenceLayer l) async {
    final f = File(l.path);
    if (f.existsSync()) await f.delete();
    await _db.delete('ref_layers', where: 'id = ?', whereArgs: [l.id]);
    refLayers.remove(l);
    notifyListeners();
  }

  /// Nama blok di posisi [p] dari lapisan referensi yang tampil.
  String? blockAt(LatLng p) {
    for (final l in refLayers.where((l) => l.visible)) {
      for (final poly in l.polygons) {
        if (poly.label.isNotEmpty && poly.contains(p)) return poly.label;
      }
    }
    return null;
  }

  /// Normalisasi nama blok untuk pencarian: huruf besar, tanpa spasi/tanda
  /// baca, nol di depan angka dibuang ("uji-c04" -> "UJIC4").
  static String normalizeBlock(String s) => s
      .toUpperCase()
      .replaceAll(RegExp(r'[^A-Z0-9]'), '')
      .replaceAllMapped(RegExp(r'(^|[A-Z])0+(\d)'), (m) => '${m[1]}${m[2]}');

  /// Cari blok di lapisan referensi yang tampil. Urutan hasil: sama persis,
  /// akhiran sama ("C4" -> "UJI-C4"), awalan sama, lalu mengandung.
  List<RefPolygon> findBlocks(String query) {
    final q = normalizeBlock(query);
    if (q.isEmpty) return [];
    final hits = <(int, RefPolygon)>[];
    final seen = <String>{};
    for (final l in refLayers.where((l) => l.visible)) {
      for (final poly in l.polygons) {
        if (poly.label.isEmpty) continue;
        final n = normalizeBlock(poly.label);
        int? score;
        if (n == q) {
          score = 0;
        } else if (n.endsWith(q)) {
          score = 1;
        } else if (n.startsWith(q)) {
          score = 2;
        } else if (n.contains(q)) {
          score = 3;
        }
        if (score != null && seen.add('${l.id}|${poly.label}')) hits.add((score, poly));
      }
    }
    hits.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.label.compareTo(b.$2.label));
    // bila ada yang sama persis, cukup itu
    if (hits.isNotEmpty && hits.first.$1 == 0) return hits.where((h) => h.$1 == 0).map((h) => h.$2).toList();
    return hits.map((h) => h.$2).toList();
  }

  /// Peta tampil pertama yang mencakup posisi [p].
  MapPackage? mapAt(LatLng p) {
    for (final m in visibleMaps.reversed) {
      if (m.contains(p)) return m;
    }
    return null;
  }

  int get totalBytes => maps.fold(0, (s, m) => s + m.sizeBytes);
}
