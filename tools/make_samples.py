#!/usr/bin/env python3
"""
Membuat data peta CONTOH di sekitar Central Park, Jakarta Barat.

Keluaran (folder ../samples dan ../assets/samples):
  - central_park_uji.tif      GeoTIFF, WGS 84 / UTM 48S (EPSG:32748), 1 m/piksel
  - central_park_uji.pdf      Geospatial PDF (ISO 32000, dictionary /VP + /Measure /GEO)
  - central_park_uji.mbtiles  Paket tile offline (Web Mercator, zoom 13-18)
  - blok_uji_central_park.geojson  Poligon "blok uji" (fiktif) untuk lapisan referensi

PENTING: ini PETA UJI SINTETIS. Isinya grid UTM, cincin jarak, penanda lokasi
Central Park, dan blok uji fiktif. BUKAN peta jalan/bangunan sebenarnya.
Tujuannya menguji alur impor, georeferensi, dan posisi GPS di lokasi nyata.

Hanya butuh Python 3 + Pillow + numpy (tanpa GDAL).
"""
import io
import json
import math
import os
import sqlite3
import struct

import numpy as np
from PIL import Image, ImageDraw, ImageFont, TiffImagePlugin

# --------------------------------------------------------------------------
# Lokasi acuan: Central Park Jakarta (Wikipedia: 6.177745 S, 106.791015 E)
# --------------------------------------------------------------------------
CENTER_LAT = -6.177745
CENTER_LON = 106.791015
ZONE = 48            # UTM zona 48, belahan selatan -> EPSG:32748
EPSG = 32748
EXTENT_M = 1700      # luas peta 1,7 x 1,7 km
RES = 1.0            # meter per piksel

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIRS = [os.path.join(ROOT, "samples"), os.path.join(ROOT, "assets", "samples")]

FONT_DIR = "/usr/share/fonts/truetype/dejavu/"


def font(size, bold=False):
    name = "DejaVuSans-Bold.ttf" if bold else "DejaVuSans.ttf"
    try:
        return ImageFont.truetype(os.path.join(FONT_DIR, name), size)
    except OSError:
        return ImageFont.load_default()


# --------------------------------------------------------------------------
# UTM WGS84 (rumus Snyder, "Map Projections - A Working Manual", 1987)
# --------------------------------------------------------------------------
A = 6378137.0
F = 1 / 298.257223563
E2 = F * (2 - F)
EP2 = E2 / (1 - E2)
K0 = 0.9996
LON0 = math.radians(-183 + 6 * ZONE)
FN = 10_000_000.0  # false northing belahan selatan
FE = 500_000.0


def _m(phi):
    e4, e6 = E2 * E2, E2 * E2 * E2
    return A * ((1 - E2 / 4 - 3 * e4 / 64 - 5 * e6 / 256) * phi
                - (3 * E2 / 8 + 3 * e4 / 32 + 45 * e6 / 1024) * np.sin(2 * phi)
                + (15 * e4 / 256 + 45 * e6 / 1024) * np.sin(4 * phi)
                - (35 * e6 / 3072) * np.sin(6 * phi))


def ll_to_utm(lat, lon):
    phi = np.radians(lat)
    lam = np.radians(lon)
    n = A / np.sqrt(1 - E2 * np.sin(phi) ** 2)
    t = np.tan(phi) ** 2
    c = EP2 * np.cos(phi) ** 2
    a_ = np.cos(phi) * (lam - LON0)
    m = _m(phi)
    x = K0 * n * (a_ + (1 - t + c) * a_ ** 3 / 6
                  + (5 - 18 * t + t * t + 72 * c - 58 * EP2) * a_ ** 5 / 120) + FE
    y = K0 * (m + n * np.tan(phi) * (a_ ** 2 / 2
                                     + (5 - t + 9 * c + 4 * c * c) * a_ ** 4 / 24
                                     + (61 - 58 * t + t * t + 600 * c - 330 * EP2) * a_ ** 6 / 720)) + FN
    return x, y


