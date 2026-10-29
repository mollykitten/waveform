/// Форматирование чисел и времени для моно-меток.
abstract final class Fmt {
  /// 1234 → "1,234"; 12400 → "12.4K"; 1280000 → "1.28M".
  static String count(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) {
      final k = n / 1000;
      return '${_trim(k)}K';
    }
    final m = n / 1000000;
    return '${_trim(m)}M';
  }

  static String _trim(double v) {
    // До 3 значащих цифр без лишних нулей: 12.4, 1.28, 341.
    final s = v >= 100
        ? v.toStringAsFixed(0)
        : v >= 10
        ? v.toStringAsFixed(1)
        : v.toStringAsFixed(2);
    return s.contains('.') ? s.replaceFirst(RegExp(r'\.?0+$'), '') : s;
  }

  /// Duration → "m:ss" (или "h:mm:ss").
  static String time(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$s';
    return '$m:$s';
  }
}
