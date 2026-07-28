#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived_data="$repo_root/.build/DerivedData"
test_log="$(mktemp "${TMPDIR:-/tmp}/codeness-tests.XXXXXX")"

cleanup() {
  rm -f "$test_log"
}
trap cleanup EXIT

cd "$repo_root"
xcodegen generate >/dev/null

if ! xcodebuild \
  -quiet \
  -project Codeness.xcodeproj \
  -scheme Codeness \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data" \
  COMPILER_INDEX_STORE_ENABLE=NO \
  "$@" \
  test >"$test_log" 2>&1; then
  cat "$test_log" >&2
  exit 1
fi

summary="$(
  rg 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' "$test_log" \
    | sed -E 's/^.*Test run with/Test run with/' \
    || true
)"
if [[ -n "$summary" ]]; then
  printf '%s\n' "$summary"
else
  printf 'All tests passed.\n'
fi
