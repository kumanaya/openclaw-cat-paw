#!/usr/bin/env bash
# Bake a tiny set of review CLIs into the image. Run as root at docker build.
set -euo pipefail

PIN="${REVIEW_TOOLS_PIN:-/opt/cat-paw/review-tools.pin}"
DEST="${REVIEW_TOOLS_DEST:-/usr/local/bin}"

if [[ ! -f "$PIN" ]]; then
  echo "install-review-tools: missing pin $PIN" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64 | amd64) SLOT=amd64 ;;
  aarch64 | arm64) SLOT=arm64 ;;
  *)
    echo "install-review-tools: unsupported arch $(uname -m)" >&2
    exit 1
    ;;
esac

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

reset_stanza() {
  TOOL=""
  VERSION=""
  KIND=""
  AMD64_URL=""
  AMD64_SHA256=""
  ARM64_URL=""
  ARM64_SHA256=""
}

url_for_slot() {
  if [[ "$SLOT" == amd64 ]]; then
    printf '%s\n' "$AMD64_URL"
  else
    printf '%s\n' "$ARM64_URL"
  fi
}

sha_for_slot() {
  if [[ "$SLOT" == amd64 ]]; then
    printf '%s\n' "$AMD64_SHA256"
  else
    printf '%s\n' "$ARM64_SHA256"
  fi
}

download_verified() {
  local url="$1" sha="$2" out="$3"
  [[ -n "$url" && -n "$sha" ]] || {
    echo "install-review-tools: $TOOL missing $SLOT url/sha256" >&2
    exit 1
  }
  echo "install-review-tools: fetching $TOOL ($SLOT)"
  curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o "$out" "$url"
  echo "${sha}  ${out}" | sha256sum -c -
}

pick_payload() {
  local dir="$1" name="$2" f
  if [[ -f "$dir/$name" ]]; then
    printf '%s\n' "$dir/$name"
    return 0
  fi
  f="$(find "$dir" -type f -name "$name" -print -quit)"
  if [[ -n "$f" ]]; then
    printf '%s\n' "$f"
    return 0
  fi
  f="$(find "$dir" -type f \( -name "${name}_*" -o -name "${name}-*" \) \
    ! -name '*.md' ! -name '*.txt' ! -name '*.1' ! -name '*.sh' -print -quit)"
  if [[ -n "$f" ]]; then
    printf '%s\n' "$f"
    return 0
  fi
  echo "install-review-tools: no payload named $name in tarball" >&2
  find "$dir" -type f >&2
  return 1
}

install_tar() {
  local archive="$TMP/$TOOL.tar.gz" extract="$TMP/extract-$TOOL" payload
  rm -rf "$extract"
  mkdir -p "$extract"
  download_verified "$(url_for_slot)" "$(sha_for_slot)" "$archive"
  tar -xzf "$archive" -C "$extract"
  payload="$(pick_payload "$extract" "$TOOL")"
  install -m 0755 "$payload" "$DEST/$TOOL"
}

APT_PACKAGES=()
STANZAS=()

flush_collect() {
  [[ -z "$TOOL" ]] && return 0
  if [[ "$KIND" == apt ]]; then
    APT_PACKAGES+=("$TOOL")
  else
    STANZAS+=("${TOOL}|${VERSION}|${KIND}|${AMD64_URL}|${AMD64_SHA256}|${ARM64_URL}|${ARM64_SHA256}")
  fi
}

reset_stanza
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    '' | \#*) continue ;;
  esac
  key="${line%%=*}"
  val="${line#*=}"
  if [[ "$key" == tool && -n "$TOOL" ]]; then
    flush_collect
    reset_stanza
  fi
  case "$key" in
    tool) TOOL="$val" ;;
    version) VERSION="$val" ;;
    kind) KIND="$val" ;;
    amd64_url) AMD64_URL="$val" ;;
    amd64_sha256) AMD64_SHA256="$val" ;;
    arm64_url) ARM64_URL="$val" ;;
    arm64_sha256) ARM64_SHA256="$val" ;;
    *)
      echo "install-review-tools: unknown pin key: $key" >&2
      exit 1
      ;;
  esac
done <"$PIN"
flush_collect

mkdir -p "$DEST"

if ((${#APT_PACKAGES[@]})); then
  echo "install-review-tools: apt ${APT_PACKAGES[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends "${APT_PACKAGES[@]}"
  rm -rf /var/lib/apt/lists/*
fi

for CURRENT in "${STANZAS[@]}"; do
  IFS='|' read -r TOOL VERSION KIND AMD64_URL AMD64_SHA256 ARM64_URL ARM64_SHA256 <<<"$CURRENT"
  case "$KIND" in
    tar) install_tar ;;
    *)
      echo "install-review-tools: unknown kind $KIND for $TOOL" >&2
      exit 1
      ;;
  esac
done

echo "install-review-tools: done ($SLOT)"
