# FA Maps

Peta offline untuk perkebunan.

Aplikasi Flutter sejenis Avenza Maps untuk area perkebunan **tanpa sinyal seluler**. Aplikasi ini mengikuti dokumen *Spesifikasi Teknis Aplikasi Peta Offline Perkebunan* dan memakai komponen open source berlisensi permisif.

Fitur utama:

- Menampilkan peta offline dari paket **MBTiles** atau file **GeoTIFF** yang diimpor langsung di HP.
- Menampilkan posisi GPS, akurasi, kompas, koordinat UTM, dan blok tempat pengguna berada.
- Mencatat temuan (titik, atribut, foto) dengan rata-rata GPS, merekam track, serta mengukur jarak dan luas.
- Semua data disimpan di **SQLite**. Data dikirim ke server saat online, dan bisa diekspor ke KML, GPX, GeoJSON, atau CSV.
- GeoPDF diubah dulu menjadi MBTiles oleh tim GIS dengan `tools/convert_map.py` (GDAL).

> **Status:** kode ini **belum dikompilasi**. Lingkungan tempat kode ini ditulis tidak bisa mengunduh Flutter SDK. Yang sudah diperiksa di sana: sintaks semua 28 file Dart (tree-sitter), rumus proyeksi dan data contoh (Python), serta server sinkronisasi (uji kirim–terima). Jalankan `flutter analyze` dan `flutter test` di komputer Anda sebagai langkah pertama. Bila ada perbedaan API karena versi paket, perbaikannya biasanya kecil.

---

## 1. Menjalankan pertama kali

Prasyarat:

- Flutter 3.35 atau lebih baru.
- Android Studio (SDK Android 34 ke atas) atau Xcode untuk iOS.

```bash
cd fa_maps

# membuat folder platform (android/ios) tanpa menimpa file yang sudah ada
flutter create . --org com.perusahaan --project-name fa_maps --platforms android,ios

flutter pub get
flutter analyze
flutter test          # uji proyeksi, parser GeoTIFF, format koordinat
flutter run           # HP Android tersambung kabel USB (mode developer aktif)
```

`flutter create .` tidak menimpa `lib/`, `test/`, maupun `android/app/src/main/AndroidManifest.xml` yang sudah berisi izin GPS. Bila Anda membuat proyek baru lalu menyalin `lib/`, salin juga manifest tersebut.

### Membuat APK tanpa memasang Flutter (GitHub Actions, gratis)

1. Buat repositori baru di GitHub (boleh privat), lalu unggah seluruh isi folder ini, termasuk folder `.github/`.
2. Buka tab **Actions**, pilih **Build APK FA Maps**, lalu klik **Run workflow**.
3. Tunggu ±10 menit sampai build selesai (tanda centang hijau). Buka hasil build dan unduh **FA-Maps-apk** di bagian *Artifacts*. Isinya file `.apk`.
4. Salin APK ke HP Android, buka, lalu izinkan **Instal aplikasi tidak dikenal** bila diminta.

APK ditandatangani dengan kunci debug: cukup untuk uji coba, tidak untuk Play Store.

### Pengaturan iOS (bila dipakai)

Tambahkan entri berikut ke `ios/Runner/Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Menampilkan posisi Anda di peta kebun dan mencatat lokasi temuan.</string>
<key>NSLocationAlwaysAndWhenInUseUsageDescription</key>
<string>Merekam track patroli saat layar terkunci.</string>
<key>NSCameraUsageDescription</key>
<string>Mengambil foto temuan lapangan.</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>Memilih foto temuan dari galeri.</string>
<key>UIBackgroundModes</key>
<array><string>location</string></array>
<key>UIFileSharingEnabled</key><true/>
<key>LSSupportsOpeningDocumentsInPlace</key><true/>
```

Lalu jalankan `cd ios && pod install`.

---

## 2. Mencoba dengan data contoh Central Park

Folder `samples/` dan `assets/samples/` berisi **peta uji sintetis** di sekitar Central Park, Jakarta Barat. Titik acuannya 6,177745°LS dan 106,791015°BT, dengan cakupan 1,7 × 1,7 km.

| File | Isi |
| --- | --- |
| `central_park_uji.tif` | GeoTIFF, WGS 84 / UTM 48S (EPSG:32748), 1 m/piksel |
| `central_park_uji.pdf` | Geospatial PDF (ISO 32000: `/VP` + `/Measure /GEO`), lengkap dengan margin dan legenda |
| `central_park_uji.mbtiles` | Paket offline zoom 13–18 (226 tile) |
| `blok_uji_central_park.geojson` | 42 poligon "blok uji" (UJI-A1 … UJI-F7) |

