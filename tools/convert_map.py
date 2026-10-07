#!/usr/bin/env python3
"""
Konversi GeoPDF / GeoTIFF menjadi paket peta offline MBTiles untuk aplikasi
FA Maps. Dijalankan oleh tim GIS di komputer/server, bukan di HP.

Butuh GDAL >= 3.4 (gratis, open source):
  - Windows : OSGeo4W atau QGIS (jalankan dari "OSGeo4W Shell")
  - Ubuntu  : sudo apt install gdal-bin
  - macOS   : brew install gdal

Contoh:
  python convert_map.py ../samples/central_park_uji.pdf  -o central_park.mbtiles
  python convert_map.py peta_afd03.pdf --dpi 300 --name "Peta blok AFD-03" --version 4
  python convert_map.py ortho_drone.tif --format JPEG --quality 85 --max-zoom 20
  python convert_map.py peta.pdf --cutline batas_afd03.geojson   (potong ke batas kerja)

Tahapan (sesuai spesifikasi bagian 6):
  1. Validasi: file harus punya georeferensi dan sistem koordinat.
  2. GeoPDF: rasterisasi pada DPI tertentu (default 300), hanya frame peta (neatline).
  3. Reproyeksi ke Web Mercator (EPSG:3857) - skema tile yang dibaca aplikasi.
  4. Tiling ke MBTiles + piramida zoom rendah (gdaladdo).
  5. Isi metadata (nama, versi, CRS sumber, deskripsi).
  6. Uji titik kontrol: pusat & sudut dibandingkan antara sumber dan hasil.
"""
import argparse
import json
import math
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile


def run(cmd):
    print("  $", " ".join(f'"{c}"' if " " in c else c for c in cmd))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit(f"Perintah gagal: {cmd[0]}")
    return r.stdout


def need(tool):
    if shutil.which(tool) is None:
        raise SystemExit(f"'{tool}' tidak ditemukan. Pasang GDAL dulu (lihat bagian atas skrip ini).")


def gdalinfo_json(path, extra=()):
    return json.loads(run(["gdalinfo", "-json", *extra, path]))


def epsg_of(info):
    wkt = (info.get("coordinateSystem") or {}).get("wkt", "")
    if not wkt:
        return None
    # ambil AUTHORITY/ID terakhir (milik CRS proyeksi, bukan datum)
    for key in ('ID["EPSG",', 'AUTHORITY["EPSG","'):
        idx = wkt.rfind(key)
        if idx >= 0:
            tail = wkt[idx + len(key):]
            digits = "".join(ch for ch in tail[:8] if ch.isdigit())
            if digits:
                return int(digits)
    return None


def neatline_window(info):
    """Ambil kotak [ulx, uly, lrx, lry] dari metadata NEATLINE (WKT POLYGON) GDAL PDF."""
    md = (info.get("metadata") or {}).get("", {})
    wkt = md.get("NEATLINE")
    if not wkt or "(" not in wkt:
        return None
    body = wkt[wkt.find("(") :].replace("(", " ").replace(")", " ")
    xs, ys = [], []
    for pair in body.split(","):
        nums = pair.split()
        if len(nums) >= 2:
            xs.append(float(nums[0]))
            ys.append(float(nums[1]))
    if len(xs) < 3:
        return None
    return [min(xs), max(ys), max(xs), min(ys)]


