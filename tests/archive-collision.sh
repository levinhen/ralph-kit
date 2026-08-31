#!/bin/bash
#
# Archiving is the last destructive-looking step in a scoped run. A directory
# left at today's archive name may belong to an earlier attempt (or to data the
# operator put there deliberately), so Ralph must not merge into it, overwrite
# it, or report success while leaving the active run half-finished.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-archive-collision-test.XXXXXX")
REPO_TEMPLATE=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CONSOLIDATE_LIB="$REPO_TEMPLATE/template/ralph/scripts/lib/consolidate.sh"
TODAY=$(date +%Y-%m-%d)

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  echo "$1" >&2
  exit 1
}

setup_repo() {
  local scenario="$1"

  REPO_ROOT="$TEST_ROOT/$scenario"
  RALPH_ROOT="$REPO_ROOT/ralph"
  RUNS_ROOT="$RALPH_ROOT/runs"
  RUN_ID="archive-fixture"
  BASE_BRANCH="main"

  mkdir -p "$RUNS_ROOT/$RUN_ID/progress" "$RALPH_ROOT/tasks"
  printf '%s\n' "active run payload" > "$RUNS_ROOT/$RUN_ID/progress/round.txt"
  printf '%s\n' "# Source PRD" > "$RALPH_ROOT/tasks/prd-$RUN_ID.md"

  git -C "$REPO_ROOT" init -q
  git -C "$REPO_ROOT" config user.name "Ralph Test"
  git -C "$REPO_ROOT" config user.email "ralph-test@example.com"
  git -C "$REPO_ROOT" add .
  git -C "$REPO_ROOT" commit -qm "test fixture"
  git -C "$REPO_ROOT" branch -M "$BASE_BRANCH"
}

# shellcheck source=../template/ralph/scripts/lib/consolidate.sh
source "$CONSOLIDATE_LIB"

# Existing destination: fail closed and leave both sides byte-for-byte intact.
setup_repo "collision"
ARCHIVE_TARGET="$RALPH_ROOT/archive/$TODAY-$RUN_ID"
mkdir -p "$ARCHIVE_TARGET"
printf '%s\n' "pre-existing archive payload" > "$ARCHIVE_TARGET/sentinel.txt"
git -C "$REPO_ROOT" add .
git -C "$REPO_ROOT" commit -qm "seed colliding archive"

COLLISION_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD)
ACTIVE_BEFORE=$(git -C "$REPO_ROOT" hash-object "$RUNS_ROOT/$RUN_ID/progress/round.txt")
PRD_BEFORE=$(git -C "$REPO_ROOT" hash-object "$RALPH_ROOT/tasks/prd-$RUN_ID.md")
ARCHIVE_BEFORE=$(git -C "$REPO_ROOT" hash-object "$ARCHIVE_TARGET/sentinel.txt")

set +e
COLLISION_OUTPUT=$(archive_consolidated_run 2>&1)
COLLISION_STATUS=$?
set -e

if [[ "$COLLISION_STATUS" -eq 0 ]]; then
  fail "Expected an existing same-day archive target to make archiving fail"
fi
echo "$COLLISION_OUTPUT" | grep -q "archive target already exists" \
  || fail "Collision failure did not explain which invariant blocked archiving"

[[ -d "$RUNS_ROOT/$RUN_ID" ]] \
  || fail "Collision moved or removed the active run dir"
[[ -f "$RALPH_ROOT/tasks/prd-$RUN_ID.md" ]] \
  || fail "Collision moved or removed the source PRD"
[[ -f "$ARCHIVE_TARGET/sentinel.txt" ]] \
  || fail "Collision removed the pre-existing archive payload"

[[ "$(git -C "$REPO_ROOT" hash-object "$RUNS_ROOT/$RUN_ID/progress/round.txt")" == "$ACTIVE_BEFORE" ]] \
  || fail "Collision changed the active run payload"
[[ "$(git -C "$REPO_ROOT" hash-object "$RALPH_ROOT/tasks/prd-$RUN_ID.md")" == "$PRD_BEFORE" ]] \
  || fail "Collision changed the source PRD"
[[ "$(git -C "$REPO_ROOT" hash-object "$ARCHIVE_TARGET/sentinel.txt")" == "$ARCHIVE_BEFORE" ]] \
  || fail "Collision changed the pre-existing archive payload"
