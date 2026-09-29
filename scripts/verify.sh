#!/usr/bin/env bash
# Confirm the Compose agent is the Index identity openclaw-cat-paw, that the
# base finished a boot against the Plow line, and that the playbook packs are
# on disk AND loaded by OpenClaw.
#
# Always exec as uid `node`, never root: `docker compose exec` defaults to root,
# and a root-owned ledger under the state volume cannot be updated by the
# five-minute reporter, which is the failure this script exists to prevent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose -f "$ROOT/compose.yml")
SERVICE=openclaw-cat-paw
AGENT_ID=openclaw-cat-paw
PYTHON=python3
CLIENT=/opt/plow/agent-index-client.py

# Container paths. STATE is the OpenClaw state directory the base itself
# exports: its rendered config, its sessions, its workspace, and the playbook
# packs the installer clones at runtime. BAKED is the image's own skills
# directory, which the base registers as `skills.load.extraDirs`, so a pack
# there needs no config to be found.
STATE=/var/lib/plow
CONFIG="$STATE/openclaw.json"
BOOT_LOG="$STATE/boot.log"
BAKED=/opt/plow/skills
RUNTIME="$STATE/workspace/skills"

cd "$ROOT"

# `docker compose exec` under Git Bash rewrites any argument that looks like a
# leading-slash path into a Windows one before the process sees it, so
# /var/lib/plow arrives as C:/Program Files/Git/var/lib/plow. Every container
# path here is a POSIX path inside the container, and this is what stops that.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

# Strip the carriage return a Windows docker CLI appends, and the padding a
# `wc -c` count picks up from a busybox coreutils.
trim() {
  local value="${1//$'\r'/}"
  printf '%s' "${value#"${value%%[![:space:]]*}"}"
}

if [[ -z "$("${COMPOSE[@]}" ps -q "$SERVICE" 2>/dev/null)" ]]; then
  echo "verify: container is not running. Start it with scripts/install.sh." >&2
  exit 1
fi

echo "verify: repairing Agent Index ledger ownership under $STATE"
# Single quotes are deliberate: this payload expands inside the container.
# shellcheck disable=SC2016
"${COMPOSE[@]}" exec -T -u 0 "$SERVICE" sh -c '
  for f in /var/lib/plow/.agent-index.json \
           /var/lib/plow/.agent-index.json.new \
           /var/lib/plow/.agent-index.lock \
           /var/lib/plow/.agent-index; do
    [ -e "$f" ] || continue
    chown -R node:node "$f"
  done
  got=$(printenv AGENT_ID || true)
  echo "verify: container AGENT_ID=${got:-<unset>}"
  if [ "$got" != "openclaw-cat-paw" ]; then
    echo "verify: AGENT_ID must be openclaw-cat-paw and must not be inherited from the host" >&2
    exit 1
  fi
'

# The base renders its own OpenClaw configuration during boot, and a cold
# first boot resolves the model provider first. Being "up" is therefore not the
# same as having rendered, and this wait is a real dependency.
echo "verify: waiting for the base to render $CONFIG"
rendered=0
for _ in $(seq 1 90); do
  if "${COMPOSE[@]}" exec -T -u node "$SERVICE" test -s "$CONFIG" 2>/dev/null; then
    rendered=1
    break
  fi
  sleep 2
done
if (( rendered != 1 )); then
  echo "verify: the base did not render $CONFIG within 180s." >&2
  echo "verify: that file is the base's own configuration, so this is a boot that did not finish." >&2
  echo "verify: docker compose logs $SERVICE" >&2
  exit 1
fi
echo "verify: $CONFIG rendered"

# The one line the base prints when the Plow line authenticated. It is a boot
# fact, not a live socket probe: the base has no channel status file to read
# from outside the Gateway, and inventing one would be a check that passes when
# the phone line is down. A reply from the line is the real proof.
identity="$(trim "$("${COMPOSE[@]}" exec -T -u node "$SERVICE" sh -c \
  "grep -o 'identity resolved to .*' '$BOOT_LOG' 2>/dev/null | tail -n 1" || true)")"
if [[ -n "$identity" ]]; then
  echo "verify: plow-boot: $identity"
else
  echo "verify: no 'identity resolved to' line in $BOOT_LOG yet." >&2
  echo "verify: the line has not authenticated. Check: docker compose logs $SERVICE" >&2
fi

# The base already runs this reporter every five minutes as long as AGENT_ID is
# set. This is the same client, run once, as the user that owns the ledger, so
# a first install does not wait out a five-minute loop to learn whether it
# registered.
index_client() {
  "${COMPOSE[@]}" exec -T -u node \
    -e HOME="$STATE" \
    -e OPENCLAW_STATE_DIR="$STATE" \
    -e AGENT_ID="$AGENT_ID" \
    "$SERVICE" "$PYTHON" "$CLIENT" "$@"
}

echo "verify: Agent Index client as uid node (never root)"
echo "verify: --self-check uses throwaway /tmp dirs; 'unreadable' there is expected."
index_client --self-check
status=0
index_client status || status=$?
echo "verify: status exit $status (0=registered, 3=unregistered)"
if [ "$status" -eq 3 ]; then
  echo "verify: not registered yet — registering now (do not wait for the 5-minute loop)"
  # PLOW_API_BASE and PLOW_AGENT_TOKEN are already in this container's
  # environment, from plow-credentials. They are read in there; the token is
  # never pulled across to this shell and never printed.
  if index_client --register --agent "$AGENT_ID" \
      --name "OpenClaw Cat Paw" \
      --blurb "Text the cat. It picks a playbook and does the job." \
      --runtime "OpenClaw / Plow Chat" \
      --repo "https://github.com/kumanaya/openclaw-cat-paw" \
      --install-url "https://github.com/kumanaya/openclaw-cat-paw/blob/main/docs/INSTALL.md"; then
    status=0
    index_client status || status=$?
  fi
