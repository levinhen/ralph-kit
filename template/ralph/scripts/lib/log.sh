#!/bin/bash

# Colour for the loop's own status lines. A round prints thousands of lines of
# agent output, so the handful of lines that say where a story started, that a
# round left the happy path, or that the run is over have to be findable by eye
# while scrolling past.
#
# Colour reaches an interactive terminal only. orchestrate.sh redirects every
# parallel run to a log file and the tests capture stdout, so anything that is
# not a tty gets byte-identical plain text — the same rule the pinned progress
# row in lib/progress-bar.sh follows, for the same reason: no control codes in
# anything that gets read back later.
#
# RALPH_LOG_COLOR=0 forces plain output, =1 forces colour (useful when piping
# into `less -R`). NO_COLOR is honoured. The default is to decide per stream.

RALPH_LOG_COLOR_ON="false"
RALPH_LOG_COLOR_ERR_ON="false"

# Decided per stream: the loop's normal status goes to stdout and the tool
# guard's warnings go to stderr, and orchestrate.sh redirects them separately.
ralph_log_color_supported() {
  local fd="$1"

  case "${RALPH_LOG_COLOR:-auto}" in
    0 | false | no | off) return 1 ;;
    1 | true | yes | on | always) return 0 ;;
  esac

  [[ -z "${NO_COLOR:-}" ]] || return 1
  [[ -t "$fd" ]] || return 1
  [[ "${TERM:-dumb}" != "dumb" ]] || return 1
}

if ralph_log_color_supported 1; then
  RALPH_LOG_COLOR_ON="true"
fi
if ralph_log_color_supported 2; then
  RALPH_LOG_COLOR_ERR_ON="true"
fi

# One colour per kind of moment, not per severity, so the same hue always means
# the same thing across a run:
#
#   story        cyan     - a new user story round starts here
#   unblock      yellow   - the repair round; the run is off the happy path
#   merge        magenta  - merge-back round
#   consolidate  blue     - consolidation round
#   success      green    - a story, a merge, or the whole run finished
#   warn         yellow   - something surprising, the loop continues
#   error        red      - the loop is stopping
#
# `unblock` deliberately matches the warning yellow the pinned progress row uses
# for the same phase in lib/progress-bar.sh, so the row and the banner agree.
ralph_log_sgr() {
  case "$1" in
    story) printf '1;36' ;;
    unblock) printf '1;33' ;;
    merge) printf '1;35' ;;
    consolidate) printf '1;34' ;;
    success) printf '1;32' ;;
    warn) printf '33' ;;
    error) printf '1;31' ;;
    *) printf '' ;;
  esac
}

ralph_log_line() {
  local style="$1"
  shift
  local text="$*"
  local sgr=""

  if [[ "$RALPH_LOG_COLOR_ON" == "true" ]]; then
    sgr="$(ralph_log_sgr "$style")"
  fi

  if [[ -n "$sgr" ]]; then
    printf '\033[%sm%s\033[0m\n' "$sgr" "$text"
  else
    printf '%s\n' "$text"
  fi
}

# Same line, on stderr - where the tool guard reports a timeout, a rate limit or
# a failed invocation.
ralph_log_line_err() {
  local style="$1"
  shift
  local text="$*"
  local sgr=""

  if [[ "$RALPH_LOG_COLOR_ERR_ON" == "true" ]]; then
    sgr="$(ralph_log_sgr "$style")"
  fi

  if [[ -n "$sgr" ]]; then
    printf '\033[%sm%s\033[0m\n' "$sgr" "$text" >&2
  else
    printf '%s\n' "$text" >&2
  fi
}

# The framed round header. Callers pass the title lines; the rules are added
# here so every banner in the run is the same width.
ralph_log_banner() {
  local style="$1"
  shift
  local rule="==============================================================="
  local line

  ralph_log_line "$style" "$rule"
  for line in "$@"; do
    ralph_log_line "$style" "  $line"
  done
  ralph_log_line "$style" "$rule"
}
