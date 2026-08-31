#!/bin/bash

# A multi-row status board pinned to the orchestrator's terminal - one row per
# scheduled run, plus a summary row.
#
# The orchestrator redirects every parallel run to its own log file, so nothing
# a run prints reaches this terminal and lib/progress-bar.sh (which needs both
# streams to be a tty) never even starts inside those children. Between launch
# and the final ok/FAILED line the terminal used to say nothing at all. This
# board is what fills that gap: the orchestrator supplies each run's scheduling
# state, the board reads the rest out of ralph/status/<run_id>.json.
#
# Like the pinned row, every control sequence goes to /dev/tty and never to
# stdout or stderr: orchestrate.sh's own output is captured by the tests and
# read back by humans, and must stay byte-identical plain text.

RALPH_BOARD_ACTIVE="false"
RALPH_BOARD_ROWS=0          # terminal height
RALPH_BOARD_COLS=0
RALPH_BOARD_HEIGHT=0        # rows reserved at the bottom
RALPH_BOARD_STATUS_DIR=""
RALPH_BOARD_HIDDEN=0        # runs that did not fit
RALPH_BOARD_LINES=()        # rendered lines for the current frame
RALPH_BOARD_STYLES=()       # log.sh style name per line

# Glyphs degrade to ASCII off a UTF-8 locale, the same rule the progress bar's
# bar characters follow.
RALPH_BOARD_GLYPH_RUN="*"
RALPH_BOARD_GLYPH_WAIT="."
RALPH_BOARD_GLYPH_OK="+"
RALPH_BOARD_GLYPH_BAD="x"
RALPH_BOARD_GLYPH_FLAG="!"

ralph_board_tty_write() {
  printf '%b' "$1" > /dev/tty 2>/dev/null || true
}

ralph_board_supported() {
  case "${RALPH_BOARD:-1}" in
    0 | false | no | off) return 1 ;;
  esac

  [[ -t 1 ]] || return 1
  [[ "${TERM:-dumb}" != "dumb" ]] || return 1
  [[ -w /dev/tty ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
}

ralph_board_terminal_size() {
  local size

  size=$(stty size < /dev/tty 2>/dev/null || echo "")
  if [[ "$size" =~ ^[0-9]+[[:space:]][0-9]+$ ]]; then
    RALPH_BOARD_ROWS="${size%% *}"
    RALPH_BOARD_COLS="${size##* }"
  elif command -v tput >/dev/null 2>&1; then
    RALPH_BOARD_ROWS=$(tput lines 2>/dev/null || echo 0)
    RALPH_BOARD_COLS=$(tput cols 2>/dev/null || echo 0)
  else
    return 1
  fi

  [[ "$RALPH_BOARD_ROWS" =~ ^[0-9]+$ ]] || return 1
  [[ "$RALPH_BOARD_COLS" =~ ^[0-9]+$ ]] || return 1
  [[ "$RALPH_BOARD_ROWS" -ge 6 && "$RALPH_BOARD_COLS" -ge 40 ]]
}

ralph_board_duration() {
  local seconds="$1"

  [[ "$seconds" =~ ^[0-9]+$ ]] || return 0
  if [[ "$seconds" -lt 3600 ]]; then
    printf '%dm%02ds' "$((seconds / 60))" "$((seconds % 60))"
  else
    printf '%dh%02dm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
  fi
}

# Reserve HEIGHT rows at the bottom and shrink the scrolling region to the rest.
#
# The cursor has to end up inside the new region, and there have to be HEIGHT
# rows below the current line for the board to occupy. Emitting HEIGHT newlines
# and then moving back up satisfies both: wherever the cursor started, the
# terminal has scrolled enough that the text line is now HEIGHT rows from the
# bottom, and CUU returns to it.
ralph_board_reserve_rows() {
  local pad="" i=0

  while [[ $i -lt $RALPH_BOARD_HEIGHT ]]; do
    pad="$pad\n"
    i=$((i + 1))
  done

  ralph_board_tty_write "${pad}\e[${RALPH_BOARD_HEIGHT}A\e7\e[1;$((RALPH_BOARD_ROWS - RALPH_BOARD_HEIGHT))r\e8"
}

# height_wanted is the number of runs; the board adds its own summary row and
# clamps the total to half the terminal so the scrolling log keeps most of the
# screen.
ralph_board_start() {
  local status_dir="$1"
  local run_count="$2"
  local max_height

  RALPH_BOARD_ACTIVE="false"
  ralph_board_supported || return 0
  ralph_board_terminal_size || return 0

  case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *UTF-8* | *utf8* | *UTF8* | *utf-8*)
      RALPH_BOARD_GLYPH_RUN="●"
      RALPH_BOARD_GLYPH_WAIT="○"
      RALPH_BOARD_GLYPH_OK="✓"
      RALPH_BOARD_GLYPH_BAD="✗"
      RALPH_BOARD_GLYPH_FLAG="⚑"
      ;;
  esac

  RALPH_BOARD_STATUS_DIR="$status_dir"

  max_height=$((RALPH_BOARD_ROWS / 2))
  [[ "$max_height" -le 12 ]] || max_height=12

  RALPH_BOARD_HEIGHT=$((run_count + 1))
  if [[ "$RALPH_BOARD_HEIGHT" -gt "$max_height" ]]; then
    RALPH_BOARD_HEIGHT="$max_height"
  fi
  [[ "$RALPH_BOARD_HEIGHT" -ge 2 ]] || return 0

  RALPH_BOARD_ACTIVE="true"
  ralph_board_reserve_rows
}

