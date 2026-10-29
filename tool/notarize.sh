#!/usr/bin/env bash
# submits an .app (zipped with ditto) or a .dmg to apple notary service and
# fails unless the submission is accepted. credentials come from the env:
#   NOTARY_KEY_PATH         path to the app store connect api key (.p8)
#   APPLE_API_KEY_ID        key id
#   APPLE_API_ISSUER_ID     issuer id
#
#   tool/notarize.sh build/macos/Build/Products/Release/Waveform.app
#   tool/notarize.sh waveform-macos-v0.4.0.dmg
set -euo pipefail

target="${1:?usage: tool/notarize.sh <app|dmg>}"
: "${NOTARY_KEY_PATH:?}" "${APPLE_API_KEY_ID:?}" "${APPLE_API_ISSUER_ID:?}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

case "$target" in
  *.app)
    # zip preserving symlinks/metadata for notarization
    payload="$work/$(basename "$target").zip"
    /usr/bin/ditto -c -k --keepParent "$target" "$payload"
    ;;
  *.dmg) payload="$target" ;;
  *) echo "unsupported target: $target" >&2; exit 2 ;;
esac

AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$APPLE_API_KEY_ID"
  --issuer "$APPLE_API_ISSUER_ID")

# bounded wait: an unbounded --wait once hung ~3h and died without a log.
OUT=$(xcrun notarytool submit "$payload" "${AUTH[@]}" \
  --wait --timeout 30m --output-format json) || true
echo "$OUT"
ID=$(plutil -extract id raw -o - - <<< "$OUT" 2>/dev/null || true)
STATUS=$(plutil -extract status raw -o - - <<< "$OUT" 2>/dev/null || true)
echo "submission: ${ID:-none} status: ${STATUS:-unknown}"
if [ "$STATUS" != "Accepted" ]; then
  if [ -n "$ID" ]; then
    xcrun notarytool log "$ID" "${AUTH[@]}" || true
  fi
  echo "::error::Notarization not accepted (status: ${STATUS:-unknown})"
  exit 1
fi
