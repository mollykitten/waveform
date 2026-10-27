# roadmap

status as of 2026-10-27. implemented means present in source;
it does not mean released or verified on a clean machine or with a live
subscribed account.

## implemented

- shuffle across all likes, including pagination.
- keyboard controls, tab traversal and reduced-motion support. a complete
  VoiceOver audit is still pending.
- macOS output selection and the system AirPlay picker. physical receiver
  playback still needs validation.
- the my wave presentation: one play action, no model settings. the model
  route (ChatGPT connection, custom providers, mood field, metadata consent)
  was removed after the pilots below; see [my-wave.md](my-wave.md).
- a continuous wave controller that refills the queue outside the screen and
  guards against stale results replacing music chosen by the user.
- independent review of the combined auth, UI, player and audio-engine changes;
  three reproduced playback issues were fixed: source/heard-time attribution,
  stale preload after queue append, and pause/load cancellation.
- final verification on main (2026-10-27): `flutter analyze` reports no issues;
  499 default Flutter tests pass with 8 optional captures skipped. the macOS
  debug app builds in CI; nothing here was run against a live account.
- local structural vectors from a bounded related-track graph: up to six seed
  interests and twelve related tracks per seed. sampled listening feedback,
  timestamped provenance and stores are bounded and isolated by verified
  SoundCloud identity. ranking includes diversity and exploration.

- persistent per-account memory of shown, played, skipped and disliked tracks
  (`SeenStore`) so a restart no longer replays what was just heard; the wave
  keeps a staged candidate pool with seed rotation, a second related level and
  genre search under a request budget, and retries instead of going quiet.
- a dislike button for wave tracks: the track is skipped and removed from the
  queue, not recommended again for a year, and lowers the matching seed
  interests; undo restores the previous state.
- sign-out clears the webview session and token file, token access is
  serialized, and pending chatgpt revocations are kept on 408/429.
- macOS release pipeline signs inside out and notarizes with an app store
  connect api key (`tool/notarize.sh`); a `*.wvd` device profile fails the build.
  no real run yet: it needs the accepted apple agreement, an api key and a
  developer id certificate.

these vectors describe graph relationships. neural audio embeddings, a server
catalog index and cross-device profile sync are **not implemented**. my wave
runs entirely on this device and makes no model call. this is not an index of
the whole SoundCloud catalog.

## before shipping this work

- exercise generation, account changes, cancellation and uninterrupted
  playback/refill on the owned native runtime.
- compare recommendation quality with the graph baseline, including cold start,
  repeated tracks, skipped tracks and a limited candidate pool. passing unit
  tests does not establish musical quality.
- run current analyze/test checks, validate release builds and notarization on a
  clean macOS machine. these source changes have not been released.

## evidence: offline candidate-source pilots — 2026-10-27

four offline pilots ran against the public likes of four SoundCloud users
(the owner plus three users sampled by a fixed procedure; the 100 newest likes
of each held out as truth, the 100 freshest earlier likes as seeds). only
public api-v2 endpoints with `client_id` and a local model were used; no
tokens, cookies or app storage were read. the bench, scripts and cached
responses live outside the repository and the reports were shared as 7-day
pastes, so the outcomes are recorded here.

- **audio taste-profile embeddings: no-go.** CLAP vectors of the seeds, as a
  centroid or 5 nearest neighbours, ranked held-out likes no better than
  random against hard negatives (recall@10 0.00–0.01, AUC below 0.5 on every
  slice). cosine between random tracks was 0.94–0.98, so the usable signal is
  a thin band. an earlier playlist-based "conditional go" measured genre
  purity, not personal taste, and did not transfer. no embedding cache or
  backend is justified for the taste-profile use. item-to-item "more like this
  track" and dedup/diversity remain the only plausible audio uses, untested.
- **related graph: precise but narrow.** where the 1-hop related graph of the
  seeds reaches a held-out like it ranks it well (recall@10 0.21 on reachable
  likes), but it reaches only 14 of 100 owner likes and 7 / 25 / 17 for the
  other users. 2-hop reaches 30 at about 1,100 requests per user, too
  expensive for the client.
