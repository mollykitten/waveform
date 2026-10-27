#!/usr/bin/env bash
# fails if a widevine device profile (*.wvd, *.wvd.*) exists under any given
# directory (case-insensitive: apfs is). symlinks count too: find matches them by name without following.
#
#   tool/check_no_wvd.sh assets build
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: tool/check_no_wvd.sh <dir>..." >&2; exit 2; }

found="$(find "$@" \( -iname '*.wvd' -o -iname '*.wvd.*' \) -print)"
if [ -n "$found" ]; then
  echo "::error::widevine device profile must not be built or shipped:"
  echo "$found"
  exit 1
fi
