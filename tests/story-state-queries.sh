#!/bin/bash

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORY_STATE_LIB="$REPO_ROOT/template/ralph/scripts/lib/story-state.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-story-state-query-test.XXXXXX")

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  echo "$1" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"

  if [[ "$actual" != "$expected" ]]; then
    fail "$label: expected '$expected', got '$actual'"
  fi
}

source "$STORY_STATE_LIB"

# A poisoned global makes accidental dependence on PRD_FILE visible: every
# query below must use the path passed as its first argument.
PRD_FILE="$TEST_ROOT/do-not-read-global-prd.json"

MISSING_PRD="$TEST_ROOT/missing.json"
MALFORMED_PRD="$TEST_ROOT/malformed.json"
EMPTY_PRD="$TEST_ROOT/empty.json"
MISSING_PASSES_PRD="$TEST_ROOT/missing-passes.json"
MISSING_TITLE_PRD="$TEST_ROOT/missing-title.json"
NORMAL_PRD="$TEST_ROOT/normal.json"
COMPLETE_PRD="$TEST_ROOT/complete.json"

printf '{"userStories": [' > "$MALFORMED_PRD"
printf '%s\n' '{"userStories":[]}' > "$EMPTY_PRD"
printf '%s\n' \
  '{"userStories":[{"id":"US-001","title":"No pass state yet"}]}' \
  > "$MISSING_PASSES_PRD"
printf '%s\n' \
  '{"userStories":[{"id":"US-002","passes":false}]}' \
  > "$MISSING_TITLE_PRD"
printf '%s\n' \
  '{"userStories":[{"id":"US-101","title":"Already done","passes":true},{"id":"US-102","title":"Still open","passes":false}]}' \
  > "$NORMAL_PRD"
printf '%s\n' \
  '{"userStories":[{"id":"US-201","title":"First","passes":true},{"id":"US-202","title":"Second","passes":true}]}' \
  > "$COMPLETE_PRD"

for unreadable_prd in "$MISSING_PRD" "$MALFORMED_PRD"; do
  assert_eq "" "$(prd_next_incomplete_story_id "$unreadable_prd")" \
    "unreadable PRD next incomplete story"
  assert_eq "false" "$(prd_story_passes "$unreadable_prd" "US-001")" \
    "unreadable PRD story passes"
  assert_eq "false" "$(prd_all_stories_complete "$unreadable_prd")" \
    "unreadable PRD all complete"
  assert_eq "unreadable" "$(prd_story_ids_summary "$unreadable_prd")" \
    "unreadable PRD story summary"
  assert_eq "" "$(prd_cleanup_story_list "$unreadable_prd")" \
    "unreadable PRD cleanup list"
done

assert_eq "" "$(prd_next_incomplete_story_id "$EMPTY_PRD")" \
  "empty PRD next incomplete story"
assert_eq "false" "$(prd_all_stories_complete "$EMPTY_PRD")" \
  "empty PRD all complete"
assert_eq "" "$(prd_story_ids_summary "$EMPTY_PRD")" \
  "empty PRD story summary"
assert_eq "" "$(prd_cleanup_story_list "$EMPTY_PRD")" \
  "empty PRD cleanup list"

assert_eq "US-001" "$(prd_next_incomplete_story_id "$MISSING_PASSES_PRD")" \
  "missing passes counts as incomplete"
assert_eq "null" "$(prd_story_passes "$MISSING_PASSES_PRD" "US-001")" \
  "missing passes preserves jq null"
assert_eq "false" "$(prd_all_stories_complete "$MISSING_PASSES_PRD")" \
  "missing passes prevents completion"

assert_eq '- `US-002` ' "$(prd_cleanup_story_list "$MISSING_TITLE_PRD")" \
  "missing title keeps the cleanup-list format"
assert_eq "US-002" "$(prd_story_ids_summary "$MISSING_TITLE_PRD")" \
  "missing title does not affect the ID summary"

assert_eq "US-102" "$(prd_next_incomplete_story_id "$NORMAL_PRD")" \
  "normal PRD next incomplete story"
assert_eq "true" "$(prd_story_passes "$NORMAL_PRD" "US-101")" \
  "normal PRD passed story"
assert_eq "false" "$(prd_story_passes "$NORMAL_PRD" "US-102")" \
  "normal PRD incomplete story"
assert_eq "false" "$(prd_all_stories_complete "$NORMAL_PRD")" \
  "normal PRD with open work is incomplete"
assert_eq "US-101, US-102" "$(prd_story_ids_summary "$NORMAL_PRD")" \
  "normal PRD story summary"
assert_eq $'- `US-101` Already done\n- `US-102` Still open' \
  "$(prd_cleanup_story_list "$NORMAL_PRD")" \
  "normal PRD cleanup list"

assert_eq "" "$(prd_next_incomplete_story_id "$COMPLETE_PRD")" \
  "complete PRD has no next story"
assert_eq "true" "$(prd_all_stories_complete "$COMPLETE_PRD")" \
  "non-empty complete PRD is complete"

echo "story state query test: ok"
