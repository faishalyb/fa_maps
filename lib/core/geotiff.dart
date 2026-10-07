import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:latlong2/latlong.dart';

import 'projection.dart';

/// Informasi georeferensi dari tag GeoTIFF.
class GeoTiffInfo {
  GeoTiffInfo({
    required this.width,
    required this.height,
    required this.epsg,
    required this.affine,
    required this.pixelIsPoint,
  });

  final int width;
  final int height;
  final int epsg;

  /// Transformasi piksel (i = kolom, j = baris, tepi kiri-atas piksel 0,0)
  /// ke koordinat model: x = a*i + b*j + c ; y = d*i + e*j + f
  final List<double> affine;
  final bool pixelIsPoint;

  ({double x, double y}) pixelToModel(double i, double j) {
    final a = affine;
    return (x: a[0] * i + a[1] * j + a[2], y: a[3] * i + a[4] * j + a[5]);
  }

  double get pixelSizeX => math.sqrt(affine[0] * affine[0] + affine[3] * affine[3]);
}

/// Pembaca tag GeoTIFF minimal (TIFF klasik, little/big endian).
///
/// Tag yang dibaca:
///   256/257  ImageWidth/ImageLength
///   33550    ModelPixelScaleTag
///   33922    ModelTiepointTag
///   34264    ModelTransformationTag
///   34735    GeoKeyDirectoryTag (1024 model type, 1025 raster type,
///            2048 geographic CRS, 3072 projected CRS)
class GeoTiffParser {
  static GeoTiffInfo parse(Uint8List bytes) {
    if (bytes.length < 16) throw const FormatException('File terlalu kecil untuk TIFF');
    final bd = ByteData.sublistView(bytes);
    final Endian endian;
    if (bytes[0] == 0x49 && bytes[1] == 0x49) {
      endian = Endian.little;
    } else if (bytes[0] == 0x4D && bytes[1] == 0x4D) {
      endian = Endian.big;
    } else {
      throw const FormatException('Bukan file TIFF');
    }
    final magic = bd.getUint16(2, endian);
    if (magic == 43) {
      throw const FormatException('BigTIFF (> 4 GB) belum didukung di HP. Konversi lewat portal.');
    }
    if (magic != 42) throw const FormatException('Header TIFF tidak valid');

    final ifd = bd.getUint32(4, endian);
    final count = bd.getUint16(ifd, endian);
    final tags = <int, List<num>>{};
    for (var k = 0; k < count; k++) {
      final p = ifd + 2 + k * 12;
      final tag = bd.getUint16(p, endian);
      final type = bd.getUint16(p + 2, endian);
      final n = bd.getUint32(p + 4, endian);
      final size = _typeSize(type) * n;
      if (size == 0) continue;
      final off = size <= 4 ? p + 8 : bd.getUint32(p + 8, endian);
      if (off + size > bytes.length) continue;
      // Hanya tag yang dibutuhkan, agar tidak membaca larik besar tanpa perlu.
      if (const {256, 257, 33550, 33922, 34264, 34735}.contains(tag)) {
        tags[tag] = _read(bd, type, n, off, endian);
      }
    }

    final width = tags[256]?.first.toInt();
    final height = tags[257]?.first.toInt();
    if (width == null || height == null) throw const FormatException('Ukuran gambar tidak ditemukan');

    // GeoKeys
    final keys = tags[34735];
    if (keys == null) {
      throw const FormatException('File TIFF ini tidak memiliki georeferensi (GeoKeyDirectory tidak ada)');
    }
    final geo = <int, int>{};
    final numKeys = keys[3].toInt();
    for (var k = 0; k < numKeys; k++) {
      final base = 4 + k * 4;
      if (base + 3 >= keys.length) break;
      final id = keys[base].toInt();
      final loc = keys[base + 1].toInt();
      final value = keys[base + 3].toInt();
      if (loc == 0) geo[id] = value; // nilai langsung (SHORT)
    }
    final modelType = geo[1024] ?? 1;
    final rasterType = geo[1025] ?? 1;
    int epsg;
    if (modelType == 2) {
      epsg = geo[2048] ?? 4326;
    } else {
      epsg = geo[3072] ?? 0;
    }
    if (epsg == 0 || epsg == 32767) {
      throw const FormatException(
          'Sistem koordinat buatan pengguna (tanpa kode EPSG). Simpan ulang GeoTIFF dengan kode EPSG di QGIS, atau konversi lewat portal.');
    }

    // Affine
    List<double> affine;
    final mt = tags[34264];
    final tp = tags[33922];
    final ps = tags[33550];
    if (mt != null && mt.length >= 16) {
      affine = [mt[0], mt[1], mt[3], mt[4], mt[5], mt[7]].map((e) => e.toDouble()).toList();
    } else if (tp != null && tp.length >= 6 && ps != null && ps.length >= 2) {
      final i0 = tp[0].toDouble(), j0 = tp[1].toDouble();
      final x0 = tp[3].toDouble(), y0 = tp[4].toDouble();
      final sx = ps[0].toDouble(), sy = ps[1].toDouble();
      affine = [sx, 0, x0 - i0 * sx, 0, -sy, y0 + j0 * sy];
    } else {
      throw const FormatException('Tag tiepoint/pixel scale tidak ditemukan');
    }
    final pixelIsPoint = rasterType == 2;
    if (pixelIsPoint) {
      // Tiepoint merujuk ke pusat piksel: geser setengah piksel ke tepi.
      affine = [
        affine[0], affine[1], affine[2] - 0.5 * (affine[0] + affine[1]),
        affine[3], affine[4], affine[5] - 0.5 * (affine[3] + affine[4]),
      ];
    }
    return GeoTiffInfo(width: width, height: height, epsg: epsg, affine: affine, pixelIsPoint: pixelIsPoint);
  }

