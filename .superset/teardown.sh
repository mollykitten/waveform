#!/usr/bin/env bash
# Stops anything started from this workspace (flutter run, the built app,
# the site server) before Superset removes the worktree.
set -uo pipefail

WS="${SUPERSET_WORKSPACE_PATH:-$PWD}"

pkill -f "$WS/build/" 2>/dev/null || true
for pid in $(pgrep -f 'flutter_tools|http.server' 2>/dev/null); do
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')"
  [[ "$cwd" == "$WS"* ]] && kill "$pid" 2>/dev/null
done
exit 0