[[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == "$COLLISION_HEAD" ]] \
  || fail "Collision unexpectedly created a commit"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] \
  || fail "Collision left staged or working-tree changes behind"

# Recovery after the run-dir move: two PRDs are ambiguous, so preserve both and
# stop instead of silently treating the partial archive as complete.
setup_repo "prd-collision"
ARCHIVE_TARGET="$RALPH_ROOT/archive/$TODAY-$RUN_ID"
mkdir -p "$RALPH_ROOT/archive"
mv "$RUNS_ROOT/$RUN_ID" "$ARCHIVE_TARGET"
printf '%s\n' "# Pre-existing archived PRD" > "$ARCHIVE_TARGET/prd-$RUN_ID.md"
git -C "$REPO_ROOT" add -A
git -C "$REPO_ROOT" commit -qm "seed partial archive with conflicting PRDs"

PRD_COLLISION_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD)
SOURCE_PRD_BEFORE=$(git -C "$REPO_ROOT" hash-object "$RALPH_ROOT/tasks/prd-$RUN_ID.md")
ARCHIVED_PRD_BEFORE=$(git -C "$REPO_ROOT" hash-object "$ARCHIVE_TARGET/prd-$RUN_ID.md")
ARCHIVED_RUN_BEFORE=$(git -C "$REPO_ROOT" hash-object "$ARCHIVE_TARGET/progress/round.txt")

set +e
PRD_COLLISION_OUTPUT=$(archive_consolidated_run 2>&1)
PRD_COLLISION_STATUS=$?
set -e

if [[ "$PRD_COLLISION_STATUS" -eq 0 ]]; then
  fail "Expected conflicting source and archived PRDs to make recovery fail"
fi
echo "$PRD_COLLISION_OUTPUT" | grep -q "PRD archive target already exists" \
  || fail "PRD collision failure did not explain which invariant blocked recovery"

[[ ! -e "$RUNS_ROOT/$RUN_ID" ]] \
  || fail "PRD collision recreated or moved the already-archived run dir"
[[ "$(git -C "$REPO_ROOT" hash-object "$RALPH_ROOT/tasks/prd-$RUN_ID.md")" == "$SOURCE_PRD_BEFORE" ]] \
  || fail "PRD collision changed the source PRD"
[[ "$(git -C "$REPO_ROOT" hash-object "$ARCHIVE_TARGET/prd-$RUN_ID.md")" == "$ARCHIVED_PRD_BEFORE" ]] \
  || fail "PRD collision changed the archived PRD"
[[ "$(git -C "$REPO_ROOT" hash-object "$ARCHIVE_TARGET/progress/round.txt")" == "$ARCHIVED_RUN_BEFORE" ]] \
  || fail "PRD collision changed the already-archived run payload"
[[ "$(git -C "$REPO_ROOT" rev-parse HEAD)" == "$PRD_COLLISION_HEAD" ]] \
  || fail "PRD collision unexpectedly created a commit"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] \
  || fail "PRD collision left staged or working-tree changes behind"

# Empty destination: archive both artifacts and create the mechanical commit.
setup_repo "happy"
ARCHIVE_TARGET="$RALPH_ROOT/archive/$TODAY-$RUN_ID"
HAPPY_HEAD=$(git -C "$REPO_ROOT" rev-parse HEAD)

archive_consolidated_run >/dev/null

[[ ! -e "$RUNS_ROOT/$RUN_ID" ]] \
  || fail "Happy path left the active run dir behind"
[[ ! -e "$RALPH_ROOT/tasks/prd-$RUN_ID.md" ]] \
  || fail "Happy path left the source PRD behind"
[[ -f "$ARCHIVE_TARGET/progress/round.txt" ]] \
  || fail "Happy path did not archive the run payload"
[[ -f "$ARCHIVE_TARGET/prd-$RUN_ID.md" ]] \
  || fail "Happy path did not archive the source PRD"
[[ "$(git -C "$REPO_ROOT" rev-parse HEAD^)" == "$HAPPY_HEAD" ]] \
  || fail "Happy path did not create exactly one child commit"
[[ "$(git -C "$REPO_ROOT" log -1 --pretty=%s)" == "chore(ralph): archive completed run $RUN_ID" ]] \
  || fail "Happy path created the wrong archive commit"
[[ -z "$(git -C "$REPO_ROOT" status --porcelain)" ]] \
  || fail "Happy path left staged or working-tree changes behind"

echo "archive collision tests passed"
