import 'dart:async';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api/liked_tracks.dart';
import '../../core/api/providers.dart';
import '../../core/api/soundcloud_api.dart';
import '../../core/audio/audio_engine.dart';
import '../../core/audio/playback_prefs.dart';
import '../../core/audio/waveform_audio_handler.dart';
import '../../core/log/talker.dart';
import '../../shared/models/track.dart';

/// Событие «трек не проигрался» — для всплывающего уведомления в UI.
/// [seq] растёт с каждым событием, чтобы listener срабатывал и на повтор.
typedef Unplayable = ({int seq, String title});

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
  );
}

class PlayerController extends Notifier<PlayerState> {
  AudioEngine get _engine => ref.read(audioEngineProvider);

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

    _subs.add(
      engine.positionStream.listen((p) {
        if (state.track == null) return;
        // Защита от «протухшего» события позиции, доставленного из broadcast-
        // пайпа старого плеера сразу после смены трека: позиция длиннее нового
        // трека к нему относиться не может — игнорим (иначе прогресс «прилипал»
        // в конце / трек стартовал с середины).
        final dur = state.track!.durationMs;
        if (dur > 0 && p.inMilliseconds > dur + 2000) return;
        if (p.inMilliseconds > _maxPosMs) _maxPosMs = p.inMilliseconds;
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
        if (state.track != null && state.isPlaying != playing) {
          state = state.copyWith(isPlaying: playing);
        }
      }),
    );
    _subs.add(
      engine.completedStream.listen((_) {
        // Crossfade уже идёт (early-trigger по позиции) — не дублируем переход.
        if (_swapping) return;
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
        if (since.inSeconds < 5 || !reachedEnd) return;
        if (state.repeat) {
          _engine.seek(Duration.zero);
          _engine.resume();
        } else if (_engine.hasPreload) {
          // Preload ready → бесшовный swap (gapless или crossfade per prefs).
          _advanceViaSwap();
        } else {
          next();
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
    _queue = (queue != null && queue.isNotEmpty) ? List.of(queue) : [track];
    _orderSource = null; // новый контекст → _order пересоберётся в _ensureOrder
    _order = [];
    _history = [track];
    _histIdx = 0;
    _recomputeFrontierNext();
    _activate(track);
  }

  /// Загрузить трек как текущий БЕЗ изменения очереди/истории (история и
  /// shuffle-порядок ведутся вызывающим). Общий путь для play/next/previous.
  void _activate(Track track) {
    _maxPosMs = 0;
    state = state.copyWith(
      track: track,
      isPlaying: true,
      position: Duration.zero,
      buffered: Duration.zero,
      // Подсветка лайка — из реального множества лайков (а не сброс в false).
      liked: ref.read(likedTracksProvider).contains(track.id),
      queueVersion: state.queueVersion + 1,
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
    state = state.copyWith(queueVersion: state.queueVersion + 1);
  }

  /// Резолв стрима (transcoding → m3u8/mp3) и передача в движок.
  /// Перебирает кандидатов (HLS → progressive): часть HLS-ссылок протухает и
  /// отдаёт 404 — тогда играем следующий источник. Мок/не streamable — тихо.
  Future<void> _load(Track track) async {
    final token = ++_loadToken;
    final candidates = track.streamCandidates;
    // Нет незашифрованных источников (мок/не streamable) — тихо (UI
    // оптимистичен, реальный «играет» придёт из движка).
    if (candidates.isEmpty) return;
    final api = ref.read(soundcloudApiProvider);
    for (final candidate in candidates) {
      try {
        final url = await api.resolveStreamUrl(candidate);
        if (token != _loadToken) return; // пользователь уже переключил трек
        if (url == null) continue; // транскодинг протух — следующий кандидат
        await _engine.load(url);
        if (token != _loadToken) return;
        _startedAt = DateTime.now();
        _deadStreak = 0; // успешная загрузка сбрасывает счётчик мёртвых
        // Фоном prepare'им next — для gapless/crossfade swap'а.
        unawaited(_preloadAfter(track));
        return; // успех
      } catch (e, st) {
        ref
            .read(talkerProvider)
            .warning('stream candidate failed: ${track.title}', e, st);
        if (token != _loadToken) return;
        // пробуем следующий источник
      }
    }
    // Все кандидаты исчерпаны: трек удалён/недоступен или остались только
    // зашифрованные источники.
    ref.read(talkerProvider).warning('no playable stream: ${track.title}');
    _markUnplayable(token, track);
  }

  /// Помечает текущий трек непроигрываемым (видимая причина «unavailable»)
  /// и в очереди перескакивает на следующий, но не более [_maxDeadSkips] подряд,
  /// чтобы цепочка мёртвых треков не пролистала всю очередь.
  void _markUnplayable(int token, Track track) {
    if (token != _loadToken || state.track?.id != track.id) return;
    state = state.copyWith(
      isPlaying: false,
      unplayable: (seq: ++_unplayableSeq, title: track.title),
    );
    if (_queue.length > 1 && ++_deadStreak < _maxDeadSkips) {
      next();
    }
  }

  int _unplayableSeq = 0;

  /// Токен текущей preload-операции — отбрасываем устаревшие резолвы.
  int _preloadToken = 0;

  /// Готовит следующий трек ([_upNext]) в теневом движке: резолвит первый
  /// candidate, кидает engine.preloadNext. Тихо отказывается на пустых.
  /// [current] оставлен для совместимости вызова — целевой трек берётся из
  /// [_upNext], чтобы preload и фактический переход выбрали один и тот же трек.
  Future<void> _preloadAfter(Track current) async {
    final token = ++_preloadToken;
    final n = _upNext;
    if (n == null || n.streamCandidates.isEmpty) {
      await _engine.preloadNext(null);
      return;
    }
    try {
      final url = await ref
          .read(soundcloudApiProvider)
          .resolveStreamUrl(n.streamCandidates.first);
      if (token != _preloadToken) return; // пользователь переключился
      if (url == null) {
        await _engine.preloadNext(null);
        return;
      }
      await _engine.preloadNext(url);
    } catch (_) {
      if (token == _preloadToken) await _engine.preloadNext(null);
    }
  }

  /// Бесшовный переход на preload'ный трек: swap движков + state.track update
  /// БЕЗ полного `_load` (он бы порвал стрим). Затем preload'им следующий.
  /// Ведёт ту же историю, что и ручной [next] — иначе авто-переход и кнопка
  /// расходились бы.
  Future<void> _advanceViaSwap() async {
    final n = _upNext;
    if (n == null) return;
    _swapping = true;
    final crossfade = _crossfade;
    // Бамп _loadToken — старые in-flight кандидаты-резолвы устаревают.
    _loadToken++;
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
    );
    _startedAt = DateTime.now();
    _deadStreak = 0;
    await _engine.swapToNext(crossfade: crossfade);
    unawaited(_preloadAfter(n));
    _swapping = false;
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
    if (!_engine.hasPreload) return;
    final remaining = durMs - posMs;
    if (remaining <= 0 || remaining > cf) return;
    _advanceViaSwap();
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
    final t = state.track;
    if (t != null) unawaited(_preloadAfter(t));
  }

  void setShuffle(bool on) {
    if (state.shuffle == on) return;
    state = state.copyWith(shuffle: on);
    _recomputeFrontierNext();
    final t = state.track;
    if (t != null) unawaited(_preloadAfter(t));
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
  void next() {
    final track = _upNext;
    if (track == null) return;
    _stepHistoryForward(track);
    _activate(track);
  }

  /// Предыдущий трек (или начало текущего, если прошло >3с). Ретрейс назад по
  /// реальной истории — никакой пере-тасовки.
  void previous() {
    if (state.position.inSeconds > 3) {
      _engine.seek(Duration.zero);
      state = state.copyWith(position: Duration.zero);
      return;
    }
    if (_histIdx > 0) {
      _histIdx--;
      _activate(_history[_histIdx]);
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
      _engine.pause();
      state = state.copyWith(isPlaying: false);
    } else {
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
    _engine.seek(pos);
    state = state.copyWith(position: pos);
  }

  /// Сдвинуть позицию на [delta] (может быть отрицательной), clamp в трек.
  /// Используется для стрелок ←/→ (±5 с).
  void seekBy(Duration delta) {
    final total = state.track?.durationMs ?? 0;
    if (total == 0) return;
    final ms = (state.position + delta).inMilliseconds.clamp(0, total);
    final pos = Duration(milliseconds: ms);
    _engine.seek(pos);
    state = state.copyWith(position: pos);
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
}

final playerControllerProvider =
    NotifierProvider<PlayerController, PlayerState>(PlayerController.new);
