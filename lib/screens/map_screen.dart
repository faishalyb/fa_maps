import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart' hide Path;

import '../app.dart';
import '../core/format.dart';
import '../core/geo.dart';
import '../core/mbtiles.dart';
import '../core/settings.dart';
import '../models/field_feature.dart';
import '../models/map_package.dart';
import '../services/feature_repository.dart';
import '../services/location_service.dart';
import '../services/map_focus.dart';
import '../services/map_repository.dart';
import '../models/reference_layer.dart';
import '../services/navigation_service.dart';
import '../services/track_recorder.dart';
import 'feature_detail_sheet.dart';
import 'feature_form_screen.dart';

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, required this.onOpenCatalog});
  final VoidCallback onOpenCatalog;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  final _search = TextEditingController();
  final Map<String, MbTilesArchive> _archives = {};
  // Provider disimpan agar TileLayer tidak memuat ulang tile tiap kali layar dibangun ulang.
  final Map<String, MbTilesTileProvider> _providers = {};
  final Set<String> _opening = {};
  StreamSubscription<Position>? _posSub;
  Timer? _ticker;

  bool _ready = false;
  bool _follow = false;
  bool _measuring = false;
  final List<LatLng> _measure = [];
  double _rotation = 0;
  int _lastMapCount = 0;
  bool _arrivedShown = false;

  @override
  void initState() {
    super.initState();
    LocationService.instance.start();
    _posSub = LocationService.instance.positions.listen((p) {
      if (_follow && _ready) _map.move(LatLng(p.latitude, p.longitude), _map.camera.zoom);
    });
    MapFocus.request.addListener(_onFocusRequest);
    MapRepository.instance.addListener(_onMapsChanged);
    TrackRecorder.instance.addListener(_onTrackChanged);
    NavigationService.instance.addListener(_onNavChanged);
    _lastMapCount = MapRepository.instance.visibleMaps.length;
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _ticker?.cancel();
    MapFocus.request.removeListener(_onFocusRequest);
    MapRepository.instance.removeListener(_onMapsChanged);
    TrackRecorder.instance.removeListener(_onTrackChanged);
    NavigationService.instance.removeListener(_onNavChanged);
    _search.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- events

  void _onTrackChanged() {
    final rec = TrackRecorder.instance.recording;
    if (rec && _ticker == null) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else if (!rec) {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _onMapsChanged() {
    final n = MapRepository.instance.visibleMaps.length;
    if (_lastMapCount == 0 && n > 0) _fitTo(MapRepository.instance.visibleMaps.last.bounds);
    _lastMapCount = n;
  }

  void _onFocusRequest() {
    final r = MapFocus.request.value;
    if (r == null || !_ready) return;
    if (r.bounds != null) _fitTo(r.bounds!);
    if (r.point != null) _map.move(r.point!, r.zoom);
    _follow = false;
  }

  void _fitTo(LatLngBounds b) {
    if (!_ready) return;
    _map.fitCamera(CameraFit.bounds(bounds: b, padding: const EdgeInsets.fromLTRB(32, 140, 32, 260)));
  }

  void _onMapReady() {
    _ready = true;
    final maps = MapRepository.instance.visibleMaps;
    if (maps.isNotEmpty) {
      _fitTo(maps.last.bounds);
    } else if (LocationService.instance.latLng != null) {
      _map.move(LocationService.instance.latLng!, 16);
    }
    _onFocusRequest();
  }

  void _onTap(LatLng p) {
    if (_measuring) setState(() => _measure.add(p));
  }

  Future<void> _onLongPress(LatLng p) async {
    if (_measuring) return;
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => FeatureFormScreen(manualPoint: p)));
  }

  void _centerOnMe() {
    final ll = LocationService.instance.latLng;
    if (ll == null) {
      _snack(LocationService.instance.error ?? 'Menunggu sinyal GPS… pastikan berada di tempat terbuka.');
      LocationService.instance.start();
      return;
    }
    setState(() => _follow = true);
    _map.move(ll, math.max(_map.camera.zoom, 17));
  }

  Future<void> _searchBlock(String q) async {
    final query = q.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    final repo = MapRepository.instance;
    if (repo.refLayers.where((l) => l.visible).isEmpty) {
      _snack('Belum ada lapisan batas blok. Impor GeoJSON blok di menu Peta saya.');
      return;
    }
    final hits = repo.findBlocks(query);
    if (hits.isEmpty) {
      _snack('Blok "$query" tidak ditemukan');
      return;
    }
    RefPolygon? pick = hits.length == 1 ? hits.first : null;
    pick ??= await showModalBottomSheet<RefPolygon>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('${hits.length} blok cocok dengan "$query"',
                style: const TextStyle(fontWeight: FontWeight.w600)),
          ),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final h in hits.take(50))
                ListTile(
                  leading: const Icon(Icons.pentagon_outlined, color: AppColors.greenDark),
                  title: Text(h.label),
                  subtitle: Text(_blockSubtitle(h)),
                  onTap: () => Navigator.pop(ctx, h),
                ),
            ]),
          ),
        ]),
      ),
    );
    if (pick != null) _selectBlock(pick);
  }

  String _blockSubtitle(RefPolygon b) {
    final here = LocationService.instance.latLng;
    final parts = <String>[];
    final afd = b.properties['afdeling'];
    if (afd != null) parts.add('$afd');
    if (here != null) {
      parts.add('${Geo.formatDistance(Geo.distance(here, b.centerPoint))} '
          'ke ${Geo.compassName(Geo.bearing(here, b.centerPoint))}');
    }
    return parts.join(' · ');
  }

  void _selectBlock(RefPolygon b) {
    NavigationService.instance.setTarget(b);
    _search.text = b.label;
    final bb = b.bounds;
    const pad = 0.0004;
    _fitTo(LatLngBounds(LatLng(bb.south - pad, bb.west - pad), LatLng(bb.north + pad, bb.east + pad)));
    setState(() {
      _follow = false;
      _measuring = false;
    });
  }

  Future<void> _startNavigation() async {
    await NavigationService.instance.start();
    if (!mounted) return;
    setState(() => _follow = true);
    final ll = LocationService.instance.latLng;
    if (ll != null) _map.move(ll, math.max(_map.camera.zoom, 17));
  }

  void _onNavChanged() {
    final nav = NavigationService.instance;
    if (nav.arrived && !_arrivedShown) {
      _arrivedShown = true;
      _snack('Anda sudah tiba di tengah Blok ${nav.target?.label ?? ''}');
    } else if (!nav.arrived) {
      _arrivedShown = false;
    }
  }

  Future<void> _startTrack() async {
    final ctrl = TextEditingController(text: 'Track ${fmtDateTime(DateTime.now())}');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Mulai rekam track'),
        content: TextField(controller: ctrl, decoration: const InputDecoration(labelText: 'Nama track')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Batal')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('Mulai')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    await TrackRecorder.instance.start(name);
    setState(() => _follow = true);
  }

  Future<void> _stopTrack() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Selesai merekam?'),
        content: const Text('Track disimpan di HP dan dikirim ke server saat online.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Lanjut merekam')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Selesai')),
        ],
      ),
    );
    if (ok == true) {
      await TrackRecorder.instance.stop();
      _snack('Track disimpan');
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ---------------------------------------------------------------- layers

  Widget _mapLayer(MapPackage m) {
    if (m.kind == MapKind.mbtiles) {
      final a = _archives[m.path];
      if (a == null) {
        if (_opening.add(m.path)) {
          MbTilesArchive.open(m.path).then((x) {
            _opening.remove(m.path);
            if (mounted) setState(() => _archives[m.path] = x);
          });
        }
        return const SizedBox.shrink();
      }
      return Opacity(
        key: ValueKey('mb-${m.id}'),
        opacity: m.opacity,
        child: TileLayer(
          tileProvider: _providers.putIfAbsent(m.path, () => MbTilesTileProvider(a)),
          minNativeZoom: m.minZoom ?? 0,
          maxNativeZoom: m.maxZoom ?? 19,
          minZoom: math.max(0, (m.minZoom ?? 0) - 3).toDouble(),
          maxZoom: 22,
          keepBuffer: 3,
        ),
      );
    }
    final c = m.corners!;
    return OverlayImageLayer(
      key: ValueKey('rs-${m.id}'),
      overlayImages: [
        RotatedOverlayImage(
          topLeftCorner: c[0],
          bottomLeftCorner: c[1],
          bottomRightCorner: c[2],
          opacity: m.opacity,
          imageProvider: FileImage(File(m.path)),
        ),
      ],
    );
  }

  List<Widget> _layers() {
    final repo = MapRepository.instance;
    final feats = FeatureRepository.instance;
    final rec = TrackRecorder.instance;
    final loc = LocationService.instance;
    _archives.removeWhere((k, _) => !repo.maps.any((m) => m.path == k));
    _providers.removeWhere((k, _) => !_archives.containsKey(k));

    final refPolys = <Polygon>[];
    final refLines = <Polyline>[];
    for (final l in repo.refLayers.where((l) => l.visible)) {
      for (final p in l.polygons) {
        refPolys.add(Polygon(
          points: p.outer,
          color: AppColors.green.withValues(alpha: 0.06),
          borderColor: AppColors.greenDark,
          borderStrokeWidth: 1.5,
          label: p.label,
          labelStyle: const TextStyle(color: AppColors.greenDark, fontWeight: FontWeight.w600, fontSize: 12),
        ));
      }
      for (final ln in l.lines) {
        refLines.add(Polyline(points: ln, color: AppColors.greenDark, strokeWidth: 2));
      }
    }

    final pos = loc.position;
    return [
      if (AppSettings.instance.onlineBaseMap)
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.perusahaan.fa_maps',
          maxNativeZoom: 19,
        ),
      for (final m in repo.visibleMaps) _mapLayer(m),
      if (refPolys.isNotEmpty) PolygonLayer(polygons: refPolys),
      if (refLines.isNotEmpty) PolylineLayer(polylines: refLines),
      PolylineLayer(polylines: [
        for (final pts in feats.trackLines.values)
          if (pts.length > 1) Polyline(points: pts, color: AppColors.orange.withValues(alpha: 0.55), strokeWidth: 3),
        if (rec.points.length > 1) Polyline(points: List.of(rec.points), color: AppColors.orange, strokeWidth: 5),
      ]),
      MarkerLayer(markers: [
        for (final f in feats.features)
          Marker(
            point: f.point,
            width: 30,
            height: 30,
            child: GestureDetector(
              onTap: () => showFeatureDetail(context, f),
              child: _FeatureDot(f),
            ),
          ),
      ]),
      if (_measure.length >= 3)
        PolygonLayer(polygons: [
          Polygon(points: _measure, color: AppColors.orange.withValues(alpha: 0.18), borderColor: AppColors.orange, borderStrokeWidth: 2),
        ]),
      if (_measure.length >= 2)
        PolylineLayer(polylines: [Polyline(points: _measure, color: AppColors.orange, strokeWidth: 3)]),
      if (_measure.isNotEmpty)
        CircleLayer(circles: [
          for (final p in _measure)
            CircleMarker(point: p, radius: 6, color: Colors.white, borderColor: AppColors.orange, borderStrokeWidth: 3),
        ]),
      if (NavigationService.instance.target != null) ...[
        PolygonLayer(polygons: [
          Polygon(
            points: NavigationService.instance.target!.block.outer,
            color: AppColors.orange.withValues(alpha: 0.12),
            borderColor: AppColors.orange,
            borderStrokeWidth: 3,
          ),
        ]),
        if (NavigationService.instance.route.length > 1)
          PolylineLayer(polylines: [
            Polyline(points: NavigationService.instance.route, color: Colors.white, strokeWidth: 10),
            Polyline(points: NavigationService.instance.route, color: AppColors.blue, strokeWidth: 6),
          ]),
        MarkerLayer(markers: [
          Marker(
            point: NavigationService.instance.target!.point,
            width: 46,
            height: 46,
            child: const _TargetPin(),
          ),
        ]),
      ],
      if (pos != null) ...[
        CircleLayer(circles: [
          CircleMarker(
            point: LatLng(pos.latitude, pos.longitude),
            radius: pos.accuracy,
            useRadiusInMeter: true,
            color: AppColors.blue.withValues(alpha: 0.14),
            borderColor: AppColors.blue.withValues(alpha: 0.5),
            borderStrokeWidth: 1,
          ),
        ]),
        MarkerLayer(markers: [
          Marker(
            point: LatLng(pos.latitude, pos.longitude),
            width: 64,
            height: 64,
            child: _LocationDot(heading: loc.heading),
          ),
        ]),
      ],
    ];
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        MapRepository.instance,
        FeatureRepository.instance,
        LocationService.instance,
        TrackRecorder.instance,
        NavigationService.instance,
        AppSettings.instance,
      ]),
      builder: (context, _) {
        return Stack(
          children: [
            FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: const LatLng(-2.5, 118),
                initialZoom: 5,
                minZoom: 3,
                maxZoom: 22,
                backgroundColor: const Color(0xFFDCE6CF),
                onMapReady: _onMapReady,
                onTap: (_, p) => _onTap(p),
                onLongPress: (_, p) => _onLongPress(p),
                onPositionChanged: (camera, hasGesture) {
                  if (hasGesture && _follow) setState(() => _follow = false);
                  if ((camera.rotation - _rotation).abs() > 1) setState(() => _rotation = camera.rotation);
                },
              ),
              children: _layers(),
            ),
            _topBar(),
            _rightControls(),
            Positioned(left: 0, right: 0, bottom: 0, child: _bottomPanel()),
          ],
        );
      },
    );
  }

  Widget _topBar() {
    final repo = MapRepository.instance;
    final rec = TrackRecorder.instance;
    final here = LocationService.instance.latLng;
    final active = here == null ? null : repo.mapAt(here);
    return Positioned(
      left: 12,
      right: 12,
      top: 0,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Row(children: [
              Expanded(
                child: Material(
                  elevation: 3,
                  borderRadius: BorderRadius.circular(12),
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onSubmitted: _searchBlock,
                    decoration: InputDecoration(
                      hintText: 'Cari blok, mis. UJI-C4',
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none),
                      contentPadding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _roundButton(Icons.layers_outlined, 'Peta & lapisan', widget.onOpenCatalog),
            ]),
            const SizedBox(height: 8),
            Wrap(spacing: 6, runSpacing: 6, children: [
              if (rec.recording)
                _chip(rec.paused ? 'Track dijeda' : 'Merekam track', AppColors.orange, Colors.white,
                    icon: Icons.fiber_manual_record),
              if (repo.visibleMaps.isEmpty)
                InkWell(
                  onTap: widget.onOpenCatalog,
                  child: _chip('Belum ada peta · ketuk untuk impor', Colors.white, AppColors.ink, icon: Icons.add),
                )
              else
                _chip(active?.name ?? '${repo.visibleMaps.length} peta aktif', Colors.white, AppColors.ink,
                    icon: Icons.map_outlined),
              if (AppSettings.instance.onlineBaseMap)
                _chip('Peta dasar online', AppColors.blue, Colors.white, icon: Icons.public),
            ]),
          ],
        ),
      ),
    );
  }

  Widget _rightControls() {
    return Positioned(
      right: 12,
      top: 150,
      child: SafeArea(
        child: Column(children: [
          Tooltip(
            message: 'Kompas · ketuk untuk utara di atas',
            child: Material(
              elevation: 3,
              shape: const CircleBorder(),
              color: Colors.white,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _map.rotate(0),
                child: SizedBox(
                  width: 48,
                  height: 48,
                  child: Transform.rotate(
                    angle: _rotation * math.pi / 180,
                    child: const Icon(Icons.navigation, color: AppColors.orange),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          _roundButton(Icons.add, 'Perbesar', () => _map.move(_map.camera.center, _map.camera.zoom + 1)),
          const SizedBox(height: 6),
          _roundButton(Icons.remove, 'Perkecil', () => _map.move(_map.camera.center, _map.camera.zoom - 1)),
          const SizedBox(height: 10),
          _roundButton(
            _follow ? Icons.my_location : Icons.location_searching,
            'Posisi saya',
            _centerOnMe,
            background: _follow ? AppColors.blue : Colors.white,
            foreground: _follow ? Colors.white : AppColors.blue,
          ),
        ]),
      ),
    );
  }

  Widget _bottomPanel() {
    final Widget content;
    if (_measuring) {
      content = _measurePanel();
    } else if (NavigationService.instance.target != null) {
      content = _navPanel();
    } else if (TrackRecorder.instance.recording) {
      content = _trackPanel();
    } else {
      content = _infoPanel();
    }
    return Material(
      elevation: 8,
      color: Colors.white,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
      child: SafeArea(
        top: false,
        child: Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 12), child: content),
      ),
    );
  }

  Widget _infoPanel() {
    final loc = LocationService.instance;
    final pos = loc.position;
    final here = loc.latLng;
    final repo = MapRepository.instance;
    final block = here == null ? null : repo.blockAt(here);
    final outside = here != null && repo.visibleMaps.isNotEmpty && repo.mapAt(here) == null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(here == null ? 'Posisi' : 'Anda berada di',
                  style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              Text(
                here == null ? 'Menunggu GPS…' : (block != null ? 'Blok $block' : 'Di luar blok referensi'),
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              if (here != null)
                Text(Geo.formatCoord(here),
                    style: const TextStyle(fontSize: 12, color: AppColors.muted, fontFamily: 'monospace')),
              if (loc.error != null)
                Text(loc.error!, style: const TextStyle(fontSize: 12, color: AppColors.orange)),
            ]),
          ),
          if (pos != null)
            _chip('GPS ±${pos.accuracy.toStringAsFixed(0)} m',
                pos.accuracy <= 10 ? AppColors.greenSoft : AppColors.orangeSoft,
                pos.accuracy <= 10 ? AppColors.greenDark : const Color(0xFF8A3D10)),
        ]),
        if (outside)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: AppColors.orangeSoft, borderRadius: BorderRadius.circular(8)),
            child: const Row(children: [
              Icon(Icons.warning_amber, size: 18, color: Color(0xFF8A3D10)),
              SizedBox(width: 6),
              Expanded(
                child: Text('Posisi Anda di luar batas peta yang ditampilkan',
                    style: TextStyle(fontSize: 12, color: Color(0xFF6E300B))),
              ),
            ]),
          ),
        const SizedBox(height: 10),
        Row(children: [
          _action(Icons.add_location_alt, 'Tambah titik', primary: true, onTap: () {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FeatureFormScreen()));
          }),
          _action(Icons.fiber_manual_record, 'Rekam track', iconColor: AppColors.orange, onTap: _startTrack),
          _action(Icons.straighten, 'Ukur', onTap: () => setState(() {
                _measuring = true;
                _measure.clear();
                _follow = false;
              })),
          _action(Icons.fit_screen, 'Ke peta', onTap: () {
            final maps = repo.visibleMaps;
            if (maps.isEmpty) {
              widget.onOpenCatalog();
            } else {
              _fitTo(maps.last.bounds);
            }
          }),
        ]),
        const SizedBox(height: 4),
        const Text('Tekan lama di peta untuk menambah titik di lokasi lain',
            style: TextStyle(fontSize: 11, color: AppColors.muted)),
      ],
    );
  }

  Widget _navPanel() {
    final nav = NavigationService.instance;
    final t = nav.target!;
    final here = LocationService.instance.latLng;

    if (nav.active && nav.arrived) {
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.check_circle, color: AppColors.green, size: 32),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Tiba di tengah Blok ${t.label}',
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.add_location_alt),
              label: const Text('Tambah titik'),
              onPressed: () =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FeatureFormScreen())),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: nav.clear, child: const Text('Selesai'))),
        ]),
      ]);
    }

    if (nav.active) {
      final next = nav.nextPoint ?? t.point;
      final b = here == null ? 0.0 : Geo.bearing(here, next);
      final heading = LocationService.instance.heading;
      final rel = heading != null ? b - heading : b + _rotation;
      final turn = nav.nextTurnAngle;
      final String instr;
      if (turn == null) {
        instr = 'Lurus ke titik tengah blok';
      } else if (turn.abs() > 150) {
        instr = 'Putar balik dalam ${Geo.formatDistance(nav.toNextTurn)}';
      } else {
        instr = '${turn > 0 ? 'Belok kanan' : 'Belok kiri'} dalam ${Geo.formatDistance(nav.toNextTurn)}';
      }
      return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(color: AppColors.blue, borderRadius: BorderRadius.circular(14)),
            child: Transform.rotate(
              angle: rel * math.pi / 180,
              child: const Icon(Icons.navigation, color: Colors.white, size: 42),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Menuju Blok ${t.label}', style: const TextStyle(fontSize: 12, color: AppColors.muted)),
              Text('Sisa ${Geo.formatDistance(nav.remaining)}',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
              Text(instr, style: const TextStyle(fontSize: 14)),
            ]),
          ),
        ]),
        if (nav.computing) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
        if (nav.note != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(nav.note!, style: const TextStyle(fontSize: 12, color: AppColors.orange)),
          ),
        if (nav.offRoute > 25 && !nav.computing)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('Anda ${Geo.formatDistance(nav.offRoute)} dari rute',
                style: const TextStyle(fontSize: 12, color: AppColors.muted)),
          ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: OutlinedButton(
              onPressed: () => nav.setMode(
                  nav.mode == RouteMode.blockEdges ? RouteMode.straight : RouteMode.blockEdges),
              child: Text(nav.mode == RouteMode.blockEdges ? 'Garis lurus' : 'Susur blok'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton(
              onPressed: nav.computing ? null : nav.recompute,
              child: const Text('Hitung ulang'),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: nav.clear, child: const Text('Selesai'))),
        ]),
      ]);
    }

    // tujuan dipilih, navigasi belum dimulai
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(
          padding: EdgeInsets.only(top: 4, right: 10),
          child: Icon(Icons.flag, color: AppColors.orange, size: 28),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Blok ${t.label}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            Text('Titik tengah: ${Geo.formatCoord(t.point)}',
                style: const TextStyle(fontSize: 12, color: AppColors.muted, fontFamily: 'monospace')),
            Text(
              here == null
                  ? 'Menunggu GPS untuk menghitung jarak'
                  : 'Garis lurus ${Geo.formatDistance(Geo.distance(here, t.point))} '
                      'ke arah ${Geo.compassName(Geo.bearing(here, t.point))}',
              style: const TextStyle(fontSize: 13),
            ),
          ]),
        ),
        IconButton(tooltip: 'Tutup', icon: const Icon(Icons.close), onPressed: nav.clear),
      ]),
      const SizedBox(height: 8),
      SizedBox(
        width: double.infinity,
        child: SegmentedButton<RouteMode>(
          segments: const [
            ButtonSegment(value: RouteMode.blockEdges, icon: Icon(Icons.alt_route), label: Text('Susur pinggir blok')),
            ButtonSegment(value: RouteMode.straight, icon: Icon(Icons.straight), label: Text('Garis lurus')),
          ],
          selected: {nav.mode},
          onSelectionChanged: (v) => nav.setMode(v.first),
        ),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: double.infinity,
        height: 50,
        child: FilledButton.icon(
          icon: const Icon(Icons.navigation),
          label: const Text('Mulai navigasi', style: TextStyle(fontSize: 16)),
          onPressed: _startNavigation,
        ),
      ),
    ]);
  }

  Widget _trackPanel() {
    final rec = TrackRecorder.instance;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(rec.name, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
      Text(fmtDuration(rec.elapsed),
          style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w600, fontFamily: 'monospace')),
      const SizedBox(height: 6),
      Row(children: [
        _stat('Jarak', Geo.formatDistance(rec.distance)),
        _stat('Titik', '${rec.points.length}'),
        _stat('GPS', LocationService.instance.position == null
            ? '-'
            : '±${LocationService.instance.position!.accuracy.toStringAsFixed(0)} m'),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.add_location_alt),
            label: const Text('Titik'),
            onPressed: () =>
                Navigator.of(context).push(MaterialPageRoute(builder: (_) => const FeatureFormScreen())),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            icon: Icon(rec.paused ? Icons.play_arrow : Icons.pause),
            label: Text(rec.paused ? 'Lanjut' : 'Jeda'),
            onPressed: rec.togglePause,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppColors.orange),
            icon: const Icon(Icons.stop),
            label: const Text('Selesai'),
            onPressed: _stopTrack,
          ),
        ),
      ]),
      const SizedBox(height: 4),
      const Text('Tetap merekam saat layar dikunci', style: TextStyle(fontSize: 11, color: AppColors.muted)),
    ]);
  }

  Widget _measurePanel() {
    final len = Geo.pathLength(_measure);
    final area = _measure.length >= 3 ? Geo.area(_measure) : 0.0;
    final perimeter = _measure.length >= 3 ? len + Geo.distance(_measure.last, _measure.first) : len;
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Mode ukur · ketuk peta untuk menambah titik',
          style: TextStyle(fontSize: 12, color: AppColors.muted)),
      const SizedBox(height: 6),
      Row(children: [
        _stat('Jarak', Geo.formatDistance(len)),
        _stat('Keliling', _measure.length >= 3 ? Geo.formatDistance(perimeter) : '-'),
        _stat('Luas', _measure.length >= 3 ? Geo.formatArea(area) : '-'),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.undo),
            label: const Text('Urungkan'),
            onPressed: _measure.isEmpty ? null : () => setState(() => _measure.removeLast()),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.my_location),
            label: const Text('Titik GPS'),
            onPressed: LocationService.instance.latLng == null
                ? null
                : () => setState(() => _measure.add(LocationService.instance.latLng!)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton(
            onPressed: () => setState(() {
              _measuring = false;
              _measure.clear();
            }),
            child: const Text('Selesai'),
          ),
        ),
      ]),
    ]);
  }

  // ---------------------------------------------------------------- widgets kecil

  Widget _stat(String label, String value) => Expanded(
        child: Container(
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: AppColors.ground, borderRadius: BorderRadius.circular(10)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: const TextStyle(fontSize: 12, color: AppColors.muted)),
            Text(value, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ]),
        ),
      );

  Widget _action(IconData icon, String label,
      {bool primary = false, Color? iconColor, required VoidCallback onTap}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Material(
          color: primary ? AppColors.green : AppColors.ground,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: SizedBox(
              height: 64,
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(icon, color: primary ? Colors.white : (iconColor ?? AppColors.ink)),
                const SizedBox(height: 4),
                Text(label,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 12, fontWeight: FontWeight.w600, color: primary ? Colors.white : AppColors.ink)),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _roundButton(IconData icon, String tooltip, VoidCallback onTap,
      {Color background = Colors.white, Color foreground = AppColors.ink}) {
    return Tooltip(
      message: tooltip,
      child: Material(
        elevation: 3,
        color: background,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: SizedBox(width: 48, height: 48, child: Icon(icon, color: foreground)),
        ),
      ),
    );
  }

  Widget _chip(String text, Color bg, Color fg, {IconData? icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        boxShadow: const [BoxShadow(color: Color(0x22000000), blurRadius: 4)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 14, color: fg), const SizedBox(width: 4)],
        Text(text, style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _FeatureDot extends StatelessWidget {
  const _FeatureDot(this.f);
  final FieldFeature f;

  @override
  Widget build(BuildContext context) {
    final sent = f.syncStatus == SyncStatus.sent;
    return Center(
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(
          color: sent ? AppColors.green : AppColors.orange,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 3)],
        ),
      ),
    );
  }
}

class _LocationDot extends StatelessWidget {
  const _LocationDot({this.heading});
  final double? heading;

  @override
  Widget build(BuildContext context) {
    return Stack(alignment: Alignment.center, children: [
      if (heading != null)
        Transform.rotate(
          angle: heading! * math.pi / 180,
          child: CustomPaint(size: const Size(64, 64), painter: _ConePainter()),
        ),
      Container(
        width: 20,
        height: 20,
        decoration: BoxDecoration(
          color: AppColors.blue,
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 3),
          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
        ),
      ),
    ]);
  }
}

class _ConePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final path = Path()
      ..moveTo(c.dx, c.dy)
      ..lineTo(c.dx - 14, c.dy - 30)
      ..arcToPoint(Offset(c.dx + 14, c.dy - 30), radius: const Radius.circular(32))
      ..close();
    canvas.drawPath(path, Paint()..color = AppColors.blue.withValues(alpha: 0.3));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _TargetPin extends StatelessWidget {
  const _TargetPin();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(color: AppColors.orange, width: 3),
          boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
        ),
        child: const Icon(Icons.flag, color: AppColors.orange, size: 22),
      ),
    );
  }
}
