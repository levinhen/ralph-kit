#!/bin/bash

# Keep one status line pinned to the bottom of an interactive terminal while
# normal Ralph/tool output scrolls in the region above it. Redirected output is
# intentionally left untouched so logs never contain terminal control codes.
#
# All control sequences go to /dev/tty, never to stdout/stderr, so nothing can
# leak into a pipe or a log file even if only one of the two is redirected.

RALPH_PROGRESS_ACTIVE="false"
RALPH_PROGRESS_ROWS=0
RALPH_PROGRESS_COLS=0
RALPH_PROGRESS_PRD_FILE=""
RALPH_PROGRESS_MAX_ITERATIONS=0
RALPH_PROGRESS_STATE_FILE=""
RALPH_PROGRESS_TICKER_PID=""
RALPH_PROGRESS_TICK_SECONDS="${RALPH_PROGRESS_TICK_SECONDS:-2}"

ralph_progress_tty_write() {
  printf '%b' "$1" > /dev/tty 2>/dev/null || true
}

ralph_progress_supported() {
  case "${RALPH_PROGRESS:-1}" in
    0 | false | no | off) return 1 ;;
  esac

  # Both streams must be a terminal: the loop prints to stdout, the tool stream
  # prints to stderr, and a pinned row only makes sense when both land here.
  [[ -t 1 && -t 2 ]] || return 1
  [[ "${TERM:-dumb}" != "dumb" ]] || return 1
  [[ -w /dev/tty ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [[ "$RALPH_PROGRESS_TICK_SECONDS" =~ ^[0-9]+$ && "$RALPH_PROGRESS_TICK_SECONDS" -ge 1 ]] \
    || RALPH_PROGRESS_TICK_SECONDS=2
}

ralph_progress_terminal_size() {
  local size

  size=$(stty size < /dev/tty 2>/dev/null || echo "")
  if [[ "$size" =~ ^[0-9]+[[:space:]][0-9]+$ ]]; then
    RALPH_PROGRESS_ROWS="${size%% *}"
    RALPH_PROGRESS_COLS="${size##* }"
  elif command -v tput >/dev/null 2>&1; then
    RALPH_PROGRESS_ROWS=$(tput lines 2>/dev/null || echo 0)
    RALPH_PROGRESS_COLS=$(tput cols 2>/dev/null || echo 0)
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

ralph_progress_write_state() {
  local phase="$1"
  local story_id="$2"
  local iteration="$3"
  local phase_started="$4"
  local tmp_file

  [[ -n "$RALPH_PROGRESS_STATE_FILE" ]] || return 0

  tmp_file="$RALPH_PROGRESS_STATE_FILE.tmp"
  {
    printf '%s\n' "on"
    printf '%s\n' "$phase"
    printf '%s\n' "$story_id"
    printf '%s\n' "$iteration"
    printf '%s\n' "$phase_started"
    printf '%s\n' "$RALPH_PROGRESS_ROWS"
    printf '%s\n' "$RALPH_PROGRESS_COLS"
  } > "$tmp_file" 2>/dev/null || return 0
  # Replace in one step: the ticker reads this file on its own schedule and must
  # never see a half-written state.
  mv -f "$tmp_file" "$RALPH_PROGRESS_STATE_FILE" 2>/dev/null || return 0
}

ralph_progress_duration() {
  local seconds="$1"

  [[ "$seconds" =~ ^[0-9]+$ ]] || return 0
  if [[ "$seconds" -lt 3600 ]]; then
    printf '%dm%02ds' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%dh%02dm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
  fi
}

ralph_progress_bar() {
  local percent="$1"
  local width="$2"
  local filled=$((percent * width / 100))
  local empty=$((width - filled))
  local full_char="#"
  local empty_char="-"
  local bar=""

  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf8* | *UTF8* | *utf-8*)
      full_char="█"
      empty_char="░"
      ;;
  esac

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
  local rows="" cols=""
  local total=0
  local completed=0
  local percent=0
  local bar_width=10
  local story_title=""
  local phase_label
  local elapsed=""
  local now
  local stats
  local status
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
  } < "$RALPH_PROGRESS_STATE_FILE" 2>/dev/null || return 0

  [[ "$state" == "on" ]] || return 0
  [[ "$rows" =~ ^[0-9]+$ && "$rows" -ge 3 ]] || return 0
  [[ "$cols" =~ ^[0-9]+$ && "$cols" -ge 36 ]] || return 0
  [[ "$iteration" =~ ^[0-9]+$ ]] || iteration=0

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
    finalizing) phase_label="finalizing worktree" ;;
    merge-back) phase_label="merge-back" ;;
    consolidating) phase_label="consolidating" ;;
    complete) phase_label="complete" ;;
    *) phase_label="starting" ;;
  esac

  if [[ "$phase_started" =~ ^[0-9]+$ && "$phase_started" -gt 0 ]]; then
    now=$(date +%s 2>/dev/null || echo 0)
    if [[ "$now" =~ ^[0-9]+$ && "$now" -ge "$phase_started" ]]; then
      elapsed="$(ralph_progress_duration "$((now - phase_started))")"
    fi
  fi

  status="Ralph [$(ralph_progress_bar "$percent" "$bar_width")] ${completed}/${total} done"
  if [[ -n "$story_id" ]]; then
    status="$status | ${story_id:0:20}"
  fi
  status="$status | $phase_label"
  if [[ -n "$elapsed" ]]; then
    status="$status $elapsed"
  fi
  if [[ "$iteration" -gt 0 ]]; then
    status="$status | iter ${iteration}/${RALPH_PROGRESS_MAX_ITERATIONS}"
  fi

  # Titles are useful, but can contain wide CJK glyphs. Budget two terminal
  # columns per character so the pinned line never wraps into the log region.
  if [[ -n "$story_title" && "$cols" -ge 72 ]]; then
    title_room=$(((cols - ${#status} - 4) / 2))
    if [[ "$title_room" -gt 3 ]]; then
      story_title="${story_title:0:title_room}"
      status="$status | $story_title"
    fi
  fi

  status="${status:0:$((cols - 1))}"
  # DECSC/DECRC around the jump so the scrolling log keeps its own cursor. The
  # scrolling region is deliberately not re-asserted here: doing that while the
  # log cursor sits on the last row of the region would push the log up by a
  # line on every refresh.
  if [[ -z "${NO_COLOR:-}" ]]; then
    ralph_progress_tty_write "\e7\e[${rows};1H\e[2K\e[1;36m${status}\e[0m\e8"
  else
    ralph_progress_tty_write "\e7\e[${rows};1H\e[2K${status}\e8"
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
  local max_iterations="$2"

  ralph_progress_supported || return 0
  ralph_progress_terminal_size || return 0

  RALPH_PROGRESS_STATE_FILE=$(mktemp "${TMPDIR:-/tmp}/ralph-progress.XXXXXX" 2>/dev/null || echo "")
  [[ -n "$RALPH_PROGRESS_STATE_FILE" ]] || return 0

  RALPH_PROGRESS_PRD_FILE="$prd_file"
  RALPH_PROGRESS_MAX_ITERATIONS="$max_iterations"
  RALPH_PROGRESS_ACTIVE="true"

  ralph_progress_write_state "starting" "" 0 "$(date +%s 2>/dev/null || echo 0)"
  ralph_progress_reserve_row
  ralph_progress_render
  ralph_progress_start_ticker
}

ralph_progress_update() {
  local phase="${1:-working}"
  local story_id="${2:-}"
  local iteration="${3:-0}"
  local previous_phase=""
  local previous_story=""
  local previous_started=""
  local ignored

  [[ "$RALPH_PROGRESS_ACTIVE" == "true" ]] || return 0
  [[ -f "$RALPH_PROGRESS_STATE_FILE" ]] || return 0

  {
    IFS= read -r ignored || true
    IFS= read -r previous_phase || true
    IFS= read -r previous_story || true
    IFS= read -r ignored || true
    IFS= read -r previous_started || true
  } < "$RALPH_PROGRESS_STATE_FILE" 2>/dev/null || true

  # The elapsed clock measures the current phase, so it only restarts when the
  # phase or the story actually changes.
  if [[ "$phase" != "$previous_phase" || "$story_id" != "$previous_story" \
    || ! "$previous_started" =~ ^[0-9]+$ ]]; then
    previous_started="$(date +%s 2>/dev/null || echo 0)"
  fi

  ralph_progress_write_state "$phase" "$story_id" "$iteration" "$previous_started"
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
  ralph_progress_update_geometry
  ralph_progress_render
}

ralph_progress_update_geometry() {
  local state="" phase="" story_id="" iteration="" phase_started=""

  [[ -f "$RALPH_PROGRESS_STATE_FILE" ]] || return 0
  {
    IFS= read -r state || true
    IFS= read -r phase || true
    IFS= read -r story_id || true
    IFS= read -r iteration || true
    IFS= read -r phase_started || true
  } < "$RALPH_PROGRESS_STATE_FILE" 2>/dev/null || return 0

  ralph_progress_write_state "$phase" "$story_id" "$iteration" "$phase_started"
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