def utm_to_ll(x, y):
    x = np.asarray(x, dtype=float) - FE
    y = np.asarray(y, dtype=float) - FN
    m = y / K0
    e4, e6 = E2 * E2, E2 * E2 * E2
    mu = m / (A * (1 - E2 / 4 - 3 * e4 / 64 - 5 * e6 / 256))
    e1 = (1 - math.sqrt(1 - E2)) / (1 + math.sqrt(1 - E2))
    phi1 = (mu + (3 * e1 / 2 - 27 * e1 ** 3 / 32) * np.sin(2 * mu)
            + (21 * e1 ** 2 / 16 - 55 * e1 ** 4 / 32) * np.sin(4 * mu)
            + (151 * e1 ** 3 / 96) * np.sin(6 * mu)
            + (1097 * e1 ** 4 / 512) * np.sin(8 * mu))
    n1 = A / np.sqrt(1 - E2 * np.sin(phi1) ** 2)
    t1 = np.tan(phi1) ** 2
    c1 = EP2 * np.cos(phi1) ** 2
    r1 = A * (1 - E2) / (1 - E2 * np.sin(phi1) ** 2) ** 1.5
    d = x / (n1 * K0)
    lat = phi1 - (n1 * np.tan(phi1) / r1) * (
        d * d / 2 - (5 + 3 * t1 + 10 * c1 - 4 * c1 * c1 - 9 * EP2) * d ** 4 / 24
        + (61 + 90 * t1 + 298 * c1 + 45 * t1 * t1 - 252 * EP2 - 3 * c1 * c1) * d ** 6 / 720)
    lon = LON0 + (d - (1 + 2 * t1 + c1) * d ** 3 / 6
                  + (5 - 2 * c1 + 28 * t1 - 3 * c1 * c1 + 8 * EP2 + 24 * t1 * t1) * d ** 5 / 120) / np.cos(phi1)
    return np.degrees(lat), np.degrees(lon)


