#!/usr/bin/env bash
# Serves the static landing (site/) on the first free port from 4173 up,
# so several workspaces can preview it side by side.
set -euo pipefail

port="${PORT:-4173}"
while lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; do
  port=$((port + 1))
done

echo "site: http://localhost:$port"
exec python3 -m http.server "$port" --bind 127.0.0.1 --directory site
