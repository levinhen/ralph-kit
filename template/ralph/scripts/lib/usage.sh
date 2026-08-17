#!/bin/bash

# Run-scoped token and cost accounting.
#
# lib/stream-agent.mjs reports normalised usage for a single tool invocation.
# This file sums those invocations for the whole ralph.sh run and hands the
# totals to two consumers: the pinned status row, which polls the ledger from a
# detached ticker, and the closing bill on stdout.
#
# The ledger is a file rather than a set of shell variables because the ticker is
# a forked subshell - it can only ever see what was written to disk after it
# started. It is a plain line-per-field format so a refresh costs one read
# instead of a jq process.
#
# Costs are carried in micro-USD (1e-6 USD) integers: bash has no float
# arithmetic, and the rates the agent CLIs are priced at are quoted per million
# tokens, so this is the unit where everything stays exact.
#
# Nothing here is fatal. A run that cannot account for its tokens still has to
# finish normally, so every failure path degrades to "no numbers".

RALPH_USAGE_FILE=""

# Populated by ralph_usage_load.
RALPH_USAGE_INPUT=0
RALPH_USAGE_CACHED=0
RALPH_USAGE_CACHE_WRITE=0
RALPH_USAGE_OUTPUT=0
RALPH_USAGE_COST_MICROS=0
RALPH_USAGE_COST_BASIS="none"
RALPH_USAGE_CALLS=0
RALPH_USAGE_MODEL=""

ralph_usage_start() {
  RALPH_USAGE_FILE=$(mktemp "${TMPDIR:-/tmp}/ralph-usage.XXXXXX" 2>/dev/null || echo "")
  [[ -n "$RALPH_USAGE_FILE" ]] || return 0

  ralph_usage_write 0 0 0 0 0 "none" 0 ""
}

ralph_usage_write() {
  local tmp_file

  [[ -n "$RALPH_USAGE_FILE" ]] || return 0

  tmp_file="$RALPH_USAGE_FILE.tmp"
  {
    printf '%s\n' "$1"
    printf '%s\n' "$2"
    printf '%s\n' "$3"
    printf '%s\n' "$4"
    printf '%s\n' "$5"
    printf '%s\n' "$6"
    printf '%s\n' "$7"
    printf '%s\n' "$8"
  } > "$tmp_file" 2>/dev/null || return 0
  # Replace in one step: the status ticker reads this on its own schedule and
  # must never catch a half-written ledger.
  mv -f "$tmp_file" "$RALPH_USAGE_FILE" 2>/dev/null || return 0
}

ralph_usage_load() {
  RALPH_USAGE_INPUT=0
  RALPH_USAGE_CACHED=0
  RALPH_USAGE_CACHE_WRITE=0
  RALPH_USAGE_OUTPUT=0
  RALPH_USAGE_COST_MICROS=0
  RALPH_USAGE_COST_BASIS="none"
  RALPH_USAGE_CALLS=0
  RALPH_USAGE_MODEL=""

  [[ -n "$RALPH_USAGE_FILE" && -f "$RALPH_USAGE_FILE" ]] || return 1

  {
    IFS= read -r RALPH_USAGE_INPUT || true
    IFS= read -r RALPH_USAGE_CACHED || true
    IFS= read -r RALPH_USAGE_CACHE_WRITE || true
    IFS= read -r RALPH_USAGE_OUTPUT || true
    IFS= read -r RALPH_USAGE_COST_MICROS || true
    IFS= read -r RALPH_USAGE_COST_BASIS || true
    IFS= read -r RALPH_USAGE_CALLS || true
    IFS= read -r RALPH_USAGE_MODEL || true
  } < "$RALPH_USAGE_FILE" 2>/dev/null || return 1

  [[ "$RALPH_USAGE_INPUT" =~ ^[0-9]+$ ]] || RALPH_USAGE_INPUT=0
  [[ "$RALPH_USAGE_CACHED" =~ ^[0-9]+$ ]] || RALPH_USAGE_CACHED=0
  [[ "$RALPH_USAGE_CACHE_WRITE" =~ ^[0-9]+$ ]] || RALPH_USAGE_CACHE_WRITE=0
  [[ "$RALPH_USAGE_OUTPUT" =~ ^[0-9]+$ ]] || RALPH_USAGE_OUTPUT=0
  [[ "$RALPH_USAGE_COST_MICROS" =~ ^[0-9]+$ ]] || RALPH_USAGE_COST_MICROS=0
  [[ "$RALPH_USAGE_CALLS" =~ ^[0-9]+$ ]] || RALPH_USAGE_CALLS=0

  return 0
}

ralph_usage_total_tokens() {
  echo $((RALPH_USAGE_INPUT + RALPH_USAGE_CACHED + RALPH_USAGE_CACHE_WRITE + RALPH_USAGE_OUTPUT))
}

