import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo.dart';

/// Rute "susur pinggir blok": jaringan jalan dibentuk dari sisi-sisi poligon
/// blok (dan garis jalan bila ada di GeoJSON). Sisi blok yang bersebelahan
/// tetapi dipisah jalan (celah <= [maxGap] m) disambung dengan "penyeberangan",
/// lalu jalur terpendek dicari dengan Dijkstra.
///
/// Semua hitungan memakai bidang datar lokal (meter), cukup akurat untuk
/// cakupan sebuah estate (puluhan km).
class RouteResult {
  RouteResult(this.points, this.length, {this.straight = false});
  final List<LatLng> points;
  final double length; // meter
  final bool straight; // true bila terpaksa garis lurus
}

class _P {
  const _P(this.x, this.y);
  final double x, y;
  double dist(_P o) => math.sqrt((x - o.x) * (x - o.x) + (y - o.y) * (y - o.y));
}

class _Seg {
  _Seg(this.a, this.b, this.owner);
  final int a, b, owner;
  final List<({double t, int node})> extra = [];
}

class _Proj {
  const _Proj(this.t, this.q, this.d);
  final double t; // posisi pada segmen 0..1
  final _P q; // titik proyeksi
  final double d; // jarak titik ke segmen
}

_Proj _project(_P p, _P a, _P b) {
  final dx = b.x - a.x, dy = b.y - a.y;
  final l2 = dx * dx + dy * dy;
  var t = l2 == 0 ? 0.0 : ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2;
  t = t.clamp(0.0, 1.0).toDouble();
  final q = _P(a.x + t * dx, a.y + t * dy);
  return _Proj(t, q, p.dist(q));
}

class BlockRouter {
  BlockRouter._(this._lat0, this._lon0, this.mergeTolerance, this.maxGap)
      : _kx = 111320.0 * math.cos(_lat0 * math.pi / 180),
        _ky = 110574.0;

  final double _lat0, _lon0, _kx, _ky;
  final double mergeTolerance;
  final double maxGap;

  final List<_P> _nodes = [];
  final List<Set<int>> _owners = [];
  final List<_Seg> _segs = [];
  late final List<Map<int, double>> _adj;
  final Map<int, List<int>> _nodeGrid = {};
  static const double _nodeCell = 10;

  int get nodeCount => _nodes.length;
  int get edgeCount => _adj.fold(0, (s, m) => s + m.length) ~/ 2;

  _P _xy(LatLng p) => _P((p.longitude - _lon0) * _kx, (p.latitude - _lat0) * _ky);
  LatLng _ll(_P p) => LatLng(_lat0 + p.y / _ky, _lon0 + p.x / _kx);

  /// Membangun jaringan dari poligon blok [rings] dan garis jalan [lines].
  static BlockRouter build(
    List<List<LatLng>> rings, {
    List<List<LatLng>> lines = const [],
    double mergeTolerance = 1.5,
    double maxGap = 40,
  }) {
    final all = [...rings, ...lines].expand((e) => e).toList();
    if (all.isEmpty) throw StateError('Tidak ada poligon blok');
    final lat0 = all.map((e) => e.latitude).reduce((a, b) => a + b) / all.length;
    final lon0 = all.map((e) => e.longitude).reduce((a, b) => a + b) / all.length;
    final r = BlockRouter._(lat0, lon0, mergeTolerance, maxGap);
    var owner = 0;
    for (final ring in rings) {
      final pts = ring.length > 1 && ring.first == ring.last ? ring.sublist(0, ring.length - 1) : ring;
      if (pts.length < 2) continue;
      final ids = [for (final p in pts) r._addNode(r._xy(p), owner)];
      for (var i = 0; i < ids.length; i++) {
        final a = ids[i], b = ids[(i + 1) % ids.length];
        if (a != b) r._segs.add(_Seg(a, b, owner));
      }
      owner++;
    }
    for (final line in lines) {
      final ids = [for (final p in line) r._addNode(r._xy(p), owner)];
      for (var i = 0; i + 1 < ids.length; i++) {
        if (ids[i] != ids[i + 1]) r._segs.add(_Seg(ids[i], ids[i + 1], owner));
      }
      owner++;
    }
    r._connect();
    return r;
  }

  int _cellKey(int cx, int cy) => cx * 1000003 + cy;

