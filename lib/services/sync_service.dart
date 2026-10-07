import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/settings.dart';
import '../models/field_feature.dart';
import 'feature_repository.dart';

class SyncResult {
  SyncResult(this.featuresSent, this.tracksSent, this.failed);
  final int featuresSent;
  final int tracksSent;
  final int failed;

  @override
  String toString() {
    if (featuresSent == 0 && tracksSent == 0 && failed == 0) return 'Semua data sudah terkirim';
    final parts = <String>[];
    if (featuresSent > 0) parts.add('$featuresSent temuan');
    if (tracksSent > 0) parts.add('$tracksSent track');
    var s = parts.isEmpty ? '' : '${parts.join(' dan ')} terkirim';
    if (failed > 0) s += '${s.isEmpty ? '' : '. '}$failed gagal, akan dicoba lagi';
    return s;
  }
}

/// Mengirim antrean data ke server saat ada koneksi (Wi-Fi atau seluler).
/// Kontrak API: lihat tools/sync_server.py dan spesifikasi bagian 8.
class SyncService extends ChangeNotifier {
  SyncService._();
  static final SyncService instance = SyncService._();

  bool running = false;
  String? lastMessage;
  DateTime? lastSync;

  static const _batch = 10;
  static const _timeout = Duration(seconds: 30);

  Uri _uri(String path) {
    var base = AppSettings.instance.serverUrl.trim();
    if (base.isEmpty) throw const HttpException('Alamat server belum diatur di Pengaturan');
    if (!base.startsWith('http')) base = 'http://$base';
    if (base.endsWith('/')) base = base.substring(0, base.length - 1);
    return Uri.parse('$base$path');
  }

  Future<SyncResult> syncNow() async {
    if (running) return SyncResult(0, 0, 0);
    running = true;
    notifyListeners();
    final repo = FeatureRepository.instance;
    var sentF = 0, sentT = 0, failed = 0;
    try {
      final settings = AppSettings.instance;
      _uri('/'); // gagal cepat bila alamat server belum diatur
      final feats = await repo.pendingFeatureList();
      for (var i = 0; i < feats.length; i += _batch) {
        final chunk = feats.sublist(i, i + _batch > feats.length ? feats.length : i + _batch);
        final body = {
          'device_id': settings.deviceId,
          'user': settings.userName,
          'features': [for (final f in chunk) await _featureJson(f)],
        };
        try {
          final res = await http
              .post(_uri('/api/sync/features'),
                  headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
              .timeout(_timeout);
          if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}: ${res.body}');
          final accepted = ((jsonDecode(res.body) as Map)['accepted'] as List).cast<String>();
          await repo.markFeatures(accepted, SyncStatus.sent);
          final rejected = chunk.map((f) => f.id).where((id) => !accepted.contains(id)).toList();
          if (rejected.isNotEmpty) {
            await repo.markFeatures(rejected, SyncStatus.failed, error: 'Ditolak server');
            failed += rejected.length;
          }
          sentF += accepted.length;
        } catch (e) {
          if (_isNetwork(e)) rethrow; // tidak ada jaringan: hentikan, coba lagi nanti
          await repo.markFeatures(chunk.map((f) => f.id).toList(), SyncStatus.failed, error: '$e');
          failed += chunk.length;
        }
      }

      final tracks = await repo.pendingTrackList();
      for (final t in tracks) {
        final pts = await repo.trackPoints(t.id);
        final body = {
          'device_id': settings.deviceId,
          'user': settings.userName,
          'tracks': [
            {
              'id': t.id,
              'name': t.name,
              'started_at': t.startedAt.toIso8601String(),
              'ended_at': t.endedAt?.toIso8601String(),
              'distance_m': t.distanceM,
              'created_by': t.createdBy,
              'points': [
                for (final p in pts)
                  [p.point.longitude, p.point.latitude, p.altitude, p.accuracy, p.time.toIso8601String()]
              ],
            }
          ],
        };
        try {
          final res = await http
              .post(_uri('/api/sync/tracks'), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body))
              .timeout(_timeout);
          if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
          await repo.markTracks([t.id], SyncStatus.sent);
          sentT++;
        } catch (e) {
          if (_isNetwork(e)) rethrow;
          await repo.markTracks([t.id], SyncStatus.failed, error: '$e');
          failed++;
        }
      }
      lastSync = DateTime.now();
      final r = SyncResult(sentF, sentT, failed);
      lastMessage = r.toString();
      return r;
    } catch (e) {
      if (!_isNetwork(e)) rethrow;
      lastMessage = 'Tidak ada koneksi ke server. Data tetap aman di HP.';
      throw HttpException(lastMessage!);
    } finally {
      running = false;
      await repo.load();
      notifyListeners();
    }
  }

  static bool _isNetwork(Object e) =>
      e is SocketException || e is http.ClientException || e is TimeoutException;

  Future<Map<String, Object?>> _featureJson(FieldFeature f) async {
    final photos = <Map<String, String>>[];
    for (final path in f.photos) {
      final file = File(path);
      if (!file.existsSync()) continue;
      photos.add({
        'filename': p.basename(path),
        'data_base64': base64Encode(await file.readAsBytes()),
      });
    }
    return {
      'id': f.id,
      'type_id': f.typeId,
      'type_label': f.typeLabel,
      'geometry': f.geometry,
      'attributes': f.attributes,
      'notes': f.notes,
      'block': f.block,
      'accuracy': f.accuracy,
      'readings': f.readings,
      'position_source': f.positionSource,
      'map_id': f.mapId,
      'created_by': f.createdBy,
      'created_at': f.createdAt.toIso8601String(),
      'updated_at': f.updatedAt.toIso8601String(),
      'deleted': f.deleted,
      'photos': photos,
    };
  }
}
