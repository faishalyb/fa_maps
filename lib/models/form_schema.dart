/// Skema formulir temuan lapangan.
///
/// Di produksi skema ini dikirim dari server (tabel form_schema, lihat
/// spesifikasi bagian 8). Untuk versi ini skema bawaan didefinisikan di kode
/// agar aplikasi langsung bisa dipakai offline.
enum FieldType { choice, integer, decimal, text }

class FieldDef {
  const FieldDef(this.key, this.label, this.type, {this.options = const [], this.required = false, this.unit});
  final String key;
  final String label;
  final FieldType type;
  final List<String> options;
  final bool required;
  final String? unit;
}

class FindingType {
  const FindingType(this.id, this.label, this.fields, {this.minPhotos = 0});
  final String id;
  final String label;
  final List<FieldDef> fields;
  final int minPhotos;
}

class FormSchema {
  static const List<String> _level = ['Ringan', 'Sedang', 'Berat'];

  static const List<FindingType> types = [
    FindingType('ganoderma', 'Ganoderma', [
      FieldDef('tingkat', 'Tingkat serangan', FieldType.choice, options: _level, required: true),
      FieldDef('pokok_terdampak', 'Pokok terdampak', FieldType.integer, required: true, unit: 'pokok'),
      FieldDef('baris', 'Nomor baris', FieldType.text),
    ], minPhotos: 1),
    FindingType('ulat_api', 'Ulat api', [
      FieldDef('tingkat', 'Tingkat serangan', FieldType.choice, options: _level, required: true),
      FieldDef('ulat_per_pelepah', 'Ulat per pelepah', FieldType.decimal, unit: 'ekor'),
    ], minPhotos: 1),
    FindingType('jalan_rusak', 'Jalan rusak', [
      FieldDef('kondisi', 'Kondisi', FieldType.choice,
          options: ['Berlubang', 'Longsor', 'Tergenang', 'Jembatan rusak'], required: true),
      FieldDef('panjang_m', 'Perkiraan panjang', FieldType.decimal, unit: 'm'),
    ], minPhotos: 1),
    FindingType('banjir', 'Banjir / genangan', [
      FieldDef('kedalaman_cm', 'Kedalaman', FieldType.integer, unit: 'cm'),
      FieldDef('luas_perkiraan', 'Perkiraan luas', FieldType.choice,
          options: ['< 0,5 ha', '0,5 - 2 ha', '> 2 ha']),
    ]),
    FindingType('pokok_tumbang', 'Pokok tumbang', [
      FieldDef('jumlah', 'Jumlah', FieldType.integer, required: true, unit: 'pokok'),
    ]),
    FindingType('lainnya', 'Lainnya', [
      FieldDef('judul', 'Judul temuan', FieldType.text, required: true),
    ]),
  ];

  static FindingType byId(String id) =>
      types.firstWhere((t) => t.id == id, orElse: () => types.last);
}
