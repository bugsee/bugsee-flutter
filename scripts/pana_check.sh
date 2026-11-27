#!/usr/bin/env bash
# Scores a package the way pub.dev does, with `pana` (the tool behind the points on pub.dev), and fails
# when it loses points it should not.
#
#   scripts/pana_check.sh [PACKAGE_DIR]        (default: the current directory)
#
# Needs `flutter`, `dart` and `jq` on PATH (CI: subosito/flutter-action on the floor, like every other check).
#
# The verdict is per section, from pana's JSON report: every section must be FULL, except the dependencies
# section ("Support up-to-date dependencies"), which may lose PANA_DEPENDENCY_ALLOWANCE points (default 10).
# Its "all dependencies are on their latest version" 10 points move when a dependency publishes, which no commit
# of ours causes; a loss anywhere else is ours and fails, whatever the dependencies section scored.
#
# pana and EVERYTHING it resolves are pinned by tools/pana/pubspec.lock (`dart pub get --enforce-lockfile`), so a
# release of pana or of one of its dependencies cannot change a verdict between two runs of the same commit.
# What it cannot pin: the pub.dev data it reads (the latest versions of OUR dependencies, advisories), which is
# why the dependencies section has an allowance, and the SDKs (this runs on the floor Flutter).
#
# The feedback package cannot be scored until the core version it depends on is on pub.dev (pana resolves
# it from there): release.yml runs it for that package after the core is live, before publishing it.
#
# PANA_REPORT_JSON=FILE judges an existing report instead of running pana (the tests use it).
set -euo pipefail

allowance="${PANA_DEPENDENCY_ALLOWANCE:-10}"
dir="${1:-.}"
here="$(cd "$(dirname "$0")" && pwd)"

case "$allowance" in '' | *[!0-9]*) echo "PANA_DEPENDENCY_ALLOWANCE must be a whole number" >&2; exit 2 ;; esac
command -v jq >/dev/null || { echo "jq is required" >&2; exit 2; }

out="${PANA_REPORT_JSON:-}"
if [ -z "$out" ]; then
  [ -f "$dir/pubspec.yaml" ] || { echo "no pubspec.yaml in $dir" >&2; exit 2; }
  dir="$(cd "$dir" && pwd)"
  flutter_bin="$(command -v flutter)" || { echo "flutter is not on PATH" >&2; exit 2; }
  flutter_root="${FLUTTER_ROOT:-$(cd "$(dirname "$(readlink -f "$flutter_bin")")/.." && pwd)}"

  out="$(mktemp)"
  trap 'rm -f "$out"' EXIT

  # The pinned tool, exactly as locked.
  (cd "$here/../tools/pana" && dart pub get --enforce-lockfile >&2)
  # pana's own exit code is not the verdict (no threshold here); a crash leaves no report.
  set +e
  (cd "$here/../tools/pana" && dart run pana --no-warning --flutter-sdk "$flutter_root" --json "$dir") > "$out"
  code=$?
  set -e
  if ! jq -e '.report.sections | length > 0' "$out" >/dev/null 2>&1; then
    echo "pana produced no report (exit $code)" >&2
    exit 2
  fi
fi

jq -e '.report.sections | length > 0' "$out" >/dev/null 2>&1 || { echo "the pana report has no sections" >&2; exit 2; }

summary="$(jq -r '"pana: \(.scores.grantedPoints)/\(.scores.maxPoints) points", (.report.sections[] | "  \(.title): \(.grantedPoints)/\(.maxPoints)")' "$out")"
echo "$summary"
[ -z "${GITHUB_STEP_SUMMARY:-}" ] || {
  echo "### $dir"
  echo '```'
  echo "$summary"
  echo '```'
} >> "$GITHUB_STEP_SUMMARY"

# Sections that lost more than they may: nothing, except the dependencies section's allowance.
bad="$(jq -r --argjson allow "$allowance" '
  .report.sections[]
  | (.maxPoints - .grantedPoints) as $lost
  | select($lost > (if (.title | test("dependencies"; "i")) then $allow else 0 end))
  | "--- \(.title) (\(.grantedPoints)/\(.maxPoints))\n\(.summary)"' "$out")"

if [ -n "$bad" ]; then
  echo "pana: sections lost points they must not (only the dependencies section may lose up to $allowance):" >&2
  echo "$bad" >&2
  exit 1
fi
