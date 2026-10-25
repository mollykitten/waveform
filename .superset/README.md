# superset workspace setup

internal guide for working on waveform in superset.

## setup

- use Flutter 3.41.0, matching CI, and create fresh worktrees from current
  `origin/main`; the primary checkout may be behind.
- `.superset/config.json` runs only `flutter pub get`. enable
  `waitForSetupBeforeAgent: true` in superset settings so agents wait for setup.
- each worktree owns its `.dart_tool/` and `build/` directories. do not symlink
  them or copy build artifacts, secrets, or authentication state between worktrees.
- `run` and `teardown` are empty: creating or deleting a workspace does not
  automatically start or stop the app.
- keep personal additions in ignored `.superset/config.local.json`.
- verification on fresh HEAD with Flutter 3.41.0 completed successfully, but
  `flutter pub get` changed five versions in `pubspec.lock`: `matcher`, `meta`,
  `test`, `test_api`, and `test_core`. this reflects a pre-existing mismatch
  between the current checkout's lockfile and this SDK. inspect the lockfile
  diff after setup; do not automatically commit it or run an upgrade without
  a separate task.

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

## agent launches

run from the current workspace root:

```sh
sh .superset/agent.sh implement|review|check|plan [prompt]
```

choose one mode in place of `implement|review|check|plan`:

| mode | CLI | model | reasoning / effort | role |
| --- | --- | --- | --- | --- |
| `implement` | Codex | `gpt-6.1-sol` | `medium` | implementation |
| `review` | Codex | `gpt-6.1-sol` | `high` | review the current diff without edits |
| `check` | Codex | `gpt-6-luna` | `medium` | verification without edits |
| `plan` | Claude | `fable` | `high` | advice and planning, permission mode `plan` |

```sh
sh .superset/agent.sh implement
sh .superset/agent.sh review
sh .superset/agent.sh check
sh .superset/agent.sh plan
```

four project-scoped saved buttons are available in the superset scripts bar:
`waveform · implement`, `waveform · review`, `waveform · check`, and
`waveform · plan`. all four are pinned and ready, using the model and effort
mappings above. their inline commands work in any branch without requiring
the launcher file; the file-based commands above remain an alternative.

the shared setup config takes effect for new workspaces once it is integrated
into the project's base branch. these uncommitted branch changes do not change
the global default for every workspace. a temporary superset workspace verified
the exact config successfully: workspace setup ran `flutter pub get` and
generated its own `.dart_tool/` directory.

optional `prompt` is task text, for example
`sh .superset/agent.sh review "focus on token storage"`. additional arguments
are treated as task text rather than CLI flags. review/check/plan prompts ask
the agent to read repository rules first and state the role restrictions.
the script uses `exec` to run the selected CLI in the current terminal.
