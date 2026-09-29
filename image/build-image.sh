#!/usr/bin/env bash
# docker build, retried only when the registry rate-limited us.
#
#   build-image.sh [tag] [context]
#
# The base image is ~1.5 GB from public.ecr.aws and anonymous pulls are limited
# per IP. GitHub-hosted runners share an IP pool, so a public repo with a few
# pushes in an hour hits "429 toomanyrequests: Data limit exceeded" and the
# build dies in seconds at metadata resolution — before it reads a line of the
# Dockerfile. Nothing about the image is wrong; the network said no.
#
# So the build is retried, and ONLY when the log says 429. Any other failure is
# a real failure: it is printed in full and exits non-zero. A retry that
# absorbs real errors is worse than no retry, because it converts a red build
# into a slow green one.
#
# Sourcing this file defines the functions and runs nothing, so the decision
# and the loop can be tested without a registry to rate-limit:
#
#   source image/build-image.sh   # then override run_build and call build_with_retry
set -euo pipefail

TAG="${1:-openclaw-cat-paw:ci}"
CONTEXT="${2:-.}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-4}"
BASE_WAIT_SECONDS="${BASE_WAIT_SECONDS:-30}"

# The whole log, not just the tail: the 429 and the refusal arrive in the same
# line, and matching half of it would miss the case that matters.
is_rate_limited() {
  grep -qE '429 Too Many Requests|toomanyrequests' <<<"$1"
}

run_build() {
  docker build --tag "$TAG" "$CONTEXT"
}

# Seconds to wait before attempt $1 retries. Linear, not exponential: the
# limit here is a rolling data allowance, so backing off hard buys nothing the
# extra wait does not, and a build that has to survive four attempts should
# not take four minutes of sleeping to find that out.
retry_wait() {
  echo $(( $1 * BASE_WAIT_SECONDS ))
}

build_with_retry() {
  local attempt=1 output
  while :; do
    if output="$(run_build 2>&1)"; then
      printf '%s\n' "$output"
      (( attempt > 1 )) && echo "build-image: attempt $attempt succeeded" >&2
      return 0
    fi

    printf '%s\n' "$output" | tail -n 40 >&2

    if ! is_rate_limited "$output"; then
      echo "build-image: the build failed for a reason other than a registry rate limit." >&2
      return 1
    fi

    if (( attempt >= MAX_ATTEMPTS )); then
      echo "::error::registry rate-limited us on $attempt consecutive attempts; the build was never attempted against a reachable registry."
      return 1
    fi

    echo "build-image: registry rate limit (429), attempt $attempt failed; retrying in $(retry_wait "$attempt")s" >&2
    sleep "$(retry_wait "$attempt")"
    attempt=$((attempt + 1))
  done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  build_with_retry
fi
