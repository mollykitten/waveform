import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../log/talker.dart';
import 'listening_store.dart';

/// Shared singleton queue for recording facts and reading ranking feedback.
final listeningStoreProvider = Provider<ListeningStore>((ref) {
  final log = ref.read(talkerProvider);
  return ListeningStore(onFailure: log.warning);
});
