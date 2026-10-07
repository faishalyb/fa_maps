import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Database lokal SQLite. Semua data lapangan ditulis di sini lebih dulu
/// (offline-first); kolom sync_status menandai antrean kirim ke server.
///
/// Untuk produksi: ganti `sqflite` dengan `sqflite_sqlcipher` agar file
/// database terenkripsi (lihat docs/KEAMANAN.md).
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  late Database db;

  Future<void> open() async {
    final dir = await getDatabasesPath();
    db = await openDatabase(
      p.join(dir, 'peta_kebun.db'),
      version: 1,
      onConfigure: (db) async => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, version) async {
        final b = db.batch();
        b.execute('''
          CREATE TABLE maps (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,            -- 'mbtiles' | 'raster'
            path TEXT NOT NULL,            -- file di folder aplikasi
            source_name TEXT,              -- nama file asal
            crs TEXT,                      -- CRS sumber, mis. EPSG:32748
            west REAL, south REAL, east REAL, north REAL,
            min_zoom INTEGER, max_zoom INTEGER,
            corners TEXT,                  -- raster: [[lat,lon] TL, BL, BR, TR]
            size_bytes INTEGER,
            description TEXT,
            map_version TEXT,
            visible INTEGER NOT NULL DEFAULT 1,
            opacity REAL NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL
          )''');
        b.execute('''
          CREATE TABLE ref_layers (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            path TEXT NOT NULL,            -- GeoJSON di folder aplikasi
            label_field TEXT,
            visible INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL
          )''');
        b.execute('''
          CREATE TABLE features (
            id TEXT PRIMARY KEY,           -- UUID dibuat di HP
            type_id TEXT NOT NULL,
            type_label TEXT NOT NULL,
            geometry TEXT NOT NULL,        -- GeoJSON geometry, WGS84
            lat REAL NOT NULL, lon REAL NOT NULL,
            attributes TEXT NOT NULL,      -- JSON
            notes TEXT,
            block TEXT,
            accuracy REAL,
            readings INTEGER,
            position_source TEXT,          -- gps-avg | gps | manual
            map_id TEXT,
            created_by TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            deleted INTEGER NOT NULL DEFAULT 0,
            sync_status TEXT NOT NULL DEFAULT 'pending',  -- pending | sent | failed
            sync_error TEXT
          )''');
        b.execute('CREATE INDEX idx_features_sync ON features(sync_status)');
        b.execute('''
          CREATE TABLE attachments (
            id TEXT PRIMARY KEY,
            feature_id TEXT NOT NULL REFERENCES features(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            size_bytes INTEGER,
            created_at TEXT NOT NULL
          )''');
        b.execute('''
          CREATE TABLE tracks (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            distance_m REAL NOT NULL DEFAULT 0,
            point_count INTEGER NOT NULL DEFAULT 0,
            created_by TEXT,
            sync_status TEXT NOT NULL DEFAULT 'pending',
            sync_error TEXT
          )''');
        b.execute('''
          CREATE TABLE track_points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            track_id TEXT NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
            lat REAL NOT NULL, lon REAL NOT NULL,
            alt REAL, accuracy REAL,
            time TEXT NOT NULL
          )''');
        b.execute('CREATE INDEX idx_track_points ON track_points(track_id)');
        await b.commit(noResult: true);
      },
    );
  }
}
