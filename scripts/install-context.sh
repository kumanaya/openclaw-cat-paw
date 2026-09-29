#!/usr/bin/env bash
# Land Cat Paw context in an OpenClaw home.
#
# OpenClaw has no SOUL.md. The persona is the workspace's AGENTS.md, and it is
# the same file the project context lives in — so this script has one file to
# write, not two.
#
# On the Compose image the base's boot renders /opt/plow/prompt/AGENTS.md
# (copied from PERSONA.md here) into /var/lib/plow/workspace/AGENTS.md on every
# start. This script does NOT write that file in the container: the persona is
# already in the image and the next boot would overwrite anything written now.
#
# An existing OpenClaw (--home) has no such boot, so the Cat Paw section is
# appended to <home>/workspace/AGENTS.md, or refreshed in place if it is
# already there. The rest of that file is never touched: an AGENTS.md the owner
# wrote is theirs, and a persona in it that somebody edited stays edited. Only
# a missing AGENTS.md is created, and then it is created as the persona plus
# the section.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERSONA="$ROOT/PERSONA.md"
SECTION="$ROOT/context/AGENTS.section.md"
COMPOSE=(docker compose -f "$ROOT/compose.yml")
SERVICE=openclaw-cat-paw
WORKSPACE=/var/lib/plow/workspace
HOME_DIR=""
BEGIN='<!-- cat-paw:agents -->'
END='<!-- /cat-paw:agents -->'

# `docker compose exec` under Git Bash rewrites any argument that looks like a
# leading-slash path into a Windows one before the process sees it.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

usage() {
  cat <<EOF
Usage: $(basename "$0") [--home OPENCLAW_STATE_DIR]

  --home DIR  Write into DIR/workspace/AGENTS.md (existing OpenClaw install).
              DIR is an OpenClaw state directory, ~/.openclaw by default.
              Default: report only. The Compose persona is baked into the
              image and the base renders it on every boot.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      HOME_DIR="${2:-}"
      [[ -n "$HOME_DIR" ]] || { echo "install-context.sh: --home needs a directory." >&2; exit 1; }
      shift 2
      ;;
    --home=*)
      HOME_DIR="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "install-context.sh: unexpected argument: $1" >&2
      exit 1
      ;;
  esac
done

[[ -f "$PERSONA" && -f "$SECTION" ]] || { echo "install-context.sh: missing PERSONA.md or context section." >&2; exit 1; }

# Print the marked section on stdout.
marked_section() {
  printf '%s\n' "$BEGIN"
  cat "$SECTION"
  if [[ -s "$SECTION" ]] && [[ "$(tail -c 1 "$SECTION" || true)" != $'\n' ]]; then
    printf '\n'
  fi
  printf '%s\n' "$END"
}

# Rewrite $1 so the Cat Paw section is present and current. The rest of the
# file is kept. A missing file is created as PERSONA.md plus that section.
apply_agents() {
  local file="$1"
  local tmp marked
  tmp="$(mktemp)"
  marked="$(mktemp)"
  marked_section >"$marked"
  if [[ ! -f "$file" ]]; then
    cat "$PERSONA" >"$tmp"
    # A file with no trailing newline would glue the heading to the last line.
    [[ ! -s "$PERSONA" || "$(tail -c 1 "$PERSONA" || true)" == $'\n' ]] || printf '\n' >>"$tmp"
    printf '\n' >>"$tmp"
    cat "$marked" >>"$tmp"
  elif grep -F -q "$BEGIN" "$file"; then
    awk -v begin="$BEGIN" -v end="$END" -v ins="$marked" '
      $0 == begin {
        while ((getline line < ins) > 0) print line
        close(ins)
        skip = 1
        next
      }
      skip && $0 == end { skip = 0; next }
      !skip { print }
    ' "$file" >"$tmp"
  else
    cat "$file" >"$tmp"
    [[ ! -s "$file" || "$(tail -c 1 "$file" || true)" == $'\n' ]] || printf '\n' >>"$tmp"
    printf '\n' >>"$tmp"
    cat "$marked" >>"$tmp"
  fi
  mv "$tmp" "$file"
  rm -f "$marked"
}

if [[ -n "$HOME_DIR" ]]; then
  workspace="$HOME_DIR/workspace"
  mkdir -p "$workspace"
  apply_agents "$workspace/AGENTS.md"
  echo "install-context.sh: Cat Paw section is in $workspace/AGENTS.md"
  echo "install-context.sh: the rest of that file is untouched"
  exit 0
fi

if [[ -z "$("${COMPOSE[@]}" ps -q "$SERVICE" 2>/dev/null || true)" ]]; then
  echo "install-context.sh: nothing to do for the Compose image." >&2
  echo "The persona is PERSONA.md, baked at /opt/plow/prompt/AGENTS.md and" >&2
  echo "rendered into $WORKSPACE/AGENTS.md on every boot." >&2
  echo "For an existing OpenClaw, re-run with --home OPENCLAW_STATE_DIR." >&2
  exit 1
fi

# Confirm the fact rather than assert it. The boot owns this file; writing it
# here would be undone by the next start, so the only useful check is that the
# persona we baked is the one the boot is holding.
rendered="$("${COMPOSE[@]}" exec -T -u node "$SERVICE" sh -c \
  "grep -c 'chaotic builder cat' '$WORKSPACE/AGENTS.md' 2>/dev/null || true" | tr -d '\r' | tail -n 1)"
if [[ "${rendered:-0}" -ge 1 ]]; then
  echo "install-context.sh: $WORKSPACE/AGENTS.md carries the Cat Paw persona"
  echo "install-context.sh: rendered on every boot from /opt/plow/prompt/AGENTS.md"
else
  echo "install-context.sh: $WORKSPACE/AGENTS.md has no Cat Paw persona." >&2
  echo "That file is written by the base's boot from the image's prompt. Rebuild" >&2
  echo "the image (scripts/install.sh) and check: docker compose logs $SERVICE" >&2
  exit 1
fi
