# my wave

open **my wave** (`/recommendations`, "discover" in the top bar) and press
**play my wave**. with a signed-in SoundCloud account, waveform builds a queue
of real SoundCloud tracks on this device and keeps refilling it while it plays.
there are no settings, no accounts with other services and no consent dialog:
nothing is sent to a model or a third party; only requests to SoundCloud
itself (related tracks, likes) leave the device. without a SoundCloud account
the screen asks you to sign in.

## how a batch is built

candidates come from three sources, interleaved rather than scored on one
scale (a fixed blend hurt the stronger source in the pilots):

- **related** (50% of a batch): the local graph engine ranks related tracks
  of a few seeds, described below. the seeds are the current track, your 20
  newest likes and up to 10 recent plays (30 in total).
- **co-likers** (25%): people who liked your freshest likes, and what else
  they liked. a background job takes your 50 newest likes, up to 50 likers
  of each, keeps neighbours who share at least two of those likes (at most
  150), reads each neighbour's latest 200 public likes and scores a track by
  the summed weight of the neighbours who liked it (weight = shared likes;
  the newest neighbour like breaks ties; a like without a timestamp counts
  as the oldest). a run makes at most 250 requests, paced at 150 ms, with
  exponential backoff on HTTP 429 (a short `Retry-After` is honoured) and is
  cancelled on logout or account switch. the 250 covers the run itself
  (the likes page, likers, neighbour likes, retries); it does not include
  hydrating cached candidates into full tracks with `tracksByIds` when the
  wave refills (one to a few requests, only for ids not yet hydrated), nor
  the single automatic retry the api client makes after a 401. a run that
  gives up after repeated 429s, or loses more than a fifth of its calls to
  other failures, writes nothing: the previous cache stays in place and the
  next attempt waits ten minutes rather than the 24 hours of a finished run.
  it starts after sign-in and when my wave opens,
  never blocks playback, and is cached for 24 hours in
  `co-likers-v1-<identity>.json` (our own track ids and scores only; other
  users' ids are never written to disk). until a cache exists, the wave runs
  on the other two sources.
- **stream** (25%): up to 40 fresh track items of your home stream (uploads
  and reposts of accounts you follow), newest first. empty when signed out
  or when the stream cannot be read.

an empty source hands its share to the next one. before blending, every
source is filtered the same way: blocked, snippet-only and encrypted-only
tracks are dropped (they cannot play), as are your likes, the seeds, tracks
heard, skipped, shown or disliked recently, and tracks already in the wave.
the blended list keeps at most two tracks per artist. likes beyond the first
page are walked, within a bounded time, only to exclude them from the result.
every result is a genuine SoundCloud track with an ordinary playback source,
and its reason says where it came from ("from related tracks…", "from your
stream", "liked by people with similar likes").

each listening fact of a wave track also records its source (`source`:
`related`, `stream` or `coLikers`), so the sources can be compared by listens
and skips; stats shows a one-line tally per source. facts stay on the device.

## local graph recommendations and learning

with a verified SoundCloud identity, **play my wave** builds a queue locally.
it uses up to six distinct playable seeds, preferring different artists, and
fetches at most 12 public related tracks per seed. returned tracks are not
expanded recursively and pagination links are not followed. candidates are
genuine SoundCloud track objects with ordinary playback sources.

the local ranker builds sparse structural vectors from seed-to-related-track
edges and ranks by cosine similarity across separate seed interests. it
diversifies results, limits any artist to two tracks, and uses every fifth
position to explore a less-observed interest. these six seed interests do not
claim to be general genre clusters. nothing is sent to a model.

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
collaborative learning. the one-button flow adds no settings. offline
pilots in 2026-10 found audio taste-profile embeddings no better than random
and co-liker collaborative filtering a two-to-seven-times wider candidate
source than this graph; see "offline pilots on public likes" below and the
[roadmap](roadmap.md).

the core supports continuation batches: previously recommended ids are excluded
before ranking, and a batch stops if no new candidates remain, without endless
retries. a persistent wave controller continues to refill the playback queue
after leaving the screen, including early refill for a one-track batch. it
stops on exhaustion, explicit cancellation, an account change or a replacement
playback queue. late initial results and appends cannot take over playback
selected by the user.

requests have deadlines. cancellation and account changes invalidate pending
generations. successful results remain available during refresh or retryable
failure. errors expose fixed messages without response bodies or transport
exceptions.

## dislike in my wave

while a track queued by the active wave plays, the player shows a thumbs-down
button (expanded and collapsed layouts). pressing it stores the track id and
its artist handle in the local seen memory for the verified identity, skips to
the next track, and shows a toast with undo, which removes the entry.

what it changes, all on the device:

- the track is excluded for 365 days.
- the interests (seeds) the track was related to lose up to 40% of their
  weight per dislike, weighted by the stored related-graph edges and decayed
  with the usual 30-day half-life. the total reduction is capped at 60%, so one
  or several dislikes never zero an interest.
- candidates whose structural vector is close (cosine) to the centroid of the
  20 latest disliked tracks are ranked lower, and tracks by the same artist get
  a mild multiplier (0.7 per dislike, at most three). nothing else is excluded.
- the seen memory (dislikes included) is local: it is deleted for an account
  when that account logs out.
- dislikes are kept ahead of ordinary seen entries (up to 500) when the store
  is trimmed.

limits: this works on sparse seed-to-related-track vectors, not audio. a
dislike only shifts candidates that share seeds with the disliked track. the
effect on real recommendation quality has not been measured.

## removed: the model-assisted route

earlier builds could also plan search queries and rank search results with a
language model (a ChatGPT connection or a custom OpenAI-compatible/Ollama
endpoint), steered by a typed mood and a metadata consent. the offline pilots
([roadmap](roadmap.md), "evidence: offline candidate-source pilots") showed
that route reached none of 100 held-out likes: the search channel itself is
the ceiling, below the related graph, so the whole layer was removed rather
than kept as a fallback. dev builds may leave a keychain item
`waveform.chatgpt.credentials.v1` and an `ai_config.json` in the support
directory; both are unused and can be deleted by hand. the full history of
that route (connection, consent, live evidence) is in git.

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
- the removed model-assisted route (plan searches, search, rank), reproduced
  with its own prompts on a local Qwen3-1.7B for ten batches per user, reached
  0 of 100 held-out likes for every user; no held-out like entered a
  candidate pool. deterministic searches without a model (profile genres,
  seed uploader names, tags) reached 3 / 9 / 13 / 3, below the graph for
  three of four users and below CF for all, so the search channel, not the
  model, is the ceiling. the route is not a recommendation source. the track
  mapper's `electronic` default for an empty genre reaches the prompt as a
  fake genre for up to half of a user's seeds.
- offline evaluation on public likes is exhausted: four users, 100 positives
  each, wide intervals and look-ahead bias. the next evidence is like/skip
  outcomes per candidate source inside the app, after v0.4.0 ships.
