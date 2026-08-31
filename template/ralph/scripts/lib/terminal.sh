#!/bin/bash

# Shared terminal primitives for Ralph's interactive UIs. This module owns only
# capabilities whose semantics are identical for the one-row progress display
# and the multi-row orchestrator board; layout and rendering policy stay with
# those callers.

if [[ "${RALPH_TERMINAL_LIB_LOADED:-}" != "true" ]]; then
  RALPH_TERMINAL_LIB_LOADED="true"

  # Raw results from the most recent size probe. Callers deliberately apply
  # their own minimum geometry and fallback policy.
  RALPH_TERMINAL_ROWS=""
  RALPH_TERMINAL_COLS=""

  ralph_terminal_tty_write() {
    printf '%b' "$1" > /dev/tty 2>/dev/null || true
  }

  # All requested descriptors must point at a terminal, and that terminal must
  # support control sequences and be writable through /dev/tty.
  ralph_terminal_supported() {
    local fd

    for fd in "$@"; do
      [[ -t "$fd" ]] || return 1
    done
    [[ "${TERM:-dumb}" != "dumb" ]] || return 1
    [[ -w /dev/tty ]] || return 1
  }

  # Prefer the single stty probe and fall back to terminfo. The raw tput result
  # is retained so each UI can preserve its existing invalid-value behavior.
  ralph_terminal_probe_size() {
    local size

    RALPH_TERMINAL_ROWS=""
    RALPH_TERMINAL_COLS=""

    size=$(stty size < /dev/tty 2>/dev/null || echo "")
    if [[ "$size" =~ ^[0-9]+[[:space:]][0-9]+$ ]]; then
      RALPH_TERMINAL_ROWS="${size%% *}"
      RALPH_TERMINAL_COLS="${size##* }"
      return 0
    fi

    command -v tput >/dev/null 2>&1 || return 1
    RALPH_TERMINAL_ROWS=$(tput lines 2>/dev/null || echo 0)
    RALPH_TERMINAL_COLS=$(tput cols 2>/dev/null || echo 0)
  }

  ralph_terminal_duration() {
    local seconds="$1"

    [[ "$seconds" =~ ^[0-9]+$ ]] || return 0
    if [[ "$seconds" -lt 3600 ]]; then
      printf '%dm%02ds' "$((seconds / 60))" "$((seconds % 60))"
    else
      printf '%dh%02dm' "$((seconds / 3600))" "$(((seconds % 3600) / 60))"
    fi
  }

  ralph_terminal_utf8() {
    case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
      *UTF-8* | *utf8* | *UTF8* | *utf-8*) return 0 ;;
    esac
    return 1
  }
fi
