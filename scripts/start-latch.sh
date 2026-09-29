#!/usr/bin/env bash
# Launch Cat Paw Latch on this machine if a display is available.
# Prefers the packaged AppImage / desktop entry; falls back to `just app`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LATCH_DIR="${LATCH_DIR:-$ROOT/../cat-paw-latch}"
APPIMAGE="${XDG_APPLICATIONS_DIR:-$HOME/Applications}/Plow-Latch.AppImage"
DESKTOP="$HOME/.local/share/applications/cat-paw-latch.desktop"
LOG="${TMPDIR:-/tmp}/plow-latch-start.log"

running() {
  pgrep -f '/PlowLatch|[[:space:]]Plow-Latch|Plow Latch' >/dev/null 2>&1 \
    || pgrep -f 'Plow-Latch\.AppImage' >/dev/null 2>&1
}

if running; then
  echo "Plow Latch is already running. Leave the approval window visible."
  exit 0
fi

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  echo "No graphical session. Open a desktop and run:" >&2
  echo "  cd $LATCH_DIR && just app" >&2
  echo "On Omarchy, open the Apps tab and launch Plow Latch." >&2
  exit 1
fi

if [[ -x "$APPIMAGE" ]]; then
  echo "Launching $APPIMAGE"
  nohup "$APPIMAGE" >"$LOG" 2>&1 &
elif command -v gtk-launch >/dev/null 2>&1 && [[ -f "$DESKTOP" ]]; then
  echo "Launching desktop entry cat-paw-latch"
  gtk-launch cat-paw-latch >/dev/null 2>&1 || true
elif [[ -d "$LATCH_DIR" ]]; then
  echo "Launching from source in $LATCH_DIR"
  (cd "$LATCH_DIR" && nohup just app >"$LOG" 2>&1 &)
else
  echo "Latch is not installed. Run scripts/setup-latch.sh first." >&2
  exit 1
fi

i=0
while [ "$i" -lt 20 ]; do
  if running; then
    echo "Plow Latch is running. Sign in if this is the first launch and leave the approval window visible."
    exit 0
  fi
  i=$((i + 1))
  sleep 1
done

echo "Latch did not stay up. Check $LOG and run: cd $LATCH_DIR && just app" >&2
exit 1
