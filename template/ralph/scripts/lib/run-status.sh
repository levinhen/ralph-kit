#!/bin/bash

# Persist what a run is doing to a file, unconditionally.
#
# lib/progress-bar.sh pins the same facts to an interactive terminal, but it
# gives up the moment stdout/stderr are not a tty - which is exactly what
# orchestrate.sh creates for every parallel run when it redirects them to log
# files. Without a file on disk, "which story is run-b on, and did it fall into
# an unblock round?" exists only inside that process, and the orchestrator's
# terminal can report nothing but ok/FAILED at the very end.
#
# One JSON document per run at ralph/status/<run_id>.json, replaced atomically.
# It deliberately does NOT live under ralph/runs/<run_id>/: consolidation moves
# that directory into ralph/archive/ and stages the result with `git add -A`,
# and a runtime status file has no business in a commit.
#
# This module deliberately owns only the durable JSON projection. The
# run-observers composition layer fans lifecycle events out to this file and to
# the interactive progress row. Keeping that wiring out of this module makes
# status persistence usable on its own (for example in a redirected worker)
# without requiring any terminal API to have been loaded first.

RALPH_STATUS_FILE=""
RALPH_STATUS_PRD_FILE=""
RALPH_STATUS_RUN_ID=""
RALPH_STATUS_TOOL=""
RALPH_STATUS_PHASE=""
RALPH_STATUS_STORY_ID=""
RALPH_STATUS_ROUND=0
RALPH_STATUS_RUN_STARTED=0
RALPH_STATUS_PHASE_STARTED=0
RALPH_STATUS_ACTIVITY_FILE=""
RALPH_STATUS_UNBLOCK_ROUNDS=0
RALPH_STATUS_UNBLOCK_STORY=""
RALPH_STATUS_UNBLOCK_OUTCOME=""
RALPH_STATUS_OUTCOME=""
RALPH_STATUS_EXIT_CODE=""

ralph_status_now() {
  local now
  now="$(date +%s 2>/dev/null || echo 0)"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0
  printf '%s' "$now"
}

