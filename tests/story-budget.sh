#!/bin/bash
#
# Ralph used to run a fixed max_iterations budget (default 10) that every round
# drew from - stories and wrap-up rounds alike. With failed stories now ending
# the run through the diagnosis round, that budget only ever capped how many
# stories a run could finish. This test pins the replacement behaviour: a
# backlog larger than the old default runs to completion.

set -e

STORY_COUNT=12

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-story-budget-test.XXXXXX")
FIXTURE_REPO="$TEST_ROOT/repo"
FAKE_BIN="$TEST_ROOT/bin"
COUNT_FILE="$TEST_ROOT/calls"
OUTPUT_FILE="$TEST_ROOT/output"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

mkdir -p "$FIXTURE_REPO" "$FAKE_BIN"
cp -R "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph" "$FIXTURE_REPO/ralph"

jq -n --argjson count "$STORY_COUNT" '
  {
    project: "story budget test",
    branchName: "",
    userStories: [
      range(1; $count + 1)
      | {
          id: ("US-" + (("00" + (. | tostring)) | .[-3:])),
          title: ("Story " + (. | tostring)),
          description: "Exercise the story-round budget.",
          acceptanceCriteria: ["The fake tool marks this story complete."],
          passes: false,
          notes: ""
        }
    ]
  }
' > "$FIXTURE_REPO/ralph/prd.json"

# Each call completes exactly one story, so the run needs one round per story.
cat > "$FAKE_BIN/codex" <<'EOF'
#!/bin/bash

set -e

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

cat > /dev/null

call_count=0
if [[ -f "$FAKE_CODEX_COUNT_FILE" ]]; then
  call_count=$(cat "$FAKE_CODEX_COUNT_FILE")
fi
call_count=$((call_count + 1))
printf '%s\n' "$call_count" > "$FAKE_CODEX_COUNT_FILE"

for story_file in "$FAKE_CODEX_STORIES_DIR"/*.json; do
  [[ -f "$story_file" ]] || continue
  if [[ "$(jq -r '.passes' "$story_file")" != "true" ]]; then
    jq '.passes = true' "$story_file" > "$story_file.tmp"
    mv "$story_file.tmp" "$story_file"
    break
  fi
done

message="Completed one story."
printf '%s\n' "$message" > "$last_message_file"
printf '%s\n' '{"type":"thread.started","thread_id":"fake-session"}'
jq -nc --arg text "$message" '{type:"item.completed",item:{type:"agent_message",text:$text}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":10}}'
EOF
chmod +x "$FAKE_BIN/codex"

git -C "$FIXTURE_REPO" init -q
git -C "$FIXTURE_REPO" config user.name "Ralph Test"
git -C "$FIXTURE_REPO" config user.email "ralph-test@example.com"
git -C "$FIXTURE_REPO" add .
git -C "$FIXTURE_REPO" commit -qm "test fixture"

set +e
PATH="$FAKE_BIN:$PATH" \
  FAKE_CODEX_COUNT_FILE="$COUNT_FILE" \
  FAKE_CODEX_STORIES_DIR="$FIXTURE_REPO/ralph/stories" \
  RALPH_NOTIFY=0 \
  RALPH_PROGRESS=0 \
  bash "$FIXTURE_REPO/ralph/scripts/ralph.sh" --legacy --tool codex \
  > "$OUTPUT_FILE" 2>&1
run_status=$?
set -e

if [[ "$run_status" -ne 0 ]]; then
  echo "Expected Ralph to complete all $STORY_COUNT stories, got exit $run_status" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if [[ "$(cat "$COUNT_FILE")" -ne "$STORY_COUNT" ]]; then
  echo "Expected exactly $STORY_COUNT implementation calls, got $(cat "$COUNT_FILE")" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

if grep -qi 'max iterations' "$OUTPUT_FILE"; then
  echo "Ralph still reports an iteration budget" >&2
  cat "$OUTPUT_FILE" >&2
  exit 1
fi

grep -q "Ralph Round $STORY_COUNT " "$OUTPUT_FILE"
grep -q 'Ralph completed all tasks!' "$OUTPUT_FILE"

echo "story budget integration test: ok"
