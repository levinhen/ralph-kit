#!/bin/bash
#
# A run redirected to a log file still has to be able to say what it is doing.
# lib/progress-bar.sh cannot: it needs both streams to be a tty, which is
# exactly what orchestrate.sh takes away. So ralph.sh writes the same facts to
# ralph/status/<run>.json unconditionally, and the orchestrator's board reads
# them back.
#
# Two things are checked here. First, that the file exists and is current
# *while the run is still going* - a status written only at exit would be
# useless to a watcher. Second, that nothing about the board leaks terminal
# control codes into redirected output, which would corrupt every log file the
# orchestrator writes.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-run-status-test.XXXXXX")
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_RALPH="$REPO_ROOT/template/ralph"
FAKE_BIN="$TEST_ROOT/bin"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FAKE_BIN"

# The stub copies the live status file aside on every call. That snapshot is the
# whole point of the test: it is taken from outside ralph.sh, mid-run, the way
# the orchestrator's board reads it.
cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash

set -e

call_count=0
if [[ -f "$FAKE_CODEX_COUNT_FILE" ]]; then
  call_count=$(cat "$FAKE_CODEX_COUNT_FILE")
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$FAKE_CODEX_COUNT_FILE"

last_message_file=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output-last-message)
      last_message_file="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

prompt_file="$FAKE_CODEX_PROMPTS_DIR/prompt-$call_count"
cat > "$prompt_file"

if [[ -f "$FAKE_RALPH_STATUS_FILE" ]]; then
  cp "$FAKE_RALPH_STATUS_FILE" "$FAKE_RALPH_SNAPSHOT_DIR/snapshot-$call_count.json"
fi

# The scaffold cleanup round is recognised the way a real agent would recognise
# it - by the prompt it was handed - and satisfied the way a real one has to be:
# by writing the marker file the loop actually trusts.
if grep -q '^## Scaffold Cleanup Context' "$prompt_file"; then
  cleanup_marker=$(grep -m1 '^- Cleanup marker' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
  cleanup_run_id=$(grep -m1 '^- Run ID: ' "$prompt_file" | sed 's/.*`\(.*\)`.*/\1/')
  printf 'status=done\nrun_id=%s\n' "$cleanup_run_id" > "$cleanup_marker"
  message="Removed the run's per-story scaffolding."
elif grep -q 'Ralph Story Unblock Round' "$prompt_file"; then
  case "$FAKE_CODEX_UNBLOCK_MODE" in
    finish)
      story_file="$FAKE_CODEX_STORIES_DIR/US-001.json"
      if [[ -f "$story_file" ]]; then
        jq '.passes = true' "$story_file" > "$story_file.tmp"
        mv "$story_file.tmp" "$story_file"
      fi
      message="Verdict: not blocked, only unfinished. Finished the story."
      ;;
    *)
      message="Verdict: blocked on a decision only a human can make."
      ;;
  esac
else
  message="Implementation stopped before the acceptance criteria passed."
fi

printf '%s\n' "$message" > "$last_message_file"
printf '%s\n' '{"type":"thread.started","thread_id":"fake-session"}'
jq -nc --arg text "$message" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":10}}'
EOF
chmod +x "$FAKE_BIN/codex"

SCENARIO=""
FIXTURE_REPO=""
STATUS_FILE=""
SNAPSHOT_DIR=""
OUTPUT_FILE=""
RUN_STATUS=0

fail() {
  echo "$1" >&2
  if [[ -n "$OUTPUT_FILE" && -f "$OUTPUT_FILE" ]]; then
    echo "--- ralph output ---" >&2
    cat "$OUTPUT_FILE" >&2
  fi
  exit 1
}

# Read one field out of a JSON file, failing the test rather than the shell when
# the file or the field is missing.
status_field() {
  local file="$1" field="$2" value
  [[ -f "$file" ]] || fail "Expected a status file at $file"
  value=$(jq -r --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null || echo "")
  printf '%s' "$value"
}

expect_field() {
  local file="$1" field="$2" want="$3" got
  got="$(status_field "$file" "$field")"
  if [[ "$got" != "$want" ]]; then
    fail "$(basename "$file"): expected $field='$want', got '$got'"
  fi
}

