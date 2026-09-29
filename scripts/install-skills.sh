#!/usr/bin/env bash
# Load the pinned Anthropic Cybersecurity Skills pack into an OpenClaw home.
# Default destination is the running Compose agent's workspace skills root on
# the state volume — a runtime clone, not a layer, so it survives a rebuild.
# Authorized testing only: the pack, SECURITY.md, and
# skills/cybersecurity-pack/SKILL.md all say so.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIN="$ROOT/vendor/cybersecurity-skills.pin"
TOOLS="$ROOT/.tools/cybersecurity-skills"
COMPOSE=(docker compose -f "$ROOT/compose.yml")
SERVICE=openclaw-cat-paw
PACK_NAME=cybersecurity-skills
SKILLS_ROOT=/var/lib/plow/workspace/skills
DOCS=(LICENSE SECURITY.md SCOPE.md AGENTS.md README.md index.json)
HOME_DIR=""
LIST_ONLY=0

# `docker compose exec` under Git Bash rewrites any argument that looks like a
# leading-slash path into a Windows one before the process sees it.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

usage() {
  cat <<EOF
Usage: $(basename "$0") [--home OPENCLAW_STATE_DIR] [--list]

  --home DIR  Install into DIR/workspace/skills/cybersecurity-skills
              (an existing OpenClaw state directory).
              Default: the running Compose container.
  --list      Fetch the pin, print SKILL.md count per subdomain, do not copy.

These playbooks are for targets the owner owns or has written permission
to test. Latch should approve live probes (browser, nmap, curl).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home)
      HOME_DIR="${2:-}"
      [[ -n "$HOME_DIR" ]] || { echo "install-skills.sh: --home needs a directory." >&2; exit 1; }
      shift 2
      ;;
    --home=*)
      HOME_DIR="${1#*=}"
      shift
      ;;
    --list)
      LIST_ONLY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "install-skills.sh: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      echo "install-skills.sh: unexpected argument: $1" >&2
      exit 1
      ;;
  esac
done

repo="$(sed -n 's/^repo=//p' "$PIN")"
sha="$(sed -n 's/^sha=//p' "$PIN")"
[[ -n "$repo" && -n "$sha" ]] || { echo "install-skills.sh: malformed $PIN" >&2; exit 1; }

ensure_clone() {
  mkdir -p "$(dirname "$TOOLS")"
  if [[ ! -d "$TOOLS/.git" ]]; then
    echo "install-skills.sh: cloning cybersecurity-skills"
    git clone --depth 1 "$repo" "$TOOLS"
  fi
  if [[ -f "$TOOLS/.git/info/sparse-checkout" ]]; then
    git -C "$TOOLS" sparse-checkout disable
  fi
  echo "install-skills.sh: checking out $sha"
  git -C "$TOOLS" fetch --depth 1 origin "$sha"
  git -C "$TOOLS" checkout --detach "$sha"
  got="$(git -C "$TOOLS" rev-parse HEAD)"
  if [[ "$got" != "$sha" ]]; then
    echo "install-skills.sh: expected $sha, got $got" >&2
    exit 1
  fi
}

count_skills() {
  find "$TOOLS/skills" -name SKILL.md -type f | wc -l
}

print_domains() {
  echo "install-skills.sh: skills per subdomain (frontmatter):"
  find "$TOOLS/skills" -name SKILL.md -type f -print0 |
    xargs -0 grep -h '^subdomain:' |
    sed 's/^subdomain:[[:space:]]*//;s/["'\'']//g' |
    sort | uniq -c | sort -nr
}

ensure_clone

n="$(count_skills)"
n="${n#"${n%%[![:space:]]*}"}"
echo "install-skills.sh: $n SKILL.md files at $sha"
print_domains

if (( LIST_ONLY )); then
  "$ROOT/scripts/install-skill-packs.sh" --list
  exit 0
fi

[[ -d "$TOOLS/skills" ]] || { echo "install-skills.sh: missing skills/ in checkout" >&2; exit 1; }

archive() {
  tar -C "$TOOLS/skills" -cf - .
}

copy_docs() {
  local dest="$1"
  local name
  for name in "${DOCS[@]}"; do
    if [[ -f "$TOOLS/$name" ]]; then
      cp -f "$TOOLS/$name" "$dest/$name"
    fi
  done
}

install_tree() {
  local dest="$1"
  mkdir -p "$dest"
  archive | tar -C "$dest" -xf -
  copy_docs "$dest"
  echo "install-skills.sh: wrote $dest ($n skills)"
}

if [[ -n "$HOME_DIR" ]]; then
  install_tree "$HOME_DIR/workspace/skills/$PACK_NAME"
  "$ROOT/scripts/install-skill-packs.sh" --home "$HOME_DIR"
  bash "$ROOT/scripts/install-context.sh" --home "$HOME_DIR"
  exit 0
fi

if [[ -z "$("${COMPOSE[@]}" ps -q "$SERVICE" 2>/dev/null)" ]]; then
  echo "install-skills.sh: Compose agent is not running." >&2
  echo "Start it with scripts/install.sh, or pass --home OPENCLAW_STATE_DIR." >&2
  exit 1
fi

echo "install-skills.sh: copying pack into the Compose agent"
"${COMPOSE[@]}" exec -T -u 0 "$SERVICE" mkdir -p "$SKILLS_ROOT/$PACK_NAME"
archive | "${COMPOSE[@]}" exec -T -u 0 "$SERVICE" tar -C "$SKILLS_ROOT/$PACK_NAME" -xf -
stage="$(mktemp -d)"
copy_docs "$stage"
tar -C "$stage" -cf - . |
  "${COMPOSE[@]}" exec -T -u 0 "$SERVICE" tar -C "$SKILLS_ROOT/$PACK_NAME" -xf -
rm -rf "$stage"
"${COMPOSE[@]}" exec -T -u 0 "$SERVICE" chown -R node:node "$SKILLS_ROOT/$PACK_NAME"
landed="$("${COMPOSE[@]}" exec -T -u node "$SERVICE" sh -c \
  "find $SKILLS_ROOT/$PACK_NAME -name SKILL.md -type f | wc -l")"
landed="${landed//$'\r'/}"
if [[ "${landed//$'\r'/}" -lt 1 ]]; then
  echo "install-skills.sh: the pack landed but carries no SKILL.md. Re-run, or check the pin." >&2
  exit 1
fi
echo "install-skills.sh: container pack has $landed SKILL.md files"
echo "install-skills.sh: authorized testing only. Live probes go through Latch."
# The persona is not this script's business. On the Compose image it is baked at
# /opt/plow/prompt/AGENTS.md and the base's boot renders it into the workspace
# on every start; scripts/install-context.sh checks that, and an existing
# OpenClaw is the only place context is written.
"$ROOT/scripts/install-skill-packs.sh"
