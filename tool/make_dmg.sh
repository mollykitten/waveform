#!/usr/bin/env bash
# builds the styled install dmg: background, window size and icon layout.
# needs dmgbuild (pip install dmgbuild==1.6.5). the dmg is unsigned —
# signing, notarization and staple stay in release.yml.
#
#   tool/make_dmg.sh build/macos/Build/Products/Release/Waveform.app \
#     waveform-macos-v0.4.0.dmg "Waveform v0.4.0"
set -euo pipefail

app="${1:?usage: tool/make_dmg.sh <app> <out.dmg> <volname>}"
out="${2:?usage: tool/make_dmg.sh <app> <out.dmg> <volname>}"
volname="${3:?usage: tool/make_dmg.sh <app> <out.dmg> <volname>}"
root="$(cd "$(dirname "$0")/.." && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# 1x + 2x in one tiff, so the background stays sharp on retina.
tiffutil -cathidpicheck \
  "$root/assets/brand/dmg-background.png" \
  "$root/assets/brand/dmg-background@2x.png" \
  -out "$work/background.tiff"

# ditto keeps symlinks, xattrs and the stapled ticket intact.
/usr/bin/ditto "$app" "$work/Waveform.app"

rm -f "$out"
dmgbuild -s "$root/tool/dmg/settings.py" \
  -D app="$work/Waveform.app" \
  -D background="$work/background.tiff" \
  "$volname" "$out"
