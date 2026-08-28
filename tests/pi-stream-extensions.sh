#!/bin/bash
#
# The pi stream reader has to surface what an extension puts into the event
# stream. A headless run has no TUI, so a shadow-mind report that steers the
# agent - and the run events explaining where it came from - would otherwise
# vanish, leaving a turn that visibly changes course for no visible reason.
# The report must stay out of assistantText: that field stands in for pi's
# closing message and feeds Ralph's story bookkeeping.

set -e

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ralph-pi-stream-test.XXXXXX")
READER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/template/ralph/scripts/lib/stream-agent.mjs"
EVENTS="$TEST_ROOT/events.jsonl"
DISPLAY_FILE="$TEST_ROOT/display"
SUMMARY_FILE="$TEST_ROOT/summary.json"

cleanup_test() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test EXIT

fail() {
  echo "$1" >&2
  echo "--- display ---" >&2
  cat "$DISPLAY_FILE" >&2
  exit 1
}

REPORT=$'[Sol Guard / sol-guard]\nThe round is adding three layers of abstraction to a one-line change.'

{
  printf '%s\n' '{"type":"session","version":3,"id":"stream-test","cwd":"."}'
  printf '%s\n' '{"type":"agent_start"}'
  printf '%s\n' '{"type":"turn_start"}'
  # A skipped heartbeat is recorded on nearly every turn; it must stay quiet.
  printf '%s\n' '{"type":"entry_appended","entry":{"id":"e1","type":"custom","customType":"shadow-mind-event","data":{"kind":"heartbeat-skipped","data":{"reason":"no-tool-activity"}}}}'
  printf '%s\n' '{"type":"entry_appended","entry":{"id":"e2","type":"custom","customType":"shadow-mind-event","data":{"kind":"run-start","data":{"runId":"r1","shadowId":"sol-guard","model":"openai-codex/gpt-5.6-sol"}}}}'
  printf '%s\n' '{"type":"entry_appended","entry":{"id":"e3","type":"custom","customType":"shadow-mind-event","data":{"kind":"run-end","data":{"runId":"r1","shadowId":"sol-guard","reason":"report","durationMs":39120}}}}'
  # A steered custom message is emitted twice, as message_start and message_end;
  # only one of them may reach the log.
  jq -nc --arg c "$REPORT" '{type:"message_start",message:{role:"custom",customType:"shadow-report",display:true,content:$c,timestamp:1}}'
  jq -nc --arg c "$REPORT" '{type:"message_end",message:{role:"custom",customType:"shadow-report",display:true,content:$c,timestamp:1}}'
  jq -nc '{type:"message_end",message:{role:"custom",customType:"quiet-extension",display:false,content:"never shown",timestamp:2}}'
  jq -nc '{
    type: "message_end",
    message: {
      role: "assistant",
      content: [{type: "text", text: "Narrowed the change back to one line."}],
      model: "gpt-5.6-sol",
      stopReason: "stop",
      usage: {input: 100, output: 20, cacheRead: 10, cacheWrite: 5, cost: {total: 0.0011}}
    }
  }'
  printf '%s\n' '{"type":"entry_appended","entry":{"id":"e4","type":"custom","customType":"shadow-mind-event","data":{"kind":"headless-drain-start","data":{"timeoutMs":120000,"active":1}}}}'
  printf '%s\n' '{"type":"agent_end","messages":[],"willRetry":false}'
} > "$EVENTS"

node "$READER" \
  --tool pi \
  --activity-file "$TEST_ROOT/activity" \
  --summary-file "$SUMMARY_FILE" \
  --diagnostic-file "$TEST_ROOT/diagnostic.jsonl" \
  < "$EVENTS" 2> "$DISPLAY_FILE"

grep -q 'shadow sol-guard started on openai-codex/gpt-5.6-sol' "$DISPLAY_FILE" \
  || fail "Expected the shadow activation to be logged"
grep -q 'shadow sol-guard report after 39.1s' "$DISPLAY_FILE" \
  || fail "Expected the shadow run outcome to be logged"
grep -q 'waiting for 1 shadow run(s) to finish' "$DISPLAY_FILE" \
  || fail "Expected the headless drain to be logged"
grep -q '\[shadow-report\]' "$DISPLAY_FILE" \
  || fail "Expected the injected report to be labelled"
grep -q 'three layers of abstraction' "$DISPLAY_FILE" \
  || fail "Expected the injected report text to reach the log"

if [[ "$(grep -c 'three layers of abstraction' "$DISPLAY_FILE")" -ne 1 ]]; then
  fail "The injected report was logged more than once"
fi

if grep -q 'heartbeat' "$DISPLAY_FILE"; then
  fail "Skipped heartbeats must not reach the log"
fi

if grep -q 'never shown' "$DISPLAY_FILE"; then
  fail "A custom message with display:false must stay hidden"
fi

assistant_text=$(jq -r '.assistantText' "$SUMMARY_FILE")
if [[ "$assistant_text" != "Narrowed the change back to one line." ]]; then
  echo "Extension output leaked into assistantText: $assistant_text" >&2
  exit 1
fi

if [[ "$(jq -r '.usage.total' "$SUMMARY_FILE")" -ne 135 ]]; then
  echo "Extension events must not change the round's usage accounting" >&2
  jq -c '.usage' "$SUMMARY_FILE" >&2
  exit 1
fi

if [[ "$(jq -r '.sawCompletion' "$SUMMARY_FILE")" != "true" ]]; then
  echo "Expected the turn to still be reported as completed" >&2
  exit 1
fi

echo "pi stream extension test: ok"
