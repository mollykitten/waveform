import 'dart:async';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/router.dart';
import '../api/providers.dart';
import '../log/talker.dart';
import 'scheme_registrar.dart';

/// Ловит входящие deep-link'и (`waveform://…` + публичные soundcloud.com
/// ссылки, переданные ОС) и открывает соответствующий экран в клиенте.
///
/// Практический ежедневный путь — вставка soundcloud.com ссылки в omnibox
/// (см. omnibox_dropdown) — не зависит от регистрации схемы в ОС. Этот сервис
/// добавляет системный хэндлер поверх: запуск по ссылке + ссылки на лету.
class DeepLinkService {
  DeepLinkService(this._ref) {
    unawaited(_init());
  }

  final Ref _ref;
  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _sub;

  Future<void> _init() async {
    unawaited(
      SchemeRegistrar(
        executable: Platform.resolvedExecutable,
        talker: _ref.read(talkerProvider),
      ).register(),
    );
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) await _handle(initial);
    } catch (_) {
      /* нет initial-link — норм */
    }
    _sub = _appLinks.uriLinkStream.listen(_handle, onError: (_) {});
    _ref.onDispose(() => _sub?.cancel());
  }

  Future<void> _handle(Uri uri) async {
    final route = await _routeFor(uri);
    if (route != null) {
      appRouter.go(route);
    } else {
      _ref.read(talkerProvider).warning('deep link not resolved: $uri');
    }
  }

  /// Преобразует входящий URI в внутренний маршрут приложения.
  Future<String?> _routeFor(Uri uri) async {
    final api = _ref.read(soundcloudApiProvider);
    if (uri.scheme == 'waveform') {
      // waveform://open?url=<encoded soundcloud url>
      final embedded = uri.queryParameters['url'];
      if (embedded != null && embedded.isNotEmpty) {
        return api.resolveUrl(embedded);
      }
      // waveform://track/123 · waveform://playlist/45 · waveform://artist/foo
      final kind = uri.host;
      final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '';
      if (seg.isNotEmpty) {
        if (kind == 'track') return '/track/$seg';
        if (kind == 'playlist') return '/playlist/$seg';
        if (kind == 'artist') return '/artist/${Uri.encodeComponent(seg)}';
      }
      // Иначе — трактуем как soundcloud-путь.
      return api.resolveUrl(
        uri.toString().replaceFirst('waveform://', 'https://'),
      );
    }
    if (uri.host.contains('soundcloud.com')) {
      return api.resolveUrl(uri.toString());
    }
    return null;
  }
}

/// Bootstrap: `ref.watch(deepLinkServiceProvider)` в AppShell поднимает сервис.
final deepLinkServiceProvider = Provider<DeepLinkService>(
  (ref) => DeepLinkService(ref),
);