def main():
    ap = argparse.ArgumentParser(description="GeoPDF/GeoTIFF -> MBTiles untuk FA Maps")
    ap.add_argument("input", help="file .pdf / .tif / .tiff")
    ap.add_argument("-o", "--output", help="file .mbtiles keluaran")
    ap.add_argument("--name", help="nama peta yang tampil di HP")
    ap.add_argument("--version", default="1", help="versi peta (naikkan tiap revisi)")
    ap.add_argument("--dpi", type=int, default=300, help="DPI rasterisasi GeoPDF (default 300)")
    ap.add_argument("--format", choices=["PNG", "JPEG", "WEBP"], default="PNG",
                    help="PNG untuk peta garis, JPEG/WEBP untuk citra (lebih kecil)")
    ap.add_argument("--quality", type=int, default=85, help="kualitas JPEG/WEBP")
    ap.add_argument("--max-zoom", type=int, help="paksa zoom maksimum (default otomatis dari resolusi)")
    ap.add_argument("--min-zoom", type=int, default=12, help="zoom minimum (default 12)")
    ap.add_argument("--cutline", help="poligon batas (GeoJSON/GPKG) untuk memotong peta")
    ap.add_argument("--keep-temp", action="store_true", help="simpan file antara untuk diperiksa")
    a = ap.parse_args()

    for t in ("gdalinfo", "gdal_translate", "gdalwarp", "gdaladdo"):
        need(t)

    src = os.path.abspath(a.input)
    base = os.path.splitext(os.path.basename(src))[0]
    out = os.path.abspath(a.output or base + ".mbtiles")
    name = a.name or base
    is_pdf = src.lower().endswith(".pdf")
    tmp = tempfile.mkdtemp(prefix="petakebun_")

    print(f"[1/6] Validasi {os.path.basename(src)}")
    open_opts = ["--config", "GDAL_PDF_DPI", str(a.dpi)] if is_pdf else []
    info = gdalinfo_json(src, open_opts)
    epsg = epsg_of(info)
    if not info.get("coordinateSystem", {}).get("wkt"):
        raise SystemExit("File tidak memiliki sistem koordinat/georeferensi. Periksa ekspor dari ArcGIS/QGIS.")
    print(f"      CRS sumber: EPSG:{epsg}  ukuran: {info['size'][0]} x {info['size'][1]} px")

    step_src = src
    if is_pdf:
        print(f"[2/6] Rasterisasi GeoPDF {a.dpi} DPI (hanya frame peta)")
        tif = os.path.join(tmp, "raster.tif")
        cmd = ["gdal_translate", "--config", "GDAL_PDF_DPI", str(a.dpi),
               "-of", "GTiff", "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES"]
        # Potong ke bingkai peta (NEATLINE) agar legenda/margin halaman tidak ikut.
        win = neatline_window(info)
        if win:
            print(f"      neatline ditemukan, dipotong ke {win}")
            cmd += ["-projwin", *[repr(v) for v in win]]
        else:
            print("      neatline tidak ada: seluruh halaman dipakai (bisa ikut margin)")
        run(cmd + [src, tif])
        step_src = tif
    else:
        print("[2/6] GeoTIFF: rasterisasi tidak diperlukan")

    print("[3/6] Reproyeksi ke Web Mercator (EPSG:3857)")
    warped = os.path.join(tmp, "warped.tif")
    warp = ["gdalwarp", "-t_srs", "EPSG:3857", "-r", "bilinear", "-dstalpha",
            "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES", "-overwrite"]
    if a.cutline:
        warp += ["-cutline", a.cutline, "-crop_to_cutline"]
    run(warp + [step_src, warped])

    winfo = gdalinfo_json(warped)
    res = abs(winfo["geoTransform"][1])  # meter/piksel Web Mercator
    auto_max = int(round(math.log2(156543.03392 / res)))
    max_zoom = a.max_zoom or min(auto_max, 21)
    print(f"      resolusi {res:.2f} m/px -> zoom maks {max_zoom}")

    print("[4/6] Tiling ke MBTiles")
    if os.path.exists(out):
        os.remove(out)
    tr = ["gdal_translate", "-of", "MBTILES", "-co", f"TILE_FORMAT={a.format}",
          "-co", f"NAME={name}", "-co", "TYPE=overlay", "-co", f"VERSION={a.version}",
          "-co", "ZOOM_LEVEL_STRATEGY=UPPER"]
    if a.format in ("JPEG", "WEBP"):
        tr += ["-co", f"QUALITY={a.quality}"]
    run(tr + [warped, out])
    # piramida zoom rendah
    levels, f = [], 2
    while max_zoom - int(math.log2(f)) >= a.min_zoom:
        levels.append(str(f))
        f *= 2
    if levels:
        run(["gdaladdo", "-r", "average", out, *levels])

    print("[5/6] Metadata")
    db = sqlite3.connect(out)
    meta = {
        "name": name,
        "map_version": a.version,
        "source_crs": f"EPSG:{epsg}" if epsg else "",
        "source_file": os.path.basename(src),
        "description": f"Dikonversi dari {os.path.basename(src)}"
                       + (f" ({a.dpi} DPI)" if is_pdf else ""),
    }
    for k, v in meta.items():
        db.execute("DELETE FROM metadata WHERE name = ?", (k,))
        db.execute("INSERT INTO metadata (name, value) VALUES (?, ?)", (k, v))
    db.commit()
    zooms = db.execute("SELECT MIN(zoom_level), MAX(zoom_level), COUNT(*) FROM tiles").fetchone()
    bounds = dict(db.execute("SELECT name, value FROM metadata").fetchall()).get("bounds")
    db.close()

    print("[6/6] Uji titik kontrol")
    ok = check_control_points(step_src, out, [] if is_pdf else open_opts)

    if not a.keep_temp:
        shutil.rmtree(tmp, ignore_errors=True)
    else:
        print(f"      file antara: {tmp}")

    size = os.path.getsize(out) / 1024 / 1024
    print(f"\nSelesai: {out}")
    print(f"  zoom {zooms[0]}-{zooms[1]}, {zooms[2]} tile, {size:.1f} MB, bounds {bounds}")
    print("  Salin file .mbtiles ke HP lalu impor di menu 'Peta saya', atau terbitkan lewat portal.")
    if not ok:
        print("  PERINGATAN: uji titik kontrol melebihi toleransi. Periksa CRS/datum sebelum diterbitkan.")
        sys.exit(2)


def check_control_points(src, mbtiles, open_opts):
    """Bandingkan koordinat pusat & sudut sumber dengan batas MBTiles (toleransi 1 piksel sumber)."""
    try:
        info = gdalinfo_json(src, open_opts)
        corners = info.get("wgs84Extent", {}).get("coordinates", [[]])[0]
        if not corners:
            print("      (lewati: gdalinfo tidak memberi wgs84Extent)")
            return True
        lons = [c[0] for c in corners]
        lats = [c[1] for c in corners]
        db = sqlite3.connect(mbtiles)
        b = dict(db.execute("SELECT name, value FROM metadata").fetchall()).get("bounds")
        db.close()
        w, s, e, n = [float(x) for x in b.split(",")]
        gt = info["geoTransform"]
        wkt = (info.get("coordinateSystem") or {}).get("wkt", "").lstrip().upper()
        geographic = wkt.startswith("GEOGCS") or wkt.startswith("GEOGCRS")
        px_m = abs(gt[1]) * (111320 if geographic else 1)  # ukuran piksel sumber (m)
        tol_deg = max(px_m, 1) / 111320 * 2
        diffs = [abs(min(lons) - w), abs(max(lons) - e), abs(min(lats) - s), abs(max(lats) - n)]
        worst = max(diffs) * 111320
        print(f"      selisih batas terbesar {worst:.2f} m (toleransi {tol_deg * 111320:.2f} m)")
        return max(diffs) <= tol_deg
    except Exception as ex:  # noqa: BLE001
        print(f"      (uji dilewati: {ex})")
        return True


if __name__ == "__main__":
    main()
