#!/usr/bin/env bash
# Asks the pub.dev API whether a package version is live. Read-only: never needs credentials.
#
#   scripts/pub_dev_status.sh status PACKAGE VERSION
#       prints one word: `live`, `missing-version` (the package exists) or `missing-package`
#   scripts/pub_dev_status.sh wait PACKAGE VERSION [TIMEOUT_SECONDS [INTERVAL_SECONDS]]
#       polls until `live` (exit 0); exit 1 on timeout (default 900 s, every 15 s)
#
# PUB_DEV_API overrides the base URL (the tests use a local server). Any answer other than 200 or
# 404, or a network failure, is an error (exit 2 from `status`), never read as "not there".
set -euo pipefail

api="${PUB_DEV_API:-https://pub.dev}"

http_code() {
  curl --silent --show-error --output /dev/null --write-out '%{http_code}' \
    --max-time 20 --header 'Accept: application/vnd.pub.v2+json' "$1" || echo 000
}

status() {
  local pkg="$1" version="$2" code
  code="$(http_code "$api/api/packages/$pkg/versions/$version")"
  case "$code" in
    200) echo live; return 0 ;;
    404) ;;
    *) echo "pub.dev answered $code for $pkg $version" >&2; return 2 ;;
  esac
  code="$(http_code "$api/api/packages/$pkg")"
  case "$code" in
    200) echo missing-version ;;
    404) echo missing-package ;;
    *) echo "pub.dev answered $code for $pkg" >&2; return 2 ;;
  esac
}

cmd="${1:-}"
case "$cmd" in
  status)
    status "${2:?usage: $0 status PACKAGE VERSION}" "${3:?usage: $0 status PACKAGE VERSION}"
    ;;
  wait)
    pkg="${2:?usage: $0 wait PACKAGE VERSION [TIMEOUT [INTERVAL]]}"
    version="${3:?usage: $0 wait PACKAGE VERSION [TIMEOUT [INTERVAL]]}"
    timeout="${4:-900}"
    interval="${5:-15}"
    deadline=$((SECONDS + timeout))
    while :; do
      # A transient error is retried until the deadline, like "not yet".
      s="$(status "$pkg" "$version" || true)"
      if [ "$s" = live ]; then
        echo "$pkg $version is live"
        exit 0
      fi
      if [ "$SECONDS" -ge "$deadline" ]; then
        echo "::error::$pkg $version is not live on pub.dev after ${timeout}s" >&2
        exit 1
      fi
      echo "waiting for $pkg $version on pub.dev (${s:-no answer})"
      sleep "$interval"
    done
    ;;
  *)
    echo "usage: $0 status PACKAGE VERSION | wait PACKAGE VERSION [TIMEOUT [INTERVAL]]" >&2
    exit 64
    ;;
esac