# The story counts and the current story's title come out of the PRD, so the
# reader never has to open a second file to render a row. Both are folded into
# the same jq that builds the document: one process per state change, not two.
ralph_status_write() {
  local tmp_file
  local now

  [[ -n "$RALPH_STATUS_FILE" ]] || return 0

  now="$(ralph_status_now)"
  tmp_file="$RALPH_STATUS_FILE.tmp.$$"

  # shellcheck disable=SC2016
  local filter='
    (.userStories // []) as $stories
    | {
        runId: $run_id,
        tool: $tool,
        pid: ($pid | tonumber),
        phase: $phase,
        storyId: $story_id,
        storyTitle: ([$stories[] | select(.id == $story_id) | .title] | first // ""),
        round: ($round | tonumber),
        storiesTotal: ($stories | length),
        storiesDone: ([$stories[] | select(.passes == true)] | length),
        runStartedAt: ($run_started | tonumber),
        phaseStartedAt: ($phase_started | tonumber),
        updatedAt: ($now | tonumber),
        activityFile: $activity_file,
        unblockRounds: ($unblock_rounds | tonumber),
        unblockStoryId: $unblock_story,
        unblockOutcome: $unblock_outcome,
        outcome: $outcome,
        exitCode: (if $exit_code == "" then null else ($exit_code | tonumber) end)
      }
  '

  {
    if [[ -f "$RALPH_STATUS_PRD_FILE" ]]; then
      jq -c \
        --arg run_id "$RALPH_STATUS_RUN_ID" \
        --arg tool "$RALPH_STATUS_TOOL" \
        --arg pid "$$" \
        --arg phase "$RALPH_STATUS_PHASE" \
        --arg story_id "$RALPH_STATUS_STORY_ID" \
        --arg round "$RALPH_STATUS_ROUND" \
        --arg run_started "$RALPH_STATUS_RUN_STARTED" \
        --arg phase_started "$RALPH_STATUS_PHASE_STARTED" \
        --arg now "$now" \
        --arg activity_file "$RALPH_STATUS_ACTIVITY_FILE" \
        --arg unblock_rounds "$RALPH_STATUS_UNBLOCK_ROUNDS" \
        --arg unblock_story "$RALPH_STATUS_UNBLOCK_STORY" \
        --arg unblock_outcome "$RALPH_STATUS_UNBLOCK_OUTCOME" \
        --arg outcome "$RALPH_STATUS_OUTCOME" \
        --arg exit_code "$RALPH_STATUS_EXIT_CODE" \
        "$filter" "$RALPH_STATUS_PRD_FILE"
    else
      # No PRD yet (or an unreadable one): the row still wants a phase and a
      # clock, so emit the same shape against an empty story list.
      jq -n -c \
        --arg run_id "$RALPH_STATUS_RUN_ID" \
        --arg tool "$RALPH_STATUS_TOOL" \
        --arg pid "$$" \
        --arg phase "$RALPH_STATUS_PHASE" \
        --arg story_id "$RALPH_STATUS_STORY_ID" \
        --arg round "$RALPH_STATUS_ROUND" \
        --arg run_started "$RALPH_STATUS_RUN_STARTED" \
        --arg phase_started "$RALPH_STATUS_PHASE_STARTED" \
        --arg now "$now" \
        --arg activity_file "$RALPH_STATUS_ACTIVITY_FILE" \
        --arg unblock_rounds "$RALPH_STATUS_UNBLOCK_ROUNDS" \
        --arg unblock_story "$RALPH_STATUS_UNBLOCK_STORY" \
        --arg unblock_outcome "$RALPH_STATUS_UNBLOCK_OUTCOME" \
        --arg outcome "$RALPH_STATUS_OUTCOME" \
        --arg exit_code "$RALPH_STATUS_EXIT_CODE" \
        "{} | $filter"
    fi
  } > "$tmp_file" 2>/dev/null || {
    rm -f "$tmp_file" 2>/dev/null || true
    return 0
  }

  # Replace in one step: a reader polls this file on its own schedule and must
  # never parse a half-written document.
  mv -f "$tmp_file" "$RALPH_STATUS_FILE" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null || true
}

# status_dir is the root checkout's ralph/status, never the worktree's: the
# orchestrator that reads these files runs in the root and never enters a
# worktree.
ralph_status_start() {
  local status_dir="$1"
  local prd_file="$2"
  local run_id="$3"
  local tool="$4"
  local now

  RALPH_STATUS_FILE=""
  [[ -n "$status_dir" && -n "$run_id" ]] || return 0
  mkdir -p "$status_dir" 2>/dev/null || return 0
  # The directory ignores itself rather than relying on the project's
  # .gitignore: these files are runtime state, they appear in a checkout the
  # installer does not own, and `git add .` in the user's repo must not sweep
  # them into a commit.
  if [[ ! -f "$status_dir/.gitignore" ]]; then
    printf '*\n' > "$status_dir/.gitignore" 2>/dev/null || true
  fi

  now="$(ralph_status_now)"

  RALPH_STATUS_FILE="$status_dir/$run_id.json"
  RALPH_STATUS_PRD_FILE="$prd_file"
  RALPH_STATUS_RUN_ID="$run_id"
  RALPH_STATUS_TOOL="$tool"
  RALPH_STATUS_PHASE="starting"
  RALPH_STATUS_STORY_ID=""
  RALPH_STATUS_ROUND=0
  RALPH_STATUS_RUN_STARTED="$now"
  RALPH_STATUS_PHASE_STARTED="$now"
  RALPH_STATUS_ACTIVITY_FILE=""
  RALPH_STATUS_UNBLOCK_ROUNDS=0
  RALPH_STATUS_UNBLOCK_STORY=""
  RALPH_STATUS_UNBLOCK_OUTCOME=""
  RALPH_STATUS_OUTCOME="running"
  RALPH_STATUS_EXIT_CODE=""

  ralph_status_write
}

# Persist the latest lifecycle position. Terminal rendering is handled by the
# run-observers composition layer, not from inside this state store.
ralph_status_update() {
  local phase="${1:-working}"
  local story_id="${2:-}"
  local round="${3:-0}"

  [[ -n "$RALPH_STATUS_FILE" ]] || return 0

  # Entering the unblock round is counted here rather than at the call site:
  # the phase transition is the event, and only this function sees both the
  # old phase and the new one.
  if [[ "$phase" == "unblocking" && "$RALPH_STATUS_PHASE" != "unblocking" ]]; then
    RALPH_STATUS_UNBLOCK_ROUNDS=$((RALPH_STATUS_UNBLOCK_ROUNDS + 1))
    RALPH_STATUS_UNBLOCK_STORY="$story_id"
    RALPH_STATUS_UNBLOCK_OUTCOME="deciding"
  fi

  if [[ "$phase" != "$RALPH_STATUS_PHASE" || "$story_id" != "$RALPH_STATUS_STORY_ID" ]]; then
    RALPH_STATUS_PHASE_STARTED="$(ralph_status_now)"
  fi

  RALPH_STATUS_PHASE="$phase"
  RALPH_STATUS_STORY_ID="$story_id"
  RALPH_STATUS_ROUND="$round"

  ralph_status_write
}

ralph_status_set_activity() {
  [[ -n "$RALPH_STATUS_FILE" ]] || return 0
  RALPH_STATUS_ACTIVITY_FILE="${1:-}"
  ralph_status_write
}

# How the single unblock round ended: `finished` (the story was merely
# unfinished), `restructured` (it was blocked and the split was reshaped), or
# `stopped` (neither, and Ralph is ending the run). This is the one thing a
# watcher most wants out of a redirected run, so it is recorded even though the
# phase has already moved on.
ralph_status_unblock_outcome() {
  [[ -n "$RALPH_STATUS_FILE" ]] || return 0
  RALPH_STATUS_UNBLOCK_OUTCOME="${1:-}"
  ralph_status_write
}

# Terminal state. The file is kept rather than deleted: the orchestrator prints
# its summary after the child is reaped, and a watcher opened afterwards should
# still be able to see that this run spent a round unblocking.
ralph_status_finish() {
  local outcome="${1:-}"
  local exit_code="${2:-}"

  [[ -n "$RALPH_STATUS_FILE" ]] || return 0

  [[ "$exit_code" =~ ^[0-9]+$ ]] || exit_code=""
  RALPH_STATUS_OUTCOME="$outcome"
  RALPH_STATUS_EXIT_CODE="$exit_code"
  RALPH_STATUS_PHASE="exited"
  ralph_status_write
}
