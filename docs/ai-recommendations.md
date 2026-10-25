# ai recommendations

Open **discover**, or `/recommendations`. Configure your own endpoint and model
in settings. Waveform does not install a model server or download weights.

- OpenAI-compatible: a base such as `https://api.openai.com/v1`, or an existing
  local server's `http://127.0.0.1:<port>/v1`. Requests use
  `/v1/chat/completions` and JSON object output.
- native Ollama: `http://localhost:11434`, with the name of a model you already
  have. Requests use `/api/chat`, `stream: false` and `format: json`.
- remote endpoints require HTTPS. Plain HTTP is restricted to exact loopback
  hosts. Redirects are disabled, including redirects to another model endpoint.
- API keys are optional for endpoints that do not require authentication. They
  live only in the current app session and are cleared on account or destination
  changes. They are never written to configuration, provider state or logs.

`ai_config.json` in application support stores only protocol, endpoint, model and
listening-consent preference. Writes are serialized and replace the file via a
temporary file. Listening authorization is revoked on startup, account changes,
destination changes, or explicitly in settings.

Every generation requires an approval dialog listing the exact destination and
data categories for both model calls. Mood text is limited to 500 characters;
links are rejected. Current-track context is optional. Recent likes/history are
separately opt-in and bounded to 20 combined seeds, including the current track.
Only bounded ID/title/artist/genre metadata is sent. Audio, descriptions,
comments, private links, stream URLs and SoundCloud credentials are excluded.

The first model call plans at most two search strings. Those strings go through
the existing `SoundcloudApi.search`. Up to 40 deduplicated, nonblocked tracks
with ordinary playback sources become candidates. The second model call ranks
at most ten candidate IDs and supplies short reasons. Unknown IDs, duplicate IDs,
additional fields, malformed JSON and oversized output are rejected. UI uses
the original SoundCloud `Track` objects and their existing playback queue.
Reasons are labeled model suggestions; no audio analysis or BPM is claimed.
There is no deterministic recommendation fallback if either model stage fails.

Requests have timeouts and response/input caps. Cancel, account changes and
configuration changes invalidate pending generations. Previous successful
results remain available during refresh or retryable failure. Account/config
changes clear them. Model errors expose fixed messages, never raw response
bodies or transport errors. The AI transport has no SoundCloud log interceptors.

## verification handoff

Unit/widget tests use test-only scripted clients and fake SoundCloud fixtures.
They do not prove live model or SoundCloud interoperability.

The runtime owner should verify with an already running, explicitly approved
model server (for example, official llama.cpp with its OpenAI-compatible API):

The parent-owned development server uses `http://127.0.0.1:19381/v1`, model alias
`waveform-dev`, and no API key. Thinking is disabled on the server; the client
expects plain JSON in `choices[0].message.content`. This is a development setup,
not an application default or a bundled runtime. Minimum viewport coverage is
960×640 for navigation, generation, approval, results and AI configuration.

1. Set its loopback `/v1` base and exact model name in settings; leave key blank
   if the server requires none. Do not install or start another model runtime.
2. Generate from a mood without listening metadata. Confirm the approval dialog
   shows the intended endpoint and categories; cancel once and confirm no model
   call occurs. Approve, then verify two model calls and real SoundCloud results.
3. Open a result on SoundCloud and play it in Waveform; verify returned IDs and
   displayed titles match actual search data. Capture the new screen and dialog.
4. Try optional current-track context and signed-in listening opt-in, then
   revoke consent. Check 401/429, unreachable endpoint, malformed model output,
   no matching candidates, refresh, cancellation and account/destination changes.
5. Check app logs with a disposable test key: its value and raw model payloads
   must never appear. Do not inspect or export existing user credentials.

Known source limitation: existing `likesPage`/`historyPage` turn certain
SoundCloud failures into empty results, so an empty seed set cannot establish
whether the library is genuinely empty. Mood-only generation remains possible.
No new SoundCloud endpoint contract is introduced here.

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
