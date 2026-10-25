#!/usr/bin/env bash
# Launches the desktop app in debug mode (hot reload in this pane).
# Flutter picks a random VM-service port, so parallel workspaces don't collide.
# Optional local secrets (LASTFM_API_KEY, LASTFM_SHARED_SECRET, MOCK=true, ...)
# go into a gitignored .env and are passed as --dart-define values.
set -euo pipefail

case "$(uname -s)" in
  Darwin) device=macos ;;
  Linux) device=linux ;;
  *) device=windows ;;
esac

args=(-d "$device")
[[ -f .env ]] && args+=(--dart-define-from-file=.env)

exec flutter run "${args[@]}" "$@"