# --------------------------------------------------------------------------
# 1. Gambar peta uji dalam ruang UTM (1 piksel = 1 m)
# --------------------------------------------------------------------------
def build_map():
    ec, nc = ll_to_utm(CENTER_LAT, CENTER_LON)
    ec, nc = float(ec), float(nc)
    e0 = math.floor((ec - EXTENT_M / 2) / 50) * 50
    n_top = math.ceil((nc + EXTENT_M / 2) / 50) * 50
    w = h = int(EXTENT_M / RES)

    def px(e, n):
        return (e - e0) / RES, (n_top - n) / RES

    img = Image.new("RGB", (w, h), (230, 237, 218))
    d = ImageDraw.Draw(img)

    # Blok uji (fiktif): 300 x 250 m, jalan 20 m
    blocks = []
    bw, bh, road = 300, 250, 20
    cols = "ABCDEF"
    gx0 = e0 + 10
    gy0 = n_top - 10
    for r in range(7):
        for c in range(6):
            be0 = gx0 + c * (bw + road)
            bn1 = gy0 - r * (bh + road)
            be1 = min(be0 + bw, e0 + EXTENT_M - 10)
            bn0 = max(bn1 - bh, n_top - EXTENT_M + 10)
            if be1 - be0 < 60 or bn1 - bn0 < 60:
                continue
            name = f"UJI-{cols[c]}{r + 1}"
            fill = (205, 219, 186) if (r + c) % 2 == 0 else (214, 226, 196)
            x0, y0 = px(be0, bn1)
            x1, y1 = px(be1, bn0)
            d.rectangle([x0, y0, x1, y1], fill=fill, outline=(150, 170, 132), width=2)
            # titik "pokok" dekoratif tiap 9 m
            for yy in range(int(y0) + 8, int(y1) - 4, 9):
                for xx in range(int(x0) + 8, int(x1) - 4, 9):
                    d.point((xx, yy), fill=(176, 196, 156))
            blocks.append((name, be0, bn0, be1, bn1))

    # Grid UTM: tiap 100 m tipis, tiap 500 m tebal
    for e in range(int(math.ceil(e0 / 100) * 100), int(e0 + EXTENT_M) + 1, 100):
        x, _ = px(e, n_top)
        thick = e % 500 == 0
        d.line([(x, 0), (x, h)], fill=(120, 140, 160) if thick else (170, 185, 200), width=2 if thick else 1)
    for n in range(int(math.ceil((n_top - EXTENT_M) / 100) * 100), int(n_top) + 1, 100):
        _, y = px(e0, n)
        thick = n % 500 == 0
        d.line([(0, y), (w, y)], fill=(120, 140, 160) if thick else (170, 185, 200), width=2 if thick else 1)

    # Label grid 500 m
    f_grid = font(18)
    for e in range(int(math.ceil(e0 / 500) * 500), int(e0 + EXTENT_M) + 1, 500):
        x, _ = px(e, n_top)
        d.text((x + 4, h - 26), f"E {e:,}".replace(",", " "), fill=(40, 60, 80), font=f_grid)
    for n in range(int(math.ceil((n_top - EXTENT_M) / 500) * 500), int(n_top) + 1, 500):
        _, y = px(e0, n)
        d.text((6, y + 4), f"N {n:,}".replace(",", " "), fill=(40, 60, 80), font=f_grid)

    # Label blok
    f_blk = font(20, bold=True)
    for name, be0, bn0, be1, bn1 in blocks:
        cx, cy = px((be0 + be1) / 2, (bn0 + bn1) / 2)
        tw = d.textlength(name, font=f_blk)
        d.text((cx - tw / 2, cy - 12), name, fill=(70, 90, 60), font=f_blk)

    # Cincin jarak 100/250/500 m dari Central Park
    cx, cy = px(ec, nc)
    for rad in (100, 200, 500):
        rr = rad / RES
        d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], outline=(31, 95, 191), width=3)
        d.text((cx + rr * 0.72 + 6, cy - rr * 0.72 - 6), f"{rad} m", fill=(31, 95, 191), font=font(20, bold=True))

    # Penanda Central Park
    d.ellipse([cx - 16, cy - 16, cx + 16, cy + 16], fill=(180, 83, 26), outline=(255, 255, 255), width=4)
    d.line([(cx - 34, cy), (cx + 34, cy)], fill=(120, 40, 10), width=3)
    d.line([(cx, cy - 34), (cx, cy + 34)], fill=(120, 40, 10), width=3)
    lbl = "Central Park (titik acuan)"
    f_lbl = font(26, bold=True)
    tw = d.textlength(lbl, font=f_lbl)
    d.rectangle([cx + 24, cy - 60, cx + 40 + tw, cy - 24], fill=(255, 255, 255), outline=(180, 83, 26), width=2)
    d.text((cx + 32, cy - 57), lbl, fill=(120, 40, 10), font=f_lbl)
    d.text((cx + 26, cy + 22), "6.177745 S, 106.791015 E", fill=(120, 40, 10), font=font(20))

    # Kotak judul di dalam peta
    title = "PETA UJI SINTETIS - bukan peta jalan/bangunan sebenarnya"
    sub = "WGS 84 / UTM 48S (EPSG:32748) - 1 m/piksel - grid 100 m"
    d.rectangle([16, 16, 16 + 860, 96], fill=(255, 255, 255), outline=(22, 32, 26), width=2)
    d.text((28, 24), title, fill=(22, 32, 26), font=font(26, bold=True))
    d.text((28, 60), sub, fill=(60, 70, 64), font=font(20))

    # Panah utara (grid)
    nx, ny = w - 70, 130
    d.polygon([(nx, ny - 60), (nx - 22, ny), (nx + 22, ny)], fill=(22, 32, 26))
    d.text((nx - 9, ny + 4), "U", fill=(22, 32, 26), font=font(26, bold=True))

    # Skala batang 200 m
    sx, sy = w - 290, h - 70
    for i in range(4):
        col = (22, 32, 26) if i % 2 == 0 else (255, 255, 255)
        d.rectangle([sx + i * 50, sy, sx + (i + 1) * 50, sy + 14], fill=col, outline=(22, 32, 26))
    d.text((sx, sy + 18), "0", fill=(22, 32, 26), font=font(18))
    d.text((sx + 170, sy + 18), "200 m", fill=(22, 32, 26), font=font(18))

    return img, e0, n_top, ec, nc, blocks


