import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:waveform_app/shared/models/collection.dart';
import 'package:waveform_app/shared/widgets/collection_card.dart';

void main() {
  for (final target in [CollectionTarget.track, CollectionTarget.playlist]) {
    for (final id in ['0', '']) {
      testWidgets('$target cards with missing id "$id" allow navigation', (
        tester,
      ) async {
        final router = GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => Scaffold(
                body: Column(
                  children: [
                    Row(
                      children: [
                        for (final title in ['first', 'second'])
                          CollectionCard(
                            item: Collection(
                              id: id,
                              title: title,
                              subtitle: 'artist',
                              kind: CollectionKind.playlist,
                              target: target,
                            ),
                          ),
                      ],
                    ),
                    Builder(
                      builder: (context) => TextButton(
                        onPressed: () => context.push('/detail'),
                        child: const Text('open detail'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            GoRoute(
              path: '/detail',
              builder: (_, _) => const Scaffold(body: Text('detail page')),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();

        await tester.tap(find.text('open detail'));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text('detail page'), findsOneWidget);
      });
    }
  }

  for (final target in [CollectionTarget.track, CollectionTarget.playlist]) {
    testWidgets('$target keeps the stable cover Hero tag', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CollectionCard(
              item: Collection(
                id: '123',
                title: 'collection',
                subtitle: 'artist',
                kind: CollectionKind.playlist,
                target: target,
              ),
            ),
          ),
        ),
      );

      expect(
        tester.widget<Hero>(find.byType(Hero)).tag,
        'cover-${target.name}-123',
      );
    });
  }
}
