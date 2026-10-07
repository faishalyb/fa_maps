#!/usr/bin/env python3
"""
Server sinkronisasi CONTOH untuk FA Maps (hanya Python standar,
tanpa instalasi paket). Untuk uji coba di laptop/server kantor estate.

Menjalankan:
    python sync_server.py --port 8080 --data ./server_data
Lalu di HP: Pengaturan > Alamat server = http://<IP-laptop>:8080

Endpoint:
    GET  /api/ping                    cek koneksi
    POST /api/sync/features           kirim temuan (idempoten per UUID)
    POST /api/sync/tracks             kirim track
    GET  /api/features.geojson        semua temuan (buka di QGIS)
    GET  /api/tracks.geojson          semua track
    GET  /photos/<nama-file>          foto temuan
    GET  /                            ringkasan

Produksi: ganti dengan API FastAPI/Spring + PostgreSQL/PostGIS + penyimpanan
objek (MinIO) dan SSO (Keycloak), sesuai spesifikasi bagian 4, 8, 10.
Kontrak JSON di sini sama, jadi aplikasi HP tidak perlu diubah.
"""
import argparse
import base64
import json
import os
import re
import sqlite3
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()
DATA_DIR = "server_data"
MAX_BODY = 200 * 1024 * 1024  # 200 MB per permintaan (foto base64)


def db():
    con = sqlite3.connect(os.path.join(DATA_DIR, "server.db"))
    con.row_factory = sqlite3.Row
    return con


def init_db():
    os.makedirs(os.path.join(DATA_DIR, "photos"), exist_ok=True)
    with db() as con:
        con.executescript("""
        CREATE TABLE IF NOT EXISTS features (
            id TEXT PRIMARY KEY, device_id TEXT, user TEXT,
            type_id TEXT, type_label TEXT, lon REAL, lat REAL,
            attributes TEXT, notes TEXT, block TEXT, accuracy REAL, readings INTEGER,
            position_source TEXT, map_id TEXT, created_by TEXT,
            created_at TEXT, updated_at TEXT, deleted INTEGER, received_at TEXT);
        CREATE TABLE IF NOT EXISTS photos (
            id INTEGER PRIMARY KEY AUTOINCREMENT, feature_id TEXT, filename TEXT, path TEXT,
            UNIQUE(feature_id, filename));
        CREATE TABLE IF NOT EXISTS tracks (
            id TEXT PRIMARY KEY, device_id TEXT, user TEXT, name TEXT,
            started_at TEXT, ended_at TEXT, distance_m REAL, points TEXT, received_at TEXT);
        """)


def now():
    return datetime.now(timezone.utc).isoformat()


SAFE = re.compile(r"[^A-Za-z0-9._-]")


