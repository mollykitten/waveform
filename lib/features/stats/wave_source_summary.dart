import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme/app_theme.dart';
import '../../app/theme/colors.dart';
import '../../core/recommendations/listening_event.dart';
import '../../core/recommendations/listening_store_provider.dart';
import '../../core/recommendations/models.dart';
import '../../core/recommendations/providers.dart';
import '../../shared/widgets/section_header.dart';

typedef SourceTally = ({int listened, int skipped});

/// Local listening facts of my wave tracks, tallied per source: a listen is
/// positive evidence, a skip negative; neutral transitions are not counted.
final waveSourceSummaryProvider = FutureProvider<Map<WaveSource, SourceTally>>((
  ref,
) async {
  final identity = await ref.watch(listeningIdentityProvider.future);
  if (identity == 'anonymous') return const {};
  final tally = <WaveSource, SourceTally>{};
  for (final event in await ref.watch(listeningStoreProvider).read(identity)) {
    final source = event.source;
    if (source == null) continue;
    final now = tally[source] ?? (listened: 0, skipped: 0);
    tally[source] = switch (event.evidence) {
      ListeningEvidence.positive => (
        listened: now.listened + 1,
        skipped: now.skipped,
      ),
      ListeningEvidence.negative => (
        listened: now.listened,
        skipped: now.skipped + 1,
      ),
      ListeningEvidence.neutral => now,
    };
  }
  return tally;
});

/// One mono line per source; hidden until my wave has produced any facts.
class WaveSourceSummary extends ConsumerWidget {
  const WaveSourceSummary({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tally = ref.watch(waveSourceSummaryProvider).value ?? const {};
    if (tally.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 28),
        const SectionHeader(title: 'my wave · listened / skipped'),
        const SizedBox(height: AppTheme.headerGap),
        for (final entry in tally.entries)
          Text(
            '${entry.key.name}  ${entry.value.listened} / ${entry.value.skipped}',
            style: AppTheme.mono(size: 11, color: AppColors.textHi),
          ),
      ],
    );
  }
}