  int _addNode(_P p, int owner) {
    final cx = (p.x / _nodeCell).floor(), cy = (p.y / _nodeCell).floor();
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final i in _nodeGrid[_cellKey(cx + dx, cy + dy)] ?? const <int>[]) {
          if (_nodes[i].dist(p) <= mergeTolerance) {
            _owners[i].add(owner);
            return i;
          }
        }
      }
    }
    _nodes.add(p);
    _owners.add({owner});
    _nodeGrid.putIfAbsent(_cellKey(cx, cy), () => []).add(_nodes.length - 1);
    return _nodes.length - 1;
  }

  int? _nearNode(_P p, double tol) {
    final cx = (p.x / _nodeCell).floor(), cy = (p.y / _nodeCell).floor();
    int? best;
    var bd = tol;
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final i in _nodeGrid[_cellKey(cx + dx, cy + dy)] ?? const <int>[]) {
          final d = _nodes[i].dist(p);
          if (d <= bd) {
            bd = d;
            best = i;
          }
        }
      }
    }
    return best;
  }

  /// Sambungkan tiap simpul ke sisi milik blok lain terdekat (<= maxGap),
  /// lalu bentuk daftar ketetanggaan.
  void _connect() {
    final cell = math.max(maxGap, 20.0);
    final segGrid = <int, List<int>>{};
    for (var s = 0; s < _segs.length; s++) {
      final a = _nodes[_segs[s].a], b = _nodes[_segs[s].b];
      final x0 = ((math.min(a.x, b.x) - maxGap) / cell).floor(), x1 = ((math.max(a.x, b.x) + maxGap) / cell).floor();
      final y0 = ((math.min(a.y, b.y) - maxGap) / cell).floor(), y1 = ((math.max(a.y, b.y) + maxGap) / cell).floor();
      for (var cx = x0; cx <= x1; cx++) {
        for (var cy = y0; cy <= y1; cy++) {
          segGrid.putIfAbsent(_cellKey(cx, cy), () => []).add(s);
        }
      }
    }
    final connectors = <(int, int)>[];
    final baseCount = _nodes.length;
    for (var v = 0; v < baseCount; v++) {
      final p = _nodes[v];
      final cands = segGrid[_cellKey((p.x / cell).floor(), (p.y / cell).floor())] ?? const <int>[];
      final best = <int, (double, int, _Proj)>{}; // owner -> (jarak, segmen, proyeksi)
      for (final s in cands) {
        final seg = _segs[s];
        if (_owners[v].contains(seg.owner)) continue;
        final pr = _project(p, _nodes[seg.a], _nodes[seg.b]);
        if (pr.d > maxGap) continue;
        final cur = best[seg.owner];
        if (cur == null || pr.d < cur.$1) best[seg.owner] = (pr.d, s, pr);
      }
      for (final e in best.values) {
        final seg = _segs[e.$2];
        final pr = e.$3;
        int n;
        if (pr.q.dist(_nodes[seg.a]) <= mergeTolerance) {
          n = seg.a;
        } else if (pr.q.dist(_nodes[seg.b]) <= mergeTolerance) {
          n = seg.b;
        } else {
          n = _addNode(pr.q, seg.owner);
          seg.extra.add((t: pr.t, node: n));
        }
        connectors.add((v, n));
      }
    }
    _adj = List.generate(_nodes.length, (_) => <int, double>{});
    for (final s in _segs) {
      final sorted = [...s.extra]..sort((x, y) => x.t.compareTo(y.t));
      final chain = [s.a, ...sorted.map((e) => e.node), s.b];
      for (var i = 0; i + 1 < chain.length; i++) {
        _edge(_adj, chain[i], chain[i + 1]);
      }
    }
    for (final c in connectors) {
      _edge(_adj, c.$1, c.$2);
    }
  }

  void _edge(List<Map<int, double>> adj, int a, int b) {
    if (a == b) return;
    final d = _nodes[a].dist(_nodes[b]);
    final cur = adj[a][b];
    if (cur == null || d < cur) {
      adj[a][b] = d;
      adj[b][a] = d;
    }
  }

  /// Rute dari [start] ke [goal] (titik tengah blok [targetRing]).
  /// Null bila start terlalu jauh (> [maxStartDistance] m) dari jaringan.
  RouteResult? route(LatLng start, LatLng goal, List<LatLng> targetRing, {double maxStartDistance = 1000}) {
    final s0 = _xy(start), g0 = _xy(goal);
    final n = _nodes.length;
    final tmp = <_P>[];
    final extra = <int, Map<int, double>>{};
    int tnode(_P p) {
      tmp.add(p);
      return n + tmp.length - 1;
    }

    _P pos(int i) => i < n ? _nodes[i] : tmp[i - n];
    void te(int a, int b, double d) {
      extra.putIfAbsent(a, () => {})[b] = d;
      extra.putIfAbsent(b, () => {})[a] = d;
    }

    final s = tnode(s0);
    final g = tnode(g0);

    // Start: sambung ke 3 sisi terdekat
    final starts = <(_Proj, _Seg)>[];
    for (final seg in _segs) {
      starts.add((_project(s0, _nodes[seg.a], _nodes[seg.b]), seg));
    }
    starts.sort((x, y) => x.$1.d.compareTo(y.$1.d));
    if (starts.isEmpty || starts.first.$1.d > maxStartDistance) return null;
    for (final e in starts.take(3)) {
      final p = tnode(e.$1.q);
      te(s, p, e.$1.d);
      te(p, e.$2.a, e.$1.q.dist(_nodes[e.$2.a]));
      te(p, e.$2.b, e.$1.q.dist(_nodes[e.$2.b]));
    }

    // Tujuan: masuk blok dari titik terdekat pada tiap sisinya
    final ring = targetRing.length > 1 && targetRing.first == targetRing.last
        ? targetRing.sublist(0, targetRing.length - 1)
        : targetRing;
    final t = ring.map(_xy).toList();
    for (var i = 0; i < t.length; i++) {
      final a = t[i], b = t[(i + 1) % t.length];
      final pr = _project(g0, a, b);
      final p = tnode(pr.q);
      te(p, g, pr.d);
      final na = _nearNode(a, mergeTolerance * 2);
      final nb = _nearNode(b, mergeTolerance * 2);
      if (na != null) te(p, na, pr.q.dist(_nodes[na]));
      if (nb != null) te(p, nb, pr.q.dist(_nodes[nb]));
    }

    // Dijkstra
    final dist = <int, double>{s: 0};
    final prev = <int, int>{};
    final heap = _Heap()..push(0, s);
    while (heap.isNotEmpty) {
      final (d, u) = heap.pop();
      if (u == g) break;
      if (d > (dist[u] ?? double.infinity)) continue;
      void relax(int v, double w) {
        final nd = d + w;
        if (nd < (dist[v] ?? double.infinity)) {
          dist[v] = nd;
          prev[v] = u;
          heap.push(nd, v);
        }
      }

      if (u < n) _adj[u].forEach(relax);
      extra[u]?.forEach(relax);
    }
    if (!dist.containsKey(g)) return null;
    final path = <int>[g];
    while (path.last != s) {
      path.add(prev[path.last]!);
    }
    final pts = path.reversed.map((i) => _ll(pos(i))).toList();
    return RouteResult(_simplify(pts), dist[g]!);
  }

  /// Buang titik yang hampir segaris (< 1 m) agar instruksi belokan bersih.
  static List<LatLng> _simplify(List<LatLng> pts) {
    if (pts.length < 3) return pts;
    final out = <LatLng>[pts.first];
    for (var i = 1; i < pts.length - 1; i++) {
      if (Geo.distance(out.last, pts[i]) < 1) continue;
      out.add(pts[i]);
    }
    out.add(pts.last);
    return out;
  }
}

/// Min-heap sederhana (jarak, simpul).
class _Heap {
  final List<(double, int)> _a = [];
  bool get isNotEmpty => _a.isNotEmpty;

  void push(double k, int v) {
    _a.add((k, v));
    var i = _a.length - 1;
    while (i > 0) {
      final p = (i - 1) >> 1;
      if (_a[p].$1 <= _a[i].$1) break;
      final tmp = _a[p];
      _a[p] = _a[i];
      _a[i] = tmp;
      i = p;
    }
  }

  (double, int) pop() {
    final top = _a.first;
    final last = _a.removeLast();
    if (_a.isNotEmpty) {
      _a[0] = last;
      var i = 0;
      while (true) {
        final l = 2 * i + 1, r = l + 1;
        var m = i;
        if (l < _a.length && _a[l].$1 < _a[m].$1) m = l;
        if (r < _a.length && _a[r].$1 < _a[m].$1) m = r;
        if (m == i) break;
        final tmp = _a[m];
        _a[m] = _a[i];
        _a[i] = tmp;
        i = m;
      }
    }
    return top;
  }
}
