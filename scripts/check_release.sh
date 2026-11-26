#!/usr/bin/env bash
# Checks that a release tag names the version both packages carry.
#
#   scripts/check_release.sh TAG        # TAG is `v<version>`, e.g. v10.0.0-beta.1
#
# Exits 0 and prints the version when TAG is `v` + a semantic version, the root pubspec and
# the feedback package's pubspec both say that version, and the top `## ` entry of both
# CHANGELOG.md files is that version. The other repeated copies (wrapper identity in Dart, iOS
# and Android, the feedback lower bound, the native pins) are compared by `flutter test`, which
# the release gate runs; this script only ties the TAG to them. pub.dev requires the same match
# (tag pattern `v{{version}}`), and a tag that disagrees must fail before anything is uploaded.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${1:?usage: $0 TAG}"

semver='[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?'
if ! printf '%s\n' "$tag" | grep -Eq "^v$semver\$"; then
  echo "::error::tag '$tag' is not v<major>.<minor>.<patch>[-prerelease]" >&2
  exit 1
fi
want="${tag#v}"

status=0
check() { # LABEL ACTUAL
  if [ "$2" != "$want" ]; then
    echo "::error::$1 is '$2', the tag says '$want'" >&2
    status=1
  fi
}
pubspec_version() { sed -n -E 's/^version:[[:space:]]*([^[:space:]#]+).*$/\1/p' "$1" | head -n 1; }
changelog_top() { sed -n -E 's/^##[[:space:]]+v?([^[:space:]]+).*$/\1/p' "$1" | head -n 1; }

check "pubspec.yaml version" "$(pubspec_version "$root/pubspec.yaml")"
check "packages/bugsee_flutter_feedback/pubspec.yaml version" "$(pubspec_version "$root/packages/bugsee_flutter_feedback/pubspec.yaml")"
check "CHANGELOG.md top entry" "$(changelog_top "$root/CHANGELOG.md")"
check "packages/bugsee_flutter_feedback/CHANGELOG.md top entry" "$(changelog_top "$root/packages/bugsee_flutter_feedback/CHANGELOG.md")"

[ $status -eq 0 ] && echo "$want"
exit $status
