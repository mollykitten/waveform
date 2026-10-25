# ai recommendations

open **my wave**, or `/recommendations`. choose **Continue with ChatGPT** once,
then **play my wave**. an **add a mood (optional)** field lets you steer the
selection; no endpoint, model name or API key is needed for ChatGPT. when signed
in to SoundCloud, the approved context includes recent listening, likes and the
current track automatically. without that account context, a mood or public
discovery request can still supply a starting point.

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

the first model call plans at most two search strings for the existing
`SoundcloudApi.search`. up to 40 deduplicated, nonblocked tracks with ordinary
playback sources become candidates. the second model call ranks at most ten
candidate IDs and supplies short reasons. unknown or duplicate IDs, extra
fields, malformed JSON and oversized output are rejected. results retain the
original SoundCloud `Track` objects and use the existing playback queue. reasons
are suggestions; no audio analysis or measured BPM is claimed. model failures
do not produce deterministic or fabricated recommendations.

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
another-account action. the complete default `test/` suite then passed all
**218 tests** through Dart MCP. the macOS debug build also exited successfully
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
the library is genuinely empty. no new SoundCloud endpoint contract is
introduced here.

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

Review follow-up: a delayed-store widget test reproduced clear → edit → save
overlap leaving active replacement configuration behind a misleading cleared
form. Save and clear now share a busy guard; endpoint/model/key fields, protocol
and section actions are disabled until persistence finishes. The regression
also verifies replacement edits save normally after clear completes. The final
default suite passed 177 tests. Both public-mood live service tests passed again
(one ambient result and the same nine drum-and-bass results, 5 seconds in the
runner). The only production change in this follow-up is the settings UI;
AI transport, prompts, service and ID validation remain unchanged.
