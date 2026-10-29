#!/usr/bin/env bash
# fails unless the release tag, pubspec.yaml and kAppVersion all agree.
#
#   tool/check_version.sh v0.4.0
set -euo pipefail

tag="${1:?usage: tool/check_version.sh <tag>}"
want="${tag#v}"
want="${want%%-*}"
pub="$(sed -nE 's/^version:[[:space:]]*([0-9]+\.[0-9]+\.[0-9]+)\+[0-9]+[[:space:]]*$/\1/p' pubspec.yaml)"
app="$(sed -nE "s/^const kAppVersion = '([^']+)';/\1/p" lib/core/update/app_version.dart)"

[ "$pub" = "$want" ] || { echo "::error::tag $tag != pubspec version $pub"; exit 1; }
[ "$app" = "$want" ] || { echo "::error::tag $tag != kAppVersion $app"; exit 1; }
echo "version ok: $want"