ralph_board_begin_frame() {
  [[ "$RALPH_BOARD_ACTIVE" == "true" ]] || return 0

  RALPH_BOARD_LINES=()
  RALPH_BOARD_STYLES=()
  RALPH_BOARD_HIDDEN=0
}

# Describe one run. `state` is the orchestrator's own scheduling verdict
# (pending | running | succeeded | failed | stopped | blocked); `note` carries
# whatever only the orchestrator knows, such as the run that blocked this one.
# Everything else is read back out of the run's status file.
ralph_board_row() {
  local run_id="$1"
  local state="$2"
  local note="${3:-}"
  local status_file="$RALPH_BOARD_STATUS_DIR/$run_id.json"
  local fields phase story_id story_title round done_count total
  local phase_started unblock_rounds unblock_outcome
  local now glyph style label detail="" elapsed="" line title_room

  [[ "$RALPH_BOARD_ACTIVE" == "true" ]] || return 0

  # One row of the board is one row of the terminal; past that, the run is
  # counted for the summary line instead of being drawn.
  if [[ "${#RALPH_BOARD_LINES[@]}" -ge $((RALPH_BOARD_HEIGHT - 1)) ]]; then
    RALPH_BOARD_HIDDEN=$((RALPH_BOARD_HIDDEN + 1))
    return 0
  fi

  now="$(date +%s 2>/dev/null || echo 0)"
  [[ "$now" =~ ^[0-9]+$ ]] || now=0

  phase=""
  story_id=""
  story_title=""
  round=0
  done_count=0
  total=0
  phase_started=0
  unblock_rounds=0
  unblock_outcome=""

  if [[ -f "$status_file" ]]; then
    # One field per line, never a shared separator. Tab counts as IFS
    # whitespace even when IFS holds nothing but a tab, so bash folds a run of
    # them into a single delimiter: a @tsv row with an empty storyId and
    # storyTitle - which is every merge-back, cleanup and consolidation round -
    # shifts every later field two places left, and the row ends up printing
    # the phase clock as the story count. The title is the only field that can
    # carry whitespace, and jq flattens it before it gets here.
    fields=$(jq -r '
      (.phase // ""),
      (.storyId // ""),
      ((.storyTitle // "") | gsub("[[:space:]]+"; " ")),
      (.round // 0),
      (.storiesDone // 0),
      (.storiesTotal // 0),
      (.phaseStartedAt // 0),
      (.unblockRounds // 0),
      (.unblockOutcome // "")
    ' "$status_file" 2>/dev/null || echo "")
    if [[ -n "$fields" ]]; then
      # A trailing empty field is stripped by the command substitution, so the
      # last reads can legitimately find nothing. The locals above already hold
      # the fallback.
      {
        IFS= read -r phase || true
        IFS= read -r story_id || true
        IFS= read -r story_title || true
        IFS= read -r round || true
        IFS= read -r done_count || true
        IFS= read -r total || true
        IFS= read -r phase_started || true
        IFS= read -r unblock_rounds || true
        IFS= read -r unblock_outcome || true
      } <<< "$fields"
    fi
  fi

  [[ "$round" =~ ^[0-9]+$ ]] || round=0
  [[ "$done_count" =~ ^[0-9]+$ ]] || done_count=0
  [[ "$total" =~ ^[0-9]+$ ]] || total=0
  [[ "$phase_started" =~ ^[0-9]+$ ]] || phase_started=0
  [[ "$unblock_rounds" =~ ^[0-9]+$ ]] || unblock_rounds=0

  case "$state" in
    running)
      glyph="$RALPH_BOARD_GLYPH_RUN"
      style="story"
      case "$phase" in
        working) label="story" ;;
        checking) label="checking" ;;
        unblocking)
          label="unblock"
          glyph="$RALPH_BOARD_GLYPH_FLAG"
          style="unblock"
          ;;
        cleanup) label="cleanup"; style="merge" ;;
        finalizing) label="finalize"; style="merge" ;;
        merge-back) label="merge-back"; style="merge" ;;
        consolidating) label="consolidate"; style="consolidate" ;;
        complete) label="complete"; style="success" ;;
        exited) label="exiting" ;;
        *) label="starting" ;;
      esac
      ;;
    succeeded)
      glyph="$RALPH_BOARD_GLYPH_OK"
      style="success"
      label="done"
      ;;
    failed)
      glyph="$RALPH_BOARD_GLYPH_BAD"
      style="error"
      label="FAILED"
      ;;
    stopped)
      glyph="$RALPH_BOARD_GLYPH_BAD"
      style="error"
      label="stopped"
      ;;
    blocked)
      glyph="$RALPH_BOARD_GLYPH_WAIT"
      style="warn"
      label="blocked"
      ;;
    *)
      glyph="$RALPH_BOARD_GLYPH_WAIT"
      style=""
      label="pending"
      ;;
  esac

  if [[ "$total" -gt 0 ]]; then
    detail="$done_count/$total"
  fi
  if [[ "$state" == "running" && -n "$story_id" ]]; then
    detail="$detail ${story_id:0:14}"
  fi
  if [[ -n "$note" ]]; then
    detail="$detail $note"
  fi

  # A finished run keeps its unblock history on the row: that one round is the
  # single most useful thing to know about a run whose output went to a file,
  # and it would otherwise be buried in thousands of lines of agent chatter.
  #
  # A run that is no longer running gets the marker whatever its last written
  # phase was. A run killed mid-unblock never got to record how the round ended,
  # and that is exactly the case worth flagging rather than hiding.
  if [[ "$unblock_rounds" -gt 0 ]] \
    && [[ "$state" != "running" || "$phase" != "unblocking" ]]; then
    case "$unblock_outcome" in
      finished) detail="$detail [unblocked x$unblock_rounds]" ;;
      restructured) detail="$detail [resplit x$unblock_rounds]" ;;
      stopped) detail="$detail [unblock gave up]" ;;
      *) detail="$detail [unblock x$unblock_rounds]" ;;
    esac
    if [[ "$state" == "running" ]]; then
      style="unblock"
    fi
  fi

  # A clock is only believable within a week of now. Anything past that is a
  # status file left behind by an older run, or a clock that moved, and a row
  # reading "496705h59m" is worse than one with no clock at all.
  if [[ "$state" == "running" && "$phase_started" -gt 0 && "$now" -ge "$phase_started" \
    && $((now - phase_started)) -lt 604800 ]]; then
    elapsed="$(ralph_board_duration "$((now - phase_started))")"
  fi

  if [[ "$state" == "running" && "$round" -gt 0 ]]; then
    detail="$detail r$round"
  fi
  if [[ -n "$elapsed" ]]; then
    detail="$detail $elapsed"
  fi

  line="$(printf ' %s %-16.16s %-11.11s %s' "$glyph" "$run_id" "$label" "${detail# }")"

  # Title last: it is the first thing worth dropping on a narrow terminal, and
  # the only field that can carry wide CJK glyphs. Budget two terminal columns
  # per character so a row never wraps into the scrolling region and pushes the
  # log up a line on every frame.
  if [[ "$state" == "running" && -n "$story_title" && "$RALPH_BOARD_COLS" -ge 80 ]]; then
    title_room=$(((RALPH_BOARD_COLS - 1 - ${#line} - 2) / 2))
    if [[ "$title_room" -gt 3 ]]; then
      line="$line  ${story_title:0:title_room}"
    fi
  fi

  RALPH_BOARD_LINES+=("$line")
  RALPH_BOARD_STYLES+=("$style")
}

ralph_board_end_frame() {
  local summary_running=0 summary_done=0 summary_failed=0
  local line style sgr row idx=0

  [[ "$RALPH_BOARD_ACTIVE" == "true" ]] || return 0

  summary_running="$1"
  summary_done="$2"
  summary_failed="$3"

  ralph_board_tty_write "\e7"

  row=$((RALPH_BOARD_ROWS - RALPH_BOARD_HEIGHT + 1))
  while [[ $idx -lt ${#RALPH_BOARD_LINES[@]} ]]; do
    line="${RALPH_BOARD_LINES[$idx]:0:$((RALPH_BOARD_COLS - 1))}"
    style="${RALPH_BOARD_STYLES[$idx]}"
    sgr=""
    if [[ -z "${NO_COLOR:-}" && -n "$style" ]]; then
      sgr="$(ralph_log_sgr "$style")"
    fi
    if [[ -n "$sgr" ]]; then
      ralph_board_tty_write "\e[${row};1H\e[2K\e[${sgr}m${line}\e[0m"
    else
      ralph_board_tty_write "\e[${row};1H\e[2K${line}"
    fi
    row=$((row + 1))
    idx=$((idx + 1))
  done

  # Blank any rows a shrinking frame left behind.
  while [[ $row -lt "$RALPH_BOARD_ROWS" ]]; do
    ralph_board_tty_write "\e[${row};1H\e[2K"
    row=$((row + 1))
  done

  line=" $summary_running running  $summary_done done  $summary_failed failed"
  if [[ "$RALPH_BOARD_HIDDEN" -gt 0 ]]; then
    line="$line  (+$RALPH_BOARD_HIDDEN more not shown)"
  fi
  line="$line  - logs under ralph/runs/<run>/"
  line="${line:0:$((RALPH_BOARD_COLS - 1))}"
  ralph_board_tty_write "\e[${RALPH_BOARD_ROWS};1H\e[2K\e[2m${line}\e[0m"

  ralph_board_tty_write "\e8"
}

ralph_board_stop() {
  [[ "$RALPH_BOARD_ACTIVE" == "true" ]] || return 0
  RALPH_BOARD_ACTIVE="false"

  local row=$((RALPH_BOARD_ROWS - RALPH_BOARD_HEIGHT + 1))
  ralph_board_tty_write "\e7"
  while [[ $row -le "$RALPH_BOARD_ROWS" ]]; do
    ralph_board_tty_write "\e[${row};1H\e[2K"
    row=$((row + 1))
  done
  # Give the terminal its full scrolling region back before restoring the cursor.
  ralph_board_tty_write "\e[r\e8"
}

ralph_board_resize() {
  [[ "$RALPH_BOARD_ACTIVE" == "true" ]] || return 0

  ralph_board_tty_write "\e[r"
  if ! ralph_board_terminal_size; then
    RALPH_BOARD_ACTIVE="false"
    return 0
  fi
  ralph_board_reserve_rows
}
