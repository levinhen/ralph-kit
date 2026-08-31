#!/bin/bash

# Keep one status line pinned to the bottom of an interactive terminal while
# normal Ralph/tool output scrolls in the region above it. Redirected output is
# intentionally left untouched so logs never contain terminal control codes.
#
# All control sequences go to /dev/tty, never to stdout/stderr, so nothing can
# leak into a pipe or a log file even if only one of the two is redirected.

_ralph_progress_lib_dir=$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=terminal.sh
. "$_ralph_progress_lib_dir/terminal.sh"
unset _ralph_progress_lib_dir

RALPH_PROGRESS_ACTIVE="false"
RALPH_PROGRESS_ROWS=0
RALPH_PROGRESS_COLS=0
RALPH_PROGRESS_PRD_FILE=""
RALPH_PROGRESS_STATE_FILE=""
RALPH_PROGRESS_TICKER_PID=""
RALPH_PROGRESS_TICK_SECONDS="${RALPH_PROGRESS_TICK_SECONDS:-2}"

# Fixed for the lifetime of the run, so the ticker inherits them at fork time
# and never has to read them back from the state file.
RALPH_PROGRESS_RUN_LABEL=""
RALPH_PROGRESS_IDLE_LIMIT=0
# Every agent turn has quiet stretches, so a permanently visible idle clock
# would be noise competing for a single row. It appears only once the silence
# is long enough to mean something.
RALPH_PROGRESS_IDLE_MIN="${RALPH_PROGRESS_IDLE_MIN:-30}"

# The mutable half of the state. The main shell is the only writer; the ticker
# reads its copy back out of the state file.
RALPH_PROGRESS_PHASE=""
RALPH_PROGRESS_STORY_ID=""
RALPH_PROGRESS_ITERATION=0
RALPH_PROGRESS_PHASE_STARTED=0
RALPH_PROGRESS_RUN_STARTED=0
# Stories already passing when this run started. The ETA extrapolates from work
# this run actually did, so resuming a half-finished run does not divide the
# elapsed time by stories some earlier run completed.
RALPH_PROGRESS_COMPLETED_AT_START=0
RALPH_PROGRESS_ACTIVITY_FILE=""

# `stat` takes different flags on BSD and GNU. Probe once, then remember, so a
# refresh never spends two processes finding that out again.
RALPH_PROGRESS_STAT_FLAVOR=""

# Scratch for the width-budgeted line assembly in ralph_progress_render.
RALPH_PROGRESS_LINE=""
RALPH_PROGRESS_BUDGET=0

ralph_progress_tty_write() {
  ralph_terminal_tty_write "$1"
}

ralph_progress_supported() {
  case "${RALPH_PROGRESS:-1}" in
    0 | false | no | off) return 1 ;;
  esac

  # Both streams must be a terminal: the loop prints to stdout, the tool stream
  # prints to stderr, and a pinned row only makes sense when both land here.
  ralph_terminal_supported 1 2 || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ "$RALPH_PROGRESS_TICK_SECONDS" =~ ^[0-9]+$ && "$RALPH_PROGRESS_TICK_SECONDS" -ge 1 ]] \
    || RALPH_PROGRESS_TICK_SECONDS=2
}

ralph_progress_terminal_size() {
  if ralph_terminal_probe_size; then
    RALPH_PROGRESS_ROWS="$RALPH_TERMINAL_ROWS"
    RALPH_PROGRESS_COLS="$RALPH_TERMINAL_COLS"
  else
    RALPH_PROGRESS_ROWS=0
    RALPH_PROGRESS_COLS=0
  fi

  [[ "$RALPH_PROGRESS_ROWS" =~ ^[0-9]+$ ]] || RALPH_PROGRESS_ROWS=0
  [[ "$RALPH_PROGRESS_COLS" =~ ^[0-9]+$ ]] || RALPH_PROGRESS_COLS=0
  [[ "$RALPH_PROGRESS_ROWS" -ge 3 && "$RALPH_PROGRESS_COLS" -ge 36 ]]
}

