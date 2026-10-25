#!/usr/bin/env bash
# Sync the AR-glasses patch files from the local Kazumi working clone into ./overlay
# Usage: bash scripts/sync-overlay.sh [path-to-kazumi-clone] [upstream-sha]
set -euo pipefail

SRC="${1:-../Kazumi}"
BASE="${2:-55e317e5f0c346d4318327ae0e5614eb8ee9097f}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DST="$HERE/overlay"

cd "$SRC"

mapfile -t CHANGED < <(git diff --name-only "$BASE" -- . | grep -E '^(lib|ios)/' || true)
mapfile -t UNTRACKED < <(git ls-files --others --exclude-standard -- 'lib/**' 'ios/**' || true)

rm -rf "$DST"
mkdir -p "$DST"

copy_one() {
  local rel="$1"
  [ -f "$SRC/$rel" ] || { echo "skip missing $rel"; return; }
  mkdir -p "$DST/$(dirname "$rel")"
  cp "$SRC/$rel" "$DST/$rel"
  echo "overlay: $rel"
}

for f in "${CHANGED[@]}"; do copy_one "$f"; done
for f in "${UNTRACKED[@]}"; do copy_one "$f"; done

echo "---"
find "$DST" -type f | wc -l
