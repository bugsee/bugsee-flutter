#!/usr/bin/env bash
# Dry-runs (default) or publishes packages/bugsee_flutter_feedback.
#
#   scripts/publish_feedback.sh              # `flutter pub publish --dry-run`
#   scripts/publish_feedback.sh --publish    # the real thing (publish bugsee_flutter FIRST)
#
# Why a script: the root package's .pubignore drops /packages/ so that `bugsee_flutter` does not
# ship its sibling, and pub applies every .pubignore between the git root and the package it
# publishes, so the sibling cannot be published from its own directory in this repository ("The
# pubspec is hidden"). Outside a git checkout pub looks at the package directory only, so this
# copies the workspace (without .git and build output) to a temporary directory and publishes there.
# Needs Flutter on PATH (the floor, 3.41.0, as in CI) and rsync.
set -euo pipefail

mode=(--dry-run)
case "${1:-}" in
  "") ;;
  --publish) mode=() ;;
  *) echo "usage: $0 [--publish]" >&2; exit 64 ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rsync -a --exclude .git --exclude .dart_tool --exclude build --exclude .build --exclude .gradle \
  --exclude Pods "$root/" "$tmp/"
cd "$tmp"
flutter pub get
cd packages/bugsee_flutter_feedback
flutter pub publish ${mode[@]+"${mode[@]}"}
