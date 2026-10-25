# superset workspace setup

internal guide for working on waveform in superset.

## setup

- use Flutter 3.41.0, matching CI, and create fresh worktrees from current
  `origin/main`; the primary checkout may be behind. after workspace creation,
  verify its base with `git rev-parse HEAD origin/main`. one observed roadmap
  planning worktree started at local `main` (`4bc6d7d`) while `origin/main` was
  `0ac370d`; treat this as a workspace-specific incident, not a universal rule.
- `.superset/config.json` runs only `flutter pub get`. enable
  `waitForSetupBeforeAgent: true` in superset settings so agents wait for setup.
- each worktree owns its `.dart_tool/` and `build/` directories. do not symlink
  them or copy build artifacts, secrets, or authentication state between worktrees.
- `run` and `teardown` are empty: creating or deleting a workspace does not
  automatically start or stop the app.
- this minimal lifecycle replaces the previous `.superset/setup.sh`,
  `.superset/run.sh`, and `.superset/teardown.sh`; those scripts are removed
  so fallback discovery cannot launch or stop the app. the optional
  `.superset/site.sh` and `ports.json` remain available for the site workflow.
- keep personal additions in ignored `.superset/config.local.json`.

## flutter mcp

Dart MCP is globally available in the current Codex installation as
`dart-mcp-server`, using `dart mcp-server`. do not add a duplicate `.mcp.json`
into this repository. use this MCP for analysis, tests, app launch, and hot
reload, following `.claude/skills/dev-loop/SKILL.md`.

## macos runtime ownership

only one workspace may own the running app on a machine at a time. worktrees
use the same macOS bundle id, so tokens and preferences in Application Support,
WebView state, media keys, and deep links may overlap. separate build directories
do not isolate these resources.

agree on the owner before launch. record the absolute workspace path, the app ID
returned by `launch_app`, and the DTD URI locally outside git, for example in
`~/.local/state/waveform/runtime-owner.json`. this is a machine-wide ownership
record; do not publish it or save its URI in tracked files. app ID here means
the MCP running app identifier, not the bundle id.

before `launch_app`, connecting to DTD, hot reload, or stopping an app, check the
ownership record against the current workspace. never attach to another
workspace's app. if the record is missing or stale, establish ownership first;
do not infer it from a process name.

before handing ownership over, stop only your own app using its app ID, confirm
that it has exited, and clear your record. the next owner launches from their
own worktree and records their own app ID and DTD URI. do not use `pkill` or stop
another workspace's apps or processes.

## agent sessions

ACP sessions started through the CLI do not push completion into the coordinator's
conversation. while workers run, check `sessions list` and read completed
`agent_message` results with `sessions read`; do not monitor only launch config.
`SUPERSET_WORKER_DONE` is a text marker, not a notification event. consume and
verify finished results before dispatching more work, then stop unused processes
while keeping chat history.

prefer Superset ACP chat sessions and open them in chat panes for planning,
implementation, review, and checks. superset CLI 1.40 exposes `sessions create`,
`sessions read`, `sessions send`, and `sessions open`; an installed orchestration
skill that only documents terminals does not describe this CLI capability.
example advisory planning launch:

```sh
superset sessions create --local --workspace <workspace-id> --agent claude \
  --mode bypassPermissions \
  --prompt "give read-only recommendations; do not edit files"
superset sessions open --local --workspace <workspace-id> --session <session-id>
```

use these model and mode choices:

| workflow | agent | model | ACP mode | reasoning / effort |
| --- | --- | --- | --- | --- |
| implementation | Codex ACP | `gpt-6.1-sol` | `agent-full-access` | `medium` |
| risky work or review | Codex ACP | `gpt-6.1-sol` | `agent-full-access` | `high` |
| mechanical work or checks | Codex ACP | `gpt-6-luna` | `agent-full-access` | `medium` |
| planning recommendations | Claude ACP | Fable preferred; select in picker and verify | `bypassPermissions` | target: `high` |

