import 'package:dio/dio.dart';

/// Добывает `client_id` так же, как веб-клиент/yt-dlp: грузит soundcloud.com,
/// перебирает <script src> (с конца — там основной бандл), ищет в JS
/// `client_id:"<32 alnum>"`. Кэширует; [refresh] форсит повторную добычу
/// (например, при 401 — id ротируются).
class ClientIdResolver {
  ClientIdResolver(this._dio);

  final Dio _dio;
  String? _cached;
  Future<String>? _inflight;

  static final _scriptSrc = RegExp(r'<script[^>]+src="([^"]+)"');
  static final _clientId = RegExp(r'client_id\s*:\s*"([0-9a-zA-Z]{32})"');
  static const _plain = ResponseType.plain;

  Future<String> get() async => _cached ?? await _dedupedFetch();

  /// Параллельные get()/refresh() делят один запрос в полёте, а не качают
  /// главную и бандлы по нескольку раз.
  Future<String> _dedupedFetch() {
    final running = _inflight;
    if (running != null) return running;
    final f = _fetch().then((id) => _cached = id);
    _inflight = f;
    return f.whenComplete(() {
      if (identical(_inflight, f)) _inflight = null;
    });
  }

  Future<String> refresh() async {
    _cached = null;
    return get();
  }

  Future<String> _fetch() async {
    final home = await _dio.get<String>(
      'https://soundcloud.com/',
      options: Options(responseType: _plain),
    );
    final scripts = _scriptSrc
        .allMatches(home.data ?? '')
        .map((m) => m.group(1)!)
        .toList();

    for (final src in scripts.reversed) {
      if (!src.startsWith('http')) continue;
      try {
        final js = await _dio.get<String>(
          src,
          options: Options(responseType: _plain),
        );
        final m = _clientId.firstMatch(js.data ?? '');
        if (m != null) return m.group(1)!;
      } catch (_) {
        // битый бандл — пробуем следующий
      }
    }
    throw StateError('client_id не найден в бандлах soundcloud.com');
  }
}
