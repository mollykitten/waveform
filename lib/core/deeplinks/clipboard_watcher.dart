import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/prefs_store.dart';

/// Тоггл «открывать ссылки SoundCloud из буфера обмена» (персистится в
/// `prefs.json`). По умолчанию включён.
class ClipboardWatchEnabled extends Notifier<bool> {
  static const _store = PrefsStore();
  static const _key = 'clipboardWatch';

  @override
  bool build() {
    _restore();
    return true;
  }

  Future<void> _restore() async {
    try {
      final v = await _store.readBool(_key);
      if (v != null) state = v;
    } catch (_) {
      /* нет плагина в тестах */
    }
  }

  void set(bool on) {
    if (state == on) return;
    state = on;
    unawaited(_safe(() => _store.writeBool(_key, on)));
  }

  void toggle() => set(!state);

  Future<void> _safe(Future<void> Function() op) async {
    try {
      await op();
    } catch (_) {}
  }
}

final clipboardWatchEnabledProvider =
    NotifierProvider<ClipboardWatchEnabled, bool>(ClipboardWatchEnabled.new);

/// Событие «в буфере появилась ссылка SoundCloud». [seq] растёт, чтобы listener
/// срабатывал даже на ту же ссылку повторно.
typedef ClipboardLink = ({int seq, String url});

class ClipboardLinkNotifier extends Notifier<ClipboardLink?> {
  @override
  ClipboardLink? build() => null;
  void emit(ClipboardLink link) => state = link;
}

final clipboardLinkProvider =
    NotifierProvider<ClipboardLinkNotifier, ClipboardLink?>(
      ClipboardLinkNotifier.new,
    );

/// Короткая подпись ссылки для тоста: путь без домена и параметров
/// (`artist/track`). Для нераспознаваемого URL — он сам.
String scLinkLabel(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.pathSegments.isEmpty) return url.trim();
  return uri.pathSegments.where((s) => s.isNotEmpty).join('/');
}

/// Следит за буфером обмена: пока включён тоггл — опрашивает clipboard и при
/// появлении НОВОЙ ссылки soundcloud.com кидает событие в [clipboardLinkProvider]
/// (AppShell показывает тост «открыть в Waveform»). Это обход того, что ОС не
/// даёт перехватывать https://soundcloud.com клики (не наш домен).
class ClipboardWatcher {
  ClipboardWatcher(this._ref) {
    _init();
  }

  final Ref _ref;
  Timer? _timer;
  String? _lastSeen;
  int _seq = 0;

  Future<void> _init() async {
    // Запоминаем текущее содержимое, чтобы не сработать на то, что уже лежало
    // в буфере до старта.
    try {
      _lastSeen = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } catch (_) {}
    _timer = Timer.periodic(const Duration(milliseconds: 1500), (_) => _tick());
    _ref.onDispose(() => _timer?.cancel());
  }

  Future<void> _tick() async {
    if (!_ref.read(clipboardWatchEnabledProvider)) return;
    String? text;
    try {
      text = (await Clipboard.getData(Clipboard.kTextPlain))?.text?.trim();
    } catch (_) {
      return;
    }
    if (text == null || text.isEmpty || text == _lastSeen) return;
    _lastSeen = text;
    if (_isScUrl(text)) {
      _ref.read(clipboardLinkProvider.notifier).emit((seq: ++_seq, url: text));
    }
  }

  /// Пометить ссылку обработанной — чтобы не предлагать её снова (после
  /// открытия из тоста или copy-link внутри приложения).
  void markSeen(String url) => _lastSeen = url.trim();

  /// Одна ссылка soundcloud.com (включая on./m.) с непустым путём, без пробелов.
  bool _isScUrl(String s) {
    if (s.contains(RegExp(r'\s'))) return false;
    final l = s.toLowerCase();
    final i = l.indexOf('soundcloud.com/');
    if (i < 0) return false;
    return l.substring(i + 'soundcloud.com/'.length).isNotEmpty;
  }
}

final clipboardWatcherProvider = Provider<ClipboardWatcher>(
  (ref) => ClipboardWatcher(ref),
);
