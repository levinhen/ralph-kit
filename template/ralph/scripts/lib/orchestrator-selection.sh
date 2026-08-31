#!/bin/bash
# Run selection for orchestrate.sh: which of the incomplete runs this
# invocation is allowed to start.
#
# The orchestrator used to schedule every incomplete run it discovered. A
# selection narrows that list before either scheduler sees it, so
# INCOMPLETE_RUNS / TOTAL_RUNS keep meaning "the runs this invocation may
# start" and no scheduler has to learn that a selection happened.
#
# The one thing the schedulers do need is that an excluded run still exists. A
# `dependsOnRuns` edge pointing at a run left out of this invocation is not a
# broken reference the way an unknown id is - the run is real, it is simply not
# scheduled here - so graph mode reports the dependent as unrunnable and keeps
# going, instead of refusing the whole graph.

SELECTION_ACTIVE="false"
SELECTION_EXCLUDED=()   # incomplete runs left out of this invocation
SELECTION_SPEC=""

# The `dependsOnRuns` entries a run declares, one per line. Shared so graph
# building, mode detection and the stage-mode heads-up all read the field the
# same way.
selection_run_deps() {
  jq -r '
    (.dependsOnRuns // [])
    | if type == "array" then .[] else empty end
    | select(type == "string")
  ' "$RUNS_ROOT/$1/prd.json" 2>/dev/null || true
}

selection_index_of() {
  local needle="$1" idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${INCOMPLETE_RUNS[$idx]}" == "$needle" ]]; then
      printf '%s\n' "$idx"
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

# Turn "1,3-5 run-b" into a sorted, deduplicated list of INCOMPLETE_RUNS
# indices. Ids are matched before numbers so a run literally named "3-5" still
# selects itself rather than a range.
selection_parse() {
  local spec="$1"
  local token first last idx picked=" " out=""

  for token in ${spec//,/ }; do
    if idx="$(selection_index_of "$token")"; then
      picked="$picked$idx "
      continue
    fi

    if [[ "$token" =~ ^[0-9]+$ ]]; then
      first="$token"
      last="$token"
    elif [[ "$token" =~ ^[0-9]+-[0-9]+$ ]]; then
      first="${token%%-*}"
      last="${token##*-}"
    else
      echo "Error: '$token' is neither a listed run id nor a number in 1-$TOTAL_RUNS." >&2
      return 1
    fi

    if [[ "$first" -lt 1 || "$last" -gt "$TOTAL_RUNS" || "$first" -gt "$last" ]]; then
      echo "Error: '$token' is out of range (1-$TOTAL_RUNS)." >&2
      return 1
    fi

    idx="$first"
    while [[ $idx -le $last ]]; do
      picked="$picked$((idx - 1)) "
      idx=$((idx + 1))
    done
  done

  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    case "$picked" in
      *" $idx "*) out="$out $idx" ;;
    esac
    idx=$((idx + 1))
  done

  if [[ -z "$out" ]]; then
    echo "Error: the selection matched no runs." >&2
    return 1
  fi

  printf '%s\n' "${out# }"
}

# Rewrite INCOMPLETE_RUNS to the selected indices, keeping the rest in
# SELECTION_EXCLUDED. Indices are passed unquoted on purpose: they are integers.
selection_apply() {
  local wanted=" $* "
  local kept=() idx=0

  SELECTION_EXCLUDED=()
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    case "$wanted" in
      *" $idx "*) kept+=("${INCOMPLETE_RUNS[$idx]}") ;;
      *) SELECTION_EXCLUDED+=("${INCOMPLETE_RUNS[$idx]}") ;;
    esac
    idx=$((idx + 1))
  done

  INCOMPLETE_RUNS=("${kept[@]}")
  TOTAL_RUNS="${#INCOMPLETE_RUNS[@]}"
  SELECTION_ACTIVE="true"
}

selection_show() {
  local idx=0 run_id

  echo "Scheduling $TOTAL_RUNS of $((TOTAL_RUNS + ${#SELECTION_EXCLUDED[@]})) incomplete run(s):"
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    printf "  %2d  %s\n" "$((idx + 1))" "${INCOMPLETE_RUNS[$idx]}"
    idx=$((idx + 1))
  done

  echo ""
  echo "Out of scope this time (left untouched):"
  for run_id in "${SELECTION_EXCLUDED[@]}"; do
    echo "  - $run_id"
  done
}

# Narrow the schedule to SPEC. An empty spec or "all" keeps every run, which is
# what the orchestrator did unconditionally before selection existed.
selection_apply_spec() {
  local spec="$1" indices

  case "$spec" in
    "" | all | ALL | All) return 0 ;;
  esac

  indices="$(selection_parse "$spec")" || return 1
  selection_apply $indices

  # A selection naming everything narrowed nothing; leave the printed list alone.
  [[ "${#SELECTION_EXCLUDED[@]}" -gt 0 ]] || return 0

  selection_show
  return 0
}

# Graph mode has no selector of its own - a stage plan's numbers are stage
# mode's - so ask before the edges are derived. There is nothing to ask when a
# single run is all there is; a non-interactive caller that wanted a subset had
# --only, and saying which way that went beats an unexplained fan-out in a log.
selection_prompt() {
  [[ "$TOTAL_RUNS" -gt 1 ]] || return 0

  if [[ ! -t 0 ]]; then
    echo "No --only given and stdin is not interactive: scheduling all $TOTAL_RUNS incomplete run(s)."
    return 0
  fi

  echo "Which runs should this invocation schedule?"
  echo "Numbers or run ids, ',' or space separated; '2-4' is a range."
  echo "Empty or 'all' schedules every run listed above."
  # End of input is not consent to run the whole backlog.
  if ! read -r -p "Runs> " SELECTION_SPEC; then
    echo ""
    echo "Error: no selection given (end of input). Nothing was started." >&2
    return 1
  fi
  echo ""

  selection_apply_spec "$SELECTION_SPEC"
}