# Reserve the bottom row and shrink the scrolling region to everything above it.
#
# The cursor MUST end up inside the new region. A terminal whose cursor sits
# below the scrolling region stops scrolling on line feed: it parks on the last
# row and every following line overwrites the previous one, which looks exactly
# like the script's output disappearing. LF + CUU is the portable way to get
# there without knowing the current row: if the cursor already is on the last
# row the LF scrolls the screen (so the text line moves up with it) and the CUU
# lands back on that same text line, now one row higher; anywhere else the pair
# is a no-op that just proves there is a row below us.
ralph_progress_reserve_row() {
  ralph_progress_tty_write "\n\e[A\e7\e[1;$((RALPH_PROGRESS_ROWS - 1))r\e8"
}

# Serialise whatever the mutable globals currently hold. Every setter updates
# the globals and calls this, so there is exactly one place that knows the file
# layout, and callers never have to read fields back just to preserve them.
ralph_progress_write_state() {
  local tmp_file

  [[ -n "$RALPH_PROGRESS_STATE_FILE" ]] || return 0

  tmp_file="$RALPH_PROGRESS_STATE_FILE.tmp"
  {
    printf '%s\n' "on"
    printf '%s\n' "$RALPH_PROGRESS_PHASE"
    printf '%s\n' "$RALPH_PROGRESS_STORY_ID"
    printf '%s\n' "$RALPH_PROGRESS_ITERATION"
    printf '%s\n' "$RALPH_PROGRESS_PHASE_STARTED"
    printf '%s\n' "$RALPH_PROGRESS_ROWS"
    printf '%s\n' "$RALPH_PROGRESS_COLS"
    printf '%s\n' "$RALPH_PROGRESS_RUN_STARTED"
    printf '%s\n' "$RALPH_PROGRESS_COMPLETED_AT_START"
    printf '%s\n' "$RALPH_PROGRESS_ACTIVITY_FILE"
  } > "$tmp_file" 2>/dev/null || return 0
  # Replace in one step: the ticker reads this file on its own schedule and must
  # never see a half-written state.
  mv -f "$tmp_file" "$RALPH_PROGRESS_STATE_FILE" 2>/dev/null || return 0
}

# The heartbeat file the tool watchdog writes. Its path changes on every
# invocation, so unlike the other fixed settings it has to travel through the
# state file to reach the ticker.
ralph_progress_set_activity() {
  [[ "$RALPH_PROGRESS_ACTIVE" == "true" ]] || return 0

  RALPH_PROGRESS_ACTIVITY_FILE="${1:-}"
  ralph_progress_write_state
}

ralph_progress_duration() {
  ralph_terminal_duration "$1"
}

ralph_progress_mtime() {
  local path="$1"
  local value=""

  [[ -n "$path" && -f "$path" ]] || return 1

  if [[ -z "$RALPH_PROGRESS_STAT_FLAVOR" ]]; then
    if value=$(stat -f %m "$path" 2>/dev/null) && [[ "$value" =~ ^[0-9]+$ ]]; then
      RALPH_PROGRESS_STAT_FLAVOR="bsd"
    elif value=$(stat -c %Y "$path" 2>/dev/null) && [[ "$value" =~ ^[0-9]+$ ]]; then
      RALPH_PROGRESS_STAT_FLAVOR="gnu"
    else
      RALPH_PROGRESS_STAT_FLAVOR="unsupported"
      return 1
    fi
    printf '%s' "$value"
    return 0
  fi

  case "$RALPH_PROGRESS_STAT_FLAVOR" in
    bsd) value=$(stat -f %m "$path" 2>/dev/null) ;;
    gnu) value=$(stat -c %Y "$path" 2>/dev/null) ;;
    *) return 1 ;;
  esac

  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s' "$value"
}

