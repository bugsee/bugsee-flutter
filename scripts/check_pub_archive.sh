#!/usr/bin/env bash
# Fails if a pub archive (the .tar.gz `flutter pub publish --to-archive=FILE` writes) lists something
# that must never be published: the sibling package, the device verification harness and its app,
# or the dev trees of either package, local
# machine files (an Android Studio `local.properties` carries the developer's SDK path), logs,
# editor files, build output, a lock file.
#
#   scripts/check_pub_archive.sh ARCHIVE...
set -euo pipefail

forbidden='^(\./)?(packages/|pigeons/|ios/wrapper_tests/|ios/feedback_wrapper_tests/|scripts/device/|example/lib/verify_main\.dart|\.git/|\.dart_tool/|\.idea/|migrate_working_dir/|build/|android/build/)|(^|/)(\.build|\.gradle|\.swiftpm)/|(^|/)(local\.properties|pubspec\.lock|\.DS_Store)$|\.(iml|ipr|iws|log|class|swp|pyc)$'

status=0
for archive in "$@"; do
  # Read the listing first: a missing or corrupt archive must fail here, not pass as "no hits".
  listing="$(tar tzf "$archive")"
  hits="$(printf '%s\n' "$listing" | grep -E "$forbidden" || true)"
  if [ -n "$hits" ]; then
    echo "::error::$archive would publish files that must not be published:" >&2
    echo "$hits" >&2
    status=1
  fi
done
exit $status
