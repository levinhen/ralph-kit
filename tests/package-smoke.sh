#!/usr/bin/env bash
#
# Exercise the exact npm artifact in an isolated prefix. Nothing is packed or
# installed into the repository under test.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-kit-package-smoke.XXXXXX")
PACK_DIR="$TEST_ROOT/pack"
INSTALL_DIR="$TEST_ROOT/install"
NPM_CACHE="$TEST_ROOT/npm-cache"
PACK_OUTPUT="$TEST_ROOT/npm-pack-output"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$PACK_DIR" "$INSTALL_DIR" "$NPM_CACHE"

echo "Packing npm artifact..."
(
  cd "$PACK_DIR"
  npm_config_cache="$NPM_CACHE" \
    npm_config_update_notifier=false \
    npm pack "$REPO_ROOT" --silent
) > "$PACK_OUTPUT"

TARBALL_NAME=$(tail -n 1 "$PACK_OUTPUT")
TARBALL_PATH="$PACK_DIR/$TARBALL_NAME"
if [[ -z "$TARBALL_NAME" || ! -f "$TARBALL_PATH" ]]; then
  echo "npm pack did not produce the expected tarball: $TARBALL_PATH" >&2
  exit 1
fi

echo "Installing packed artifact..."
(
  cd "$INSTALL_DIR"
  npm_config_cache="$NPM_CACHE" \
    npm_config_update_notifier=false \
    npm install --ignore-scripts --no-audit --no-fund "$TARBALL_PATH" >/dev/null
)

CLI="$INSTALL_DIR/node_modules/.bin/ralph-kit"
if [[ ! -x "$CLI" ]]; then
  echo "Installed package did not expose an executable ralph-kit CLI" >&2
  exit 1
fi

echo "Running installed CLI help..."
HELP_OUTPUT=$("$CLI" --help)
if ! grep -Fq 'Usage:' <<< "$HELP_OUTPUT" ||
   ! grep -Fq 'ralph-kit init' <<< "$HELP_OUTPUT"; then
  echo "Installed CLI help did not contain the expected usage text" >&2
  printf '%s\n' "$HELP_OUTPUT" >&2
  exit 1
fi

echo "Package smoke test passed."
