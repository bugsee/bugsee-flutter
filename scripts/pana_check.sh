#!/usr/bin/env bash
# Scores a package the way pub.dev does, with `pana` (the tool behind the points on pub.dev), and fails
# when it loses more than the allowed points.
#
#   scripts/pana_check.sh [PACKAGE_DIR]        (default: the current directory)
#
# Needs `flutter` and `dart` on PATH (CI: subosito/flutter-action on the floor, like every other check).
# PANA_THRESHOLD: points that may be lost before it fails (default 10: pub.dev's "all dependencies are on
# their latest version" is 10 points and moves when a dependency publishes, which no commit of ours causes;
# anything else we control must be full). PANA_VERSION pins the tool so a new pana cannot change a verdict
# between two runs of the same commit.
#
# The feedback package cannot be scored until the core version it depends on is on pub.dev (pana resolves
# it from there): release.yml runs it for that package after the core is live, before publishing it.
set -euo pipefail

PANA_VERSION="${PANA_VERSION:-0.23.19}"
threshold="${PANA_THRESHOLD:-10}"
dir="${1:-.}"

[ -f "$dir/pubspec.yaml" ] || { echo "no pubspec.yaml in $dir" >&2; exit 2; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

flutter_bin="$(command -v flutter)" || { echo "flutter is not on PATH" >&2; exit 2; }
flutter_root="${FLUTTER_ROOT:-$(cd "$(dirname "$(readlink -f "$flutter_bin")")/.." && pwd)}"

dart pub global activate pana "$PANA_VERSION" >/dev/null

out="$(mktemp)"
trap 'rm -f "$out"' EXIT

# pana's own exit code carries the verdict; its JSON report is read either way.
set +e
dart pub global run pana --no-warning --flutter-sdk "$flutter_root" \
  --exit-code-threshold "$threshold" --json "$dir" > "$out"
code=$?
set -e

if ! jq -e '.scores.maxPoints' "$out" >/dev/null 2>&1; then
  echo "pana produced no report (exit $code)" >&2
  exit 2
fi

summary="$(jq -r --arg v "$PANA_VERSION" '"pana \($v): \(.scores.grantedPoints)/\(.scores.maxPoints) points", (.report.sections[] | "  \(.title): \(.grantedPoints)/\(.maxPoints)")' "$out")"
echo "$summary"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || {
  echo "### $dir"
  echo '```'
  echo "$summary"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

if [ "$code" -ne 0 ]; then
  echo "pana: more than $threshold points lost. The sections below lost points:" >&2
  jq -r '.report.sections[] | select(.grantedPoints < .maxPoints) | "--- \(.title) (\(.grantedPoints)/\(.maxPoints))\n\(.summary)"' "$out" >&2
  exit 1
fi
