#!/bin/bash

# The durable run status and interactive progress row are independent
# projections. This test pins both halves of that boundary: run-status works
# without any progress functions in scope, and run-observers is the only place
# that fans lifecycle events out to both implementations.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-run-observers-test.XXXXXX")
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$REPO_ROOT/template/ralph/scripts/lib"
PRD_FILE="$TEST_ROOT/prd.json"
STATUS_DIR="$TEST_ROOT/status"
EVENT_LOG="$TEST_ROOT/events"
EXPECTED_LOG="$TEST_ROOT/expected-events"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  echo "$1" >&2
  exit 1
}

cat > "$PRD_FILE" <<'EOF'
{
  "userStories": [
    {
      "id": "US-001",
      "title": "Independent status projection",
      "passes": false
    }
  ]
}
EOF

# Source only the persistence module. No ralph_progress_* symbol exists here;
# every lifecycle operation must still succeed and update the JSON snapshot.
(
  source "$LIB_DIR/run-status.sh"

  if command -v ralph_progress_update >/dev/null 2>&1 \
    || command -v ralph_progress_set_activity >/dev/null 2>&1; then
    fail "run-status.sh unexpectedly loaded the progress API"
  fi

  ralph_status_start "$STATUS_DIR" "$PRD_FILE" "run-a" "codex"
  ralph_status_update "unblocking" "US-001" "4"
  ralph_status_set_activity "$TEST_ROOT/activity"
  ralph_status_unblock_outcome "finished"
  ralph_status_finish "succeeded" "0"
)

STATUS_FILE="$STATUS_DIR/run-a.json"
[[ -f "$STATUS_FILE" ]] || fail "run-status.sh did not write its standalone snapshot"

jq -e '
  .runId == "run-a"
  and .tool == "codex"
  and .phase == "exited"
  and .storyId == "US-001"
  and .round == 4
  and .activityFile == $activity
  and .unblockRounds == 1
  and .unblockStoryId == "US-001"
  and .unblockOutcome == "finished"
  and .outcome == "succeeded"
  and .exitCode == 0
' --arg activity "$TEST_ROOT/activity" "$STATUS_FILE" >/dev/null \
  || fail "standalone run status snapshot did not retain the lifecycle state"

# Replace both projections with recording doubles, then verify that the
# composition layer preserves argument order and the historical dispatch order.
record_event() {
  printf '%s\n' "$1" >> "$EVENT_LOG"
}

ralph_progress_start() {
  record_event "progress:start|$1|$2"
}
ralph_status_start() {
  record_event "status:start|$1|$2|$3|$4"
}
ralph_progress_update() {
  record_event "progress:update|$1|$2|$3"
  return 9
}
ralph_status_update() {
  record_event "status:update|$1|$2|$3"
}
ralph_progress_set_activity() {
  record_event "progress:activity|$1"
}
ralph_status_set_activity() {
  record_event "status:activity|$1"
}
ralph_status_unblock_outcome() {
  record_event "status:unblock|$1"
}
ralph_status_finish() {
  record_event "status:finish|$1|$2"
}
ralph_progress_resize() {
  record_event "progress:resize"
}
ralph_progress_stop() {
  record_event "progress:stop"
}

source "$LIB_DIR/run-observers.sh"

ralph_observers_start "/status" "/prd.json" "run-b" "pi" "Run B"
ralph_observers_update "working" "US-002" "5"
ralph_observers_activity "/tmp/activity"
ralph_observers_unblock "restructured"
ralph_observers_finish "failed" "1"
ralph_observers_resize
ralph_observers_stop

cat > "$EXPECTED_LOG" <<'EOF'
progress:start|/prd.json|Run B
status:start|/status|/prd.json|run-b|pi
progress:update|working|US-002|5
status:update|working|US-002|5
progress:activity|/tmp/activity
status:activity|/tmp/activity
status:unblock|restructured
status:finish|failed|1
progress:resize
progress:stop
EOF

if ! cmp -s "$EXPECTED_LOG" "$EVENT_LOG"; then
  echo "--- expected observer events ---" >&2
  cat "$EXPECTED_LOG" >&2
  echo "--- actual observer events ---" >&2
  cat "$EVENT_LOG" >&2
  fail "run-observers.sh did not forward lifecycle events correctly"
fi

echo "run observers test: ok"
