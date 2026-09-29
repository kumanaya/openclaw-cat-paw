#!/usr/bin/env bash
# Flatten a skills root so every SKILL.md sits at the top level.
#
#   publish-skills.sh <skills-root>
#
# OpenClaw's loader treats a directory under a skills root that HAS a SKILL.md
# as a leaf and never looks inside it. A directory without one is a group, and
# its children are the skills. This repository's layout is two levels —
# `skills/<pack>/SKILL.md` plus `skills/<pack>/<child>/SKILL.md` — so baking it
# as-is would load the ten routers and none of the thirty playbooks they route
# to. The cat would advertise playbooks it does not have, which is the one
# failure the product cannot have.
#
# So this lifts every nested skill directory to the top of the same root. The
# routers reference their children by NAME, not by path, so the published tree
# reads the same as the repository, and OpenClaw now lists every playbook as a
# first-class skill the model can open directly.
#
# Runs at docker build as root. It is a build step, not an installer: the
# repository layout stays nested for the humans who maintain it.
set -euo pipefail

ROOT="${1:-}"
if [[ -z "$ROOT" || ! -d "$ROOT" ]]; then
  echo "usage: $(basename "$0") <skills-root>" >&2
  exit 1
fi

before="$(find "$ROOT" -name SKILL.md -type f | wc -l)"
moved=0

# Repeat until a pass moves nothing. Every move raises a directory towards the
# root, so the total depth strictly decreases and this terminates.
while :; do
  pass=0
  # `nullglob` matters: a pack with no children must not iterate a literal
  # glob and be treated as a directory that happens to exist.
  shopt -s nullglob
  for dir in "$ROOT"/*/*/; do
    dir="${dir%/}"
    [[ -f "$dir/SKILL.md" ]] || continue
    name="$(basename "$dir")"
    target="$ROOT/$name"
    if [[ -e "$target" ]]; then
      # Two playbooks with one name would silently shadow each other, and
      # whichever loaded last would win. Refuse instead of guessing.
      echo "publish-skills: $name is already a top-level skill. Refusing to overwrite." >&2
      exit 1
    fi
    mv "$dir" "$target"
    pass=$((pass + 1))
    moved=$((moved + 1))
  done
  shopt -u nullglob
  if (( pass == 0 )); then
    break
  fi
done

# A pack whose children were all lifted is now an empty husk. Remove it, or it
# sits in the published tree as a directory with no skill in it.
find "$ROOT" -mindepth 1 -maxdepth 1 -type d -empty -exec rmdir {} +

# Depth counts from the root: a top-level skill's SKILL.md is at depth 2, so
# anything at depth 3 or deeper is a skill the loader would never reach.
nested="$(find "$ROOT" -mindepth 3 -type f -name SKILL.md | wc -l)"
if [[ "$nested" -ne 0 ]]; then
  echo "publish-skills: $nested SKILL.md files are still nested after flattening." >&2
  exit 1
fi

after="$(find "$ROOT" -name SKILL.md -type f | wc -l)"
if [[ "$after" -ne "$before" ]]; then
  echo "publish-skills: skill count changed ($before -> $after). Flattening must not add or drop one." >&2
  exit 1
fi

echo "publish-skills: $after top-level skills ($moved lifted out of a pack)"

