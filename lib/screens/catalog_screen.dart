import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../app.dart';
import '../core/format.dart';
import '../models/map_package.dart';
import '../models/reference_layer.dart';
import '../services/map_focus.dart';
import '../services/map_repository.dart';

/// "Peta saya": daftar peta offline di HP, impor file, data contoh.
class CatalogScreen extends StatelessWidget {
  const CatalogScreen({super.key, required this.onShowMap});
  final VoidCallback onShowMap;

  Future<void> _import(BuildContext context) async {
    // Tanpa filter jenis: Android tidak mengenal MIME .tif/.mbtiles secara konsisten.
    final XFile? file = await openFile();
    if (file == null) return;
    if (!context.mounted) return;
    await _run(context, () async {
      // Salin ke folder sementara dengan nama aslinya, agar ekstensi file terbaca.
      final tmp = p.join((await getTemporaryDirectory()).path, file.name);
      await file.saveTo(tmp);
      return MapRepository.instance.importFile(tmp, displayName: p.basenameWithoutExtension(file.name));
    });
  }

  Future<void> _loadSamples(BuildContext context) async {
    await _run(context, () async {
      final msgs = await MapRepository.instance.loadSamples();
      return msgs.join('\n');
    });
  }

  Future<void> _run(BuildContext context, Future<String> Function() job) async {
    try {
      final msg = await job();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } catch (e) {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Peta tidak bisa diimpor'),
          content: Text('$e'),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Mengerti'))],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: MapRepository.instance,
      builder: (context, _) {
        final repo = MapRepository.instance;
        return Scaffold(
          appBar: AppBar(
            title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Peta saya'),
              Text('Peta offline memakai ${fmtBytes(repo.totalBytes)}',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            ]),
            actions: [
              PopupMenuButton<String>(
                onSelected: (v) {
                  if (v == 'samples') _loadSamples(context);
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'samples', child: Text('Muat data contoh Central Park')),
                ],
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: repo.busy ? null : () => _import(context),
            icon: const Icon(Icons.add),
            label: const Text('Impor file'),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 100),
            children: [
              if (repo.busy)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(repo.busyMessage ?? 'Memproses…'),
                      const SizedBox(height: 8),
                      const LinearProgressIndicator(),
                    ]),
                  ),
                ),
              if (repo.maps.isEmpty && !repo.busy) _emptyState(context),
              if (repo.maps.isNotEmpty) _section('Peta offline'),
              for (final m in repo.maps) _MapTile(m: m, onShowMap: onShowMap),
              if (repo.refLayers.isNotEmpty) _section('Lapisan referensi (batas blok)'),
              for (final l in repo.refLayers) _LayerTile(l: l),
              const SizedBox(height: 16),
              const _FormatsInfo(),
            ],
          ),
        );
      },
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 16, 4, 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.muted, letterSpacing: 0.5)),
      );

  Widget _emptyState(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(side: const BorderSide(color: AppColors.line), borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.map_outlined, size: 40, color: AppColors.green),
          const SizedBox(height: 8),
          const Text('Belum ada peta di HP ini', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text(
            'Impor paket MBTiles dari portal, file GeoTIFF, atau batas blok GeoJSON. '
            'Untuk mencoba, muat data contoh di sekitar Central Park, Jakarta Barat.',
            style: TextStyle(color: AppColors.muted),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => _loadSamples(context),
            icon: const Icon(Icons.download_done),
            label: const Text('Muat data contoh Central Park'),
          ),
        ]),
      ),
    );
  }
}

class _MapTile extends StatelessWidget {
  const _MapTile({required this.m, required this.onShowMap});
  final MapPackage m;
  final VoidCallback onShowMap;