# Fold one invocation's summary into the ledger. Called once per tool call, so
# the single jq here is the only per-invocation cost of the whole feature.
ralph_usage_record() {
  local summary_file="$1"
  local fields=""
  local input=0 cached=0 cache_write=0 output=0 cost=0 exact="false" model=""
  local basis

  [[ -n "$RALPH_USAGE_FILE" && -f "$summary_file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # Tabs, not spaces: a model label can contain anything the CLI reports.
  fields=$(jq -r '
    (.usage // {}) as $u
    | [
        ($u.input // 0),
        ($u.cached // 0),
        ($u.cacheWrite // 0),
        ($u.output // 0),
        (.costMicros // 0),
        (if .costExact == true then "true" else "false" end),
        (.model // "")
      ]
    | @tsv
  ' "$summary_file" 2>/dev/null || echo "")
  [[ -n "$fields" ]] || return 0

  IFS=$'\t' read -r input cached cache_write output cost exact model <<< "$fields"

  [[ "$input" =~ ^[0-9]+$ ]] || input=0
  [[ "$cached" =~ ^[0-9]+$ ]] || cached=0
  [[ "$cache_write" =~ ^[0-9]+$ ]] || cache_write=0
  [[ "$output" =~ ^[0-9]+$ ]] || output=0
  [[ "$cost" =~ ^[0-9]+$ ]] || cost=0

  ralph_usage_load || return 0

  # An invocation that reported nothing at all (a crashed CLI, a summary written
  # before the first event) must not count as a billed call.
  if [[ "$input" -eq 0 && "$cached" -eq 0 && "$cache_write" -eq 0 && "$output" -eq 0 ]]; then
    return 0
  fi

  # A run can switch tools mid-flight, and one side reports a real bill while the
  # other is priced from a table. Keep that visible instead of averaging it away.
  basis="$RALPH_USAGE_COST_BASIS"
  if [[ "$exact" == "true" ]]; then
    case "$basis" in
      none | exact) basis="exact" ;;
      *) basis="mixed" ;;
    esac
  else
    case "$basis" in
      none | estimated) basis="estimated" ;;
      *) basis="mixed" ;;
    esac
  fi

  if [[ -n "$model" && "$model" != "$RALPH_USAGE_MODEL" ]]; then
    if [[ -z "$RALPH_USAGE_MODEL" ]]; then
      RALPH_USAGE_MODEL="$model"
    else
      RALPH_USAGE_MODEL="multiple"
    fi
  fi

  ralph_usage_write \
    "$((RALPH_USAGE_INPUT + input))" \
    "$((RALPH_USAGE_CACHED + cached))" \
    "$((RALPH_USAGE_CACHE_WRITE + cache_write))" \
    "$((RALPH_USAGE_OUTPUT + output))" \
    "$((RALPH_USAGE_COST_MICROS + cost))" \
    "$basis" \
    "$((RALPH_USAGE_CALLS + 1))" \
    "$RALPH_USAGE_MODEL"
}

# 1234567 -> "1.2M", 45678 -> "45k", 812 -> "812". The status row is one line
# wide, so exact token counts are the closing bill's job, not the bar's.
ralph_usage_format_tokens() {
  local tokens="$1"

  [[ "$tokens" =~ ^[0-9]+$ ]] || return 0
  if [[ "$tokens" -ge 1000000 ]]; then
    printf '%d.%01dM' "$((tokens / 1000000))" "$(((tokens % 1000000) / 100000))"
  elif [[ "$tokens" -ge 1000 ]]; then
    printf '%dk' "$((tokens / 1000))"
  else
    printf '%d' "$tokens"
  fi
}

ralph_usage_format_cost() {
  local micros="$1"

  [[ "$micros" =~ ^[0-9]+$ ]] || return 0
  if [[ "$micros" -gt 0 && "$micros" -lt 5000 ]]; then
    # Anything below half a cent would render as $0.00 and read like a bug.
    printf '<0.01'
  else
    # Round to the cent rather than truncating: reporting $2.46 for a $2.469
    # bill is a small lie, and it compounds across a long run.
    micros=$((micros + 5000))
    printf '%d.%02d' "$((micros / 1000000))" "$(((micros % 1000000) / 10000))"
  fi
}

ralph_usage_cost_prefix() {
  case "$RALPH_USAGE_COST_BASIS" in
    exact) printf '$' ;;
    *) printf '~$' ;;
  esac
}

# The closing bill. Unlike the status row this has room to be exact, and it is
# the only place the cache split and the pricing basis are spelled out.
ralph_usage_report() {
  local total

  ralph_usage_load || return 0
  [[ "$RALPH_USAGE_CALLS" -gt 0 ]] || return 0

  total=$(ralph_usage_total_tokens)

  echo ""
  echo "Ralph usage for this run:"
  printf '  Tool calls:    %d\n' "$RALPH_USAGE_CALLS"
  if [[ -n "$RALPH_USAGE_MODEL" ]]; then
    printf '  Model:         %s\n' "$RALPH_USAGE_MODEL"
  fi
  printf '  Input:         %d (new) + %d (cache read) + %d (cache write)\n' \
    "$RALPH_USAGE_INPUT" "$RALPH_USAGE_CACHED" "$RALPH_USAGE_CACHE_WRITE"
  printf '  Output:        %d\n' "$RALPH_USAGE_OUTPUT"
  printf '  Total tokens:  %d\n' "$total"

  case "$RALPH_USAGE_COST_BASIS" in
    exact)
      printf '  Cost:          $%s (reported by the tool)\n' \
        "$(ralph_usage_format_cost "$RALPH_USAGE_COST_MICROS")"
      ;;
    estimated)
      printf '  Cost:          ~$%s (estimated at %s/%s/%s/%s USD per 1M in/cached/write/out)\n' \
        "$(ralph_usage_format_cost "$RALPH_USAGE_COST_MICROS")" \
        "${RALPH_PRICE_INPUT_USD:-5}" "${RALPH_PRICE_CACHED_INPUT_USD:-0.5}" \
        "${RALPH_PRICE_CACHE_WRITE_USD:-6.25}" "${RALPH_PRICE_OUTPUT_USD:-30}"
      ;;
    mixed)
      printf '  Cost:          ~$%s (part reported, part estimated)\n' \
        "$(ralph_usage_format_cost "$RALPH_USAGE_COST_MICROS")"
      ;;
  esac
}

ralph_usage_stop() {
  [[ -n "$RALPH_USAGE_FILE" ]] || return 0
  rm -f "$RALPH_USAGE_FILE" "$RALPH_USAGE_FILE.tmp" 2>/dev/null || true
  RALPH_USAGE_FILE=""
}
