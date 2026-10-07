String _two(int v) => v.toString().padLeft(2, '0');

const _bulan = ['Jan', 'Feb', 'Mar', 'Apr', 'Mei', 'Jun', 'Jul', 'Agu', 'Sep', 'Okt', 'Nov', 'Des'];

/// "07 Okt 2026 09.42"
String fmtDateTime(DateTime d) => '${_two(d.day)} ${_bulan[d.month - 1]} ${d.year} ${_two(d.hour)}.${_two(d.minute)}';

/// "09.42" bila hari ini, selain itu "07 Okt 09.42"
String fmtShort(DateTime d) {
  final now = DateTime.now();
  final today = d.year == now.year && d.month == now.month && d.day == now.day;
  return today ? '${_two(d.hour)}.${_two(d.minute)}' : '${_two(d.day)} ${_bulan[d.month - 1]} ${_two(d.hour)}.${_two(d.minute)}';
}

/// "01:42:15"
String fmtDuration(Duration d) =>
    '${_two(d.inHours)}:${_two(d.inMinutes.remainder(60))}:${_two(d.inSeconds.remainder(60))}';

String fmtBytes(int b) {
  if (b < 1024) return '$b B';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} KB';
  if (b < 1024 * 1024 * 1024) return '${(b / 1024 / 1024).toStringAsFixed(1).replaceAll('.', ',')} MB';
  return '${(b / 1024 / 1024 / 1024).toStringAsFixed(2).replaceAll('.', ',')} GB';
}
