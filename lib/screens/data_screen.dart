import 'package:flutter/material.dart';

import '../app.dart';
import '../core/format.dart';
import '../core/geo.dart';
import '../models/field_feature.dart';
import '../models/track_record.dart';
import '../services/export_service.dart';
import '../services/feature_repository.dart';
import '../services/sync_service.dart';
import 'feature_detail_sheet.dart';

/// Daftar data lapangan, status sinkronisasi, dan ekspor.
class DataScreen extends StatelessWidget {
  const DataScreen({super.key});

  Future<void> _sync(BuildContext context) async {
    try {
      final r = await SyncService.instance.syncNow();
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(r.toString())));
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('HttpException: ', ''))));
      }
    }
  }

  Future<void> _export(BuildContext context, ExportFormat f) async {
    try {
      final path = await ExportService.export(f);
      await ExportService.share(path);
    } catch (e) {
      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ekspor gagal: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([FeatureRepository.instance, SyncService.instance]),
      builder: (context, _) {
        final repo = FeatureRepository.instance;
        final sync = SyncService.instance;
        return DefaultTabController(
          length: 2,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Data lapangan'),
              actions: [
                PopupMenuButton<ExportFormat>(
                  tooltip: 'Ekspor',
                  icon: const Icon(Icons.ios_share),
                  onSelected: (f) => _export(context, f),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: ExportFormat.kml, child: Text('Ekspor KML (Google Earth)')),
                    PopupMenuItem(value: ExportFormat.gpx, child: Text('Ekspor GPX (perangkat GPS)')),
                    PopupMenuItem(value: ExportFormat.geojson, child: Text('Ekspor GeoJSON (QGIS)')),
                    PopupMenuItem(value: ExportFormat.csv, child: Text('Ekspor CSV (Excel)')),
                  ],
                ),
              ],
              bottom: TabBar(tabs: [
                Tab(text: 'Temuan (${repo.features.length})'),
                Tab(text: 'Track (${repo.tracks.length})'),
              ]),
            ),
            body: Column(children: [
              _SyncBanner(
                pending: repo.pendingCount,
                failed: repo.failedCount,
                running: sync.running,
                message: sync.lastMessage,
                onSync: () => _sync(context),
              ),
              Expanded(
                child: TabBarView(children: [
                  _FeatureList(features: repo.features),
                  _TrackList(tracks: repo.tracks),
                ]),
              ),
            ]),
          ),
        );
      },
    );
  }
}

class _SyncBanner extends StatelessWidget {
  const _SyncBanner({
    required this.pending,
    required this.failed,
    required this.running,
    required this.message,
    required this.onSync,
  });
  final int pending, failed;
  final bool running;
  final String? message;
  final VoidCallback onSync;

  @override
  Widget build(BuildContext context) {
    final allSent = pending == 0;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: allSent ? AppColors.greenSoft : AppColors.orangeSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Icon(allSent ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
            color: allSent ? AppColors.greenDark : const Color(0xFF8A3D10)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              allSent ? 'Semua data sudah terkirim' : '$pending data menunggu dikirim${failed > 0 ? ' · $failed gagal' : ''}',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            Text(message ?? 'Data aman di HP. Terkirim otomatis saat ada Wi-Fi atau sinyal.',
                style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            if (running) const Padding(padding: EdgeInsets.only(top: 6), child: LinearProgressIndicator()),
          ]),
        ),
        const SizedBox(width: 8),
        FilledButton(onPressed: running ? null : onSync, child: const Text('Kirim')),
      ]),
    );
  }
}

Widget _statusChip(SyncStatus s) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        color: switch (s) {
          SyncStatus.pending => AppColors.ground,
          SyncStatus.sent => AppColors.greenSoft,
          SyncStatus.failed => AppColors.orangeSoft,
        },
      ),
      child: Text(syncLabel(s),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: syncColor(s))),
    );

class _FeatureList extends StatelessWidget {
  const _FeatureList({required this.features});
  final List<FieldFeature> features;

  @override
  Widget build(BuildContext context) {
    if (features.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Belum ada temuan. Gunakan tombol "Tambah titik" di layar Peta.',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: features.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final f = features[i];
        return Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Colors.white,
          shape: RoundedRectangleBorder(
              side: BorderSide(color: f.syncStatus == SyncStatus.failed ? const Color(0xFFE8B79A) : AppColors.line),
              borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: AppColors.orangeSoft,
              child: Icon(Icons.place, color: Color(0xFF8A3D10)),
            ),
            title: Text('${f.typeLabel}${f.block != null ? ' · ${f.block}' : ''}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text([
              fmtShort(f.createdAt),
              if (f.photos.isNotEmpty) '${f.photos.length} foto',
              if (f.accuracy != null) '±${f.accuracy!.toStringAsFixed(1)} m',
            ].join(' · ')),
            trailing: _statusChip(f.syncStatus),
            onTap: () => showFeatureDetail(context, f),
          ),
        );
      },
    );
  }
}

class _TrackList extends StatelessWidget {
  const _TrackList({required this.tracks});
  final List<TrackRecord> tracks;

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text('Belum ada track. Gunakan tombol "Rekam track" di layar Peta.',
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.muted)),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: tracks.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final t = tracks[i];
        final active = t.endedAt == null;
        return Card(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Colors.white,
          shape: RoundedRectangleBorder(side: const BorderSide(color: AppColors.line), borderRadius: BorderRadius.circular(12)),
          child: ListTile(
            leading: const CircleAvatar(
              backgroundColor: AppColors.orangeSoft,
              child: Icon(Icons.timeline, color: Color(0xFF8A3D10)),
            ),
            title: Text(t.name, style: const TextStyle(fontWeight: FontWeight.w600)),
            subtitle: Text(active
                ? 'Sedang direkam'
                : '${fmtShort(t.startedAt)} · ${fmtDuration(t.duration)} · ${Geo.formatDistance(t.distanceM)}'),
            trailing: active ? null : _statusChip(t.syncStatus),
            onLongPress: active
                ? null
                : () async {
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: const Text('Hapus track ini?'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Batal')),
                          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Hapus')),
                        ],
                      ),
                    );
                    if (ok == true) await FeatureRepository.instance.deleteTrack(t);
                  },
          ),
        );
      },
    );
  }
}
