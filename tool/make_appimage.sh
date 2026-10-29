#!/usr/bin/env bash
# packs the flutter linux bundle into an AppImage with embedded update info
# (gh-releases-zsync) and writes the .zsync next to it.
#
#   tool/make_appimage.sh build/linux/x64/release/bundle v0.4.0
#
# produces waveform-<tag>-x86_64.AppImage and waveform-<tag>-x86_64.AppImage.zsync
# in the current directory. needs `zsyncmake` (apt: zsync) for the .zsync.
# the appimage does not bundle gtk/webkit: same system libs as the tar.gz.
set -euo pipefail

bundle="${1:?usage: tool/make_appimage.sh <bundle-dir> <tag>}"
tag="${2:?usage: tool/make_appimage.sh <bundle-dir> <tag>}"
[ "$(uname -m)" = "x86_64" ] || { echo "x86_64 only" >&2; exit 2; }

TOOL_VERSION=1.9.1
TOOL_SHA256=ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0
UPDATE_INFO='gh-releases-zsync|mollykitten|waveform|latest|waveform-*-x86_64.AppImage.zsync'
here="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL -o "$work/appimagetool" \
  "https://github.com/AppImage/appimagetool/releases/download/$TOOL_VERSION/appimagetool-x86_64.AppImage"
echo "$TOOL_SHA256  $work/appimagetool" | sha256sum -c -
chmod +x "$work/appimagetool"

appdir="$work/Waveform.AppDir"
mkdir -p "$appdir/usr/bin"
cp -a "$bundle"/. "$appdir/usr/bin/"
cp "$here/linux/appimage/waveform.desktop" "$appdir/waveform.desktop"
cp "$here/assets/icon/icon.png" "$appdir/waveform.png"
cp "$here/assets/icon/icon.png" "$appdir/.DirIcon"
cat > "$appdir/AppRun" <<'RUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
exec "$HERE/usr/bin/waveform_app" "$@"
RUN
chmod +x "$appdir/AppRun"

# never pack a widevine profile, before and after squashing
"$here/tool/check_no_wvd.sh" "$appdir"

out="waveform-$tag-x86_64.AppImage"
rm -f "$out" "$out.zsync"
APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$work/appimagetool" \
  --updateinformation "$UPDATE_INFO" "$appdir" "$out"
chmod +x "$out"
[ -f "$out.zsync" ] || { echo "::error::$out.zsync was not produced (install zsync)"; exit 1; }

mkdir "$work/extracted"
(cd "$work/extracted" && "$OLDPWD/$out" --appimage-extract >/dev/null)
"$here/tool/check_no_wvd.sh" "$work/extracted"
ls -lh "$out" "$out.zsync"
