# ai recommendations

open **my wave**, or `/recommendations`. choose **Continue with ChatGPT** once,
then **play my wave**. an **add a mood (optional)** field lets you steer the
selection; no endpoint, model name or API key is needed for ChatGPT. with an
empty mood, approved listening context and a verified SoundCloud identity, the
button can use local graph recommendations without a model request. a nonempty
mood continues through the existing model-assisted discovery route. without
account context, a mood or public discovery request can still supply a starting
point.

## ChatGPT connection

the default connection uses the official [open-source sign-in flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
for eligible ChatGPT plans. waveform opens the system browser, binds a temporary
callback listener to `127.0.0.1`, and uses OAuth authorization code + PKCE. it
registers a client dynamically and retains the issued client ID and a stable
host identifier for returning sign-ins. no Codex token files, browser cookies,
client secret or partner API key are used.

state and nonce are fresh for each attempt. before activating a connection,
waveform verifies the ID-token signature against OpenAI's JWKS, issuer,
audience, expiry, nonce and subject. a pending or failed sign-in does not replace
the active account. OAuth and inference transports disable redirects and do not
use SoundCloud logging interceptors.

access, refresh and retained ID tokens live in OS secure storage. on macOS,
this uses the legacy encrypted Keychain with data-protection sharing disabled,
which avoids a shared-keychain provisioning requirement. linux requires an
unlocked secret service; see [development](development.md). there is no plaintext
credential fallback. refreshes are serialized, rotating credentials are saved
together, and transient storage failures can be retried. logout attempts remote
revocation and clears local tokens while retaining the registration and host.
if remote revocation cannot be confirmed, the UI directs the user to disconnect
waveform in ChatGPT settings.

waveform requests the signed-in account's model catalog and chooses its first
visible model in server order. subscription inference uses only the public
`https://api.openai.com/v1/responses` endpoint with `store: false`, `stream: true`,
an input array and instructions. it omits unsupported sampling and output-limit
fields. streamed text is accepted only after `response.completed`; failed,
incomplete or interrupted responses are rejected, including subscription usage
failures delivered after text has begun. these contracts follow the official
[models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
and [preview limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations)
documentation.

## listening permission and custom providers

the first wave asks permission to send the displayed metadata categories to the
chosen destination. this choice is remembered across batches and restarts for
the same SoundCloud identity, AI connection and permission scope. logout,
confirmed account changes, destination changes, custom credential changes or
revocation in settings require a new approval. a delayed or offline account
restore does not erase a saved approval: the binding is checked again before
listening metadata can be sent.

`ai_config.json` stores only public protocol, endpoint, model, consent and an
opaque consent binding. serialized writes replace the file through a temporary
file. the binding contains no OAuth tokens. recent likes/history and the current
track are bounded to 20 combined seeds. only bounded ID/title/artist/genre
metadata and an optional mood are sent. mood text is limited to 500 characters
and rejects links. audio, descriptions, comments, private links, stream URLs and
SoundCloud credentials are excluded.

**advanced settings** preserves existing custom providers:

- OpenAI-compatible: an HTTPS `/v1` base or an existing loopback server's
  `http://127.0.0.1:<port>/v1`; requests use chat completions and JSON output.
- native Ollama: an existing `http://localhost:11434` server and installed model;
  requests use `/api/chat`, `stream: false` and `format: json`.
- custom API keys are optional and remain in memory for the current session.
  they are cleared on SoundCloud account or destination changes and never enter
  configuration files, provider state or logs.
- remote endpoints require HTTPS; plain HTTP is restricted to exact loopback
  hosts. redirects are disabled. waveform does not install a server or download
  model weights.

## recommendation batches

the existing model-assisted route uses one model call to plan at most two
search strings for `SoundcloudApi.search`. up to 40 deduplicated, nonblocked
tracks with ordinary playback sources become candidates. a second model call
ranks at most ten candidate IDs and supplies short reasons. unknown or
duplicate IDs, extra fields, malformed JSON and oversized output are rejected.
results retain the original SoundCloud `Track` objects and use the existing
playback queue. reasons are suggestions; no audio analysis or measured BPM is
claimed. model failures do not produce fabricated recommendations.

## local graph recommendations and learning

when the mood is empty, listening permission is approved, and the SoundCloud
identity is verified, **play my wave** first tries local recommendations. it
uses up to six distinct playable seeds, preferring different artists, and
fetches at most 12 public related tracks per seed. returned tracks are not
expanded recursively and pagination links are not followed. candidates are
genuine SoundCloud track objects with ordinary playback sources.

the local ranker builds sparse structural vectors from seed-to-related-track
edges and ranks by cosine similarity across separate seed interests. it
diversifies results, limits any artist to two tracks, and uses every fifth
position to explore a less-observed interest. these six seed interests do not
claim to be general genre clusters. a valid local pool needs no model call; if
the graph produces no candidates, the existing model-assisted route remains the
fallback (an offline pilot found it reaches no held-out likes; see "offline
pilots on public likes" below). a nonempty mood always uses that existing
route. local listening facts are not added to model requests.

the player records explicit transition causes and sampled listening facts.
advancing playback counts as heard time; pauses, seeks, buffering, and playback
errors do not count as negative feedback. sampling gaps longer than two seconds
are discarded. during crossfade, the outgoing track continues to accrue heard
time only until the overlap begins. a listen of at least 30 seconds and 70% of
track duration is positive evidence. a manual next without seeking can be
negative evidence when heard time is 5–30 seconds and below 25% of track
duration. other transitions, including unplayable tracks, are neutral. feedback
support decays with a 30-day half-life.

facts are stored locally per verified SoundCloud identity in an atomic bounded
store of at most 2,000 records and 2 MiB. the store holds track IDs and playback
facts, not titles, stream URLs, audio, or SoundCloud payloads. account changes
clear current playback attribution while identity is unresolved. vector
provenance is persisted separately with limits of 600 latest vectors, 1,200
timestamped revisions, 2,000 session attributions, and 512 KiB. related edges
are timestamped after retrieval completes, so a newly fetched edge cannot be
backdated to a session that occurred during retrieval. session attribution is
preserved across repeated generations and reloads; unknown earlier context
stays unknown. listening to a seed track also updates that seed's own interest
without counting the same fact twice.

this is sparse graph ranking, not neural audio embeddings. waveform does not
download models, index the full SoundCloud catalog, or perform global
collaborative learning. the one-button flow adds no new settings. offline
pilots in 2026-10 found audio taste-profile embeddings no better than random
and co-liker collaborative filtering a two-to-seven-times wider candidate
source than this graph; see "offline pilots on public likes" below and the
[roadmap](roadmap.md).

the core supports continuation batches: previously recommended IDs are excluded
before ranking, with a bounded recent exclusion list sent to the planner. a
batch stops if no new candidates remain, without endless retries. a persistent
wave controller continues to refill the playback queue after leaving the screen,
including early refill for a one-track batch. it stops on exhaustion, explicit
cancellation, connection changes or a replacement playback queue. late initial
results and appends cannot take over playback selected by the user.

requests have deadlines and response/input caps. cancellation, account and
configuration changes invalidate pending generations. successful results remain
available during refresh or retryable failure; connection changes clear stale
results. errors expose fixed messages without response bodies or transport
exceptions.

## dislike in my wave

while a track queued by the active wave plays, the player shows a thumbs-down
button (expanded and collapsed layouts). pressing it stores the track id and
its artist handle in the local seen memory for the verified identity, skips to
the next track, and shows a toast with undo, which removes the entry.

what it changes, all on the device:

- the track is excluded for 365 days in every mode, including a nonempty mood,
  where it only filters candidates after the search.
- the interests (seeds) the track was related to lose up to 40% of their
  weight per dislike, weighted by the stored related-graph edges and decayed
  with the usual 30-day half-life. the total reduction is capped at 60%, so one
  or several dislikes never zero an interest.
- candidates whose structural vector is close (cosine) to the centroid of the
  20 latest disliked tracks are ranked lower, and tracks by the same artist get
  a mild multiplier (0.7 per dislike, at most three). nothing else is excluded.
- the seen memory (dislikes included) is local and unrelated to the model
  connection: it is deleted for an account when that account logs out, and
  disconnecting chatgpt does not erase it.
- dislikes are kept ahead of ordinary seen entries (up to 500) when the store
  is trimmed.

limits: this works on sparse seed-to-related-track vectors, not audio. a
dislike only shifts candidates that share seeds with the disliked track, and a
track served in mood mode has no stored graph vector, so there it only
excludes the track and softens its artist. dislikes, the centroid and the
penalties are never sent to a model. the effect on real recommendation quality
has not been measured.

## verification handoff

an earlier core verification passed **51 tests** across auth, SSE transport,
consent, config, providers, service and model parsing. targeted analysis reported
no errors and `git diff --check` was clean. coverage includes signed identity and
PKCE exchange, negative callback/token checks, refresh and logout races,
secure-storage recovery, persisted consent and identity recovery, continuation
exclusions, and existing custom-provider behavior. the later adjustment to send
the most recent exclusion IDs passed all nine service tests.

four later privacy regressions cover every generation relying on remembered
consent, including mood/current-track requests without history: an anonymous
restored identity sends nothing, a confirmed new identity revokes and persists
the stale grant, unavailable identity preserves the grant while blocking
requests until recovery, and a late lookup cannot revoke replacement settings.
the final consent/provider run passed **16 tests**, with no analyzer errors.

the focused UI/controller verification passed **23 tests**. it exercised a wave
across screen disposal through four batches and 16 tracks, one-track prefetch,
exhaustion without retries, late initial playback and appends after a foreign
queue replaces the wave while keeping the same current track, configuration,
authentication and explicit cancellation, denied reconnect, and the advanced
another-account action. the previous complete default `test/` suite passed all
**218 tests** through Dart MCP; that is the prior baseline, not verification of
the current graph and listening increment. the macOS debug build also exited successfully
and produced `Waveform.app`; this does not verify native Keychain access,
interactive OAuth or subscribed live inference.

before/after screen and settings captures at 960×640 were reviewed at
`/tmp/waveform-wave-ui/{before,after}-{screen,settings}-960x640.png`. these are
widget-harness renders with test fixtures, not screenshots of a live signed-in
account.

these tests use injected credentials, network adapters and SoundCloud fixtures;
the loopback listener is also tested with real local HTTP requests. they do not
prove an interactive ChatGPT login, native Keychain access or subscribed live
inference. public OpenAI discovery and JWKS metadata were checked without an
account login. no existing user tokens were read and no application runtime was
launched for the core work.

the runtime owner should verify the complete flow on the owned runtime:

1. complete **Continue with ChatGPT** in the user's browser, then confirm native
   secure storage, restart restoration, refresh and logout/revocation behavior.
2. cancel the initial metadata dialog and confirm no model generation occurs;
   approve once, then verify subsequent waves use the same bound approval.
3. generate with automatic likes/history context and with an optional mood;
   confirm public Responses requests, real SoundCloud results and playback.
4. verify continuation/refill behavior, cancellation and stale playback guards,
   then account/destination changes and explicit permission revocation.
5. check fixed messages for denied access, usage limits, unavailable services,
   malformed output and missing candidates. capture the screen and consent
   dialog at a 960×640 viewport. tokens and raw model payloads must not appear in
   app logs; do not inspect or export existing credentials.

known source limitation: existing `likesPage`/`historyPage` turn certain
SoundCloud failures into empty results, so empty seeds cannot establish whether
the library is genuinely empty.

the current increment's focused player/listening verification passed **63
tests**. vector, service, and consent verification passed **32 tests**. an
independent read-only high-risk review reported no findings. a combined 250-test
run exposed one widget-test failure: its harness had not drained the legitimate
120 ms mocked identity lookup, which also exposed a late-identity regression.
the existing widget test now drains that lookup. production code was unchanged
for this fix apart from null-aware style cleanup. final whole-root Dart MCP
verification passed all **252 default tests**, with analyzer reporting no
errors or diagnostics. `git diff --check` is clean, and the latest macOS debug
build succeeded without launching the app. these checks do not evaluate live
recommendation quality or verify interactive OAuth, native Keychain access, or
subscribed inference. the graph and listening facts remain within the existing
ChatGPT connection, consent, and verified-identity gates.

the historical live evidence below covers the advanced custom-provider route
before the ChatGPT integration. its earlier suite counts and UI descriptions
are not verification of the current subscription connection or continuous wave.

## live client evidence — 2026-10-25

The explicit manual test `test/recommendations/live_ai_smoke.dart` passed against
the parent-owned server at `http://127.0.0.1:19381/v1`, alias `waveform-dev`,
without an API key. The real `HttpAiClient` sent one bounded request containing
only the public mood `quiet instrumental ambient music for reading` and an
empty seed list. The strict parser accepted the returned plan:
`{"queries":["quiet instrumental ambient music for reading"]}`. Elapsed client
time was 1234 ms. No app was launched and no server lifecycle was changed.

The server/model identity supplied by the runtime owner was llama.cpp 0.7.0
(`620d2225c`) with official Qwen3-1.7B-GGUF Q8 at revision
`90862c4b9d2787eaed51d12237eafdfe7c5f6077`, thinking disabled. This client smoke
does not independently verify model hashes, SoundCloud search, model ranking or
native playback; the runtime owner performs that end-to-end proof separately.

The manual file deliberately has no `_test.dart` suffix, so normal CI test
discovery does not contact any model server. Run it explicitly only after the
runtime owner authorizes that loopback endpoint.

## live recommendation service evidence — 2026-10-25

`test/recommendations/live_recommendation_smoke.dart` passed both explicit live
tests against the same parent-owned model server. It uses the production
`RecommendationService`, `HttpAiClient`, anonymous `HttpSoundcloudApi` and real
`ClientIdResolver`. Observation wrappers forward every real request unchanged;
there are no fake adapters or catalog fixtures. No auth provider, token file,
account, API key, current track or listening history is used.

Each flow asserts exactly two model calls, one or two actual SoundCloud searches,
an empty seed list, at most 40 candidates containing only ID/title/artist/genre,
and one to ten unique allowlisted results. Each result is the identical `Track`
object returned by the production search API, has an ordinary playback source,
is not blocked, and has a public HTTPS SoundCloud permalink without query data.
Only public result IDs, titles and permalinks are printed. The combined test
runner reported two passes at 7 seconds, without launching the app. Production
source was unchanged by this verification.

Mood: `instrumental ambient music for quiet reading` — one result:

| id | title | public permalink |
| --- | --- | --- |
| 1231485607 | Quiet - Calm Ambient Piano Background Music / Beautiful Relaxing Music (Free Download) | https://soundcloud.com/ashamaluevmusic/quiet |

Mood: `energetic drum and bass music for running` — nine results:

| id | title | public permalink |
| --- | --- | --- |
| 1982585711 | Best Drum and Bass of 2024 - 180 BPM (DnB for Running / Drum & Bass Workout) | https://soundcloud.com/easytygermusic/best_drumnbass_2024 |
| 1104685495 | Music For Running Drum And Bass Mix | https://soundcloud.com/creativehype/music-for-running-drum-and-bass-mix |
| 27801601 | DODECAPHONIC DRUM AND BASS WITH FLANGERS | https://soundcloud.com/tsen/tsen-dodecaphonic |
| 392364942 | Precision - Music For People (Koherent Remix)[FREE DOWNLOAD] | https://soundcloud.com/drumandbassarena/precision-music-for-people-koherent-remixfree-download |
| 1353697273 | Music For Bass Drum & Snare Drum and Two Fans | https://soundcloud.com/corentin-marillier/music-for-bass-drum-snare-drum-two-fans |
| 2140446639 | Best Running Mix In The World Ever / DnB for Workout (Best Drum and Bass Summer 2025) 174 BPM | https://soundcloud.com/easytygermusic/best-running-mix-in-the-world-ever-dnb-for-workout-best-drum-and-bass-summer-2025-176-bpm |
| 1888882860 | Best Running Mix In The World Ever / DnB for Workout (Best Drum and Bass Summer 2024) 180 BPM | https://soundcloud.com/easytygermusic/40-180bpmdnb-summer-2024 |
| 708481942 | amendoim drum and bass virtual dj set | https://soundcloud.com/lfmontag451c/amendoim-drum-and-bass-virtual-dj-set |
| 264369853 | Precision - Music For People | https://soundcloud.com/drumandbassarena/precision-music-for-people |

These titles are reproduced from live SoundCloud metadata, including any BPM
text uploaded by their owners; Waveform has not measured audio tempo. This
proves the live plan → search → rank flow and original-object grounding, not
native playback, musical-quality scoring, or signed-in listening behavior.
The manual file is excluded from default test discovery by its filename.

on 2026-10-25, a separate bounded read-only probe selected one playable public
track from `/search/tracks` and requested `/tracks/{id}/related?limit=12` with
the existing public client-id flow. the related endpoint returned HTTP 200 and
12 entries. all 12 parsed through the existing `PageDto` and `TrackDto` classes;
all had ordinary stream candidates. the probe inspected no stream URLs and
downloaded no audio. this verifies one public response shape, not broad endpoint
availability or recommendation quality.

Review follow-up: a delayed-store widget test reproduced clear → edit → save
overlap leaving active replacement configuration behind a misleading cleared
form. Save and clear now share a busy guard; endpoint/model/key fields, protocol
and section actions are disabled until persistence finishes. The regression
also verifies replacement edits save normally after clear completes. The final
default suite passed 177 tests. Both public-mood live service tests passed again
(one ambient result and the same nine drum-and-bass results, 5 seconds in the
runner). The only production change in this follow-up is the settings UI;
AI transport, prompts, service and ID validation remain unchanged.


## integrated presentation evidence — 2026-10-25

PRs #53–#55 supply the approved ambient hero, compact controls and header
alignment. the ChatGPT/continuous-wave integration retains that presentation:
one play action, one remembered destination/account consent, an optional mood
shelf and custom provider fields hidden in advanced settings. local structural
vector ranking adds no new user choices. see [roadmap](roadmap.md) for the
planned broader candidate sources; the audio-embedding backend plan was
dropped after the 2026-10-27 pilots.

the combined UI/settings/presentation run passed 20 tests, with two optional
settings captures skipped; targeted analysis reported no errors. a separate
manual renderer passed four captures using real fonts at 960×640. reviewed
before evidence from the #55 tree is under
`/Users/flakke/.superset/worktrees/waveform/feat/notes-integrated-20261025/build/visual-review/`
(`wave-idle-960x640.png`, `wave-tune-open-960x640.png`,
`wave-consent-960x640.png`, `ai-settings-960x640.png`). combined captures are
`/tmp/waveform-wave-ui/integrated-{connected,unconnected}-{screen,settings}-960x640.png`;
the updated consent and tuning captures are in this worktree's ignored
`build/visual-review/` directory. the unconnected screen asserts that the
ChatGPT connection action is visible and tappable without scrolling. the
connection button uses the existing 3px corner token.

these are widget-harness renders with injected account/data fixtures, not
native signed-in runtime screenshots. no app was launched or attached during
integration. interactive OAuth, native secure storage, subscription inference,
musical quality and physical AirPlay remain outside this evidence.


final independent review of the combined authentication, consent/UI, player and
audio-engine changes reported no remaining blocker. playback regressions cover
old audio during pending track resolution, appended-queue preload identity,
source-generation feedback ownership, and pause/load cancellation and timeout.
waiting for source readiness preserves the user's paused state and cancels on
source replacement, stop or disposal. this review does not resolve the pending
live-account and musical-quality checks above.


## final combined verification — 2026-10-25

independent verification of the final combined source reported:

- Dart MCP analyzer: no errors.
- default Flutter suite: **356 passed**, **10 optional captures skipped**.
- notifier Python suite: **36/36 passed**.
- macOS debug build: successful,
  `build/macos/Build/Products/Debug/Waveform.app`; the app was not launched.
- staged and working-tree `git diff --check`: clean.

independent review and the coordinator's player/audio diff review found no
remaining blocker after fixing three reproduced issues: old-source listening
attribution while the next track resolves, stale preload after queue append,
and pause/load cancellation. focused regressions include readiness cancellation
on replacement, stop and disposal, failed/superseded loads and rapid pause/resume.

the successful build still emitted nonfatal warnings about an unused
`audio_session` expression, deprecated `javaEnabled`, missing Metal toolchain
Swift search paths and an always-running script phase. it was not warning-free.
these checks do not verify release signing/notarization, interactive ChatGPT
OAuth, native Keychain persistence, subscription inference, musical quality or
physical AirPlay playback. those remain explicit follow-up work in the roadmap.

## offline pilots on public likes — 2026-10-27

four offline pilots measured candidate sources against the public likes of
four SoundCloud users (the owner and three sampled by a fixed procedure), using
only public api-v2 endpoints with `client_id` and a local model. for each user
the 100 newest likes were held out as truth and the 100 freshest earlier likes
served as seeds. the bench and cached responses live outside the repository;
the full outcome table is in the [roadmap](roadmap.md).

- audio taste-profile embeddings (CLAP centroid or 5-nn of the seeds) ranked
  held-out likes no better than random against hard negatives; AUC was below
  0.5 on every slice and cosine between random tracks was 0.94–0.98. the
  taste-profile use of audio embeddings is a no-go.
- the related graph used by the local core is precise where it reaches
  (recall@10 0.21 on reachable likes) but reaches 14 / 7 / 25 / 17 of 100
  held-out likes.
- co-liker collaborative filtering (likers of the seeds, neighbours with at
  least two shared seeds, their recent likes) reaches 44 / 52 / 76 / 39 of 100
  and is almost a superset of the graph for three of four users. on a balanced
  negative pool it beats the graph on recall@10 for the owner; on the product
  metric (held-out likes in the top 50 of each method's own list) the two are
  indistinguishable for all but one user. CF is a candidate source, not a
  proven ranker. 16–30% of its candidates were unplayable or DRM-only.
- 48 of 100 owner likes were reachable by neither source; followed uploaders
  cover 26 of them, which points at the authenticated home stream as the next
  source the app can read and the pilots could not.
- the model-assisted route above (plan searches, search, rank), reproduced
  with its own prompts on a local Qwen3-1.7B for ten batches per user, reached
  0 of 100 held-out likes for every user; no held-out like entered a
  candidate pool. deterministic searches without a model (profile genres,
  seed uploader names, tags) reached 3 / 9 / 13 / 3, below the graph for
  three of four users and below CF for all, so the search channel, not the
  model, is the ceiling. the route is not a recommendation source; its only
  remaining use is translating a typed mood into search strings. the track
  mapper's `electronic` default for an empty genre reaches the prompt as a
  fake genre for up to half of a user's seeds.
- offline evaluation on public likes is exhausted: four users, 100 positives
  each, wide intervals and look-ahead bias. the next evidence is like/skip
  outcomes per candidate source inside the app, after v0.4.0 ships.
