import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/liked_tracks.dart';
import '../../core/api/providers.dart';
import '../../core/api/soundcloud_api.dart';
import '../../core/audio/audio_engine.dart';
import '../../core/audio/playback_prefs.dart';
import '../../core/audio/waveform_audio_handler.dart';
import '../../core/drm/drm_stream_service.dart';
import '../../core/log/talker.dart';
import '../../core/recommendations/listening_event.dart';
import '../../core/recommendations/listening_providers.dart';
import '../../core/recommendations/listening_tracker.dart';
import '../../core/recommendations/vector_engine.dart';
import '../../core/recommendations/wave_sources.dart';
import '../../shared/models/track.dart';

/// Событие «трек не проигрался» — для всплывающего уведомления в UI.
/// [seq] растёт с каждым событием, чтобы listener срабатывал и на повтор.
typedef Unplayable = ({int seq, String title, bool goPlus});

/// Состояние плеера. Прогресс/признак «играет» приходят из [AudioEngine]
/// (just_audio); очередь next/previous — реальный список с экрана.
class PlayerState {
  const PlayerState({
    this.track,
    this.isPlaying = false,
    this.position = Duration.zero,
    this.buffered = Duration.zero,
    this.shuffle = false,
    this.repeat = false,
    this.liked = false,
    this.volume = 1.0,
    this.muted = false,
    this.unplayable,
    this.queueVersion = 0,
    this.transitionCause,
    this.sessionVersion = 0,
    this.seekVersion = 0,
  });

  final Track? track;
  final bool isPlaying;
  final Duration position;
  final Duration buffered;
  final bool shuffle;
  final bool repeat;
  final bool liked;
  final double volume;

  /// Замьючено ли воспроизведение. Громкость ползунка сохраняется в [volume]
  /// и восстанавливается при повторном [toggleMute].
  final bool muted;

  /// Монотонно растущий счётчик — bump'ится контроллером на любую мутацию
  /// очереди. UI слушает `select((s) => s.queueVersion)` и пере-читает
  /// `notifier.upcomingTracks` для актуального списка.
  final int queueVersion;
  final ListeningTransitionCause? transitionCause;

  /// New playback intent, including replay/restart of the same track.
  final int sessionVersion;

  /// Explicit seek intent; normal position ticks leave this unchanged.
  final int seekVersion;

  /// Последний непроигравшийся трек — UI показывает уведомление.
  final Unplayable? unplayable;

