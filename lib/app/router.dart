import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../features/artist/artist_screen.dart';
import '../features/debug/logs_screen.dart';
import '../features/feed/feed_screen.dart';
import '../features/home/home_screen.dart';
import '../features/library/library_screen.dart';
import '../features/playlist/playlist_screen.dart';
import '../features/recommendations/recommendations_screen.dart';
import '../features/search/search_screen.dart';
import '../features/settings/settings_screen.dart';
import '../features/stats/stats_screen.dart';
import '../features/track/track_screen.dart';
import 'app_shell.dart';

/// Мягкий переход экрана: fade + лёгкий подъём (apple-like).
CustomTransitionPage<void> _page(BuildContext context, Widget child) {
  final reducedMotion = MediaQuery.disableAnimationsOf(context);
  return AppTransitionPage(
    child: child,
    transitionDuration: reducedMotion
        ? Duration.zero
        : const Duration(milliseconds: 240),
    reverseTransitionDuration: reducedMotion
        ? Duration.zero
        : const Duration(milliseconds: 160),
    transitionsBuilder: (context, animation, secondary, child) {
      final reducedMotion = MediaQuery.disableAnimationsOf(context);
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: reducedMotion ? const AlwaysStoppedAnimation(1) : curved,
        child: SlideTransition(
          position: reducedMotion
              ? const AlwaysStoppedAnimation(Offset.zero)
              : Tween(
                  begin: const Offset(0, 0.015),
                  end: Offset.zero,
                ).animate(curved),
          child: child,
        ),
      );
    },
  );
}

/// Keeps route animation timing in sync with accessibility preference changes.
class AppTransitionPage extends CustomTransitionPage<void> {
  const AppTransitionPage({
    required super.child,
    required super.transitionsBuilder,
    required super.transitionDuration,
    required super.reverseTransitionDuration,
    super.key,
  });

  @override
  Route<void> createRoute(BuildContext context) => _AppTransitionRoute(this);
}

class _AppTransitionRoute extends PageRouteBuilder<void> {
  _AppTransitionRoute(AppTransitionPage page)
    : super(
        settings: page,
        transitionDuration: page.transitionDuration,
        reverseTransitionDuration: page.reverseTransitionDuration,
        pageBuilder: (_, _, _) => page.child,
      );

  AppTransitionPage get _page => settings as AppTransitionPage;

  @override
  void changedInternalState() {
    controller?.duration = _page.transitionDuration;
    controller?.reverseDuration = _page.reverseTransitionDuration;
    super.changedInternalState();
  }

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => Semantics(
    scopesRoute: true,
    explicitChildNodes: true,
    child: _page.child,
  );

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _page.transitionsBuilder(context, animation, secondaryAnimation, child);
}

final appRouter = GoRouter(
  // START позволяет открыть приложение сразу на нужном экране (deep-link / скриншоты).
  initialLocation: const String.fromEnvironment('START', defaultValue: '/'),
  routes: [
    ShellRoute(
      builder: (context, state, child) =>
          AppShell(location: state.uri.path, child: child),
      routes: [
        GoRoute(path: '/', pageBuilder: (c, s) => _page(c, const HomeScreen())),
        GoRoute(
          path: '/recommendations',
          pageBuilder: (c, s) => _page(const RecommendationsScreen()),
        ),
        GoRoute(
          path: '/feed',
          pageBuilder: (c, s) => _page(c, const FeedScreen()),
        ),
        GoRoute(
          path: '/library',
          pageBuilder: (c, s) =>
              _page(c, LibraryScreen(initialTab: s.uri.queryParameters['tab'])),
        ),
        GoRoute(
          path: '/track/:id',
          pageBuilder: (c, s) =>
              _page(c, TrackScreen(trackId: s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/artist/:handle',
          pageBuilder: (c, s) => _page(
            c,
            ArtistScreen(
              handle: Uri.decodeComponent(s.pathParameters['handle']!),
            ),
          ),
        ),
        GoRoute(
          path: '/search',
          pageBuilder: (c, s) =>
              _page(c, SearchScreen(query: s.uri.queryParameters['q'] ?? '')),
        ),
        GoRoute(
          path: '/playlist/:id',
          pageBuilder: (c, s) =>
              _page(c, PlaylistScreen(id: s.pathParameters['id']!)),
        ),
        GoRoute(
          path: '/settings',
          pageBuilder: (c, s) => _page(c, const SettingsScreen()),
        ),
        GoRoute(
          path: '/stats',
          pageBuilder: (c, s) => _page(c, const StatsScreen()),
        ),
      ],
    ),
    // Экран логов — вне shell (на весь экран, без TopBar/плеера).
    GoRoute(path: '/logs', builder: (c, s) => const LogsScreen()),
  ],
);
