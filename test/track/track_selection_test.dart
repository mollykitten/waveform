import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:talker_flutter/talker_flutter.dart';
import 'package:waveform_app/app/app.dart';
import 'package:waveform_app/app/router.dart';
import 'package:waveform_app/core/api/feeds.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/audio/audio_engine.dart';
import 'package:waveform_app/core/log/talker.dart';
import 'package:waveform_app/features/player/player_controller.dart';
import 'package:waveform_app/features/track/track_screen.dart';
import 'package:waveform_app/shared/models/comment.dart';
import 'package:waveform_app/shared/models/track.dart';
import 'package:waveform_app/shared/widgets/selectable_block.dart';

import '../support/fake_audio_engine.dart';
import '../support/stub_liked_tracks.dart';

const _track = Track(
  id: 'selection-qa',
  title: 'Музыка — Café 🎧',
  description: 'Первая строка 🎵\nhttps://example.com/café\n日本語 — e\u0301.',
  artist: 'Selection artist',
  durationMs: 100000,
  likes: 0,
  reposts: 0,
  plays: 0,
  waveform: [0.3, 0.5],
);

void main() {
  testWidgets(
    'real track screen selection preserves shell playback and route',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final copied = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
      );
      final engine = FakeAudioEngine();
      addTearDown(engine.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            soundcloudApiProvider.overrideWithValue(const MockSoundcloudApi()),
            trackDetailProvider(_track.id).overrideWith(
              (ref) async =>
                  (track: _track, comments: <Comment>[], related: <Track>[]),
            ),
            audioEngineProvider.overrideWithValue(engine),
            likedTracksProvider.overrideWith(StubLikedTracks.new),
            talkerProvider.overrideWithValue(Talker()),
          ],
          child: const WaveformApp(),
        ),
      );
      appRouter.go('/track/${_track.id}');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final container = ProviderScope.containerOf(
        tester.element(find.byType(WaveformApp)),
      );
      container.read(playerControllerProvider.notifier).play(_track);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      final before = container.read(playerControllerProvider);
      expect(before.isPlaying, isTrue);
      final blocks = find.descendant(
        of: find.byType(TrackScreen),
        matching: find.byType(SelectableBlock),
      );
      expect(blocks, findsNWidgets(2));
      Future<void> copy() async {
        final modifier = Platform.isMacOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await tester.sendKeyDownEvent(modifier);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(modifier);
        await tester.pump();
      }

      for (final (index, expected) in [
        _track.title,
        _track.description,
      ].indexed) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: blocks.at(index),
            matching: find.byType(RichText),
          ),
        );
        final mouse = await tester.startGesture(
          paragraph.localToGlobal(const Offset(0, 1)),
          kind: PointerDeviceKind.mouse,
        );
        await mouse.moveTo(
          paragraph.localToGlobal(
            Offset(paragraph.size.width, paragraph.size.height - 1),
          ),
        );
        await mouse.up();
        await tester.pump();
        await copy();
        expect(copied.last, expected);
        expect(copied, hasLength(index + 1));
        await tester.pump(const Duration(seconds: 1));
        await tester.tapAt(
          paragraph.localToGlobal(const Offset(5, 5)),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();
        await copy();
        expect(copied, hasLength(index + 1));
        expect(container.read(playerControllerProvider), same(before));
        expect(
          appRouter.routeInformationProvider.value.uri.path,
          '/track/${_track.id}',
        );
      }
      // The real shell must still receive Space after focus moves to selection.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(container.read(playerControllerProvider).isPlaying, isFalse);
      expect(container.read(playerControllerProvider).track, same(_track));
      expect(
        appRouter.routeInformationProvider.value.uri.path,
        '/track/${_track.id}',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 5));
    },
  );
}