setup_scenario() {
  SCENARIO="$1"
  local scenario_dir="$TEST_ROOT/$SCENARIO"

  FIXTURE_REPO="$scenario_dir/repo"
  SNAPSHOT_DIR="$scenario_dir/snapshots"
  OUTPUT_FILE="$scenario_dir/output"
  STATUS_FILE="$FIXTURE_REPO/ralph/status/legacy.json"

  mkdir -p "$FIXTURE_REPO" "$SNAPSHOT_DIR" "$scenario_dir/prompts"
  cp -R "$TEMPLATE_RALPH" "$FIXTURE_REPO/ralph"

  cat > "$FIXTURE_REPO/ralph/prd.json" <<'PRD'
{
  "project": "run status test",
  "branchName": "",
  "userNeed": "A watcher can see what a redirected run is doing.",
  "userStories": [
    {
      "id": "US-001",
      "title": "A story that stays incomplete",
      "description": "Exercise the status file. Covers: the whole need.",
      "acceptanceCriteria": ["The fake implementation would need to mark this story complete."],
      "dependsOn": [],
      "passes": false,
      "notes": ""
    }
  ]
}
PRD

  git -C "$FIXTURE_REPO" init -q
  git -C "$FIXTURE_REPO" config user.name "Ralph Test"
  git -C "$FIXTURE_REPO" config user.email "ralph-test@example.com"
  git -C "$FIXTURE_REPO" add .
  git -C "$FIXTURE_REPO" commit -qm "test fixture"
}

run_ralph() {
  local unblock_mode="$1"
  local scenario_dir="$TEST_ROOT/$SCENARIO"

  set +e
  env \
    "PATH=$FAKE_BIN:$PATH" \
    "FAKE_CODEX_COUNT_FILE=$scenario_dir/calls" \
    "FAKE_CODEX_PROMPTS_DIR=$scenario_dir/prompts" \
    "FAKE_CODEX_STORIES_DIR=$FIXTURE_REPO/ralph/stories" \
    "FAKE_CODEX_UNBLOCK_MODE=$unblock_mode" \
    "FAKE_RALPH_STATUS_FILE=$STATUS_FILE" \
    "FAKE_RALPH_SNAPSHOT_DIR=$SNAPSHOT_DIR" \
    RALPH_NOTIFY=0 \
    RALPH_PROGRESS=0 \
    bash "$FIXTURE_REPO/ralph/scripts/ralph.sh" --legacy --tool codex \
    > "$OUTPUT_FILE" 2>&1
  RUN_STATUS=$?
  set -e
}

# --- The status file is live, and the unblock round is on it -----------------
#
# RALPH_PROGRESS=0 above is deliberate: the pinned row is off, and the status
# file still has to be written. The two are independent outputs of the same
# state, not one wrapping the other.

setup_scenario "unfinished"
run_ralph "finish"

if [[ "$RUN_STATUS" -ne 0 ]]; then
  fail "Expected Ralph to finish the run after the unblock round completed the story, got $RUN_STATUS"
fi

STORY_SNAPSHOT="$SNAPSHOT_DIR/snapshot-1.json"
UNBLOCK_SNAPSHOT="$SNAPSHOT_DIR/snapshot-2.json"

[[ -f "$STORY_SNAPSHOT" ]] \
  || fail "No status file existed while the first story round was running"
[[ -f "$UNBLOCK_SNAPSHOT" ]] \
  || fail "No status file existed while the unblock round was running"

expect_field "$STORY_SNAPSHOT" "phase" "working"
expect_field "$STORY_SNAPSHOT" "storyId" "US-001"
expect_field "$STORY_SNAPSHOT" "storyTitle" "A story that stays incomplete"
expect_field "$STORY_SNAPSHOT" "round" "1"
expect_field "$STORY_SNAPSHOT" "storiesTotal" "1"
expect_field "$STORY_SNAPSHOT" "storiesDone" "0"
expect_field "$STORY_SNAPSHOT" "outcome" "running"
expect_field "$STORY_SNAPSHOT" "unblockRounds" "0"

# The whole reason the phase is named separately from the round: a watcher has
# to be able to tell an ordinary story round from the repair round.
expect_field "$UNBLOCK_SNAPSHOT" "phase" "unblocking"
expect_field "$UNBLOCK_SNAPSHOT" "storyId" "US-001"
expect_field "$UNBLOCK_SNAPSHOT" "unblockRounds" "1"
expect_field "$UNBLOCK_SNAPSHOT" "unblockStoryId" "US-001"

