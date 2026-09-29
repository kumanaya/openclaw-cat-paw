#!/usr/bin/env bash
# Print the dashboard name and phone number for this checkout's credential.
# Installing agents must relay both to the owner in the same turn.
# Never print tokens or plow-credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREDENTIALS="$ROOT/plow-credentials"
TOOLS="$ROOT/.tools/plow-agents"
TOKEN_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/plow/token"

usage() {
  cat <<EOF
Usage: $(basename "$0")

Prints the Plow line this agent is on (dashboard name + phone number)
by matching plow-credentials' # plow-agent-uid to \`plow-agents lines\`.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if [[ ! -f "$CREDENTIALS" ]]; then
  echo "announce-line: no plow-credentials file. The line is not signed in." >&2
  echo "announce-line: tell the owner the install is not done. Re-run scripts/install.sh." >&2
  exit 1
fi

uid="$(sed -n 's/^# plow-agent-uid:[[:space:]]*//p' "$CREDENTIALS" | head -n 1)"
uid="${uid%"${uid##*[![:space:]]}"}"
if [[ -z "$uid" ]]; then
  echo "announce-line: plow-credentials has no # plow-agent-uid comment." >&2
  echo "announce-line: tell the owner you could not name the line. Do not guess." >&2
  exit 1
fi

if [[ ! -s "$TOKEN_FILE" ]]; then
  echo "announce-line: no Plow account token at $TOKEN_FILE." >&2
  echo "announce-line: tell the owner you could not name the line. Do not guess." >&2
  exit 1
fi

if [[ ! -d "$TOOLS/.git" ]]; then
  mkdir -p "$(dirname "$TOOLS")"
  git clone https://github.com/plow-pbc/plow-agents.git "$TOOLS"
fi

# TSV: uid, name, number, status (status is "free" or the agent uid).
# Do not print the full table: other lines on the account are not this agent.
matched=0
while IFS=$'\t' read -r _line_uid name number status; do
  [[ "$status" == "$uid" ]] || continue
  echo "announce-line: dashboard name: $name"
  echo "announce-line: text this number: $number"
  echo "announce-line: tell the owner both in this turn. They text that number. Do not make them guess."
  matched=1
  break
done < <(python3 "$TOOLS/bin/plow-agents" lines | awk -F '\t' 'NR > 1 && NF >= 4 { print }')

if (( ! matched )); then
  echo "announce-line: this credential did not match a dashboard line." >&2
  echo "announce-line: tell the owner you could not name the line. Do not guess." >&2
  echo "announce-line: run python3 $TOOLS/bin/plow-agents lines and match STATUS to the credential uid. Never print the token." >&2
  exit 1
fi