**Penting:** isi peta uji adalah grid UTM 100 m, lingkaran jarak 100/200/500 m dari titik acuan, dan blok **fiktif**. Peta ini **bukan** peta jalan atau bangunan sebenarnya. Fungsinya untuk menguji alur impor, georeferensi, dan posisi GPS di lokasi nyata.

Data dibuat ulang dengan `python3 tools/make_samples.py` (butuh Python, Pillow, numpy; tidak butuh GDAL). Untuk peta jalan/bangunan asli, ekspor dari QGIS (misalnya lapisan OpenStreetMap atau citra drone) ke GeoTIFF/GeoPDF, lalu konversi dengan langkah 4.

Langkah uji:

1. Buka aplikasi, lalu pilih **Peta saya → Muat data contoh Central Park**. MBTiles, GeoTIFF, dan blok uji langsung terimpor.
2. Aktifkan **mode pesawat** (GPS tetap jalan tanpa sinyal).
3. Di layar **Peta**, posisi Anda muncul sebagai titik biru dengan lingkaran akurasi.
   - Bila berada di sekitar Central Park, panel bawah menampilkan blok uji tempat Anda berdiri.
   - Bila di tempat lain, muncul peringatan "di luar batas peta".
   - Di emulator Android: *Extended controls → Location*, isi -6.177745, 106.791015.
4. **Tambah titik**: GPS dirata-rata, blok terisi otomatis, lalu isi jenis temuan, foto, dan catatan, kemudian **Simpan di HP**.
5. **Rekam track** → berjalan → **Selesai**.
6. **Ukur**: ketuk beberapa titik di peta untuk melihat jarak, keliling, dan luas.
7. **Cari blok**: ketik `c4` di kolom pencarian, lalu pilih **Mulai navigasi**. Rute biru menyusuri pinggir blok menuju bendera di tengah blok. Bila Anda keluar rute lebih dari 40 m, rute dihitung ulang otomatis.
8. Di **Peta saya**, matikan MBTiles dan nyalakan GeoTIFF. Peta yang sama tampil dari jalur impor GeoTIFF di HP. Penanda Central Park harus berada di posisi yang sama.

---

## 3. Struktur proyek

```
lib/
  main.dart, app.dart          Inisialisasi, tema, navigasi bawah, sinkron otomatis
  core/
    db.dart                    Skema SQLite (maps, ref_layers, features, attachments, tracks, track_points)
    projection.dart            WGS 84, Web Mercator, UTM semua zona, DGN95 TM-3 (tanpa pustaka luar)
    geotiff.dart               Pembaca tag GeoTIFF + impor di isolate (decode → JPEG + 4 sudut)
    mbtiles.dart               Pembaca MBTiles + TileProvider flutter_map
    geo.dart                   Jarak, luas (UTM + shoelace), arah, titik-dalam-poligon, format koordinat
    routing.dart               Rute susur pinggir blok: jaringan dari sisi poligon + penyeberangan jalan, Dijkstra
    settings.dart, format.dart
  models/                      MapPackage, ReferenceLayer, FieldFeature, TrackRecord, FormSchema
  services/
    map_repository.dart        Impor .mbtiles / .tif / .geojson, data contoh, katalog
    location_service.dart      Satu aliran GPS + kompas, GpsAverager (rata-rata + buang pencilan)
    track_recorder.dart        Rekam track (foreground service Android), tulis tiap titik ke SQLite
    feature_repository.dart    Simpan temuan + foto (transaksi), antrean sinkron
    sync_service.dart          Kirim antrean ke server (idempoten per UUID)
    navigation_service.dart    Tujuan blok, rute, kemajuan, hitung ulang, deteksi tiba
    export_service.dart        KML, GPX, GeoJSON, CSV + bagikan
  screens/                     Peta, Peta saya, Temuan baru, Data lapangan, Pengaturan
tools/
  make_samples.py              Generator data contoh (GeoTIFF, GeoPDF, MBTiles, GeoJSON)
  convert_map.py               GeoPDF/GeoTIFF → MBTiles dengan GDAL (untuk tim GIS / portal)
  sync_server.py               Server sinkronisasi contoh (Python standar, tanpa instalasi)
samples/                       Data contoh Central Park (termasuk GeoPDF)
assets/samples/                Salinan data contoh yang dibundel ke aplikasi
test/                          Unit test proyeksi, GeoTIFF, geometri, format
```

---

## 4. Mengonversi GeoPDF / GeoTIFF menjadi MBTiles (tim GIS)

Pasang GDAL (gratis):

- Windows: lewat OSGeo4W atau QGIS.
- Ubuntu: `apt install gdal-bin`.
- macOS: `brew install gdal`.

```bash
python tools/convert_map.py samples/central_park_uji.pdf -o central_park.mbtiles --name "Peta uji Central Park"
python tools/convert_map.py peta_blok_afd03.pdf --dpi 300 --name "Peta blok AFD-03" --version 4
python tools/convert_map.py ortho_drone.tif --format JPEG --quality 85
```

