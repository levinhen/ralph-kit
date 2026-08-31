#!/bin/bash

# Phase choice has one owner and one fixed priority. Keep this test free of Git,
# jq, and agent CLIs so transition regressions fail immediately.

set -e

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
LIB_DIR="$REPO_ROOT/template/ralph/scripts/lib"

CLEANUP_NEEDED="false"
CLEANUP_DONE="false"
MERGE_NEEDED="false"
MERGE_DONE="false"
CONSOLIDATION_NEEDED="false"
CONSOLIDATION_DONE="false"

scaffold_cleanup_needed() {
  [[ "$CLEANUP_NEEDED" == "true" ]]
}

scaffold_cleanup_done() {
  [[ "$CLEANUP_DONE" == "true" ]]
}

merge_back_needed() {
  [[ "$MERGE_NEEDED" == "true" ]]
}

merge_back_done() {
  [[ "$MERGE_DONE" == "true" ]]
}

consolidation_needed() {
  [[ "$CONSOLIDATION_NEEDED" == "true" ]]
}

consolidation_done() {
  [[ "$CONSOLIDATION_DONE" == "true" ]]
}

source "$LIB_DIR/phase-controller.sh"

expect_phase() {
  local expected="$1"
  local story_id="${2:-}"

  ralph_select_phase "$story_id"
  if [[ "$RALPH_PHASE" != "$expected" ]]; then
    echo "Expected phase '$expected', got '$RALPH_PHASE'" >&2
    exit 1
  fi
}

# A selected story wins even when every downstream phase is also pending.
CLEANUP_NEEDED="true"
MERGE_NEEDED="true"
CONSOLIDATION_NEEDED="true"
expect_phase "story" "US-001"

# With no story, each completed phase exposes the next one in priority order.
expect_phase "cleanup"
CLEANUP_DONE="true"
expect_phase "merge-back"
MERGE_DONE="true"
expect_phase "consolidation"
CONSOLIDATION_DONE="true"
expect_phase "complete"

# A disabled phase is skipped without changing the order of the remaining ones.
CLEANUP_NEEDED="false"
CLEANUP_DONE="false"
MERGE_NEEDED="false"
MERGE_DONE="false"
CONSOLIDATION_NEEDED="true"
CONSOLIDATION_DONE="false"
expect_phase "consolidation"

CONSOLIDATION_NEEDED="false"
expect_phase "complete"

echo "phase controller test: ok"
