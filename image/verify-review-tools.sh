#!/bin/sh
# Confirm the tiny CLI set is on PATH. Safe as node or root.
set -eu

missing=0
for t in jq yq gh gitleaks shellcheck; do
  if ! command -v "$t" >/dev/null 2>&1; then
    echo "review-tools: missing $t" >&2
    missing=1
  else
    echo "review-tools: $t=$(command -v "$t")"
  fi
done

if [ "$missing" -ne 0 ]; then
  echo "review-tools: image is incomplete. Rebuild with scripts/install.sh." >&2
  exit 1
fi

for t in jq yq gh gitleaks shellcheck; do
  if ! timeout 15 "$t" --version >/dev/null 2>&1 && ! timeout 15 "$t" version >/dev/null 2>&1; then
    echo "review-tools: $t did not start" >&2
    exit 1
  fi
done

echo "review-tools: all baked CLIs start"
