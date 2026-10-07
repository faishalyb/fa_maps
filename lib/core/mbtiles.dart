import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image/image.dart' as img;
import 'package:sqflite/sqflite.dart';

/// Arsip MBTiles (SQLite) yang dibuka read-only.
///
/// Skema standar: tabel `metadata(name, value)` dan
/// `tiles(zoom_level, tile_column, tile_row, tile_data)`. Baris memakai skema
/// TMS (dihitung dari bawah), jadi y dibalik dari skema XYZ milik flutter_map.
class MbTilesArchive {
  MbTilesArchive._(this.path, this._db, this.metadata);

  final String path;
  final Database _db;
  final Map<String, String> metadata;

  static final Map<String, MbTilesArchive> _open = {};

  static Future<MbTilesArchive> open(String path) async {
    final cached = _open[path];
    if (cached != null) return cached;
    final db = await openDatabase(path, readOnly: true, singleInstance: false);
    final meta = <String, String>{};
    try {
      final rows = await db.query('metadata');
      for (final r in rows) {
        meta['${r['name']}'] = '${r['value']}';
      }
    } catch (_) {
      // tabel metadata boleh tidak ada
    }
    final a = MbTilesArchive._(path, db, meta);
    _open[path] = a;
    return a;
  }

  static Future<void> close(String path) async {
    final a = _open.remove(path);
    await a?._db.close();
  }

  int? get minZoom => int.tryParse(metadata['minzoom'] ?? '');
  int? get maxZoom => int.tryParse(metadata['maxzoom'] ?? '');

  /// Batas [west, south, east, north] dari metadata, atau dihitung dari tile.
  Future<List<double>?> bounds() async {
    final b = metadata['bounds'];
    if (b != null) {
      final parts = b.split(',').map((e) => double.tryParse(e.trim())).toList();
      if (parts.length == 4 && !parts.contains(null)) {
        return parts.map((e) => e!).toList();
      }
    }
    final r = await _db.rawQuery('SELECT MAX(zoom_level) AS z FROM tiles');
    final z = r.first['z'] as int?;
    if (z == null) return null;
    final e = await _db.rawQuery(
      'SELECT MIN(tile_column) AS x0, MAX(tile_column) AS x1, '
      'MIN(tile_row) AS y0, MAX(tile_row) AS y1 FROM tiles WHERE zoom_level = ?',
      [z],
    );
    final x0 = e.first['x0'] as int, x1 = e.first['x1'] as int;
    final y0 = e.first['y0'] as int, y1 = e.first['y1'] as int;
    final n = 1 << z;
    double lon(int x) => x / n * 360 - 180;
    // lintang tepi atas tile XYZ ke-y
    double lat(int xyzY) {
      final r = math.pi * (1 - 2 * xyzY / n);
      return (2 * math.atan(math.exp(r)) - math.pi / 2) * 180 / math.pi;
    }

    // TMS -> XYZ: y = n - 1 - tms. Tepi selatan = tepi bawah baris tms terkecil.
    final south = lat(n - 1 - y0 + 1);
    final north = lat(n - 1 - y1);
    return [lon(x0), south, lon(x1 + 1), north];
  }

  Future<Uint8List?> tile(int z, int x, int y) async {
    final tmsY = (1 << z) - 1 - y;
    final rows = await _db.query(
      'tiles',
      columns: ['tile_data'],
      where: 'zoom_level = ? AND tile_column = ? AND tile_row = ?',
      whereArgs: [z, x, tmsY],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['tile_data'] as Uint8List?;
  }
}

/// Penyedia tile flutter_map yang membaca langsung dari file MBTiles lokal.
class MbTilesTileProvider extends TileProvider {
  MbTilesTileProvider(this.archive);
  final MbTilesArchive archive;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MbTilesImage(archive, coordinates.z, coordinates.x, coordinates.y);
}

/// ImageProvider untuk satu tile; tile kosong diganti gambar transparan.
@immutable
class MbTilesImage extends ImageProvider<MbTilesImage> {
  const MbTilesImage(this.archive, this.z, this.x, this.y);

  final MbTilesArchive archive;
  final int z, x, y;

  static Uint8List? _transparent;
  static Uint8List get transparentPng =>
      _transparent ??= Uint8List.fromList(img.encodePng(img.Image(width: 1, height: 1, numChannels: 4)));

  @override
  Future<MbTilesImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(MbTilesImage key, ImageDecoderCallback decode) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: 'mbtiles $z/$x/$y',
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await archive.tile(z, x, y) ?? transparentPng;
    final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      other is MbTilesImage && other.archive.path == archive.path && other.z == z && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(archive.path, z, x, y);
}
