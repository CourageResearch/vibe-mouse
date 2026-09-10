#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$REPO_ROOT/.build"
SWIFTPM_ROOT="$REPO_ROOT/.swiftpm"
SCRATCH_PATH="$BUILD_ROOT/scratch"

if [[ "${VIBE_MOUSE_DIRECT_RUN:-0}" != "1" ]]; then
  echo "Refreshing installed app bundle for an unambiguous launch..."
  exec "$SCRIPT_DIR/dev-restart.sh"
fi

export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/ModuleCache"
export SWIFTPM_CUSTOM_CACHE_PATH="$BUILD_ROOT/swiftpm-cache"
export SWIFTPM_CONFIG_PATH="$SWIFTPM_ROOT/configuration"
export SWIFTPM_SECURITY_PATH="$SWIFTPM_ROOT/security"

mkdir -p \
  "$CLANG_MODULE_CACHE_PATH" \
  "$SWIFTPM_CUSTOM_CACHE_PATH" \
  "$SWIFTPM_CONFIG_PATH" \
  "$SWIFTPM_SECURITY_PATH" \
  "$SCRATCH_PATH"

cd "$REPO_ROOT"

echo "Building vibe-mouse direct binary..."
swift build --disable-sandbox --scratch-path "$SCRATCH_PATH"

BIN_PATH="$(swift build --disable-sandbox --scratch-path "$SCRATCH_PATH" --show-bin-path)/vibe-mouse"

echo "Launching $BIN_PATH"
exec "$BIN_PATH"
