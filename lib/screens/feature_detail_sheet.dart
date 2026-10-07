import 'dart:io';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/format.dart';
import '../core/geo.dart';
import '../models/field_feature.dart';
import '../models/form_schema.dart';
import '../services/feature_repository.dart';
import '../services/map_focus.dart';

String syncLabel(SyncStatus s) => switch (s) {
      SyncStatus.pending => 'Menunggu',
      SyncStatus.sent => 'Terkirim',
      SyncStatus.failed => 'Gagal',
    };

Color syncColor(SyncStatus s) => switch (s) {
      SyncStatus.pending => AppColors.muted,
      SyncStatus.sent => AppColors.green,
      SyncStatus.failed => AppColors.orange,
    };

/// Lembar detail satu temuan.
Future<void> showFeatureDetail(BuildContext context, FieldFeature f, {VoidCallback? onShowMap}) {
  final type = FormSchema.byId(f.typeId);
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          Row(children: [
            Expanded(
              child: Text('${f.typeLabel}${f.block != null ? ' · ${f.block}' : ''}',
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            ),
            Chip(
              label: Text(syncLabel(f.syncStatus)),
              labelStyle: TextStyle(color: syncColor(f.syncStatus), fontWeight: FontWeight.w600),
              side: BorderSide(color: syncColor(f.syncStatus)),
            ),
          ]),
          Text(fmtDateTime(f.createdAt), style: const TextStyle(color: AppColors.muted)),
          if (f.syncError != null && f.syncStatus == SyncStatus.failed)
            Text('Alasan gagal: ${f.syncError}', style: const TextStyle(color: AppColors.orange, fontSize: 12)),
          const SizedBox(height: 12),
          _row('Koordinat', Geo.formatCoord(f.point)),
          _row('Akurasi', f.accuracy == null ? '-' : '±${f.accuracy!.toStringAsFixed(1)} m'),
          _row('Sumber posisi', switch (f.positionSource) {
            'gps-avg' => 'GPS dirata-rata (${f.readings ?? 0} bacaan)',
            'manual' => 'Dipilih di peta',
            _ => 'GPS',
          }),
          for (final field in type.fields)
            if (f.attributes[field.key] != null && '${f.attributes[field.key]}'.isNotEmpty)
              _row(field.label, '${f.attributes[field.key]}${field.unit != null ? ' ${field.unit}' : ''}'),
          if (f.notes != null && f.notes!.isNotEmpty) _row('Catatan', f.notes!),
          if (f.createdBy != null) _row('Dicatat oleh', f.createdBy!),
          if (f.photos.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: f.photos.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) => ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.file(File(f.photos[i]), width: 120, height: 120, fit: BoxFit.cover),
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          Row(children: [
            if (onShowMap != null)
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('Lihat di peta'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    MapFocus.point(f.point);
                    onShowMap();
                  },
                ),
              ),
            if (onShowMap != null) const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(foregroundColor: AppColors.orange),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Hapus'),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: ctx,
                    builder: (d) => AlertDialog(
                      title: const Text('Hapus temuan ini?'),
                      content: const Text('Penghapusan juga dikirim ke server saat sinkronisasi.'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Batal')),
                        FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Hapus')),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await FeatureRepository.instance.deleteFeature(f);
                    if (ctx.mounted) Navigator.pop(ctx);
                  }
                },
              ),
            ),
          ]),
        ],
      ),
    ),
  );
}

Widget _row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 130, child: Text(label, style: const TextStyle(color: AppColors.muted))),
        Expanded(child: Text(value)),
      ]),
    );