  static int _typeSize(int type) {
    switch (type) {
      case 1: case 2: case 6: case 7:
        return 1;
      case 3: case 8:
        return 2;
      case 4: case 9: case 11:
        return 4;
      case 5: case 10: case 12: case 16: case 17: case 18:
        return 8;
      default:
        return 0;
    }
  }

  static List<num> _read(ByteData bd, int type, int n, int off, Endian e) {
    final out = <num>[];
    for (var i = 0; i < n; i++) {
      switch (type) {
        case 1: case 7: out.add(bd.getUint8(off + i)); break;
        case 6: out.add(bd.getInt8(off + i)); break;
        case 3: out.add(bd.getUint16(off + i * 2, e)); break;
        case 8: out.add(bd.getInt16(off + i * 2, e)); break;
        case 4: out.add(bd.getUint32(off + i * 4, e)); break;
        case 9: out.add(bd.getInt32(off + i * 4, e)); break;
        case 11: out.add(bd.getFloat32(off + i * 4, e)); break;
        case 12: out.add(bd.getFloat64(off + i * 8, e)); break;
        case 5:
          {
            final den = bd.getUint32(off + i * 8 + 4, e);
            out.add(den == 0 ? 0 : bd.getUint32(off + i * 8, e) / den);
          }
          break;
        default:
          return out;
      }
    }
    return out;
  }
}

/// Hasil impor GeoTIFF: gambar JPEG siap tampil + 4 sudut dalam WGS 84.
class RasterImportResult {
  RasterImportResult({
    required this.epsg,
    required this.crsName,
    required this.topLeft,
    required this.bottomLeft,
    required this.bottomRight,
    required this.topRight,
    required this.sourceWidth,
    required this.sourceHeight,
    required this.outputWidth,
    required this.outputHeight,
    required this.pixelSize,
  });

  final int epsg;
  final String crsName;
  final LatLng topLeft, bottomLeft, bottomRight, topRight;
  final int sourceWidth, sourceHeight, outputWidth, outputHeight;
  final double pixelSize;

  List<LatLng> get corners => [topLeft, bottomLeft, bottomRight, topRight];
}

class GeoTiffImporter {
  /// Membaca GeoTIFF, memperkecil bila terlalu besar, menyimpan sebagai JPEG,
  /// dan menghitung sudut-sudutnya. Berjalan di isolate terpisah agar UI lancar.
  static Future<RasterImportResult> import(String srcPath, String outJpgPath, {int maxDim = 4096}) {
    return Isolate.run(() => _importSync(srcPath, outJpgPath, maxDim));
  }

  static RasterImportResult _importSync(String srcPath, String outJpgPath, int maxDim) {
    final bytes = File(srcPath).readAsBytesSync();
    final info = GeoTiffParser.parse(bytes);
    final crs = CrsProjection.fromEpsg(info.epsg);
    if (crs == null) {
      throw FormatException(
          'EPSG:${info.epsg} belum didukung di HP. Gunakan UTM, TM-3, WGS 84, atau konversi lewat portal.');
    }
    final decoded = img.decodeTiff(bytes);
    if (decoded == null) {
      throw const FormatException(
          'Kompresi/format piksel TIFF ini belum bisa dibaca di HP. Konversi lewat portal (tools/convert_map.py).');
    }
    var out = decoded;
    if (out.hasPalette || out.numChannels != 3 || out.bitsPerChannel != 8) {
      out = out.convert(format: img.Format.uint8, numChannels: 3);
    }
    if (math.max(out.width, out.height) > maxDim) {
      out = out.width >= out.height
          ? img.copyResize(out, width: maxDim, interpolation: img.Interpolation.average)
          : img.copyResize(out, height: maxDim, interpolation: img.Interpolation.average);
    }
    File(outJpgPath).writeAsBytesSync(img.encodeJpg(out, quality: 88));

    LatLng corner(double i, double j) {
      final m = info.pixelToModel(i, j);
      return crs.toLatLng(m.x, m.y);
    }

    final w = info.width.toDouble(), h = info.height.toDouble();
    return RasterImportResult(
      epsg: info.epsg,
      crsName: crs.name,
      topLeft: corner(0, 0),
      bottomLeft: corner(0, h),
      bottomRight: corner(w, h),
      topRight: corner(w, 0),
      sourceWidth: info.width,
      sourceHeight: info.height,
      outputWidth: out.width,
      outputHeight: out.height,
      pixelSize: info.pixelSizeX,
    );
  }
}