- **co-liker collaborative filtering: confirmed as a candidate source, not as
  a ranker.** likers of the seeds, then neighbours with at least two shared
  seeds, then their recent likes reached 44 / 52 / 76 / 39 of 100 held-out
  likes, two to seven times the graph; for three of four users the graph set
  is almost a subset of the CF set. on a negative pool balanced between graph-
  and CF-reachable negatives, CF recall@10 was 0.12 against 0.03 for the owner
  (paired difference +0.09, 95% CI 0.02–0.16). on the product metric (held-out
  likes landing in the top 50 of each method's own candidate list) CF and the
  graph were indistinguishable for every user except a dense techno profile;
  the CF list is about 20 times longer and its per-candidate precision far
  lower. cost about 250 requests and 2 minutes per user; graph plus CF about
  350 requests and 3–4 minutes as a background job.
- **ceiling on public data.** 48 of 100 owner likes were reachable by neither
  graph nor CF. followed uploaders cover 26 (24 of them outside the graph) and
  reposts by followings 7; both approximate the home stream, which the pilots
  could not read (`/stream` requires oauth) but the signed-in app can.
- **playability.** 16–30% of CF candidates were unplayable or DRM-only against
  2–12% of graph candidates; a product list needs a playability filter and
  the hydration requests that implies.
- **model-assisted search route: not a recommendation source.** the existing
  route (a model plans one or two search strings from 20 seeds, SoundCloud
  search supplies up to 40 candidates, the model ranks ten) was reproduced
  with the app's own prompts on a local Qwen3-1.7B through llama.cpp and run
  for ten batches per user. it reached 0 of 100 held-out likes for every
  user, and no held-out like ever entered a candidate pool. the search channel
  itself is the ceiling: deterministic queries without any model (profile
  genres, seed uploader names, tags; 29–36 queries per user) reached 3 / 9 /
  13 / 3 of 100, below the graph for three of four users and below CF for
  all; five random control words reached 0. the model's queries were genre
  templates ("electronic beats", "Dance & EDM tracks"); none of 90 named an
  uploader or a track. 9% of ranking replies were invalid under the app's
  strict parser, which ends a batch. a stronger model could reach the
  uploader-name level of the ceiling, which is still below the graph, so the
  conclusion does not depend on model size. the route was removed entirely,
  mood field included. side finding, since fixed: the track mapper
  substituted `electronic` for an empty genre, so half of some users' seeds
  reached the prompt with a fake genre.
- **limits.** four users, one of them degenerate (100 likes in a single day),
  100 positives each, wide intervals including zero on most pairs, and
  look-ahead bias because followings, likers and neighbour likes were fetched
  today. offline evaluation on public likes is exhausted; the next evidence
  has to come from like/skip signals on recommended tracks inside the app.

## planned: broader candidate sources for my wave

this replaces the earlier plan for audio embeddings and a vector backend. it
starts after v0.4.0 ships (horizon 0). each stage needs evidence before the
next starts.

1. **candidate sources.** (implemented, unreleased) add co-liker CF (bounded: 50 likers per seed, at
   least two shared seeds, 200 recent likes per neighbour, a neighbour cap) and
   the authenticated home stream next to the related graph. run them as a
   background job with an on-disk cache and incremental refresh, never on the
   playback path, within explicit request budgets and backoff on rate limits.
   the batch interleaves the sources 50% related / 25% co-likers / 25% stream
   instead of blending scores; see [my-wave.md](my-wave.md).
2. **filtering and ranking.** (implemented) drop unplayable and DRM-only candidates before
   ranking; exclude known likes, seeds and recent recommendations; keep
   artist/repeat limits, diversity and deliberate exploration. rank CF
   candidates by neighbour weight and recency of the neighbour's like. do not
   ship a fixed 0.5 graph/CF blend: in the pilot it hurt CF on its own
   reachable slice.
3. **in-app evaluation.** (facts recorded; comparison pending) record local, redacted like/skip/completion outcomes
   per candidate source for recommended tracks and compare sources on live
   sessions. offline pilots cannot answer which source ranks better.
4. **backend, only if needed.** a server index is justified only if the
   per-user request budget or latency of client-side CF proves unacceptable in
   step 3. the earlier backend requirements still apply: account isolation,
   deletion and retention rules, separate explicit opt-in for profile sync,
   local fallback, quality, latency and cost gates, redacted metrics and
   rollout/rollback controls.

backend compute, storage, model licensing and any paid inference API would
need their own budget and access arrangements.

## platform parity and later features

- media keys and now-playing on windows (SMTC) and linux (MPRIS).
- verify the Windows sign-in fixes on Windows; validate Google popup behavior.
- `waveform://` links on windows and linux; Windows code signing.
- light theme following the system; a full VoiceOver pass.
- hour-of-week listening heatmap after confirming the live `played_at` contract.
- lyrics with a permitted external source, drag between playlists, and an
  always-on-top mini player.
- official SoundCloud OAuth 2.1 + PKCE if application registration becomes
  available.
