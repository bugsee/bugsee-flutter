#!/usr/bin/env bash
# Dry-runs (default) or publishes packages/bugsee_flutter_feedback.
#
#   scripts/publish_feedback.sh                # `flutter pub publish --dry-run`, then checks the archive
#   scripts/publish_feedback.sh --publish      # the real thing (publish bugsee_flutter FIRST); refuses a dirty tree
#   scripts/publish_feedback.sh --stage DIR    # only writes the copy to DIR (for the test of this script)
#
# Why a copy: the root package's .pubignore drops /packages/ so that `bugsee_flutter` does not ship
# its sibling, and pub applies every .pubignore between the git root and the package it publishes,
# so the sibling cannot be published from its own directory in this repository ("The pubspec is
# hidden"). Outside a git checkout pub looks at the package directory only, so the workspace is
# copied to a temporary directory and published from there.
#
# The copy is made from the TRACKED files only (`git ls-files`): outside git pub no longer applies
# the root .gitignore, so copying the working tree would publish whatever an editor or a build left
# in it (an Android Studio local.properties, logs). The archive is checked once more
# (scripts/check_pub_archive.sh). Needs Flutter on PATH (the floor, 3.41.0, as in CI) and rsync.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
mode=(--dry-run)
stage=""
case "${1:-}" in
  "") ;;
  --publish) mode=() ;;
  --stage) stage="${2:?usage: $0 --stage DIR}" ;;
  *) echo "usage: $0 [--publish | --stage DIR]" >&2; exit 64 ;;
esac

if [ ${#mode[@]} -eq 0 ] && [ -n "$(git -C "$root" status --porcelain)" ]; then
  echo "refusing to publish from a dirty working tree; commit or stash first" >&2
  exit 1
fi

if [ -n "$stage" ]; then
  tmp="$stage"
  mkdir -p "$tmp"
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
fi

git -C "$root" ls-files -z | rsync -a --from0 --files-from=- "$root/" "$tmp/"
[ -n "$stage" ] && exit 0

cd "$tmp"
flutter pub get
cd packages/bugsee_flutter_feedback
flutter pub publish ${mode[@]+"${mode[@]}"}
flutter pub publish --to-archive="$tmp/feedback.tar.gz" > /dev/null
"$root/scripts/check_pub_archive.sh" "$tmp/feedback.tar.gz"