# --------------------------------------------------------------------------
# 2. GeoTIFF
# --------------------------------------------------------------------------
def write_geotiff(img, e0, n_top, path):
    ifd = TiffImagePlugin.ImageFileDirectory_v2()
    ifd[33550] = (RES, RES, 0.0)                      # ModelPixelScaleTag
    ifd.tagtype[33550] = 12                           # DOUBLE
    ifd[33922] = (0.0, 0.0, 0.0, float(e0), float(n_top), 0.0)  # ModelTiepointTag
    ifd.tagtype[33922] = 12
    # GeoKeyDirectory: versi 1.1.0, 4 key (urut naik)
    geokeys = (1, 1, 0, 4,
               1024, 0, 1, 1,      # GTModelTypeGeoKey = Projected
               1025, 0, 1, 1,      # GTRasterTypeGeoKey = PixelIsArea
               3072, 0, 1, EPSG,   # ProjectedCSTypeGeoKey = 32748
               3076, 0, 1, 9001)   # ProjLinearUnitsGeoKey = metre
    ifd[34735] = geokeys
    ifd.tagtype[34735] = 3                            # SHORT
    ifd[305] = "FA Maps - make_samples.py"  # Software
    img.save(path, format="TIFF", tiffinfo=ifd)


def read_geotiff_tags(path):
    """Parser minimal (logika yang sama dipakai di lib/core/geotiff.dart)."""
    with open(path, "rb") as fh:
        data = fh.read()
    bo = "<" if data[:2] == b"II" else ">"
    assert struct.unpack(bo + "H", data[2:4])[0] == 42
    off = struct.unpack(bo + "I", data[4:8])[0]
    n = struct.unpack(bo + "H", data[off:off + 2])[0]
    sizes = {1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 11: 4, 12: 8, 16: 8}
    fmt = {1: "B", 2: "c", 3: "H", 4: "I", 7: "B", 11: "f", 12: "d"}
    tags = {}
    for i in range(n):
        p = off + 2 + i * 12
        tag, typ, cnt = struct.unpack(bo + "HHI", data[p:p + 8])
        size = sizes.get(typ, 1) * cnt
        vp = p + 8 if size <= 4 else struct.unpack(bo + "I", data[p + 8:p + 12])[0]
        if typ in fmt and typ != 2:
            tags[tag] = struct.unpack(bo + fmt[typ] * cnt, data[vp:vp + size])
        elif typ == 2:
            tags[tag] = data[vp:vp + cnt].rstrip(b"\0").decode("latin-1")
    return tags


# --------------------------------------------------------------------------
# 3. Geospatial PDF (ISO 32000 / OGC best practice: /VP + /Measure /GEO)
# --------------------------------------------------------------------------
WKT_32748 = ('PROJCS["WGS 84 / UTM zone 48S",GEOGCS["WGS 84",DATUM["WGS_1984",'
             'SPHEROID["WGS 84",6378137,298.257223563,AUTHORITY["EPSG","7030"]],AUTHORITY["EPSG","6326"]],'
             'PRIMEM["Greenwich",0,AUTHORITY["EPSG","8901"]],UNIT["degree",0.0174532925199433,AUTHORITY["EPSG","9122"]],'
             'AUTHORITY["EPSG","4326"]],PROJECTION["Transverse_Mercator"],PARAMETER["latitude_of_origin",0],'
             'PARAMETER["central_meridian",105],PARAMETER["scale_factor",0.9996],PARAMETER["false_easting",500000],'
             'PARAMETER["false_northing",10000000],UNIT["metre",1,AUTHORITY["EPSG","9001"]],'
             'AXIS["Easting",EAST],AXIS["Northing",NORTH],AUTHORITY["EPSG","32748"]]')


