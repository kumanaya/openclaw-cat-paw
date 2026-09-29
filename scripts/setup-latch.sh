#!/usr/bin/env bash
# Prepare Cat Paw Latch from source on this machine. Does not launch the GUI:
# keep `just app` in a visible terminal so approval prompts stay on screen.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LATCH_DIR="${LATCH_DIR:-$ROOT/../cat-paw-latch}"
LATCH_REPO="${LATCH_REPO:-https://github.com/kumanaya/cat-paw-latch.git}"

deps_hint() {
  echo "Debian/Ubuntu: sudo apt install build-essential pkg-config libsecret-1-dev just git python3 bubblewrap fuse2" >&2
  echo "Arch/Omarchy: sudo pacman -S --needed base-devel just git python bubblewrap fuse2" >&2
  echo "Also need Node.js 22+ (node -v) and npm." >&2
}

need() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing '$1'." >&2
    deps_hint
    exit 1
  }
}

need git
need just
need node
need npm
need python3

if ! command -v cc >/dev/null 2>&1 && ! command -v gcc >/dev/null 2>&1 && ! command -v clang >/dev/null 2>&1; then
  echo "Missing a C compiler (cc/gcc). Latch native modules need it (better-sqlite3, sandbox, keychain)." >&2
  deps_hint
  exit 1
fi
if ! command -v make >/dev/null 2>&1; then
  echo "Missing 'make'." >&2
  deps_hint
  exit 1
fi
if [[ "$(uname -s)" == "Linux" ]]; then
  if ! command -v pkg-config >/dev/null 2>&1; then
    echo "Missing 'pkg-config'." >&2
    deps_hint
    exit 1
  fi
  if ! pkg-config --exists libsecret-1 2>/dev/null; then
    echo "Missing libsecret headers (pkg-config libsecret-1)." >&2
    echo "Debian/Ubuntu: sudo apt install libsecret-1-dev" >&2
    echo "Arch/Omarchy: sudo pacman -S --needed libsecret" >&2
    exit 1
  fi
fi

node_major="$(node -p "process.versions.node.split('.')[0]")"
if (( node_major < 22 )); then
  echo "Node.js 22 or newer is required (found $(node -v))." >&2
  exit 1
fi

if [[ "$(uname -s)" == "Linux" ]] && ! command -v bwrap >/dev/null 2>&1; then
  echo "bubblewrap (bwrap) is required on Linux." >&2
  echo "Debian/Ubuntu: sudo apt install bubblewrap" >&2
  echo "Arch/Omarchy: sudo pacman -S --needed bubblewrap" >&2
  exit 1
fi

if [[ ! -d "$LATCH_DIR/.git" ]]; then
  mkdir -p "$(dirname "$LATCH_DIR")"
  git clone "$LATCH_REPO" "$LATCH_DIR"
fi

(
  cd "$LATCH_DIR"
  just install
)

if [[ "$(uname -s)" == "Linux" ]] && [[ -d /usr/share/omarchy || -n "${OMARCHY:-}" ]]; then
  if ls "$LATCH_DIR"/apps/desktop/release/Plow-Latch-*.AppImage >/dev/null 2>&1; then
    (cd "$LATCH_DIR" && just install-desktop) || true
  fi
fi

echo "Cat Paw Latch is ready at $LATCH_DIR"

if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
  "$ROOT/scripts/start-latch.sh" || {
    echo "Could not auto-launch Latch. In a visible terminal:" >&2
    echo "  cd $LATCH_DIR && just app" >&2
  }
else
  cat <<EOF
Start it in a visible terminal and leave it running:

  cd $LATCH_DIR
  just app

On Omarchy, a packaged build also lands in the Apps tab:

  cd $LATCH_DIR
  just package-linux    # builds the AppImage, then just install-desktop
  # or, if the AppImage already exists: just install-desktop
EOF
fi

cat <<EOF

Sign in, keep the approval window visible, then continue the agent setup with
scripts/install.sh (Linux/Omarchy) or scripts/install.ps1 (Windows). That
installer mints a free line (or \`--line NAME\`) and always starts Compose as
AGENT_ID=openclaw-cat-paw.
EOF