  /// Доля воспроизведённого (0..1) — для оранжевой части waveform.
  double get progress {
    final total = track?.durationMs ?? 0;
    if (total == 0) return 0;
    return (position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  /// Доля буферизированного (0..1) — для серого тиера на waveform.
  double get bufferedFraction {
    final total = track?.durationMs ?? 0;
    if (total == 0) return 0;
    return (buffered.inMilliseconds / total).clamp(0.0, 1.0);
  }

  PlayerState copyWith({
    Track? track,
    bool? isPlaying,
    Duration? position,
    Duration? buffered,
    bool? shuffle,
    bool? repeat,
    bool? liked,
    double? volume,
    bool? muted,
    Unplayable? unplayable,
    int? queueVersion,
    ListeningTransitionCause? transitionCause,
    int? sessionVersion,
    int? seekVersion,
  }) => PlayerState(
    track: track ?? this.track,
    isPlaying: isPlaying ?? this.isPlaying,
    position: position ?? this.position,
    buffered: buffered ?? this.buffered,
    shuffle: shuffle ?? this.shuffle,
    repeat: repeat ?? this.repeat,
    liked: liked ?? this.liked,
    volume: volume ?? this.volume,
    muted: muted ?? this.muted,
    unplayable: unplayable ?? this.unplayable,
    queueVersion: queueVersion ?? this.queueVersion,
    transitionCause: transitionCause ?? this.transitionCause,
    sessionVersion: sessionVersion ?? this.sessionVersion,
    seekVersion: seekVersion ?? this.seekVersion,
  );
}

class PlayerController extends Notifier<PlayerState> {
  AudioEngine get _engine => ref.read(audioEngineProvider);
  late ListeningTracker _listening;

  /// Очередь, из которой пришёл текущий трек (для next/previous).
  /// Growable — мутируется queue-панелью (add/remove/reorder).
  List<Track> _queue = [];

  /// Реальная история воспроизведения (порядок, в котором треки звучали).
  /// Источник правды для next/previous: назад/вперёд ретрейсят этот список,
  /// а не пере-тасовку. На фронтире (хвосте истории) next генерит новый трек.
  List<Track> _history = [];
  int _histIdx = -1;

  /// Закешированный «следующий новый» трек на фронтире — вычисляется один раз
  /// при активации фронтир-трека, чтобы preload и фактический переход выбрали
  /// ОДИН и тот же трек (иначе на границе цикла шафл мог разойтись).
  Track? _frontierNext;

  /// Идёт ли сейчас swap (crossfade-рампа или gapless). Гейтит повторный
  /// early-trigger по позиции и completion-путь, пока переход не завершён.
  bool _swapping = false;
  final List<StreamSubscription<dynamic>> _subs = [];

  /// Токен последней загрузки — отбрасываем резолв устаревшего трека,
  /// если пользователь быстро переключил на другой.
  int _loadToken = 0;

  /// Only the matching completed load/swap may supply listening observations.
  int? _readySourceToken;
  bool get _sourceReady => _readySourceToken == _loadToken;

  /// Когда реально начали играть текущий источник — для защиты от
  /// «мгновенного completed» (битый HLS), который иначе устраивал skip-storm.
  DateTime? _startedAt;

  /// Максимальная виденная позиция текущего трека (мс). Сбрасывается на смене
  /// трека. Используется completion-гейтом — см. completedStream listener.
  int _maxPosMs = 0;

  /// Подряд идущих непроигрываемых треков (нет DRM-free источника). Ограничивает
  /// авто-переход на следующий, чтобы цепочка мёртвых треков не пролистала всё.
  int _deadStreak = 0;
  static const _maxDeadSkips = 3;

  @override
  PlayerState build() {
    final engine = ref.watch(audioEngineProvider);
    _listening = ref.read(listeningTrackerProvider);

    _subs.add(
      engine.positionStream.listen((p) {
        if (state.track == null) return;
        // Защита от «протухшего» события позиции, доставленного из broadcast-
        // пайпа старого плеера сразу после смены трека: позиция длиннее нового
        // трека к нему относиться не может — игнорим (иначе прогресс «прилипал»
        // в конце / трек стартовал с середины).
        final dur = state.track!.durationMs;
        if (dur > 0 && p.inMilliseconds > dur + 2000) return;
        if (_sourceReady) {
          if (p.inMilliseconds > _maxPosMs) _maxPosMs = p.inMilliseconds;
          _listening.sample(
            positionMs: p.inMilliseconds,
            playing: state.isPlaying,
          );
        }
        state = state.copyWith(position: p);
        // Истинный crossfade: overlap-переход стартует ДО конца трека.
        _maybeStartCrossfade(p.inMilliseconds, dur);
      }),
    );
    _subs.add(
      engine.bufferedPositionStream.listen((b) {
        if (state.track != null) state = state.copyWith(buffered: b);
      }),
    );
    _subs.add(
      engine.playingStream.listen((playing) {
        if (!_sourceReady) return;
        _listening.setPlaying(playing);
        if (state.track != null && state.isPlaying != playing) {
          state = state.copyWith(isPlaying: playing);
        }
      }),
    );
    _subs.add(
      engine.completedStream.listen((_) {
        // Crossfade уже идёт (early-trigger по позиции) — не дублируем переход.
        if (_swapping || !_sourceReady) return;
        // Ложный «completed» сразу после загрузки (битый HLS) НЕ должен
        // перескакивать дальше — иначе очередь пролистывается за секунды.
        // Реальный конец трека = играли заметное время И дошли почти до конца.
        final since = _startedAt == null
            ? Duration.zero
            : DateTime.now().difference(_startedAt!);
        final dur = state.track?.durationMs ?? 0;
        // Используем МАКСИМАЛЬНУЮ виденную позицию, а не последнюю: positionStream
        // у just_audio перед `completed` нередко отстаёт (последний emit < конца),
        // и порог 0.85 отбрасывал реальный конец → плеер замирал «раз в 10 треков»,
        // пока не подёргаешь. Порог снижен до 0.7 + берём max-seen.
        final reachedEnd = dur > 0
            ? _maxPosMs >= dur * 0.7
            : since.inSeconds > 5;
        if (since.inSeconds < 5) return;
        if (!reachedEnd) {
          ref
              .read(talkerProvider)
              .warning(
                'source ended early (${_maxPosMs}ms of ${dur}ms): '
                '${state.track?.title}',
              );
        }
        final reason = reachedEnd
            ? ListeningTransitionCause.naturalCompletion
            : ListeningTransitionCause.unplayable;
        if (state.repeat) {
          _restartListening(reason);
          _engine.seek(Duration.zero);
          _engine.resume();
        } else if (_hasMatchingPreload) {
          // Preload ready → бесшовный swap (gapless или crossfade per prefs).
          _advanceViaSwap(reason: reason);
        } else {
          next(reason: reason);
        }
      }),
    );

    // Подсветка «liked» в плеере держится в синхроне с реальным множеством
    // лайков (могло догрузиться после play или измениться из списка).
    ref.listen(likedTracksProvider, (_, liked) {
      final id = state.track?.id;
      if (id != null) {
        final isLiked = liked.contains(id);
        if (state.liked != isLiked) state = state.copyWith(liked: isLiked);
      }
    });

    // Пушим состояние в audio_service handler — OS Control Center, media-keys,
    // lockscreen now-playing видят актуальные данные.
    listenSelf((_, next) {
      try {
        ref.read(audioHandlerProvider).sync(next);
      } catch (_) {
        /* singleton не инициализирован в тестах — игнорим */
      }
    });

    ref.onDispose(() {
      ++_loadToken;
      ++_preloadToken;
      _readySourceToken = null;
      _listening.finish(ListeningTransitionCause.disposal);
      for (final s in _subs) {
        s.cancel();
      }
      _subs.clear();
    });
    return const PlayerState();
  }

  /// Запустить трек. [queue] — список-контекст для next/previous;
  /// без него очередью становится сам трек. Это ПУБЛИЧНЫЙ вход (пользователь
  /// выбрал трек/очередь в UI) — он сбрасывает контекст: новую очередь, свежий
  /// shuffle-порядок и историю из одного трека. Навигация next/previous НЕ
  /// проходит сюда (иначе сбрасывала бы шафл на каждый шаг — старый баг).
  void play(Track track, {List<Track>? queue}) {
    // Wave sources belong to the queue the wave started: a play from anywhere
    // else must not inherit them through a shared track id.
    final waveSources = ref.read(waveSourcesProvider.notifier);
    if (!waveSources.consumeArm()) waveSources.clear();
    _queue = (queue != null && queue.isNotEmpty) ? List.of(queue) : [track];
    _orderSource = null; // новый контекст → _order пересоберётся в _ensureOrder
    _order = [];
    _history = [track];
    _histIdx = 0;
    _recomputeFrontierNext();
    _activate(track, reason: ListeningTransitionCause.directSelection);
  }

  /// Загрузить трек как текущий БЕЗ изменения очереди/истории (история и
  /// shuffle-порядок ведутся вызывающим). Общий путь для play/next/previous.
  void _activate(Track track, {required ListeningTransitionCause reason}) {
    _readySourceToken = null;
    _preloadedTrackId = null;
    ++_preloadToken;
    if (_swapping) {
      // Invalidate the old engine transition before resolving the new URL.
      // Its completion must not own this track's swap gate or preload.
      _swapping = false;
      ++_preloadToken;
      unawaited(_engine.stop());
    }
    _listening.finish(reason);
    _startListening(track);
    _startedAt = null;
    _maxPosMs = 0;
    state = state.copyWith(
      track: track,
      isPlaying: true,
      position: Duration.zero,
      buffered: Duration.zero,
      // Подсветка лайка — из реального множества лайков (а не сброс в false).
      liked: ref.read(likedTracksProvider).contains(track.id),
      queueVersion: state.queueVersion + 1,
      transitionCause: reason,
      sessionVersion: state.sessionVersion + 1,
    );
    _load(track);
  }

  // ── Публичная queue-API (для queue-панели) ──────────────────────────────
  /// Текущий список «дальше будет» — без проигрываемого. В shuffle —
  /// из тасованного `_order`, иначе линейный хвост `_queue` от current'а.
  List<Track> get upcomingTracks {
    if (state.shuffle && _order.isNotEmpty && identical(_orderSource, _queue)) {
      final i = _order.indexWhere((t) => t.id == state.track?.id);
      if (i == -1) return List.unmodifiable(_order);
      return List.unmodifiable(_order.skip(i + 1));
    }
    final i = _queue.indexWhere((t) => t.id == state.track?.id);
    if (i == -1) return List.unmodifiable(_queue);
    return List.unmodifiable(_queue.skip(i + 1));
  }

  /// Копия основной очереди (контекст воспроизведения) в порядке списка.
  List<Track> get queueSnapshot => List.unmodifiable(_queue);

  /// Есть ли трек в текущей очереди.
  bool queueContains(String trackId) => _queue.any((t) => t.id == trackId);

  /// Индекс играющего в основной `_queue`; −1 если нет в очереди.
  int get currentQueueIndex =>
      _queue.indexWhere((t) => t.id == state.track?.id);

  /// Активная последовательность «дальше будет»: в shuffle — тасованный
  /// `_order`, иначе линейная `_queue`. Мутации очереди правят именно её
  /// (на месте), не сбрасывая весь shuffle-цикл.
  List<Track> get _activeSeq =>
      (state.shuffle && _order.isNotEmpty && identical(_orderSource, _queue))
      ? _order
      : _queue;

  /// Переставить трек в upcoming-секции. Индексы — в координатах списка
  /// `upcomingTracks` (0 = первый после current), транслируется в абсолютные
  /// индексы активной последовательности.
  void reorderUpcoming(int upcomingOld, int upcomingNew) {
    final seq = _activeSeq;
    final cur = seq.indexWhere((t) => t.id == state.track?.id);
    if (cur < 0) return;
    final base = cur + 1;
    final oldAbs = base + upcomingOld;
    var newAbs = base + upcomingNew;
    if (oldAbs < base || oldAbs >= seq.length) return;
    if (newAbs > seq.length) newAbs = seq.length;
    if (newAbs > oldAbs) newAbs -= 1; // ReorderableListView соглашение
    final item = seq.removeAt(oldAbs);
    seq.insert(newAbs, item);
    _recomputeFrontierNext();
    _refreshPreload();
    state = state.copyWith(queueVersion: state.queueVersion + 1);
  }

  /// Убрать трек из очереди (нельзя текущий — он играет).
  void removeFromQueue(String trackId) {
    if (trackId == state.track?.id) return;
    final n = _queue.length;
    _queue.removeWhere((t) => t.id == trackId);
    if (_order.isNotEmpty) _order.removeWhere((t) => t.id == trackId);
    if (_queue.length == n) return;
    _recomputeFrontierNext();
    _refreshPreload();
    state = state.copyWith(queueVersion: state.queueVersion + 1);
  }

  /// Добавить трек в конец очереди; игнорим дубликат.
  void addToQueue(Track t) {
    if (_queue.any((x) => x.id == t.id)) {
      // Можно «поднять» наверх; пока проще no-op для дубликата.
      return;
    }
    _queue.add(t);
    if (_order.isNotEmpty) _order.add(t);
    _recomputeFrontierNext();
    _refreshPreload();
    state = state.copyWith(queueVersion: state.queueVersion + 1);
  }

  /// Вставить трек СЛЕДУЮЩИМ после текущего (vs. addToQueue — в конец).
  /// Дубликат не плодим — переносим на позицию «следующий». Учитывает shuffle:
  /// вставляем после текущего в АКТИВНОЙ последовательности (что реально
  /// слышно), сохраняя членство/позицию во второй. Когда ничего не играет
  /// (cur < 0) — вставляем в начало (станет первым «следующим»).
  void playNext(Track t) {
    final curId = state.track?.id;
    _queue.removeWhere((x) => x.id == t.id);
    _order.removeWhere((x) => x.id == t.id);

    final seq = _activeSeq; // _order в shuffle, иначе _queue
    final curInSeq = curId == null ? -1 : seq.indexWhere((x) => x.id == curId);
    seq.insert(curInSeq < 0 ? 0 : curInSeq + 1, t);

    if (identical(seq, _queue)) {
      // Линейный режим активен: _order (если непуст) держим в синхроне — тоже
      // после текущего, а не в хвосте, иначе re-shuffle сыграл бы трек последним.
      if (_order.isNotEmpty) {
        final co = curId == null ? -1 : _order.indexWhere((x) => x.id == curId);
        _order.insert(co < 0 ? _order.length : co + 1, t);
      }
    } else {
      // Shuffle активен (seq == _order): _queue — источник правды членства.
      if (!_queue.any((x) => x.id == t.id)) _queue.add(t);
    }
    _recomputeFrontierNext();
    _refreshPreload();
    state = state.copyWith(queueVersion: state.queueVersion + 1);
  }

  /// Резолв стрима (transcoding → m3u8/mp3) и передача в движок.
  /// Перебирает кандидатов (HLS → progressive): часть HLS-ссылок протухает и
  /// отдаёт 404 — тогда играем следующий источник. Мок/не streamable — тихо.
  Future<void> _load(Track track) async {
    final token = ++_loadToken;
    if (track.blocked) {
      _markUnplayable(token, track);
      return;
    }
    final candidates = track.streamCandidates;
    // Нет незашифрованных источников — возможен GO+ (Widevine). Ни тех, ни
    // других (мок/не streamable) — тихо (UI оптимистичен, реальный «играет»
    // придёт из движка).
    if (candidates.isEmpty && track.drmStreamCandidates.isEmpty) return;
    final api = ref.read(soundcloudApiProvider);
    for (final candidate in candidates) {
      try {
        final url = await api.resolveStreamUrl(candidate);
        if (token != _loadToken) return; // пользователь уже переключил трек
        if (url == null) continue; // транскодинг протух — следующий кандидат
        await _engine.load(url);
        if (token != _loadToken) return;
        _startedAt = DateTime.now();
        _markSourceReady(token);
        _deadStreak = 0; // успешная загрузка сбрасывает счётчик мёртвых
        // Фоном prepare'им next — для gapless/crossfade swap'а.
        unawaited(_preloadAfter(track));
        return; // успех
      } catch (e, st) {
        if (token != _loadToken) return;
        ref
            .read(talkerProvider)
            .warning('stream candidate failed: ${track.title}', e, st);
        // пробуем следующий источник
      }
    }
    // GO+ (ctr-encrypted-hls): Widevine-дешифровка ядром scdrm в локальный
    // файл — сетевой трафик + транскод всего трека, поэтому идём после
    // обычных кандидатов (они дешевле).
    if (track.drmStreamCandidates.isNotEmpty) {
      try {
        final uri = await ref.read(drmStreamServiceProvider).prepare(track);
        if (token != _loadToken) return;
        if (uri != null) {
          await _engine.load(uri);
          if (token != _loadToken) return;
          _startedAt = DateTime.now();
          _markSourceReady(token);
          _deadStreak = 0;
          unawaited(_preloadAfter(track));
          return;
        }
      } catch (e, st) {
        if (token != _loadToken) return;
        ref
            .read(talkerProvider)
            .warning('drm stream failed: ${track.title}', e, st);
      }
    }
    // Все кандидаты исчерпаны: трек удалён/недоступен или остались только
    // зашифрованные источники, которые и DRM не расшевелил.
    ref.read(talkerProvider).warning('no playable stream: ${track.title}');
    _markUnplayable(token, track);
  }

  /// Помечает текущий трек непроигрываемым (видимая причина «unavailable»)
  /// и в очереди перескакивает на следующий, но не более [_maxDeadSkips] подряд,
  /// чтобы цепочка мёртвых треков не пролистала всю очередь.
  void _markUnplayable(int token, Track track) {
    if (token != _loadToken || state.track?.id != track.id) return;
    _listening.finish(ListeningTransitionCause.unplayable);
    state = state.copyWith(
      isPlaying: false,
      unplayable: (
        seq: ++_unplayableSeq,
        title: track.title,
        goPlus: track.goPlus,
      ),
      transitionCause: ListeningTransitionCause.unplayable,
    );
    if (_queue.length > 1 && ++_deadStreak < _maxDeadSkips) {
      next(reason: ListeningTransitionCause.unplayable);
    }
  }

  int _unplayableSeq = 0;

  /// Токен текущей preload-операции — отбрасываем устаревшие резолвы.
  int _preloadToken = 0;
  String? _preloadedTrackId;

  bool get _hasMatchingPreload =>
      _engine.hasPreload && _preloadedTrackId == _upNext?.id;

  void _refreshPreload() {
    ++_preloadToken;
    _preloadedTrackId = null;
    final current = state.track;
    if (current != null && _sourceReady) {
      unawaited(_preloadAfter(current));
    }
  }

  void _markSourceReady(int token, {int positionMs = 0}) {
    if (token != _loadToken) return;
    _readySourceToken = token;
    _maxPosMs = positionMs;
    _listening.sample(positionMs: positionMs, playing: false);
    _listening.setPlaying(state.isPlaying);
  }

  /// Готовит следующий трек ([_upNext]) в теневом движке: резолвит первый
  /// candidate, кидает engine.preloadNext. Тихо отказывается на пустых.
  /// [current] оставлен для совместимости вызова — целевой трек берётся из
  /// [_upNext], чтобы preload и фактический переход выбрали один и тот же трек.
  Future<void> _preloadAfter(Track current) async {
    final token = ++_preloadToken;
    _preloadedTrackId = null;
    // The inactive player may still own the selected incoming source until
    // output binding commits. Defer queue/shuffle preloads until swap settles.
    if (_swapping) return;
    final n = _upNext;
    if (n == null ||
        n.blocked ||
        (n.streamCandidates.isEmpty && n.drmStreamCandidates.isEmpty)) {
      await _engine.preloadNext(null);
      return;
    }
    try {
      // Обычные кандидаты — только резолв первого (сам стрим тянет движок).
      // GO+ без незашифрованных кандидатов — полная дешифровка в файл
      // (тяжёлая, но фоновая; результат переиспользуется кэшем сервиса).
      final url = n.streamCandidates.isNotEmpty
          ? await ref
                .read(soundcloudApiProvider)
                .resolveStreamUrl(n.streamCandidates.first)
          : await ref.read(drmStreamServiceProvider).prepare(n);
      if (token != _preloadToken) return; // пользователь переключился
      if (url == null) {
        await _engine.preloadNext(null);
        return;
      }
      await _engine.preloadNext(url);
      if (token == _preloadToken) _preloadedTrackId = n.id;
    } catch (_) {
      if (token == _preloadToken) await _engine.preloadNext(null);
    }
  }

  /// Бесшовный переход на preload'ный трек: swap движков + state.track update
  /// БЕЗ полного `_load` (он бы порвал стрим). Затем preload'им следующий.
  /// Ведёт ту же историю, что и ручной [next] — иначе авто-переход и кнопка
  /// расходились бы.
  Future<void> _advanceViaSwap({
    ListeningTransitionCause reason =
        ListeningTransitionCause.naturalCompletion,
  }) async {
    final n = _upNext;
    if (n == null) {
      _listening.finish(reason);
      return;
    }
    final previous = state;
    final history = List<Track>.of(_history);
    final historyIndex = _histIdx;
    final startedAt = _startedAt;
    final maxPosMs = _maxPosMs;
    _listening.finish(reason);
    _startListening(n);
    _readySourceToken = null;
    _preloadedTrackId = null;
    _swapping = true;
    final crossfade = _crossfade;
    // Бамп _loadToken — старые in-flight кандидаты-резолвы устаревают.
    final token = ++_loadToken;
    ++_preloadToken;
    _stepHistoryForward(n);
    _maxPosMs = 0;
    // ВАЖНО: state.track обновляем СРАЗУ, до await на swap. При crossfade
    // swap блокируется на длительность рампы (до 6с) — иначе UI всё это
    // время рисует старый трек, хотя звук уже от нового. На gapless (0с)
    // тоже была видимая задержка из-за async-await цикла engine.
    state = state.copyWith(
      track: n,
      position: Duration.zero,
      buffered: Duration.zero,
      isPlaying: true,
      liked: ref.read(likedTracksProvider).contains(n.id),
      queueVersion: state.queueVersion + 1,
      transitionCause: reason,
      sessionVersion: state.sessionVersion + 1,
    );
    _startedAt = DateTime.now();
    _deadStreak = 0;
    try {
      await _engine.swapToNext(crossfade: crossfade);
      if (token == _loadToken) {
        _markSourceReady(token);
        _swapping = false;
        unawaited(_preloadAfter(n));
      }
    } catch (error, stack) {
      if (token != _loadToken) return;
      ref.read(talkerProvider).warning('audio swap failed', error, stack);
      if (error is AudioSwapCommittedException) {
        // The incoming source owns the active player already. Stop playback
        // instead of rolling metadata back over a different audio source.
        state = state.copyWith(
          isPlaying: false,
          unplayable: (seq: ++_unplayableSeq, title: n.title, goPlus: n.goPlus),
        );
        _listening.finish(ListeningTransitionCause.unplayable);
        _startListening(n);
        _markSourceReady(token);
        // Publish before cleanup so a failed pause still reports the source
        // error, and delayed cleanup cannot overwrite a newer play/resume.
        try {
          await _engine.pause();
        } catch (pauseError, pauseStack) {
          if (token != _loadToken) return;
          ref
              .read(talkerProvider)
              .warning('audio swap pause failed', pauseError, pauseStack);
        }
        return;
      }
      // Binding failed before the engine committed the incoming player.
      // Restore navigation and metadata, retaining the user's pause intent.
      _history = history;
      _histIdx = historyIndex;
      _recomputeFrontierNext();
      _startedAt = startedAt;
      _maxPosMs = maxPosMs;
      state = state.copyWith(
        track: previous.track,
        position: previous.position,
        buffered: previous.buffered,
        liked: previous.liked,
        queueVersion: state.queueVersion + 1,
      );
      _listening.finish(ListeningTransitionCause.unplayable);
      final track = state.track;
      if (track != null) {
        _startListening(track, positionMs: previous.position.inMilliseconds);
        _markSourceReady(token, positionMs: previous.position.inMilliseconds);
        _maxPosMs = maxPosMs;
      }
      _swapping = false;
      if (track != null) unawaited(_preloadAfter(track));
    } finally {
      if (token == _loadToken) _swapping = false;
    }
  }

  /// Стартовать overlap-crossfade за [_crossfade] до конца текущего трека —
  /// оба плеера играют, уходящий гаснет, входящий набирает. При выключенном
  /// crossfade (0) или неготовом preload — no-op: конец трека обработает
  /// completion-путь (gapless-swap при 0, fade-in next как фолбэк).
  void _maybeStartCrossfade(int posMs, int durMs) {
    if (_swapping) return;
    if (state.repeat || !state.isPlaying) return;
    if (durMs <= 0 || posMs <= 0) return;
    final cf = _crossfade.inMilliseconds;
    if (cf <= 0) return;
    if (!_sourceReady || !_hasMatchingPreload) return;
    final remaining = durMs - posMs;
    if (remaining <= 0 || remaining > cf) return;
    _advanceViaSwap(reason: ListeningTransitionCause.crossfadeCompletion);
  }

  /// Длительность crossfade'а из пользовательских настроек. 0 = gapless.
  Duration get _crossfade => ref.read(playbackPrefsProvider).crossfade;

  void setVolume(double volume) {
    final v = volume.clamp(0.0, 1.0);
    // state.volume = позиция ползунка (линейная, для UI/тултипа), а в движок
    // отдаём перцептивную кривую: слух логарифмичен, а just_audio.setVolume —
    // линейная амплитуда. Без кривой вся полезная тихая зона сжата в нижние
    // ~5% ползунка. Кубическая «audio taper» растягивает её по всему ходу.
    // Смена громкости снимает mute — естественное поведение.
    state = state.copyWith(volume: v, muted: false);
    _engine.setVolume(v * v * v);
  }

  void toggleShuffle() {
    state = state.copyWith(shuffle: !state.shuffle);
    // Сменился режим выбора «следующего» — пересчитать кеш и перепреload'ить.
    _recomputeFrontierNext();
    _refreshPreload();
  }

  void setShuffle(bool on) {
    if (state.shuffle == on) return;
    state = state.copyWith(shuffle: on);
    _recomputeFrontierNext();
    _refreshPreload();
  }

  void toggleRepeat() => state = state.copyWith(repeat: !state.repeat);

  /// Лайк текущего трека: оптимистично в UI + запись в API через общий контроллер
  /// (listener синхронизирует обратно при провале/догрузке). Возвращает исход —
  /// UI показывает предложение верификации при [LikeOutcome.blocked].
  Future<LikeOutcome> toggleLike() async {
    final track = state.track;
    if (track == null) return LikeOutcome.failed;
    state = state.copyWith(liked: !state.liked);
    return ref.read(likedTracksProvider.notifier).toggle(track.id);
  }

  /// Следующий трек. Если мы зашли назад в историю — идём вперёд по реальной
  /// истории (симметрично previous). На фронтире — берём закешированный
  /// [_frontierNext] (новый трек) и дописываем его в историю.
  void next({
    ListeningTransitionCause reason = ListeningTransitionCause.manualNext,
  }) {
    final track = _upNext;
    if (track == null) {
      if (reason == ListeningTransitionCause.naturalCompletion ||
          reason == ListeningTransitionCause.unplayable) {
        _listening.finish(reason);
        state = state.copyWith(transitionCause: reason);
      }
      return;
    }
    _stepHistoryForward(track);
    _activate(track, reason: reason);
  }

  /// Предыдущий трек (или начало текущего, если прошло >3с). Ретрейс назад по
  /// реальной истории — никакой пере-тасовки.
  void previous() {
    if (state.position.inSeconds > 3) {
      _restartListening(ListeningTransitionCause.manualRestart);
      _engine.seek(Duration.zero);
      state = state.copyWith(position: Duration.zero);
      return;
    }
    if (_histIdx > 0) {
      _histIdx--;
      _activate(
        _history[_histIdx],
        reason: ListeningTransitionCause.manualPrevious,
      );
    }
  }

  final Random _rng = Random();

  /// Перетасованный порядок очереди для true-shuffle (полный охват без
  /// повторов внутри цикла), и очередь, на которой он построен.
  List<Track> _order = [];
  List<Track>? _orderSource;

  /// Что заиграет при движении вперёд: если мы зашли назад в историю — её
  /// следующий элемент; на фронтире — закешированный новый трек.
  Track? get _upNext {
    if (_histIdx >= 0 && _histIdx < _history.length - 1) {
      return _history[_histIdx + 1];
    }
    return _frontierNext;
  }

  /// Перевести историю на шаг вперёд к [track]: внутри истории — сдвиг индекса;
  /// на фронтире — дописать новый трек и пересчитать следующий за ним.
  void _stepHistoryForward(Track track) {
    if (_histIdx >= 0 &&
        _histIdx < _history.length - 1 &&
        _history[_histIdx + 1].id == track.id) {
      _histIdx++;
    } else {
      _history.add(track);
      // Мягкий потолок на длинной сессии — обрезаем самые старые записи.
      const cap = 300;
      if (_history.length > cap) {
        _history.removeRange(0, _history.length - cap);
      }
      _histIdx = _history.length - 1;
    }
    _recomputeFrontierNext();
  }

  /// Гарантирует, что `_order` построен на текущей `_queue` (для shuffle).
  void _ensureOrder() {
    if (!identical(_orderSource, _queue) || _order.length != _queue.length) {
      _order = List.of(_queue)..shuffle(_rng);
      _orderSource = _queue;
    }
  }

  /// Пересчитать закешированный «следующий новый» трек на фронтире. Вызывать
  /// после любого изменения текущего фронтир-трека / очереди / режима shuffle.
  void _recomputeFrontierNext() {
    _frontierNext = _generateAfter(_history.isEmpty ? null : _history.last);
  }

  /// Вычислить трек, который должен прозвучать ПОСЛЕ [cur] на фронтире.
  /// Shuffle: следующий в стабильном `_order`; на конце цикла — новая
  /// перетасовка (текущий не идёт первым). Линейно: (idx+1) по кругу.
  /// Может реорганизовать `_order` ровно один раз на границе цикла.
  Track? _generateAfter(Track? cur) {
    if (_queue.length <= 1 || cur == null) return null;
    if (state.shuffle) {
      _ensureOrder();
      var pos = _order.indexWhere((t) => t.id == cur.id);
      if (pos == -1) pos = 0;
      if (pos + 1 < _order.length) return _order[pos + 1];
      // Конец цикла → новая перетасовка для следующего круга.
      _order = List.of(_queue)..shuffle(_rng);
      _orderSource = _queue;
      if (_order.length > 1 && _order.first.id == cur.id) {
        _order.add(_order.removeAt(0)); // не повторять текущий сразу
      }
      return _order.first;
    }
    final idx = _queue.indexWhere((t) => t.id == cur.id);
    if (idx == -1) return _queue.isEmpty ? null : _queue.first;
    return _queue[(idx + 1) % _queue.length];
  }

  void toggle() {
    if (state.track == null) return;
    if (state.isPlaying) {
      _listening.setPlaying(false);
      _engine.pause();
      state = state.copyWith(isPlaying: false);
    } else {
      if (_sourceReady) _listening.setPlaying(true);
      _engine.resume();
      state = state.copyWith(isPlaying: true);
    }
  }

  /// Перемотка по доле (клик по waveform).
  void seekFraction(double fraction) {
    final total = state.track?.durationMs ?? 0;
    if (total == 0) return;
    final pos = Duration(
      milliseconds: (fraction.clamp(0.0, 1.0) * total).round(),
    );
    _listening.seek(pos.inMilliseconds);
    _engine.seek(pos);
    state = state.copyWith(position: pos, seekVersion: state.seekVersion + 1);
  }

  /// Сдвинуть позицию на [delta] (может быть отрицательной), clamp в трек.
  /// Используется для стрелок ←/→ (±5 с).
  void seekBy(Duration delta) {
    final total = state.track?.durationMs ?? 0;
    if (total == 0) return;
    final ms = (state.position + delta).inMilliseconds.clamp(0, total);
    final pos = Duration(milliseconds: ms);
    _listening.seek(pos.inMilliseconds);
    _engine.seek(pos);
    state = state.copyWith(position: pos, seekVersion: state.seekVersion + 1);
  }

  /// Mute/unmute. Mute → движок 0; UI-значение громкости сохраняется в
  /// [state.volume] и восстанавливается при unmute (перцептивная кубическая
  /// кривая, как в [setVolume]).
  void toggleMute() {
    if (state.muted) {
      state = state.copyWith(muted: false);
      final v = state.volume;
      _engine.setVolume(v * v * v);
    } else {
      state = state.copyWith(muted: true);
      _engine.setVolume(0);
    }
  }

  /// Begin a listening fact for [track], stamped with the wave source that
  /// queued it (null for anything played outside my wave).
  void _startListening(Track track, {int positionMs = 0}) => _listening.start(
    trackId: track.id,
    durationMs: track.durationMs,
    positionMs: positionMs,
    source: ref.read(waveSourcesProvider)[track.id],
    obscure: VectorEngine.isObscure(track),
  );

  void _restartListening(ListeningTransitionCause reason) {
    final track = state.track;
    if (track == null) return;
    _listening.finish(reason);
    _startListening(track);
    _listening.setPlaying(_sourceReady && state.isPlaying);
    state = state.copyWith(
      transitionCause: reason,
      sessionVersion: state.sessionVersion + 1,
    );
  }
}

final playerControllerProvider =
    NotifierProvider<PlayerController, PlayerState>(PlayerController.new);
