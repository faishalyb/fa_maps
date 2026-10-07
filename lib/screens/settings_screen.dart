import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../app.dart';
import '../core/settings.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final s = AppSettings.instance;
  late final _server = TextEditingController(text: s.serverUrl);
  late final _user = TextEditingController(text: s.userName);
  String? _testResult;
  bool _testing = false;

  @override
  void dispose() {
    _server.dispose();
    _user.dispose();
    super.dispose();
  }

  Future<void> _testServer() async {
    await s.update(serverUrl: _server.text);
    setState(() {
      _testing = true;
      _testResult = null;
    });
    try {
      var base = s.serverUrl;
      if (!base.startsWith('http')) base = 'http://$base';
      if (base.endsWith('/')) base = base.substring(0, base.length - 1);
      final res = await http.get(Uri.parse('$base/api/ping')).timeout(const Duration(seconds: 8));
      _testResult = res.statusCode == 200 ? 'Terhubung ke server' : 'Server menjawab HTTP ${res.statusCode}';
    } catch (e) {
      _testResult = 'Tidak terhubung (tidak ada jaringan atau alamat salah)';
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Pengaturan')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _section('Pengguna'),
            TextField(
              controller: _user,
              decoration: const InputDecoration(labelText: 'Nama petugas'),
              onSubmitted: (v) => s.update(userName: v),
              onTapOutside: (_) => s.update(userName: _user.text),
            ),
            _section('Format koordinat'),
            SegmentedButton<CoordFormat>(
              segments: const [
                ButtonSegment(value: CoordFormat.utm, label: Text('UTM')),
                ButtonSegment(value: CoordFormat.decimal, label: Text('Desimal')),
                ButtonSegment(value: CoordFormat.dms, label: Text('DMS')),
              ],
              selected: {s.coordFormat},
              onSelectionChanged: (v) => s.update(coordFormat: v.first),
            ),
            _section('GPS'),
            Text('Rata-rata ${s.avgReadings} bacaan per titik'),
            Slider(
              value: s.avgReadings.toDouble(),
              min: 5,
              max: 60,
              divisions: 11,
              label: '${s.avgReadings}',
              onChanged: (v) => s.update(avgReadings: v.round()),
            ),
            Text('Buang bacaan dengan akurasi lebih buruk dari ${s.maxAccuracy.toStringAsFixed(0)} m'),
            Slider(
              value: s.maxAccuracy,
              min: 5,
              max: 100,
              divisions: 19,
              label: '${s.maxAccuracy.toStringAsFixed(0)} m',
              onChanged: (v) => s.update(maxAccuracy: v),
            ),
            _section('Sinkronisasi'),
            TextField(
              controller: _server,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Alamat server',
                hintText: 'http://192.168.1.10:8080',
              ),
              onSubmitted: (v) => s.update(serverUrl: v),
            ),
            const SizedBox(height: 8),
            Row(children: [
              OutlinedButton(onPressed: _testing ? null : _testServer, child: const Text('Simpan & uji koneksi')),
              const SizedBox(width: 12),
              if (_testing) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              if (_testResult != null) Expanded(child: Text(_testResult!, style: const TextStyle(fontSize: 13))),
            ]),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Kirim otomatis saat aplikasi dibuka'),
              value: s.autoSync,
              onChanged: (v) => s.update(autoSync: v),
            ),
            _section('Peta dasar'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Peta dasar online (OpenStreetMap)'),
              subtitle: const Text('Hanya tampil bila ada internet. Di kebun tanpa sinyal, pakai peta offline.'),
              value: s.onlineBaseMap,
              onChanged: (v) => s.update(onlineBaseMap: v),
            ),
            _section('Perangkat'),
            SelectableText('ID perangkat: ${s.deviceId}', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            const SizedBox(height: 4),
            const Text('FA Maps v0.1.0 · peta offline kebun · komponen open source',
                style: TextStyle(fontSize: 12, color: AppColors.muted)),
          ],
        ),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
        child: Text(t.toUpperCase(),
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.muted, letterSpacing: 0.5)),
      );
}