# The wrap-up rounds are on the file too: the scaffold cleanup round belongs to
# no story, so a watcher would otherwise see the row freeze on the last one.
CLEANUP_SNAPSHOT="$SNAPSHOT_DIR/snapshot-3.json"
[[ -f "$CLEANUP_SNAPSHOT" ]] \
  || fail "No status file existed while the scaffold cleanup round was running"
expect_field "$CLEANUP_SNAPSHOT" "phase" "cleanup"
expect_field "$CLEANUP_SNAPSHOT" "storyId" ""
expect_field "$CLEANUP_SNAPSHOT" "storiesDone" "1"

if [[ "$(status_field "$STORY_SNAPSHOT" "pid")" -le 0 ]]; then
  fail "The status file carried no pid, so a watcher cannot tell a live run from an abandoned file"
fi

# The verdict outlives the phase: by the time the run ends it is back on the
# happy path, and this is the only record that it was ever off it.
expect_field "$STATUS_FILE" "phase" "exited"
expect_field "$STATUS_FILE" "outcome" "succeeded"
expect_field "$STATUS_FILE" "exitCode" "0"
expect_field "$STATUS_FILE" "unblockOutcome" "finished"
expect_field "$STATUS_FILE" "unblockRounds" "1"
expect_field "$STATUS_FILE" "storiesDone" "1"

# Consolidation archives ralph/runs/ and stages it with `git add -A`. A runtime
# status file underneath it would end up in a commit.
if [[ -e "$FIXTURE_REPO/ralph/runs" ]] \
  && find "$FIXTURE_REPO/ralph/runs" -name '*.json' -path '*status*' | grep -q .; then
  fail "A status file was written under ralph/runs/, where consolidation would commit it"
fi

# --- A run that stops on a blocker records that too ---------------------------

setup_scenario "stopped"
run_ralph "stop"

if [[ "$RUN_STATUS" -eq 0 ]]; then
  fail "Expected Ralph to stop when the unblock round neither finished nor restructured the story"
fi

expect_field "$STATUS_FILE" "phase" "exited"
expect_field "$STATUS_FILE" "outcome" "failed"
expect_field "$STATUS_FILE" "exitCode" "1"
expect_field "$STATUS_FILE" "unblockOutcome" "stopped"
expect_field "$STATUS_FILE" "unblockRounds" "1"

# --- Nothing about the board reaches a redirected stream ----------------------
#
# orchestrate.sh redirects every parallel run to a log file and the tests here
# capture stdout. A single escape sequence written to stdout instead of /dev/tty
# would corrupt both.

if grep -q $'\033' "$OUTPUT_FILE"; then
  fail "Ralph wrote a terminal escape sequence into redirected output"
fi

BOARD_PROBE="$TEST_ROOT/board-probe"
set +e
bash -c '
  . "'"$TEMPLATE_RALPH"'/scripts/lib/log.sh"
  . "'"$TEMPLATE_RALPH"'/scripts/lib/status-board.sh"
  ralph_board_start "'"$TEST_ROOT"'/status" 3
  ralph_board_begin_frame
  ralph_board_row "run-a" "running" ""
  ralph_board_end_frame 1 0 0
  ralph_board_stop
  printf "board probe finished\n"
' > "$BOARD_PROBE" 2>&1
probe_status=$?
set -e

if [[ "$probe_status" -ne 0 ]]; then
  echo "--- board probe output ---" >&2
  cat "$BOARD_PROBE" >&2
  echo "The board's own calls failed with a redirected stdout" >&2
  exit 1
fi

if ! grep -q "board probe finished" "$BOARD_PROBE"; then
  echo "--- board probe output ---" >&2
  cat "$BOARD_PROBE" >&2
  echo "The board swallowed the probe's output" >&2
  exit 1
fi

if grep -q $'\033' "$BOARD_PROBE"; then
  echo "--- board probe output ---" >&2
  cat -v "$BOARD_PROBE" >&2
  echo "The board wrote a terminal escape sequence to a redirected stdout" >&2
  exit 1
fi

echo "run status integration test: ok"
