import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:waveform_app/core/api/liked_tracks.dart';
import 'package:waveform_app/core/api/me_likes.dart';
import 'package:waveform_app/core/api/mock_soundcloud_api.dart';
import 'package:waveform_app/core/api/providers.dart';
import 'package:waveform_app/core/api/soundcloud_auth.dart';
import 'package:waveform_app/shared/mock/mock_data.dart';

void main() {
  // Регрессия: лайк из волны/плеера не появлялся во вкладке likes, потому что
  // её paginated-список жил со снимка первой загрузки.
  test('like toggle is reflected in the loaded library likes list', () async {
    final container = ProviderContainer(
      overrides: [
        authControllerProvider.overrideWithBuild(
          (ref, notifier) =>
              const SoundcloudAuth(clientId: 'test', userToken: 'token'),
        ),
        soundcloudApiProvider.overrideWithValue(const MockSoundcloudApi()),
      ],
    );
    addTearDown(container.dispose);

    container.read(likedTracksProvider);
    container.read(meLikesPagedProvider);
    await pumpEventQueue();

    final track = Mock.listeningHistory.first;
    List<String> libraryIds() => [
      for (final t in container.read(meLikesPagedProvider).tracks) t.id,
    ];
    expect(libraryIds(), contains(track.id));

    final liked = container.read(likedTracksProvider.notifier);
    await liked.toggle(track.id, track: track);
    expect(libraryIds(), isNot(contains(track.id)));

    await liked.toggle(track.id, track: track);
    expect(libraryIds().first, track.id);
  });
}
