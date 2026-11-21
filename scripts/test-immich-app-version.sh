#!/usr/bin/env bash
# Runnable check for immich-app.sh version helpers.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMMICH_APP_SOURCED=1
# shellcheck disable=SC1091
source "$ROOT/scripts/immich-app.sh"

assert_eq() {
  local got="$1" want="$2" label="$3"
  [[ "$got" == "$want" ]] || { echo "FAIL $label: got='$got' want='$want'" >&2; exit 1; }
}

assert_eq "$(normalize_version '3.4.2')" 'v3.4.2' 'normalize plain'
assert_eq "$(normalize_version 'v3.4.2')" 'v3.4.2' 'normalize v-prefix'
assert_eq "$(normalize_version '{"major":3,"minor":4,"patch":2}')" 'v3.4.2' 'normalize json'

assert_eq "$(normalize_version 'nope' || true)" '' 'normalize invalid'

ec=0
version_cmp v3.4.2 v3.4.2 || ec=$?
[[ "$ec" -eq 0 ]] || { echo 'FAIL 3.4.2 >= 3.4.2'; exit 1; }

ec=0
version_cmp v3.4.2 v3.4.1 || ec=$?
[[ "$ec" -eq 0 ]] || { echo 'FAIL 3.4.2 >= 3.4.1'; exit 1; }

ec=0
version_cmp v3.4.1 v3.4.2 || ec=$?
[[ "$ec" -eq 1 ]] || { echo 'FAIL 3.4.1 < 3.4.2'; exit 1; }

echo 'OK scripts/test-immich-app-version.sh'