fi
if [ "$status" -ne 0 ] && [ "$status" -ne 3 ]; then
  echo "verify: Agent Index status failed ($status)" >&2
  exit 1
fi
index_client --agent "$AGENT_ID" --dry-run

echo "verify: reporting current usage as node"
if ! index_client --agent "$AGENT_ID"; then
  echo "verify: live report failed. Check docker compose logs $SERVICE" >&2
  exit 1
fi

count_skills() {
  trim "$("${COMPOSE[@]}" exec -T -u node "$SERVICE" sh -c \
    "find '$1' -name SKILL.md -type f 2>/dev/null | wc -l" || true)"
}

echo "verify: baked playbooks ($BAKED)"
# Every SKILL.md in this repository must be a TOP-LEVEL directory in the image.
# image/publish-skills.sh flattens the repo's `skills/<pack>/<playbook>/` shape
# at build time, because OpenClaw's loader stops at a directory that has a
# SKILL.md and never looks inside it — a pack baked as-is loads its router and
# none of the playbooks behind it.
expected=0
missing=0
while IFS= read -r skill_md; do
  expected=$((expected + 1))
  name="$(basename "$(dirname "$skill_md")")"
  if ! "${COMPOSE[@]}" exec -T -u node "$SERVICE" test -f "$BAKED/$name/SKILL.md" 2>/dev/null; then
    echo "verify: $name is not a top-level skill in the image." >&2
    missing=$((missing + 1))
  fi
done < <(find "$ROOT/skills" -name SKILL.md -type f | LC_ALL=C sort)
if (( missing != 0 )); then
  echo "verify: $missing of $expected playbooks are missing or still nested. Rebuild (scripts/install.sh)." >&2
  exit 1
fi
echo "verify: $expected/$expected playbooks are top-level skills in the image"

echo "verify: OpenClaw actually loads them (not just on disk)"
# Files in a skills directory prove a copy landed. They do not prove the loader
# sees them, and a playbook the model cannot open is a playbook the cat does
# not have. This asks OpenClaw itself, and requires every one of them to be
# model-visible.
# The same list, comma-joined, handed to the Python below. Built in a loop
# rather than with xargs: xargs runs its command once with no arguments when
# the input is empty, which is a usage error and an empty list at once.
expected_names=""
while IFS= read -r skill_md; do
  name="$(basename "$(dirname "$skill_md")")"
  expected_names="${expected_names:+$expected_names,}$name"
done < <(find "$ROOT/skills" -name SKILL.md -type f | LC_ALL=C sort)
loaded="$("${COMPOSE[@]}" exec -T -u node "$SERVICE" "$PYTHON" -c '
import json, subprocess, sys
listed = subprocess.run(
    ["openclaw", "skills", "list", "--json"],
    capture_output=True, text=True,
)
if listed.returncode != 0:
    print("SKILLS-UNAVAILABLE")
    sys.exit(0)
data = json.loads(listed.stdout)
wanted = {name for name in sys.argv[1].split(",") if name}
names = {skill["name"] for skill in data.get("skills", []) if skill.get("modelVisible")}
print(",".join(sorted(names & wanted)) or "NONE")
' "$expected_names" 2>/dev/null | tr -d '\r' | tail -n 1 || true)"
if [[ -z "${loaded:-}" || "$loaded" == "SKILLS-UNAVAILABLE" ]]; then
  echo "verify: could not read the loaded skill list. Check: docker compose exec $SERVICE openclaw skills list" >&2
  exit 1
fi
if [[ "$loaded" == "NONE" ]]; then
  echo "verify: OpenClaw sees none of the Cat Paw skills. The extraDirs the base registers is $BAKED." >&2
  exit 1
fi
seen="$(tr ',' '\n' <<<"$loaded" | grep -c . || true)"
if [[ "$seen" -ne "$expected" ]]; then
  echo "verify: OpenClaw loads $seen of $expected playbooks. The rest are on disk but not model-visible." >&2
  echo "verify: docker compose exec $SERVICE openclaw skills check" >&2
  exit 1
fi
echo "verify: OpenClaw loads all $seen playbooks as model-visible"

echo "verify: runtime-cloned packs ($RUNTIME)"
pack="$(count_skills "$RUNTIME/cybersecurity-skills")"
echo "verify: cybersecurity-skills pack=${pack:-0} (run scripts/install-skills.sh if this is 0)"

for extra in engineering/mattpocock engineering/addyosmani engineering/alirezarezvani product marketing content sales finance customer-success design/emilkowalski design/ui-skills academic-research; do
  n="$(count_skills "$RUNTIME/$extra")"
  echo "verify: $extra=${n:-0}"
done

echo "verify: baked review CLIs"
if ! "${COMPOSE[@]}" exec -T -u node "$SERVICE" /opt/cat-paw/verify-review-tools.sh; then
  echo "verify: review CLIs missing. Rebuild the image (scripts/install.sh)." >&2
  exit 1
fi

if [ "$status" -eq 0 ]; then
  echo "verify: container OK, usage heartbeat signed in."
  echo "verify: days=0 / tokens=0 is normal before a real chat."
else
  echo "verify: container OK, usage heartbeat not signed in yet. It retries on its own. This is not a failed install."
fi
echo "verify: a reply from the line is the only proof the phone line is live. Text it now."
echo "verify: do not docker compose exec the Agent Index client as root; use this script or -u node."
# Name the line so the installing agent can relay it. Failure here is not a
# failed verify — the container may still be healthy.
if ! "$ROOT/scripts/announce-line.sh"; then
  echo "verify: could not name the line. Do not make the owner guess." >&2
fi