Skrip ini menjalankan tahapan bagian 6 spesifikasi secara berurutan:

1. Validasi CRS.
2. Rasterisasi PDF, lalu potong ke neatline (bingkai peta).
3. Reproyeksi ke EPSG:3857.
4. Tiling dan pembuatan piramida zoom.
5. Pengisian metadata (nama, versi, CRS sumber).
6. Uji titik kontrol.

Hasil `.mbtiles` disalin ke HP (kabel USB, Google Drive, dan sebagainya) lalu diimpor di **Peta saya → Impor file**. Di produksi, langkah ini diganti portal web.

---

## 5. Server sinkronisasi (uji coba)

```bash
python tools/sync_server.py --port 8080 --data ./server_data
```

- Di HP, buka **Pengaturan → Alamat server**, isi `http://<IP-laptop>:8080`, lalu ketuk **Simpan & uji koneksi**. HP dan laptop harus di jaringan Wi-Fi yang sama.
- Data terkirim saat menekan **Kirim** di layar Data, atau otomatis saat aplikasi dibuka.
- Hasil di server:
  - `http://<IP>:8080/api/features.geojson` (temuan; bisa dibuka langsung di QGIS)
  - `http://<IP>:8080/api/tracks.geojson` (track)
  - Foto tersimpan di `server_data/photos/`.

Kontrak JSON (`POST /api/sync/features`, `/api/sync/tracks`) sama dengan rancangan produksi. Server contoh ini nanti bisa diganti FastAPI/Spring + PostGIS + MinIO + Keycloak tanpa mengubah aplikasi HP.

---

## 6. Pemetaan ke spesifikasi

| Kode | Fitur | Status di versi ini |
| --- | --- | --- |
| F-01, F-02 | Katalog dan unduh peta | Katalog lokal + impor file. Unduhan dari portal: tahap berikut |
| F-03 | Tampilan peta, lapisan, transparansi | Ada |
| F-04, F-05 | Posisi GPS, akurasi, kompas, UTM/DMS/desimal, peringatan di luar peta | Ada |
| F-06, F-07, F-10 | Temuan + rata-rata GPS + formulir + foto wajib | Ada (skema formulir bawaan di kode) |
| F-08 | Rekam track di latar belakang | Ada (foreground service Android) |
| F-09 | Ukur jarak dan luas | Ada |
| F-11 | Sinkronisasi offline-first | Ada (antrean per data, idempoten) |
| F-12 | Ekspor KML, GPX, CSV, GeoJSON | Ada |
| F-13 | Impor vektor | GeoJSON (poligon/garis) sebagai lapisan referensi + deteksi blok otomatis |
| F-15 | Cari blok | Ada: pencocokan longgar ("c4", "UJI C4", "uji-c04"), daftar pilihan bila lebih dari satu, penanda di titik tengah blok |
| F-16 | Impor GeoTIFF di HP | Ada (UTM, TM-3, WGS 84, Web Mercator; maks. 4096 px setelah diperkecil) |
| F-14 | Navigasi ke blok | Ada: rute menyusuri pinggiran blok (bawaan) atau garis lurus, panah arah, sisa jarak, belokan berikutnya, hitung ulang otomatis bila keluar rute > 40 m, notifikasi tiba di tengah blok |
| F-17, F-18, F-19 | GNSS Bluetooth, penugasan, GeoPDF di HP | Tahap berikut |

## 7. Catatan teknis dan langkah berikutnya

- **Proyeksi peta:** tampilan memakai Web Mercator. GeoTIFF UTM ditampilkan dengan 3 sudut (`RotatedOverlayImage`). Untuk area sampai beberapa kilometer, galatnya jauh di bawah 1 piksel. Untuk area sangat luas, gunakan jalur MBTiles.
- **Keamanan (bagian 9):** ganti `sqflite` dengan `sqflite_sqlcipher` agar database terenkripsi. Tambahkan juga login SSO (Keycloak/OIDC) + PIN offline, distribusi lewat MDM, dan HTTPS. Setelah HTTPS aktif, hapus `usesCleartextTraffic`.
- **Ukuran aplikasi:** data contoh di `assets/samples/` menambah ±10 MB. Hapus dari `pubspec.yaml` untuk build produksi.
- **GeoTIFF besar:** di HP, GeoTIFF dibaca utuh ke memori lalu diperkecil. File di atas ±100 MB atau berkompresi JPEG sebaiknya dikonversi ke MBTiles lewat `convert_map.py`.
- **Lisensi:** semua paket Dart berlisensi MIT/BSD/Apache. GDAL (MIT) hanya dipakai di sisi server. Server contoh hanya memakai pustaka standar Python.
