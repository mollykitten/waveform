# roadmap

status as of 2026-10-25. implemented means present in source;
it does not mean released or verified with a live subscribed account.

## implemented

- shuffle across all likes, including pagination.
- keyboard controls, tab traversal and reduced-motion support. a complete
  VoiceOver audit is still pending.
- macOS output selection and the system AirPlay picker. physical receiver
  playback still needs validation.
- model-assisted recommendations grounded in real SoundCloud search results,
  with bounded requests, candidate allowlists and explicit metadata consent.
- the my wave presentation, compact mood controls and separate model settings.
- ChatGPT browser connection with PKCE, signed identity checks and OS secure
  storage; custom OpenAI-compatible and Ollama providers remain available.
- a continuous wave controller that refills the queue outside the screen and
  guards against stale results replacing music chosen by the user.
- independent review of the combined auth, UI, player and audio-engine changes;
  three reproduced playback issues were fixed: source/heard-time attribution,
  stale preload after queue append, and pause/load cancellation.
- final verification: Dart MCP analysis reports no errors; all 356 default
  Flutter tests pass with 10 optional captures skipped; all 36 notifier Python
  tests pass; the macOS debug app builds successfully without launching it.
- local structural vectors from a bounded related-track graph: up to six seed
  interests and twelve related tracks per seed. sampled listening feedback,
  timestamped provenance and stores are bounded and isolated by verified
  SoundCloud identity. ranking includes diversity and exploration.

these vectors describe graph relationships. neural audio embeddings, a server
catalog index and cross-device profile sync are **not implemented**. a valid
local pool needs no model call; cold start, an empty graph and an explicit mood
use the model-assisted path. this is not an index of the whole SoundCloud catalog.

## before shipping this work

- verify interactive ChatGPT OAuth with an eligible account, subscription access
  to inference, native Keychain persistence, restart, refresh and logout.
- exercise generation, one-time bound consent, account/destination changes,
  cancellation and uninterrupted playback/refill on the owned native runtime.
- compare recommendation quality with the graph baseline, including cold start,
  repeated tracks, skipped tracks and a limited candidate pool. passing unit
  tests does not establish musical quality.
- run current analyze/test checks, validate release builds and notarization on a
  clean macOS machine. these source changes have not been released.

## planned: audio embeddings and a recommendation backend

this is a staged plan, not backend implementation. each stage needs evidence
before the next starts.

1. **quality and source experiment.** choose a model and a small, permitted
   evaluation set. establish rights and source-access terms for audio and
   metadata before downloading or processing either. compare model embeddings
   with local graph ranking using held-out listening tasks, retrieval relevance,
   diversity, novelty and repeat rate. proceed only if the musical gain justifies
   measured inference latency and cost.
2. **bounded backend and index.** add an authenticated API and PostgreSQL vector
   index for an explicitly bounded catalog obtained through permitted sources.
   enforce request budgets, rate limits, retries and retention. do not promise
   unrestricted SoundCloud ingestion or bypass access restrictions.
3. **background inference.** run embedding jobs outside the playback/UI path.
   record model/version, dimensionality, source revision, preprocessing and
   provenance with every embedding. make jobs idempotent, support reindexing and
   backfills, and avoid comparing incompatible embedding spaces.
4. **hybrid retrieval and ranking.** combine audio similarity, graph candidates,
   permitted metadata and account-specific listening signals. filter unavailable
   tracks and apply ranking, artist/repeat limits, diversity and deliberate
   exploration. retain the local graph/model fallback when the backend is offline.
5. **profiles and migration.** isolate every account's data. profile sync requires
   separate explicit opt-in; destination-bound model consent does not authorize
   cloud sync. define export, deletion, retention, revocation and account-switch
   behavior before upload. version local/server schemas and make migration
   reversible with a safe local fallback.
6. **operational gates.** evaluate offline quality and consenting live sessions,
   with explicit relevance/diversity thresholds, p95 latency, availability and
   per-user/job cost budgets. add redacted metrics for retrieval, inference,
   queue refill and failures, plus rollout/rollback controls before broad use.

ChatGPT subscription access in the desktop app does not fund or authorize
backend embedding inference. backend compute, storage, model licensing and any
paid inference API need their own budget and access arrangements.

authentication follow-ups: distinguish policy-related HTTP 403 responses from
credential expiry, and review secure-storage cleanup after a terminal refresh
rejection. these do not replace the pending live OAuth checks.

## platform parity and later features

- media keys and now-playing on windows (SMTC) and linux (MPRIS).
- verify the Windows sign-in fixes on Windows; validate Google popup behavior.
- `waveform://` links on windows and linux; Windows code signing.
- light theme following the system; a full VoiceOver pass.
- hour-of-week listening heatmap after confirming the live `played_at` contract.
- lyrics with a permitted external source, drag between playlists, and an
  always-on-top mini player.
- official SoundCloud OAuth 2.1 + PKCE if application registration becomes
  available. this is separate from the implemented ChatGPT connection.