# Append a segment only if the whole thing still fits. Segments are offered in
# priority order, so a long story title losing its place never costs the run
# clock its own - and a segment that does not fit is skipped rather than
# truncated, because half a number is worse than no number.
ralph_progress_add() {
  local segment="$1"

  [[ -n "$segment" ]] || return 0
  [[ $((${#RALPH_PROGRESS_LINE} + ${#segment})) -le "$RALPH_PROGRESS_BUDGET" ]] || return 1
  RALPH_PROGRESS_LINE="${RALPH_PROGRESS_LINE}${segment}"
}

ralph_progress_bar() {
  local percent="$1"
  local width="$2"
  local filled=$((percent * width / 100))
  local empty=$((width - filled))
  local full_char="#"
  local empty_char="-"
  local bar=""

  if ralph_terminal_utf8; then
    full_char="█"
    empty_char="░"
  fi

  while [[ "$filled" -gt 0 ]]; do
    bar="${bar}${full_char}"
    filled=$((filled - 1))
  done
  while [[ "$empty" -gt 0 ]]; do
    bar="${bar}${empty_char}"
    empty=$((empty - 1))
  done

  printf '%s' "$bar"
}

ralph_progress_render() {
  local state="" phase="" story_id="" iteration="" phase_started=""
  local rows="" cols="" run_started="" completed_at_start="" activity_file=""
  local total=0
  local completed=0
  local percent=0
  local bar_width=10
  local story_title=""
  local phase_label
  local elapsed=""
  local now=0
  local stats
  local head
  local idle_seconds=-1
  local activity_at
  local run_elapsed=0
  local done_here=0
  local remaining=0
  local color="1;36"
  local title_room

  [[ "$RALPH_PROGRESS_ACTIVE" == "true" ]] || return 0
  [[ -n "$RALPH_PROGRESS_STATE_FILE" && -f "$RALPH_PROGRESS_STATE_FILE" ]] || return 0

  {
    IFS= read -r state || true
    IFS= read -r phase || true
    IFS= read -r story_id || true
    IFS= read -r iteration || true
    IFS= read -r phase_started || true
    IFS= read -r rows || true
    IFS= read -r cols || true
    IFS= read -r run_started || true
    IFS= read -r completed_at_start || true
    IFS= read -r activity_file || true
  } < "$RALPH_PROGRESS_STATE_FILE" 2>/dev/null || return 0

  [[ "$state" == "on" ]] || return 0
  [[ "$rows" =~ ^[0-9]+$ && "$rows" -ge 3 ]] || return 0
  [[ "$cols" =~ ^[0-9]+$ && "$cols" -ge 36 ]] || return 0
  [[ "$iteration" =~ ^[0-9]+$ ]] || iteration=0
  [[ "$run_started" =~ ^[0-9]+$ ]] || run_started=0
  [[ "$completed_at_start" =~ ^[0-9]+$ ]] || completed_at_start=0

  if [[ -f "$RALPH_PROGRESS_PRD_FILE" ]]; then
    # One jq per refresh: story counts and the current story title together.
    stats=$(jq -r --arg story_id "$story_id" '
      (.userStories // []) as $stories
      | ($stories | length) as $total
      | ([$stories[] | select(.passes == true)] | length) as $done
      | ([$stories[] | select(.id == $story_id) | .title] | first // "")
      | (. | tostring | gsub("[[:space:]]+"; " ")) as $title
      | "\($total) \($done) \($title)"
    ' "$RALPH_PROGRESS_PRD_FILE" 2>/dev/null || echo "")
    read -r total completed story_title <<< "$stats" || true
  fi

  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  [[ "$completed" =~ ^[0-9]+$ ]] || completed=0
  if [[ "$total" -gt 0 ]]; then
    percent=$((completed * 100 / total))
  fi
  if [[ "$cols" -ge 72 ]]; then
    bar_width=16
  fi

  case "$phase" in
    working) phase_label="working" ;;
    checking) phase_label="checking" ;;
    unblocking) phase_label="unblocking story" ;;
    cleanup) phase_label="scaffold cleanup" ;;
    finalizing) phase_label="finalizing worktree" ;;
    merge-back) phase_label="merge-back" ;;
    consolidating) phase_label="consolidating" ;;
    complete) phase_label="complete" ;;
    *) phase_label="starting" ;;
  esac

  # The unblock round gets the warning colour: the run is off the happy path
  # until the story is finished or the backlog is reshaped around it.
  if [[ "$phase" == "unblocking" ]]; then
    color="1;33"
  fi

  now=$(date +%s 2>/dev/null || echo 0)
  [[ "$now" =~ ^[0-9]+$ ]] || now=0

  if [[ "$phase_started" =~ ^[0-9]+$ && "$phase_started" -gt 0 && "$now" -ge "$phase_started" ]]; then
    elapsed="$(ralph_progress_duration "$((now - phase_started))")"
  fi
  if [[ "$run_started" -gt 0 && "$now" -ge "$run_started" ]]; then
    run_elapsed=$((now - run_started))
  fi

  # The watchdog's heartbeat file is rewritten on every parsed agent event, so
  # its mtime is the last time the tool said anything at all. Without this the
  # row cannot distinguish a long test run from a wedged CLI: the phase clock
  # advances identically in both cases.
  if [[ -n "$activity_file" ]] && activity_at=$(ralph_progress_mtime "$activity_file"); then
    if [[ "$now" -ge "$activity_at" ]]; then
      idle_seconds=$((now - activity_at))
    fi
  fi

  # Priority order below is also display order, so the row degrades from the
  # right as the terminal narrows.
  RALPH_PROGRESS_BUDGET=$((cols - 1))
  RALPH_PROGRESS_LINE=""

  head="Ralph"
  # Parallel runs put identical-looking rows in several windows; the label is
  # the only thing telling them apart. It is gated on width rather than budgeted
  # because it is worthless in the middle of a truncated line.
  #
  # The separator stays ASCII on purpose: bash 3.2 (still the system shell on
  # macOS) folds a following multibyte character into the variable name when it
  # is written unbraced, and a non-ASCII glyph would be mojibake in a terminal
  # that is not on a UTF-8 locale anyway.
  if [[ -n "$RALPH_PROGRESS_RUN_LABEL" && "$cols" -ge 90 ]]; then
    head="${head}:${RALPH_PROGRESS_RUN_LABEL:0:16}"
  fi
  RALPH_PROGRESS_LINE="$head [$(ralph_progress_bar "$percent" "$bar_width")] ${completed}/${total} done"

  if [[ -n "$story_id" ]]; then
    ralph_progress_add " | ${story_id:0:20}" || true
  fi
  if [[ -n "$elapsed" ]]; then
    ralph_progress_add " | $phase_label $elapsed" || true
  else
    ralph_progress_add " | $phase_label" || true
  fi

  if [[ "$idle_seconds" -ge "$RALPH_PROGRESS_IDLE_MIN" ]]; then
    if [[ "$RALPH_PROGRESS_IDLE_LIMIT" -gt 0 ]]; then
      ralph_progress_add " | idle $(ralph_progress_duration "$idle_seconds")/$(ralph_progress_duration "$RALPH_PROGRESS_IDLE_LIMIT")" || true
    else
      ralph_progress_add " | idle $(ralph_progress_duration "$idle_seconds")" || true
    fi
    # Recolour the whole row rather than just the segment: escape codes would
    # count against the width budget, and a silent agent is worth the alarm.
    color="1;33"
  fi

  if [[ "$iteration" -gt 0 ]]; then
    ralph_progress_add " | round ${iteration}" || true
  fi
  if [[ "$run_elapsed" -gt 0 ]]; then
    ralph_progress_add " | total $(ralph_progress_duration "$run_elapsed")" || true
  fi

  # Straight-line extrapolation from this run's own throughput. Merge-back and
  # consolidation rounds are not stories, so the estimate drifts near the end of
  # a run - hence the tilde.
  done_here=$((completed - completed_at_start))
  remaining=$((total - completed))
  if [[ "$done_here" -gt 0 && "$remaining" -gt 0 && "$run_elapsed" -gt 0 ]]; then
    ralph_progress_add " | eta ~$(ralph_progress_duration "$((run_elapsed * remaining / done_here))")" || true
  fi

  if command -v ralph_usage_load >/dev/null 2>&1 && ralph_usage_load; then
    if [[ "$RALPH_USAGE_CALLS" -gt 0 ]]; then
      ralph_progress_add " | $(ralph_usage_cost_prefix)$(ralph_usage_format_cost "$RALPH_USAGE_COST_MICROS")" || true
      ralph_progress_add " | $(ralph_usage_format_tokens "$(ralph_usage_total_tokens)") tok" || true
    fi
  fi

  # Titles are useful, but can contain wide CJK glyphs. Budget two terminal
  # columns per character so the pinned line never wraps into the log region.
  if [[ -n "$story_title" && "$cols" -ge 72 ]]; then
    title_room=$(((RALPH_PROGRESS_BUDGET - ${#RALPH_PROGRESS_LINE} - 3) / 2))
    if [[ "$title_room" -gt 3 ]]; then
      RALPH_PROGRESS_LINE="$RALPH_PROGRESS_LINE | ${story_title:0:title_room}"
    fi
  fi

  # Last-resort clamp. Every segment above is width-budgeted, but the title's
  # two-columns-per-character budget is an estimate, and a malformed PRD could
  # still make the counts unexpectedly wide.
  RALPH_PROGRESS_LINE="${RALPH_PROGRESS_LINE:0:$((cols - 1))}"

  # DECSC/DECRC around the jump so the scrolling log keeps its own cursor. The
  # scrolling region is deliberately not re-asserted here: doing that while the
  # log cursor sits on the last row of the region would push the log up by a
  # line on every refresh.
  if [[ -z "${NO_COLOR:-}" ]]; then
    ralph_progress_tty_write "\e7\e[${rows};1H\e[2K\e[${color}m${RALPH_PROGRESS_LINE}\e[0m\e8"
  else
    ralph_progress_tty_write "\e7\e[${rows};1H\e[2K${RALPH_PROGRESS_LINE}\e8"
  fi
}

# Refresh the pinned row on a timer so it keeps reporting during long agent
# invocations: the phase clock moves and the story count picks up whatever the
# agent has committed, without the loop having to reach its next call site.
ralph_progress_start_ticker() {
  local parent_pid="$$"

  (
    # Default signal handling on purpose: the parent stops this ticker with a
    # plain TERM, and Ctrl-C should take it down with the rest of the group.
    trap - EXIT
    while :; do
      sleep "$RALPH_PROGRESS_TICK_SECONDS"
      kill -0 "$parent_pid" 2>/dev/null || break
      [[ -f "$RALPH_PROGRESS_STATE_FILE" ]] || break
      ralph_progress_render || true
    done
    # Ralph was killed without running its cleanup: give the terminal its full
    # scrolling region back instead of leaving a dead row pinned to the bottom.
    if ! kill -0 "$parent_pid" 2>/dev/null; then
      ralph_progress_tty_write "\e7\e[${RALPH_PROGRESS_ROWS};1H\e[2K\e[r\e8"
      rm -f "$RALPH_PROGRESS_STATE_FILE" "$RALPH_PROGRESS_STATE_FILE.tmp" || true
    fi
  ) > /dev/null 2>&1 &
  RALPH_PROGRESS_TICKER_PID="$!"
}

ralph_progress_stop_ticker() {
  [[ -n "$RALPH_PROGRESS_TICKER_PID" ]] || return 0

  kill "$RALPH_PROGRESS_TICKER_PID" 2>/dev/null || true
  wait "$RALPH_PROGRESS_TICKER_PID" 2>/dev/null || true
  RALPH_PROGRESS_TICKER_PID=""
}

ralph_progress_start() {
  local prd_file="$1"
  local run_label="${2:-}"
  local now

  ralph_progress_supported || return 0
  ralph_progress_terminal_size || return 0

  RALPH_PROGRESS_STATE_FILE=$(mktemp "${TMPDIR:-/tmp}/ralph-progress.XXXXXX" 2>/dev/null || echo "")
  [[ -n "$RALPH_PROGRESS_STATE_FILE" ]] || return 0

  now="$(date +%s 2>/dev/null || echo 0)"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0

  RALPH_PROGRESS_PRD_FILE="$prd_file"
  RALPH_PROGRESS_RUN_LABEL="$run_label"
  RALPH_PROGRESS_ACTIVE="true"

  if [[ "${RALPH_TOOL_IDLE_TIMEOUT_SECONDS:-360}" =~ ^[0-9]+$ ]]; then
    RALPH_PROGRESS_IDLE_LIMIT="${RALPH_TOOL_IDLE_TIMEOUT_SECONDS:-360}"
  fi
  [[ "$RALPH_PROGRESS_IDLE_MIN" =~ ^[0-9]+$ ]] || RALPH_PROGRESS_IDLE_MIN=30

  RALPH_PROGRESS_PHASE="starting"
  RALPH_PROGRESS_STORY_ID=""
  RALPH_PROGRESS_ITERATION=0
  RALPH_PROGRESS_PHASE_STARTED="$now"
  RALPH_PROGRESS_RUN_STARTED="$now"
  RALPH_PROGRESS_ACTIVITY_FILE=""
  RALPH_PROGRESS_COMPLETED_AT_START=0
  if [[ -f "$prd_file" ]]; then
    RALPH_PROGRESS_COMPLETED_AT_START=$(jq -r '
      [(.userStories // [])[] | select(.passes == true)] | length
    ' "$prd_file" 2>/dev/null || echo 0)
    [[ "$RALPH_PROGRESS_COMPLETED_AT_START" =~ ^[0-9]+$ ]] || RALPH_PROGRESS_COMPLETED_AT_START=0
  fi

  ralph_progress_write_state
  ralph_progress_reserve_row
  ralph_progress_render
  ralph_progress_start_ticker
}

ralph_progress_update() {
  local phase="${1:-working}"
  local story_id="${2:-}"
  local iteration="${3:-0}"

  [[ "$RALPH_PROGRESS_ACTIVE" == "true" ]] || return 0
  [[ -f "$RALPH_PROGRESS_STATE_FILE" ]] || return 0

  # The phase clock measures the current phase, so it only restarts when the
  # phase or the story actually changes. The run clock never restarts.
  if [[ "$phase" != "$RALPH_PROGRESS_PHASE" || "$story_id" != "$RALPH_PROGRESS_STORY_ID" \
    || ! "$RALPH_PROGRESS_PHASE_STARTED" =~ ^[0-9]+$ ]]; then
    RALPH_PROGRESS_PHASE_STARTED="$(date +%s 2>/dev/null || echo 0)"
  fi

  RALPH_PROGRESS_PHASE="$phase"
  RALPH_PROGRESS_STORY_ID="$story_id"
  RALPH_PROGRESS_ITERATION="$iteration"

  ralph_progress_write_state
  ralph_progress_render
}

ralph_progress_resize() {
  local previous_rows="$RALPH_PROGRESS_ROWS"

  [[ "$RALPH_PROGRESS_ACTIVE" == "true" ]] || return 0

  # Terminals drop DECSTBM on resize and reflow the rows, so rebuild the whole
  # reservation from scratch against the new geometry.
  ralph_progress_tty_write "\e[r"
  if ! ralph_progress_terminal_size; then
    # Too small to pin anything: clear the old row and give the terminal back.
    RALPH_PROGRESS_ROWS="$previous_rows"
    ralph_progress_stop
    return 0
  fi

  ralph_progress_reserve_row
  # The globals still hold everything except the geometry, which
  # ralph_progress_terminal_size just refreshed, so republishing them is enough.
  ralph_progress_write_state
  ralph_progress_render
}

ralph_progress_stop() {
  [[ "$RALPH_PROGRESS_ACTIVE" == "true" ]] || return 0
  RALPH_PROGRESS_ACTIVE="false"

  # Drop the state first: a tick that fires between here and the kill finds no
  # state and exits on its own instead of redrawing a row we just cleared.
  rm -f "$RALPH_PROGRESS_STATE_FILE" "$RALPH_PROGRESS_STATE_FILE.tmp" 2>/dev/null || true
  ralph_progress_stop_ticker
  RALPH_PROGRESS_STATE_FILE=""

  # Clear the status, restore the full scrolling region, then return to the
  # log cursor so the caller's final newline/prompt remains in the right place.
  ralph_progress_tty_write "\e7\e[${RALPH_PROGRESS_ROWS};1H\e[2K\e[r\e8"
}