class Handler(BaseHTTPRequestHandler):
    server_version = "FAMapsSync/0.1"

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _json(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n <= 0 or n > MAX_BODY:
            raise ValueError("ukuran body tidak valid")
        return json.loads(self.rfile.read(n))

    # ------------------------------------------------------------- GET
    def do_GET(self):
        if self.path == "/api/ping":
            return self._send(200, {"ok": True, "time": now()})
        if self.path == "/api/features.geojson":
            with db() as con:
                rows = con.execute("SELECT * FROM features WHERE deleted = 0").fetchall()
                fc = {"type": "FeatureCollection", "features": [{
                    "type": "Feature",
                    "geometry": {"type": "Point", "coordinates": [r["lon"], r["lat"]]},
                    "properties": {
                        "id": r["id"], "jenis": r["type_label"], "blok": r["block"],
                        "akurasi_m": r["accuracy"], "catatan": r["notes"], "dibuat": r["created_at"],
                        "oleh": r["created_by"], "perangkat": r["device_id"],
                        **json.loads(r["attributes"] or "{}"),
                        "foto": [f"/photos/{p['filename']}" for p in con.execute(
                            "SELECT filename FROM photos WHERE feature_id = ?", (r["id"],))],
                    }} for r in rows]}
            return self._send(200, fc, "application/geo+json")
        if self.path == "/api/tracks.geojson":
            with db() as con:
                rows = con.execute("SELECT * FROM tracks").fetchall()
            fc = {"type": "FeatureCollection", "features": [{
                "type": "Feature",
                "geometry": {"type": "LineString",
                             "coordinates": [[p[0], p[1]] for p in json.loads(r["points"] or "[]")]},
                "properties": {"id": r["id"], "nama": r["name"], "mulai": r["started_at"],
                               "selesai": r["ended_at"], "jarak_m": r["distance_m"], "oleh": r["user"]},
            } for r in rows]}
            return self._send(200, fc, "application/geo+json")
        if self.path.startswith("/photos/"):
            name = SAFE.sub("", self.path[len("/photos/"):])
            path = os.path.join(DATA_DIR, "photos", name)
            if os.path.isfile(path):
                with open(path, "rb") as fh:
                    return self._send(200, fh.read(), "image/jpeg")
            return self._send(404, {"error": "tidak ada"})
        if self.path == "/":
            with db() as con:
                nf = con.execute("SELECT COUNT(*) FROM features WHERE deleted = 0").fetchone()[0]
                nt = con.execute("SELECT COUNT(*) FROM tracks").fetchone()[0]
                np_ = con.execute("SELECT COUNT(*) FROM photos").fetchone()[0]
            html = (f"<h1>Server sinkronisasi FA Maps</h1><p>{nf} temuan, {np_} foto, {nt} track.</p>"
                    "<p><a href='/api/features.geojson'>features.geojson</a> · "
                    "<a href='/api/tracks.geojson'>tracks.geojson</a></p>")
            return self._send(200, html.encode(), "text/html; charset=utf-8")
        return self._send(404, {"error": "tidak ada"})

    # ------------------------------------------------------------- POST
    def do_POST(self):
        try:
            body = self._json()
        except Exception as e:  # noqa: BLE001
            return self._send(400, {"error": f"JSON tidak valid: {e}"})
        if self.path == "/api/sync/features":
            return self._features(body)
        if self.path == "/api/sync/tracks":
            return self._tracks(body)
        return self._send(404, {"error": "tidak ada"})

    def _features(self, body):
        accepted, rejected = [], []
        with LOCK, db() as con:
            for f in body.get("features", []):
                try:
                    lon, lat = f["geometry"]["coordinates"][:2]
                    con.execute("""
                        INSERT INTO features VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                        ON CONFLICT(id) DO UPDATE SET
                          attributes=excluded.attributes, notes=excluded.notes, block=excluded.block,
                          lon=excluded.lon, lat=excluded.lat, accuracy=excluded.accuracy,
                          updated_at=excluded.updated_at, deleted=excluded.deleted, received_at=excluded.received_at
                        WHERE excluded.updated_at >= features.updated_at
                    """, (f["id"], body.get("device_id"), body.get("user"), f.get("type_id"), f.get("type_label"),
                          float(lon), float(lat), json.dumps(f.get("attributes") or {}, ensure_ascii=False),
                          f.get("notes"), f.get("block"), f.get("accuracy"), f.get("readings"),
                          f.get("position_source"), f.get("map_id"), f.get("created_by"),
                          f.get("created_at"), f.get("updated_at"), 1 if f.get("deleted") else 0, now()))
                    for ph in f.get("photos") or []:
                        fname = SAFE.sub("", f"{f['id'][:8]}_{ph.get('filename', 'foto.jpg')}")
                        path = os.path.join(DATA_DIR, "photos", fname)
                        if not os.path.exists(path):
                            with open(path, "wb") as fh:
                                fh.write(base64.b64decode(ph["data_base64"]))
                        con.execute("INSERT OR IGNORE INTO photos (feature_id, filename, path) VALUES (?,?,?)",
                                    (f["id"], fname, path))
                    accepted.append(f["id"])
                except Exception as e:  # noqa: BLE001
                    print("ditolak:", f.get("id"), e)
                    rejected.append(f.get("id"))
        print(f"[{now()}] {body.get('user')} ({body.get('device_id', '')[:8]}): "
              f"{len(accepted)} temuan diterima, {len(rejected)} ditolak")
        return self._send(200, {"accepted": accepted, "rejected": rejected})

    def _tracks(self, body):
        accepted = []
        with LOCK, db() as con:
            for t in body.get("tracks", []):
                con.execute("INSERT OR REPLACE INTO tracks VALUES (?,?,?,?,?,?,?,?,?)",
                            (t["id"], body.get("device_id"), body.get("user"), t.get("name"),
                             t.get("started_at"), t.get("ended_at"), t.get("distance_m"),
                             json.dumps(t.get("points") or []), now()))
                accepted.append(t["id"])
        print(f"[{now()}] {body.get('user')}: {len(accepted)} track diterima")
        return self._send(200, {"accepted": accepted})

    def log_message(self, fmt, *args):  # ringkas
        pass


def main():
    global DATA_DIR
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument("--data", default="server_data")
    a = ap.parse_args()
    DATA_DIR = a.data
    init_db()
    print(f"Server sinkronisasi berjalan di http://{a.host}:{a.port}  (data: {os.path.abspath(DATA_DIR)})")
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
