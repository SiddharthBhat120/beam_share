/// Human-friendly formatting helpers.
library;

String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final digits = i == 0 ? 0 : (v >= 100 ? 0 : (v >= 10 ? 1 : 2));
  return '${v.toStringAsFixed(digits)} ${units[i]}';
}

/// "38.4 MB/s"
String formatSpeed(double bytesPerSecond) => '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(1)} MB/s';

/// "1 h 02 min", "3 min 05 s", "12 s"
String formatDuration(Duration? d) {
  if (d == null) return '--';
  final s = d.inSeconds;
  if (s < 60) return '$s s';
  if (s < 3600) return '${s ~/ 60} min ${(s % 60).toString().padLeft(2, '0')} s';
  return '${s ~/ 3600} h ${((s % 3600) ~/ 60).toString().padLeft(2, '0')} min';
}

String formatCount(int n) {
  final s = n.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String plural(int n, String one, [String? many]) => '${formatCount(n)} ${n == 1 ? one : (many ?? '${one}s')}';

String formatDate(DateTime t) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '${t.day} ${months[t.month - 1]} ${t.year}, $hh:$mm';
}
