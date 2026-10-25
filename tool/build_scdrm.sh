#!/usr/bin/env bash
# Собирает Go DRM-ядро (third_party/scdrm) в macOS-динамигу для dart:ffi.
# Результат: macos/Runner/Frameworks/libscdrm.dylib — Xcode-фаза Copy Files
# кладёт её в Contents/Frameworks бандла, Dart грузит через @rpath.
#
#   tool/build_scdrm.sh            # arch хост-машины
#   tool/build_scdrm.sh arm64 x86_64   # затем lipo в universal
set -euo pipefail
cd "$(dirname "$0")/../third_party/scdrm"

OUT=../../macos/Runner/Frameworks
mkdir -p "$OUT"

host_arch() {
  case "$(uname -m)" in
    arm64) echo arm64 ;;
    x86_64) echo x86_64 ;;
    *) echo "" ;;
  esac
}

archs=("$@")
if [ ${#archs[@]} -eq 0 ]; then archs=("$(host_arch)"); fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
files=()
for a in "${archs[@]}"; do
  case "$a" in
    arm64) goarch=arm64 ;;
    # Go-имя архитектуры Intel — amd64; lipo/clang используют x86_64.
    x86_64) goarch=amd64 ;;
    *) echo "неизвестная архитектура: $a" >&2; exit 1 ;;
  esac
  echo "building $a (GOARCH=$goarch)"
  MACOSX_DEPLOYMENT_TARGET=12.0 \
    CGO_ENABLED=1 GOOS=darwin GOARCH="$goarch" \
    CGO_CFLAGS="-arch $a -mmacosx-version-min=12.0" \
    CGO_LDFLAGS="-arch $a -mmacosx-version-min=12.0" \
    go build -buildmode=c-shared -o "$tmpdir/libscdrm-$a.dylib" ./cmd/scdrm
  files+=("$tmpdir/libscdrm-$a.dylib")
done

if [ ${#files[@]} -gt 1 ]; then
  lipo -create -output "$OUT/libscdrm.dylib" "${files[@]}"
else
  cp "${files[0]}" "$OUT/libscdrm.dylib"
fi

install_name_tool -id @rpath/libscdrm.dylib "$OUT/libscdrm.dylib"
codesign --force --sign - "$OUT/libscdrm.dylib"
echo "-> $OUT/libscdrm.dylib ($(lipo -archs "$OUT/libscdrm.dylib"))"