use `gpt-6-astra` for planning only when Fable through ACP is unavailable. the
sessions CLI has no effort flag. planning prompts must request recommendations
only and explicitly say not to edit files; `bypassPermissions` is the session
mode, while advisory-only behavior comes from the prompt. claude's ACP options
list includes `claude-fable-5-1[1m]`, but the CLI rejects that ID as
unsupported. the CLI accepts `claude-fable-5-1`, yet a created session still
reported Opus. select Fable in the ACP model picker and verify the session
before relying on it;
never infer the selected model from the create argument. codex exposes
`reasoning_effort`, while Claude exposes `effort`. inspect exact IDs and values
through a bounded read that prints only the harness and model/mode/effort
options, omitting prompts, tool output, and large config or skills payloads:

```sh
superset sessions read --local --workspace <workspace-id> --session <session-id> \
  --limit 100 --json |
  jq '[.envelopes[] | select(.event.type == "session") |
    {harness: .event.session.harness,
     options: [.event.session.configOptions[]? |
       select(.id == "model" or .id == "mode" or .id == "effort" or .id == "reasoning_effort") |
       {id, currentValue}]}]'
```

the existing `.superset/agent.sh` and pinned script-bar buttons are legacy
terminal launchers and may still select Fable for `plan`; they are not proof of
ACP harness, model, or reasoning settings. for terminal-launched agents, use:

```sh
sh .superset/agent.sh implement|review|check|plan [prompt]
```

the script runs the selected CLI in the current terminal. prefer ACP sessions
for new agent work.

## worker completion notifier

`.superset/worker_notifier.py` bridges one explicit worker ACP session to one
coordinator ACP session. It reads only completed `agent_message` items carrying
`SUPERSET_WORKER_DONE` or `SUPERSET_WORKER_BLOCKED`; it does not forward tool
output, reasoning, or raw logs. The marker must be a standalone unquoted line
outside fenced code blocks, and the matching ACP turn must be completed. Keep
its per-user JSON config outside the repo:

```json
{
  "source": {"workspace": "worker-workspace-id", "session": "worker-session-id"},
  "target": {"workspace": "coordinator-workspace-id", "session": "coordinator-session-id"},
  "task": "worker task name",
  "since_ms": 1792890000000
}
```

Set `since_ms` to the Unix epoch in milliseconds from which this watcher should
accept completions. It processes all newer undelivered completion markers in
chronological order, then stores a source-and-target-scoped checkpoint. Watch
mode polls every 10 seconds by default and exits with an unavailable status if
the source session disappears on a direct `sessions read`. The capped list is
used only for metadata fallback, not to decide that the source is absent. Start
with
`--dry-run` to inspect the short message without sending or marking it delivered:

```sh
python3 .superset/worker_notifier.py --config ~/.config/superset/worker-notifier.json --dry-run
python3 .superset/worker_notifier.py --config ~/.config/superset/worker-notifier.json
python3 .superset/worker_notifier.py --config ~/.config/superset/worker-notifier.json --watch --interval 10
```

Delivery state is stored atomically under
`~/.local/state/superset/worker-notifier-state.json`; only successful sends
advance the checkpoint. Dedupe is target-scoped; checkpoints are scoped to the
source provider session and target, so a different coordinator can receive the
same result. The notifier rejects identical source and target sessions and uses
a process lock. It reads completed
`event.type: item` messages only when `item.completedAtMs` is present. A
stopped source gets one final history read; an explicit direct-read not-found
response is reported unavailable. Use a distinct `--state` path for each
concurrent watcher. Review the config and dry-run output before enabling sends.

## accepted roadmap recommendations

these are planning recommendations, not completed work: validate a release
before starting another large feature; keep sampled statistics and error
reporting honest about their coverage; prioritize queue accessibility; revisit
theme tokens and mini-window mode afterward. the listening heatmap remains
blocked on confirming the live play-history contract.

the shared setup config takes effect for new workspaces once it is integrated
into the project's base branch. these branch changes do not change
the global default for every workspace. a temporary superset workspace verified
the exact config successfully: workspace setup ran `flutter pub get` and
generated its own `.dart_tool/` directory.

optional `prompt` is task text, for example
`sh .superset/agent.sh review "focus on token storage"`. additional arguments
are treated as task text rather than CLI flags. review/check/plan prompts ask
the agent to read repository rules first and state the role restrictions.
the script uses `exec` to run the selected CLI in the current terminal.
