#!/usr/bin/env bash
# Prepares a fresh Superset workspace: copies local-only files from the main
# checkout and resolves Dart/Flutter dependencies. Safe to re-run.
set -euo pipefail

ROOT="${SUPERSET_ROOT_PATH:-}"
WS="${SUPERSET_WORKSPACE_PATH:-$PWD}"

# Untracked, machine-local files worth carrying over (copied only if present
# in the main checkout and missing here, so local edits are never clobbered).
COPY=(
  .env
  .env.json
  .superset/config.local.json
  .claude/settings.local.json
  docs/superpowers
)

if [[ -n "$ROOT" && "$ROOT" != "$WS" ]]; then
  for f in "${COPY[@]}"; do
    src="$ROOT/$f"
    dst="$WS/$f"
    [[ -e "$src" && ! -e "$dst" ]] || continue
    mkdir -p "$(dirname "$dst")"
    cp -R "$src" "$dst"
    echo "copied $f"
  done
fi

flutter pub get
echo "workspace ready"