def write_geopdf(map_img, e0, n_top, path):
    dpi = 150
    ml, mr, mt, mb = 60, 60, 130, 230           # margin halaman (piksel)
    mw, mh = map_img.size
    page = Image.new("RGB", (ml + mw + mr, mt + mh + mb), (255, 255, 255))
    page.paste(map_img, (ml, mt))
    d = ImageDraw.Draw(page)
    d.rectangle([ml - 2, mt - 2, ml + mw + 1, mt + mh + 1], outline=(22, 32, 26), width=3)
    d.text((ml, 30), "PETA UJI - Sekitar Central Park, Jakarta Barat", fill=(22, 32, 26), font=font(40, bold=True))
    d.text((ml, 84), "Contoh Geospatial PDF untuk aplikasi FA Maps (data sintetis)",
           fill=(80, 90, 84), font=font(24))
    ly = mt + mh + 30
    legend = [
        "Sistem koordinat : WGS 84 / UTM zona 48S (EPSG:32748)",
        "Grid             : 100 m (garis tipis), 500 m (garis tebal)",
        "Lingkaran biru   : jarak 100 / 200 / 500 m dari titik acuan Central Park",
        "Blok UJI-xx      : blok fiktif untuk uji pencatatan data, bukan batas nyata",
        "Frame peta       : hanya area di dalam bingkai yang bergeoreferensi",
    ]
    for i, line in enumerate(legend):
        d.text((ml, ly + i * 34), line, fill=(40, 50, 44), font=ImageFont.truetype(FONT_DIR + "DejaVuSansMono.ttf", 22))

    jpg = io.BytesIO()
    page.save(jpg, format="JPEG", quality=88)
    jpg = jpg.getvalue()

    s = 72.0 / dpi
    pw, ph = page.size[0] * s, page.size[1] * s
    # BBox frame peta dalam koordinat halaman PDF (asal kiri bawah)
    bx0, by0 = ml * s, mb * s
    bx1, by1 = (ml + mw) * s, (mb + mh) * s

    # Sudut frame (piksel tepi) -> UTM -> lat/lon. Urutan LPTS: BL, TL, TR, BR
    e1, n_bot = e0 + mw * RES, n_top - mh * RES
    corners_utm = [(e0, n_bot), (e0, n_top), (e1, n_top), (e1, n_bot)]
    gpts = []
    for e, n in corners_utm:
        la, lo = utm_to_ll(e, n)
        gpts += [float(la), float(lo)]
    lpts = [0, 0, 0, 1, 1, 1, 1, 0]

    def num(v):
        return ("%.10f" % v).rstrip("0").rstrip(".")

    objs = []
    objs.append("<< /Type /Catalog /Pages 2 0 R >>")
    objs.append("<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objs.append(
        f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {num(pw)} {num(ph)}] "
        f"/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R /VP [6 0 R] >>")
    objs.append(None)  # 4: image (stream biner)
    content = f"q {num(pw)} 0 0 {num(ph)} 0 0 cm /Im0 Do Q".encode()
    objs.append(None)  # 5: content stream
    objs.append(
        f"<< /Type /Viewport /Name (Peta utama) /BBox [{num(bx0)} {num(by0)} {num(bx1)} {num(by1)}] "
        f"/Measure 7 0 R >>")
    objs.append(
        "<< /Type /Measure /Subtype /GEO /Bounds [0 0 0 1 1 1 1 0] "
        f"/GPTS [{' '.join(num(v) for v in gpts)}] /LPTS [{' '.join(str(v) for v in lpts)}] "
        "/GCS 8 0 R /PDU [/M /SQM /DEG] >>")
    objs.append(f"<< /Type /PROJCS /EPSG {EPSG} /WKT ({WKT_32748}) >>")

    out = io.BytesIO()
    out.write(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = []
    for i, o in enumerate(objs, start=1):
        offsets.append(out.tell())
        out.write(f"{i} 0 obj\n".encode())
        if i == 4:
            out.write(f"<< /Type /XObject /Subtype /Image /Width {page.size[0]} /Height {page.size[1]} "
                      f"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length {len(jpg)} >>\nstream\n".encode())
            out.write(jpg)
            out.write(b"\nendstream")
        elif i == 5:
            out.write(f"<< /Length {len(content)} >>\nstream\n".encode())
            out.write(content)
            out.write(b"\nendstream")
        else:
            out.write(o.encode())
        out.write(b"\nendobj\n")
    xref = out.tell()
    out.write(f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode())
    for o in offsets:
        out.write(f"{o:010d} 00000 n \n".encode())
    out.write(f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode())
    with open(path, "wb") as fh:
        fh.write(out.getvalue())
    return gpts


# --------------------------------------------------------------------------
# 4. MBTiles (Web Mercator) hasil proyeksi ulang dari raster UTM
# --------------------------------------------------------------------------
def lonlat_to_tile(lon, lat, z):
    n = 2 ** z
    x = (lon + 180) / 360 * n
    y = (1 - math.log(math.tan(math.radians(lat)) + 1 / math.cos(math.radians(lat))) / math.pi) / 2 * n
    return x, y


def write_mbtiles(map_img, e0, n_top, path, zmin=13, zmax=18):
    src = np.asarray(map_img.convert("RGB"))
    hpx, wpx = src.shape[:2]
    e1, n_bot = e0 + wpx * RES, n_top - hpx * RES
    lats, lons = utm_to_ll(np.array([e0, e0, e1, e1]), np.array([n_bot, n_top, n_top, n_bot]))
    west, east = float(lons.min()), float(lons.max())
    south, north = float(lats.min()), float(lats.max())

    if os.path.exists(path):
        os.remove(path)
    db = sqlite3.connect(path)
    db.executescript("""
        CREATE TABLE metadata (name TEXT, value TEXT);
        CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB);
        CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row);
    """)
    meta = {
        "name": "Peta uji Central Park",
        "format": "png",
        "type": "overlay",
        "version": "1",
        "description": "Peta uji sintetis sekitar Central Park, Jakarta Barat. Bukan peta jalan/bangunan.",
        "attribution": "Data sintetis - FA Maps",
        "bounds": f"{west:.7f},{south:.7f},{east:.7f},{north:.7f}",
        "center": f"{CENTER_LON},{CENTER_LAT},16",
        "minzoom": str(zmin),
        "maxzoom": str(zmax),
        "source_crs": f"EPSG:{EPSG}",
        "map_version": "1",
    }
    db.executemany("INSERT INTO metadata VALUES (?, ?)", meta.items())

    count = 0
    for z in range(zmin, zmax + 1):
        # resolusi tile (m/piksel) di lintang ini; pilih sumber yang sudah diperkecil
        res_z = 156543.03392 * math.cos(math.radians(CENTER_LAT)) / 2 ** z
        factor = max(1, int(res_z / RES))
        level = src if factor == 1 else np.asarray(
            map_img.resize((wpx // factor, hpx // factor), Image.LANCZOS).convert("RGB"))
        lres = RES * factor
        lh, lw = level.shape[:2]

        tx0, ty0 = lonlat_to_tile(west, north, z)
        tx1, ty1 = lonlat_to_tile(east, south, z)
        for tx in range(int(tx0), int(tx1) + 1):
            for ty in range(int(ty0), int(ty1) + 1):
                # pusat piksel tile -> lon/lat (Web Mercator)
                jj, ii = np.meshgrid(np.arange(256) + 0.5, np.arange(256) + 0.5)
                n = 2 ** z
                lon = (tx + jj / 256) / n * 360 - 180
                yy = (ty + ii / 256) / n
                lat = np.degrees(np.arctan(np.sinh(np.pi * (1 - 2 * yy))))
                e, nn = ll_to_utm(lat, lon)
                col = (e - e0) / lres
                row = (n_top - nn) / lres
                inside = (col >= 0) & (col < lw) & (row >= 0) & (row < lh)
                if not inside.any():
                    continue
                c = np.clip(col.astype(int), 0, lw - 1)
                r = np.clip(row.astype(int), 0, lh - 1)
                rgba = np.zeros((256, 256, 4), dtype=np.uint8)
                rgba[..., :3] = level[r, c]
                rgba[..., 3] = np.where(inside, 255, 0)
                buf = io.BytesIO()
                Image.fromarray(rgba, "RGBA").save(buf, format="PNG", optimize=True)
                tms_y = (2 ** z - 1) - ty
                db.execute("INSERT INTO tiles VALUES (?, ?, ?, ?)", (z, tx, tms_y, buf.getvalue()))
                count += 1
    db.commit()
    db.close()
    return count, (west, south, east, north)


# --------------------------------------------------------------------------
# 5. GeoJSON blok uji
# --------------------------------------------------------------------------
def write_blocks_geojson(blocks, path):
    feats = []
    for name, be0, bn0, be1, bn1 in blocks:
        es = np.array([be0, be1, be1, be0, be0], dtype=float)
        ns = np.array([bn0, bn0, bn1, bn1, bn0], dtype=float)
        la, lo = utm_to_ll(es, ns)
        ring = [[round(float(x), 7), round(float(y), 7)] for x, y in zip(lo, la)]
        feats.append({
            "type": "Feature",
            "properties": {"blok": name, "afdeling": "AFD-UJI", "estate": "Estate Uji Central Park",
                           "luas_ha": round((be1 - be0) * (bn1 - bn0) / 10000, 2), "keterangan": "Blok fiktif untuk uji"},
            "geometry": {"type": "Polygon", "coordinates": [ring]},
        })
    with open(path, "w") as fh:
        json.dump({"type": "FeatureCollection", "name": "blok_uji_central_park", "features": feats}, fh, indent=1)


def main():
    img, e0, n_top, ec, nc, blocks = build_map()
    for out in OUT_DIRS:
        os.makedirs(out, exist_ok=True)

    tif = os.path.join(OUT_DIRS[0], "central_park_uji.tif")
    write_geotiff(img, e0, n_top, tif)
    pdf = os.path.join(OUT_DIRS[0], "central_park_uji.pdf")
    gpts = write_geopdf(img, e0, n_top, pdf)
    mbt = os.path.join(OUT_DIRS[0], "central_park_uji.mbtiles")
    count, bounds = write_mbtiles(img, e0, n_top, mbt)
    gj = os.path.join(OUT_DIRS[0], "blok_uji_central_park.geojson")
    write_blocks_geojson(blocks, gj)

    # salin ke assets aplikasi
    import shutil
    for name in ("central_park_uji.tif", "central_park_uji.mbtiles", "blok_uji_central_park.geojson"):
        shutil.copy(os.path.join(OUT_DIRS[0], name), os.path.join(OUT_DIRS[1], name))

    print(f"Pusat UTM 48S       : E {ec:.2f}  N {nc:.2f}")
    print(f"Pojok kiri atas     : E {e0}  N {n_top}  (ukuran {img.size[0]} x {img.size[1]} px)")
    print(f"MBTiles             : {count} tile, bounds {bounds}")
    print(f"GeoPDF GPTS         : {gpts}")
    print(f"Blok uji            : {len(blocks)}")


if __name__ == "__main__":
    main()
