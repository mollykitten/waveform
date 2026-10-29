/// Версия приложения. Обновлять синхронно с `version:` в pubspec.yaml
/// (сверяет тест `update_version_test.dart` и релизный workflow).
const kAppVersion = '0.5.0';

/// Страница релизов: фолбэк, когда автообновление недоступно.
const kReleasesPageUrl =
    'https://github.com/mollykitten/waveform/releases/latest';

/// `x.y.z` (с необязательным `v` и хвостом `-pre`/`+build`) → [major, minor,
/// patch]; `null`, если строка не похожа на версию.
List<int>? parseVersion(String raw) {
  final m = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)').firstMatch(raw.trim());
  if (m == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

/// `true`, если [candidate] строго новее [current]. Непарсящаяся версия — не
/// новее (молчим, а не зовём пользователя обновляться по мусору).
bool isNewerVersion(String candidate, String current) {
  final a = parseVersion(candidate);
  final b = parseVersion(current);
  if (a == null || b == null) return false;
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i] > b[i];
  }
  return false;
}
