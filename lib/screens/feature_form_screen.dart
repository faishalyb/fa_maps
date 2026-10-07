import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';

import '../app.dart';
import '../core/geo.dart';
import '../core/settings.dart';
import '../models/form_schema.dart';
import '../services/feature_repository.dart';
import '../services/location_service.dart';
import '../services/map_repository.dart';

/// Formulir temuan baru. Posisi dari rata-rata GPS, atau dari titik yang
/// dipilih di peta (tekan lama) bila [manualPoint] diisi.
class FeatureFormScreen extends StatefulWidget {
  const FeatureFormScreen({super.key, this.manualPoint});
  final LatLng? manualPoint;

  @override
  State<FeatureFormScreen> createState() => _FeatureFormScreenState();
}

class _FeatureFormScreenState extends State<FeatureFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _notes = TextEditingController();
  final Map<String, TextEditingController> _text = {};
  final Map<String, String?> _choice = {};
  final List<String> _photos = [];
  GpsAverager? _avg;
  FindingType _type = FormSchema.types.first;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.manualPoint == null) {
      _avg = GpsAverager(target: AppSettings.instance.avgReadings)..addListener(_refresh);
      _avg!.start();
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _avg?.removeListener(_refresh);
    _avg?.dispose();
    _notes.dispose();
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  LatLng? get _point => widget.manualPoint ?? _avg?.current?.point;

  TextEditingController _ctrl(String key) => _text.putIfAbsent(key, () => TextEditingController());

  Future<void> _addPhoto(ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(source: source, maxWidth: 1600, maxHeight: 1600, imageQuality: 80);
      if (x != null) setState(() => _photos.add(x.path));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Kamera tidak bisa dibuka: $e')));
    }
  }

  Future<void> _save() async {
    final point = _point;
    if (point == null) {
      _msg('Belum ada bacaan GPS yang cukup akurat. Tunggu sebentar di tempat terbuka.');
      return;
    }
    if (!_formKey.currentState!.validate()) return;
    if (_photos.length < _type.minPhotos) {
      _msg('Jenis temuan ini wajib minimal ${_type.minPhotos} foto.');
      return;
    }
    setState(() => _saving = true);
    _avg?.finish();
    final fix = widget.manualPoint == null ? await _avg!.result : null;
    final attrs = <String, dynamic>{};
    for (final f in _type.fields) {
      switch (f.type) {
        case FieldType.choice:
          if (_choice[f.key] != null) attrs[f.key] = _choice[f.key];
          break;
        case FieldType.integer:
          final v = int.tryParse(_ctrl(f.key).text.trim());
          if (v != null) attrs[f.key] = v;
          break;
        case FieldType.decimal:
          final v = double.tryParse(_ctrl(f.key).text.trim().replaceAll(',', '.'));
          if (v != null) attrs[f.key] = v;
          break;
        case FieldType.text:
          final v = _ctrl(f.key).text.trim();
          if (v.isNotEmpty) attrs[f.key] = v;
          break;
      }
    }
    final finalPoint = fix?.point ?? point;
    try {
      await FeatureRepository.instance.saveFeature(
        typeId: _type.id,
        typeLabel: _type.label,
        point: finalPoint,
        attributes: attrs,
        notes: _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        block: MapRepository.instance.blockAt(finalPoint),
        accuracy: fix?.accuracy,
        readings: fix?.readings,
        positionSource: widget.manualPoint != null ? 'manual' : 'gps-avg',
        mapId: MapRepository.instance.mapAt(finalPoint)?.id,
        createdBy: AppSettings.instance.userName,
        photoPaths: _photos,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Temuan tersimpan di HP · dikirim otomatis saat online')),
      );
    } catch (e) {
      setState(() => _saving = false);
      _msg('Gagal menyimpan: $e');
    }
  }

  void _msg(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Temuan baru')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _positionCard(),
            const SizedBox(height: 16),
            const Text('Jenis temuan', style: TextStyle(color: AppColors.muted)),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final t in FormSchema.types)
                ChoiceChip(
                  label: Text(t.label),
                  selected: t.id == _type.id,
                  onSelected: (_) => setState(() {
                    _type = t;
                    _choice.clear();
                    for (final c in _text.values) {
                      c.clear();
                    }
                  }),
                ),
            ]),
            const SizedBox(height: 16),
            for (final f in _type.fields) ...[
              _field(f),
              const SizedBox(height: 12),
            ],
            Text(
              _type.minPhotos > 0 ? 'Foto (wajib, min. ${_type.minPhotos})' : 'Foto (opsional)',
              style: const TextStyle(color: AppColors.muted),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 10, runSpacing: 10, children: [
              for (var i = 0; i < _photos.length; i++)
                Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: Image.file(File(_photos[i]), width: 88, height: 88, fit: BoxFit.cover),
                  ),
                  Positioned(
                    right: 0,
                    top: 0,
                    child: IconButton.filledTonal(
                      visualDensity: VisualDensity.compact,
                      tooltip: 'Hapus foto',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: () => setState(() => _photos.removeAt(i)),
                    ),
                  ),
                ]),
              _photoButton(Icons.photo_camera_outlined, 'Kamera', () => _addPhoto(ImageSource.camera)),
              _photoButton(Icons.photo_library_outlined, 'Galeri', () => _addPhoto(ImageSource.gallery)),
            ]),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notes,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Catatan'),
            ),
            const SizedBox(height: 80),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: const Text('Simpan di HP', style: TextStyle(fontSize: 16)),
              ),
            ),
            const SizedBox(height: 4),
            const Text('Dikirim otomatis ke server saat ada sinyal atau Wi-Fi',
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
          ]),
        ),
      ),
    );
  }

  Widget _positionCard() {
    final p = _point;
    final block = p == null ? null : MapRepository.instance.blockAt(p);
    final avg = _avg;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
          side: const BorderSide(color: AppColors.line), borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Posisi titik', style: TextStyle(fontWeight: FontWeight.w600))),
            Text(block != null ? 'Blok $block · otomatis' : 'Di luar blok referensi',
                style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          ]),
          const SizedBox(height: 8),
          if (avg == null) ...[
            const Text('Dipilih di peta (tekan lama)'),
          ] else ...[
            Row(children: [
              Expanded(
                child: Text(avg.finished ? 'Posisi terkunci' : 'Merata-rata GPS',
                    style: const TextStyle(fontSize: 13)),
              ),
              Text('${avg.samples.length} / ${avg.target} bacaan',
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace')),
            ]),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: avg.samples.length / avg.target,
              color: AppColors.blue,
              backgroundColor: AppColors.ground,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            if (avg.rejected > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${avg.rejected} bacaan dibuang (akurasi > ${AppSettings.instance.maxAccuracy.toStringAsFixed(0)} m)',
                    style: const TextStyle(fontSize: 11, color: AppColors.muted)),
              ),
            if (LocationService.instance.error != null)
              Text(LocationService.instance.error!, style: const TextStyle(fontSize: 12, color: AppColors.orange)),
          ],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: Text(p == null ? 'Menunggu GPS…' : Geo.formatCoord(p),
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            ),
            if (avg?.current != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration:
                    BoxDecoration(color: AppColors.greenSoft, borderRadius: BorderRadius.circular(999)),
                child: Text('±${avg!.current!.accuracy.toStringAsFixed(1)} m',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.greenDark)),
              ),
            if (avg != null && !avg.finished && avg.samples.isNotEmpty) ...[
              const SizedBox(width: 8),
              OutlinedButton(onPressed: avg.finish, child: const Text('Selesai lebih awal')),
            ],
          ]),
        ]),
      ),
    );
  }

  Widget _field(FieldDef f) {
    final label = '${f.label}${f.unit != null ? ' (${f.unit})' : ''}${f.required ? ' *' : ''}';
    switch (f.type) {
      case FieldType.choice:
        return DropdownButtonFormField<String>(
          key: ValueKey('${_type.id}-${f.key}'),
          initialValue: _choice[f.key],
          decoration: InputDecoration(labelText: label),
          items: [for (final o in f.options) DropdownMenuItem(value: o, child: Text(o))],
          onChanged: (v) => setState(() => _choice[f.key] = v),
          validator: (v) => f.required && v == null ? 'Wajib dipilih' : null,
        );
      case FieldType.integer:
      case FieldType.decimal:
        return TextFormField(
          key: ValueKey('${_type.id}-${f.key}'),
          controller: _ctrl(f.key),
          keyboardType: TextInputType.numberWithOptions(decimal: f.type == FieldType.decimal),
          decoration: InputDecoration(labelText: label),
          validator: (v) {
            final t = (v ?? '').trim().replaceAll(',', '.');
            if (t.isEmpty) return f.required ? 'Wajib diisi' : null;
            final ok = f.type == FieldType.integer ? int.tryParse(t) != null : double.tryParse(t) != null;
            return ok ? null : 'Angka tidak valid';
          },
        );
      case FieldType.text:
        return TextFormField(
          key: ValueKey('${_type.id}-${f.key}'),
          controller: _ctrl(f.key),
          decoration: InputDecoration(labelText: label),
          validator: (v) => f.required && (v ?? '').trim().isEmpty ? 'Wajib diisi' : null,
        );
    }
  }

  Widget _photoButton(IconData icon, String label, VoidCallback onTap) {
    return SizedBox(
      width: 88,
      height: 88,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          padding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        onPressed: onTap,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(icon),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}
