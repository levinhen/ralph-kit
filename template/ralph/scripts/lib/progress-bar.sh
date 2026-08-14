#!/bin/bash

# Keep one status line pinned to the bottom of an interactive terminal while
# normal Ralph/tool output scrolls in the region above it. Redirected output is
# intentionally left untouched so logs never contain terminal control codes.

RALPH_PROGRESS_ACTIVE="false"
RALPH_PROGRESS_ROWS=0
RALPH_PROGRESS_COLS=0
RALPH_PROGRESS_PRD_FILE=""
RALPH_PROGRESS_MAX_ITERATIONS=0
RALPH_PROGRESS_PHASE="starting"
RALPH_PROGRESS_STORY_ID=""
RALPH_PROGRESS_ITERATION=0

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

ralph_progress_render() {
  local phase="$RALPH_PROGRESS_PHASE"
  local story_id="$RALPH_PROGRESS_STORY_ID"
  local iteration="$RALPH_PROGRESS_ITERATION"
  local total=0
  local completed=0
  local percent=0
  local bar_width=10
  local filled=0
  local empty=0
  local bar=""
  local story_title=""
  local story_label=""
  local phase_label="$phase"
  local stats
  local status
  local title_room

  [[ "$RALPH_PROGRESS_ACTIVE" == "true" ]] || return 0

  if [[ -f "$RALPH_PROGRESS_PRD_FILE" ]]; then
    stats=$(jq -r '
      (.userStories // []) as $stories
      | "\($stories | length) \([$stories[] | select(.passes == true)] | length)"
    ' "$RALPH_PROGRESS_PRD_FILE" 2>/dev/null || echo "0 0")
    read -r total completed <<< "$stats"
  fi

  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  [[ "$completed" =~ ^[0-9]+$ ]] || completed=0
  if [[ "$total" -gt 0 ]]; then
    percent=$((completed * 100 / total))
  fi

  if [[ "$RALPH_PROGRESS_COLS" -ge 72 ]]; then
    bar_width=16
  fi
  filled=$((percent * bar_width / 100))
  empty=$((bar_width - filled))
  while [[ "$filled" -gt 0 ]]; do
    bar="${bar}#"
    filled=$((filled - 1))
  done
  while [[ "$empty" -gt 0 ]]; do
    bar="${bar}-"
    empty=$((empty - 1))
  done

  case "$phase" in
    working) phase_label="working" ;;
    checking) phase_label="checking" ;;
    finalizing) phase_label="finalizing worktree" ;;
    merge-back) phase_label="merge-back" ;;
    consolidating) phase_label="consolidating" ;;
    complete) phase_label="complete" ;;
    *) phase_label="starting" ;;
  esac

  if [[ -n "$story_id" ]]; then
    story_id="${story_id:0:20}"
    story_label="$story_id"
    story_title=$(jq -r --arg story_id "$RALPH_PROGRESS_STORY_ID" '
      [.userStories[]? | select(.id == $story_id) | .title] | first // ""
    ' "$RALPH_PROGRESS_PRD_FILE" 2>/dev/null || echo "")
    story_title="${story_title//$'\n'/ }"
  fi

  status="Ralph [$bar] ${completed}/${total} done"
  if [[ -n "$story_label" ]]; then
    status="$status | $story_label"
  fi
  status="$status | $phase_label"
  if [[ "$iteration" -gt 0 ]]; then
    status="$status | iter ${iteration}/${RALPH_PROGRESS_MAX_ITERATIONS}"
  fi

  # Titles are useful, but can contain wide CJK glyphs. Budget two terminal
  # columns per character so the pinned line never wraps into the log region.
  if [[ -n "$story_title" && "$RALPH_PROGRESS_COLS" -ge 72 ]]; then
    title_room=$(((RALPH_PROGRESS_COLS - ${#status} - 4) / 2))
    if [[ "$title_room" -gt 3 ]]; then
      story_title="${story_title:0:title_room}"
      status="$status | $story_title"
    fi
  fi

  status="${status:0:$((RALPH_PROGRESS_COLS - 1))}"
  if [[ -z "${NO_COLOR:-}" ]]; then
    printf '\0337\033[%d;1H\033[2K\033[1;36m%s\033[0m\0338' \
      "$RALPH_PROGRESS_ROWS" "$status"
  else
    printf '\0337\033[%d;1H\033[2K%s\0338' \
      "$RALPH_PROGRESS_ROWS" "$status"
  fi
}

ralph_progress_start() {
  local prd_file="$1"
  local max_iterations="$2"

  case "${RALPH_PROGRESS:-1}" in
    0|false|no|off) return 0 ;;
  esac
  [[ -t 1 && -t 2 && "${TERM:-dumb}" != "dumb" ]] || return 0
  ralph_progress_terminal_size || return 0

  RALPH_PROGRESS_PRD_FILE="$prd_file"
  RALPH_PROGRESS_MAX_ITERATIONS="$max_iterations"
  RALPH_PROGRESS_ACTIVE="true"

  # Reserve the last row. DECSC/DECRC keeps the log cursor where it was while
  # DECSTBM limits subsequent scrolling to the rows above the status line.
  printf '\0337\033[1;%dr\0338' "$((RALPH_PROGRESS_ROWS - 1))"
  ralph_progress_render
}

ralph_progress_update() {
  RALPH_PROGRESS_PHASE="${1:-working}"
  RALPH_PROGRESS_STORY_ID="${2:-}"
  RALPH_PROGRESS_ITERATION="${3:-0}"
  ralph_progress_render
}

ralph_progress_resize() {
  local old_rows="$RALPH_PROGRESS_ROWS"

  [[ "$RALPH_PROGRESS_ACTIVE" == "true" ]] || return 0
  # Clear the old pinned row and restore the full screen before measuring and
  # applying the resized scroll region.
  printf '\0337\033[%d;1H\033[2K\033[r\0338' "$old_rows"
  if ! ralph_progress_terminal_size; then
    RALPH_PROGRESS_ACTIVE="false"
    return 0
  fi
  printf '\0337\033[1;%dr\0338' "$((RALPH_PROGRESS_ROWS - 1))"
  ralph_progress_render
}

ralph_progress_stop() {
  [[ "$RALPH_PROGRESS_ACTIVE" == "true" ]] || return 0
  # Clear the status, restore the full scrolling region, then return to the
  # log cursor so the caller's final newline/prompt remains in the right place.
  printf '\0337\033[%d;1H\033[2K\033[r\0338' "$RALPH_PROGRESS_ROWS"
  RALPH_PROGRESS_ACTIVE="false"
}
