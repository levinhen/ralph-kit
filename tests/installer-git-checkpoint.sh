#!/usr/bin/env bash
# A failed optional installer commit must leave the caller's pre-existing Git
# index exactly as it was. Installed files remain as ordinary working-tree
# changes so the user can inspect or commit them manually.

set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
INSTALLER="$REPO_ROOT/bin/ralph-kit.mjs"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-installer-git-test.XXXXXX")
TARGET="$TEST_ROOT/target"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  echo "installer Git checkpoint test failed: $1" >&2
  exit 1
}

mkdir -p "$TARGET"
git -C "$TARGET" init -q
git -C "$TARGET" config user.name "Ralph Test"
git -C "$TARGET" config user.email "ralph-test@example.com"
printf 'base\n' > "$TARGET/README.md"
git -C "$TARGET" add README.md
git -C "$TARGET" commit -qm "base"

# Establish a clean installed baseline through the real successful checkpoint.
NO_COLOR=1 node "$INSTALLER" init "$TARGET" > "$TEST_ROOT/init-output"
[[ -z "$(git -C "$TARGET" status --short)" ]] \
  || fail "successful init did not leave a clean repository"

# Keep unrelated staged work, then force the installer's own commit to fail.
# The sync itself remains successful and must preserve this index entry only.
printf 'user staged work\n' > "$TARGET/user-notes.txt"
git -C "$TARGET" add user-notes.txt
printf 'local managed drift\n' > "$TARGET/ralph/scripts/CODEX.md"
git -C "$TARGET" config commit.gpgSign true
git -C "$TARGET" config gpg.program false

NO_COLOR=1 node "$INSTALLER" sync "$TARGET" > "$TEST_ROOT/sync-output"

STAGED=$(git -C "$TARGET" diff --cached --name-only)
[[ "$STAGED" == "user-notes.txt" ]] \
  || fail "failed checkpoint changed the index; staged paths were: $STAGED"

cmp -s "$REPO_ROOT/template/ralph/scripts/CODEX.md" \
  "$TARGET/ralph/scripts/CODEX.md" \
  || fail "sync did not repair the managed file after the optional commit failed"
if git -C "$TARGET" diff --cached --name-only | grep -q '^ralph/'; then
  fail "failed checkpoint left generated Ralph files staged"
fi

echo "installer Git checkpoint test passed"
