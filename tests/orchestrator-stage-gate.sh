#!/bin/bash
# The orchestrator must stop after a failed stage. A run that ends in the
# failure diagnosis round exits 1, and every later stage has to be skipped.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-orchestrator-test.XXXXXX")
FIXTURE_REPO="$TEST_ROOT/repo"
RALPH_ROOT="$FIXTURE_REPO/ralph"
SCRIPTS_DIR="$RALPH_ROOT/scripts"
ORCHESTRATOR="$SCRIPTS_DIR/orchestrate.sh"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FIXTURE_REPO"
cp -R "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph" "$RALPH_ROOT"
# The installer marks the shipped scripts executable; mirror that here.
chmod +x "$SCRIPTS_DIR"/*.sh

# Every run stays incomplete so the orchestrator schedules all of them.
for run_id in run-a run-b run-c; do
  mkdir -p "$RALPH_ROOT/runs/$run_id"
  cat > "$RALPH_ROOT/runs/$run_id/prd.json" <<EOF
{
  "project": "$run_id",
  "branchName": "",
  "userStories": [
    {
      "id": "US-001",
      "title": "An unfinished story",
      "description": "Keeps $run_id incomplete.",
      "acceptanceCriteria": ["Never satisfied in this test."],
      "passes": false,
      "notes": ""
    }
  ]
}
EOF
done

# Stand in for ralph.sh: record the call, honour a per-run delay, exit with a
# per-run status. Behavior file format: "<exit_code> <delay_seconds>".
cat > "$SCRIPTS_DIR/ralph.sh" <<'EOF'
#!/bin/bash

set -e

run_id=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      run_id="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done

printf '%s\n' "$run_id" >> "$FAKE_RALPH_CALLS_FILE"

exit_code=0
delay=0
if [[ -f "$FAKE_RALPH_BEHAVIOR_DIR/$run_id" ]]; then
  read -r exit_code delay < "$FAKE_RALPH_BEHAVIOR_DIR/$run_id"
fi

if [[ "$delay" -gt 0 ]]; then
  sleep "$delay"
fi

printf '%s\n' "$run_id" >> "$FAKE_RALPH_FINISHED_FILE"
echo "fake ralph $run_id exiting $exit_code"
exit "$exit_code"
EOF
chmod +x "$SCRIPTS_DIR/ralph.sh"

export FAKE_RALPH_BEHAVIOR_DIR="$TEST_ROOT/behavior"
mkdir -p "$FAKE_RALPH_BEHAVIOR_DIR"

reset_case() {
  export FAKE_RALPH_CALLS_FILE="$TEST_ROOT/calls-$1"
  export FAKE_RALPH_FINISHED_FILE="$TEST_ROOT/finished-$1"
  : > "$FAKE_RALPH_CALLS_FILE"
  : > "$FAKE_RALPH_FINISHED_FILE"
  rm -f "$FAKE_RALPH_BEHAVIOR_DIR"/*
}

fail_test() {
  echo "$1" >&2
  echo "--- orchestrator output ---" >&2
  cat "$2" >&2
  exit 1
}

# --- Case 1: a failed single-run stage must skip every later stage ------------

reset_case "serial"
echo "1 0" > "$FAKE_RALPH_BEHAVIOR_DIR/run-a"
OUTPUT_FILE="$TEST_ROOT/output-serial"

set +e
"$ORCHESTRATOR" --tool codex --plan "1 > 2 > 3" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 1 ]]; then
  fail_test "Expected the orchestrator to exit 1 after the failed stage, got $status" "$OUTPUT_FILE"
fi

if grep -qx "run-b" "$FAKE_RALPH_CALLS_FILE" || grep -qx "run-c" "$FAKE_RALPH_CALLS_FILE"; then
  fail_test "Later stages ran even though stage 1 failed" "$OUTPUT_FILE"
fi

grep -q "\[stage 1\] run-a: FAILED (exit 1)" "$OUTPUT_FILE" \
  || fail_test "Expected the failed run's real exit code in the stage report" "$OUTPUT_FILE"
grep -q "Stage 1 had failures" "$OUTPUT_FILE" \
  || fail_test "Expected the orchestrator to report the stage failure" "$OUTPUT_FILE"

# --- Case 2: a rate limit propagates its dedicated exit code ------------------

reset_case "ratelimit"
echo "75 0" > "$FAKE_RALPH_BEHAVIOR_DIR/run-a"
OUTPUT_FILE="$TEST_ROOT/output-ratelimit"

set +e
"$ORCHESTRATOR" --tool codex --plan "1 > 2" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 75 ]]; then
  fail_test "Expected the orchestrator to exit 75 on a rate-limited run, got $status" "$OUTPUT_FILE"
fi

if grep -qx "run-b" "$FAKE_RALPH_CALLS_FILE"; then
  fail_test "The next stage ran after a rate limit" "$OUTPUT_FILE"
fi

# --- Case 3: a parallel stage reaps in completion order, siblings finish ------

reset_case "parallel"
echo "0 3" > "$FAKE_RALPH_BEHAVIOR_DIR/run-a"   # slow, succeeds
echo "1 0" > "$FAKE_RALPH_BEHAVIOR_DIR/run-b"   # fails immediately
OUTPUT_FILE="$TEST_ROOT/output-parallel"

set +e
"$ORCHESTRATOR" --tool codex --plan "1,2 > 3" > "$OUTPUT_FILE" 2>&1 < /dev/null
status=$?
set -e

if [[ "$status" -ne 1 ]]; then
  fail_test "Expected the orchestrator to exit 1 after the failed parallel stage, got $status" "$OUTPUT_FILE"
fi

if grep -qx "run-c" "$FAKE_RALPH_CALLS_FILE"; then
  fail_test "Stage 2 ran even though a run in stage 1 failed" "$OUTPUT_FILE"
fi

grep -qx "run-a" "$FAKE_RALPH_FINISHED_FILE" \
  || fail_test "The sibling run was cut short instead of finishing" "$OUTPUT_FILE"

failed_line=$(grep -n "run-b: FAILED" "$OUTPUT_FILE" | head -1 | cut -d: -f1)
ok_line=$(grep -n "run-a: ok" "$OUTPUT_FILE" | head -1 | cut -d: -f1)
if [[ -z "$failed_line" || -z "$ok_line" ]]; then
  fail_test "Expected both parallel runs to be reported" "$OUTPUT_FILE"
fi
if [[ "$failed_line" -ge "$ok_line" ]]; then
  fail_test "The early failure was reported only after the slow sibling finished" "$OUTPUT_FILE"
fi

echo "orchestrator stage gate integration test: ok"
