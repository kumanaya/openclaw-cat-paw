#!/usr/bin/env bash
# Regression test for image/build-image.sh: a retry that never fires, or that
# fires on the wrong failure, is worse than no retry at all.
#
# run_build is redefined below and called from build_with_retry in the sourced
# file. `shellcheck -x` follows the source and sees the real call, so there is
# nothing to suppress: without the directive it cannot, and reports the
# overrides as unreachable code. That is a version-dependent trap - the
# runner's shellcheck is newer than the 0.11.0 most people run locally, and
# added SC2317 after the fact.
# shellcheck source=image/build-image.sh
#
# The call count lives in a file, not a variable: build_with_retry captures the
# build log with $(...), so every call runs in a subshell and a shell variable
# incremented inside it never reaches here.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../image/build-image.sh"

BASE_WAIT_SECONDS=0
MAX_ATTEMPTS=4
sleep() { :; }   # no real waiting in a test
COUNTS="$(mktemp)"
trap 'rm -f "$COUNTS"' EXIT

RATE_LIMITED='#2 ERROR: failed to copy: httpReadSeeker: failed open: unexpected status code https://public.ecr.aws/v2/x/manifests/sha256:abc: 429 Too Many Requests - Server message: toomanyrequests: Data limit exceeded'
REAL_FAILURE='ERROR: failed to solve: Dockerfile:13: unknown instruction: FOO'

pass=0
fail=0
check() {
  if [ "$2" = "$3" ]; then
    echo "  pass: $1"
    pass=$((pass + 1))
  else
    echo "  FAIL: $1 (got '$2', want '$3')"
    fail=$((fail + 1))
  fi
}
reset() { : >"$COUNTS"; }
bump() { echo x >>"$COUNTS"; }
count() { wc -l <"$COUNTS" | tr -d ' '; }

# 1. Clean first try: one build, no waiting, no retry.
reset
run_build() { bump; echo "built"; }
out="$(build_with_retry 2>/dev/null)"
check "clean build runs once" "$(count)" "1"
check "clean build reports its output" "$out" "built"

# 2. 429 then success: retried, and it says which attempt worked.
reset
run_build() {
  bump
  if [ "$(count)" -lt 3 ]; then echo "$RATE_LIMITED"; return 1; fi
  echo "built"
}
out="$(build_with_retry 2>/dev/null)"
check "429 is retried until it works" "$(count)" "3"
check "the successful attempt reports" "$out" "built"

# 3. A real build error fails at once. Retrying it would hide it behind a slow
#    green, which is the exact failure mode this script exists to avoid.
reset
run_build() { bump; echo "$REAL_FAILURE"; return 1; }
build_with_retry >/dev/null 2>&1 && rc=0 || rc=1
check "a real failure exits non-zero" "$rc" "1"
check "a real failure is not retried" "$(count)" "1"

# 4. 429 forever: gives up at MAX_ATTEMPTS and leaves an annotation saying why.
reset
run_build() { bump; echo "$RATE_LIMITED"; return 1; }
# Both streams: the ::error:: annotation is a workflow command and belongs on
# stdout, the build log tail on stderr. This test is about the annotation, so
# it has to look at both to find it.
err="$(build_with_retry 2>&1 || true)"
check "a permanent 429 stops at MAX_ATTEMPTS" "$(count)" "4"
case "$err" in
  *"::error::"*) echo "  pass: the permanent 429 leaves an annotation"; pass=$((pass + 1)) ;;
  *) echo "  FAIL: no annotation for a permanent 429"; fail=$((fail + 1)) ;;
esac

# 5. The classifier, on both shapes of the real message and on nothing at all.
is_rate_limited "$RATE_LIMITED" && r=0 || r=1
check "the ECR message is classified as a rate limit" "$r" "0"
is_rate_limited "$REAL_FAILURE" && r=0 || r=1
check "a real build error is not" "$r" "1"
is_rate_limited "" && r=0 || r=1
check "an empty log is not" "$r" "1"

echo
echo "build-image: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
