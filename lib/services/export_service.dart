import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/field_feature.dart';
import '../models/track_record.dart';
import 'feature_repository.dart';

enum ExportFormat { kml, gpx, csv, geojson }

/// Ekspor data lapangan ke format yang bisa dibuka QGIS / Google Earth / Excel.
class ExportService {
  static Future<String> export(ExportFormat format) async {
    final repo = FeatureRepository.instance;
    final feats = repo.features;
    final tracks = <TrackRecord, List<TrackPoint>>{};
    for (final t in repo.tracks.where((t) => t.endedAt != null)) {
      tracks[t] = await repo.trackPoints(t.id);
    }
    final stamp = DateTime.now().toIso8601String().substring(0, 16).replaceAll(RegExp('[:T]'), '');
    final dir = await getTemporaryDirectory();
    late String content;
    late String ext;
    switch (format) {
      case ExportFormat.kml:
        content = _kml(feats, tracks);
        ext = 'kml';
        break;
      case ExportFormat.gpx:
        content = _gpx(feats, tracks);
        ext = 'gpx';
        break;
      case ExportFormat.csv:
        content = _csv(feats);
        ext = 'csv';
        break;
      case ExportFormat.geojson:
        content = _geojson(feats, tracks);
        ext = 'geojson';
        break;
    }
    final path = p.join(dir.path, 'data_lapangan_$stamp.$ext');
    await File(path).writeAsString(content);
    return path;
  }

  static Future<void> share(String path) async {
    await Share.shareXFiles([XFile(path)], text: 'Data lapangan FA Maps');
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  static String _kml(List<FieldFeature> feats, Map<TrackRecord, List<TrackPoint>> tracks) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Data lapangan</name>');
    for (final f in feats) {
      b.writeln('<Placemark><name>${_esc(f.typeLabel)}${f.block != null ? ' · ${_esc(f.block!)}' : ''}</name>');
      b.writeln('<description>${_esc(f.notes ?? '')}</description><ExtendedData>');
      final data = {
        'id': f.id,
        'jenis': f.typeLabel,
        'blok': f.block ?? '',
        'akurasi_m': f.accuracy?.toStringAsFixed(1) ?? '',
        'dibuat': f.createdAt.toIso8601String(),
        ...f.attributes.map((k, v) => MapEntry(k, '$v')),
      };
      data.forEach((k, v) => b.writeln('<Data name="${_esc(k)}"><value>${_esc(v)}</value></Data>'));
      b.writeln('</ExtendedData><Point><coordinates>${f.point.longitude},${f.point.latitude},0</coordinates></Point></Placemark>');
    }
    tracks.forEach((t, pts) {
      b.writeln('<Placemark><name>${_esc(t.name)}</name><LineString><tessellate>1</tessellate><coordinates>');
      b.writeln(pts.map((e) => '${e.point.longitude},${e.point.latitude},${e.altitude ?? 0}').join(' '));
      b.writeln('</coordinates></LineString></Placemark>');
    });
    b.writeln('</Document></kml>');
    return b.toString();
  }

  static String _gpx(List<FieldFeature> feats, Map<TrackRecord, List<TrackPoint>> tracks) {
    final b = StringBuffer()
      ..writeln('<?xml version="1.0" encoding="UTF-8"?>')
      ..writeln('<gpx version="1.1" creator="FA Maps" xmlns="http://www.topografix.com/GPX/1/1">');
    for (final f in feats) {
      b.writeln('<wpt lat="${f.point.latitude}" lon="${f.point.longitude}">'
          '<time>${f.createdAt.toUtc().toIso8601String()}</time>'
          '<name>${_esc(f.typeLabel)}</name><desc>${_esc(f.notes ?? '')}</desc></wpt>');
    }
    tracks.forEach((t, pts) {
      b.writeln('<trk><name>${_esc(t.name)}</name><trkseg>');
      for (final e in pts) {
        b.writeln('<trkpt lat="${e.point.latitude}" lon="${e.point.longitude}">'
            '${e.altitude != null ? '<ele>${e.altitude}</ele>' : ''}'
            '<time>${e.time.toUtc().toIso8601String()}</time></trkpt>');
      }
      b.writeln('</trkseg></trk>');
    });
    b.writeln('</gpx>');
    return b.toString();
  }

  static String _csv(List<FieldFeature> feats) {
    String q(Object? v) => '"${'${v ?? ''}'.replaceAll('"', '""')}"';
    final b = StringBuffer()
      ..writeln('id,jenis,lintang,bujur,blok,akurasi_m,bacaan_gps,sumber_posisi,dibuat,catatan,atribut_json,status_sync');
    for (final f in feats) {
      b.writeln([
        f.id,
        f.typeLabel,
        f.point.latitude.toStringAsFixed(7),
        f.point.longitude.toStringAsFixed(7),
        f.block,
        f.accuracy?.toStringAsFixed(1),
        f.readings,
        f.positionSource,
        f.createdAt.toIso8601String(),
        f.notes,
        jsonEncode(f.attributes),
        f.syncStatus.name,
      ].map(q).join(','));
    }
    return b.toString();
  }

  static String _geojson(List<FieldFeature> feats, Map<TrackRecord, List<TrackPoint>> tracks) {
    final features = <Map<String, Object?>>[
      for (final f in feats)
        {
          'type': 'Feature',
          'geometry': f.geometry,
          'properties': {
            'id': f.id,
            'jenis': f.typeLabel,
            'jenis_id': f.typeId,
            'blok': f.block,
            'akurasi_m': f.accuracy,
            'bacaan_gps': f.readings,
            'dibuat': f.createdAt.toIso8601String(),
            'catatan': f.notes,
            ...f.attributes,
          },
        },
      for (final e in tracks.entries)
        {
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': e.value.map((p) => [p.point.longitude, p.point.latitude]).toList(),
          },
          'properties': {
            'id': e.key.id,
            'nama': e.key.name,
            'mulai': e.key.startedAt.toIso8601String(),
            'selesai': e.key.endedAt?.toIso8601String(),
            'jarak_m': e.key.distanceM,
          },
        },
    ];
    return const JsonEncoder.withIndent(' ').convert({'type': 'FeatureCollection', 'features': features});
  }
}