  @override
  Widget build(BuildContext context) {
    final repo = MapRepository.instance;
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(side: const BorderSide(color: AppColors.line), borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        contentPadding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
        leading: Container(
          width: 48,
          height: 48,
          decoration: BoxDecoration(
            color: m.kind == MapKind.mbtiles ? AppColors.greenSoft : const Color(0xFFE6E1CC),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(m.kind == MapKind.mbtiles ? Icons.grid_view : Icons.image_outlined, color: AppColors.greenDark),
        ),
        title: Text(m.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${m.kindLabel} · ${m.crs ?? '-'} · ${fmtBytes(m.sizeBytes)}'),
        trailing: Switch(value: m.visible, onChanged: (v) => repo.setVisible(m, v)),
        onTap: () => _details(context),
      ),
    );
  }

  void _details(BuildContext context) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheet) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(m.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            if (m.description != null) Text(m.description!, style: const TextStyle(color: AppColors.muted)),
            const SizedBox(height: 12),
            _kv('Jenis', m.kindLabel),
            _kv('CRS sumber', m.crs ?? '-'),
            if (m.minZoom != null) _kv('Zoom', '${m.minZoom} – ${m.maxZoom}'),
            if (m.mapVersion != null) _kv('Versi peta', m.mapVersion!),
            _kv('File asal', m.sourceName ?? '-'),
            _kv('Batas', '${m.south.toStringAsFixed(5)}, ${m.west.toStringAsFixed(5)}\n'
                '${m.north.toStringAsFixed(5)}, ${m.east.toStringAsFixed(5)}'),
            _kv('Diimpor', fmtDateTime(m.createdAt)),
            const SizedBox(height: 8),
            Text('Transparansi ${(100 - m.opacity * 100).round()}%', style: const TextStyle(color: AppColors.muted)),
            Slider(
              value: m.opacity,
              min: 0.2,
              max: 1,
              divisions: 8,
              onChanged: (v) {
                MapRepository.instance.setOpacity(m, v);
                setSheet(() {});
              },
            ),
            Row(children: [
              Expanded(
                child: FilledButton.icon(
                  icon: const Icon(Icons.map),
                  label: const Text('Tampilkan'),
                  onPressed: () {
                    if (!m.visible) MapRepository.instance.setVisible(m, true);
                    MapFocus.bounds(m.bounds);
                    Navigator.pop(ctx);
                    onShowMap();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(foregroundColor: AppColors.orange),
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Hapus'),
                  onPressed: () async {
                    final ok = await showDialog<bool>(
                      context: ctx,
                      builder: (d) => AlertDialog(
                        title: const Text('Hapus peta dari HP?'),
                        content: const Text('Data lapangan tidak ikut terhapus. Peta bisa diunduh/impor lagi.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Batal')),
                          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Hapus')),
                        ],
                      ),
                    );
                    if (ok == true) {
                      await MapRepository.instance.delete(m);
                      if (ctx.mounted) Navigator.pop(ctx);
                    }
                  },
                ),
              ),
            ]),
          ]),
        ),
      ),
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 110, child: Text(k, style: const TextStyle(color: AppColors.muted))),
          Expanded(child: Text(v)),
        ]),
      );
}

class _LayerTile extends StatelessWidget {
  const _LayerTile({required this.l});
  final ReferenceLayer l;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(side: const BorderSide(color: AppColors.line), borderRadius: BorderRadius.circular(12)),
      child: ListTile(
        leading: const Icon(Icons.pentagon_outlined, color: AppColors.greenDark),
        title: Text(l.name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${l.polygons.length} poligon${l.lines.isNotEmpty ? ' · ${l.lines.length} garis' : ''}'
            '${l.labelField != null ? ' · label: ${l.labelField}' : ''}'),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Switch(value: l.visible, onChanged: (v) => MapRepository.instance.setLayerVisible(l, v)),
          IconButton(
            tooltip: 'Hapus lapisan',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => MapRepository.instance.deleteLayer(l),
          ),
        ]),
      ),
    );
  }
}

class _FormatsInfo extends StatelessWidget {
  const _FormatsInfo();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: const Color(0xFFEEF2F7), borderRadius: BorderRadius.circular(12)),
      child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Format yang bisa diimpor di HP', style: TextStyle(fontWeight: FontWeight.w600, color: Color(0xFF24364F))),
        SizedBox(height: 6),
        Text(
          '• MBTiles (.mbtiles) — paket peta dari portal/tim GIS\n'
          '• GeoTIFF (.tif, .tiff) — UTM, TM-3, WGS 84, Web Mercator\n'
          '• GeoJSON (.geojson) — batas blok sebagai lapisan referensi\n\n'
          'GeoPDF diubah dulu menjadi MBTiles oleh tim GIS dengan tools/convert_map.py, '
          'lalu file .mbtiles disalin atau diunduh ke HP.',
          style: TextStyle(fontSize: 13, color: Color(0xFF24364F)),
        ),
      ]),
    );
  }
}
