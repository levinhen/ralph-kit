#!/bin/bash
# Dependency-graph planning, scheduling, presentation, and summary for
# orchestrate.sh. The entrypoint owns CLI selection and shared root variables;
# child-process state is owned by orchestrator-executor.sh.

# Per-run state lives in indexed arrays sharing INCOMPLETE_RUNS' indices - bash
# 3.2 (the macOS default) has no associative arrays. GRAPH_DEPS holds a
# space-separated list of dependency *indices* and is expanded unquoted on
# purpose; the values are always integers.
GRAPH_DEPS=()       # intra-graph dependency indices
GRAPH_MET_DEPS=()   # dependency ids already merged back or archived (display)
GRAPH_OUT_OF_SCOPE=()  # dependency ids that exist but were not selected
GRAPH_SKIP_REASON=()   # why this run cannot run in this selection
GRAPH_BLOCKER=()    # id of the failed ancestor that blocked this run
GRAPH_WAVE=()       # topological wave, 0 until assigned

# True when any scheduled run declares at least one `dependsOnRuns` entry. Such
# a run already carries the ordering a stage plan would only restate by hand.
graph_edges_declared() {
  local idx=0 first_dep
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    first_dep="$(selection_run_deps "${INCOMPLETE_RUNS[$idx]}" | head -1)"
    if [[ -n "$first_dep" ]]; then
      return 0
    fi
    idx=$((idx + 1))
  done
  return 1
}

graph_index_of_run() {
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

# Read `dependsOnRuns` for every scheduled run and sort each entry into one of
# four buckets: an edge to another run scheduled here, a dependency that has
# already landed (dropped - there is nothing left to wait for), a real run this
# invocation did not select (the dependent cannot run; see
# graph_mark_unrunnable), or a reference naming nothing at all (fatal).
graph_build() {
  local idx=0 run_id dep dep_idx seen bad=0

  orchestrator_executor_reset

  while [[ $idx -lt $TOTAL_RUNS ]]; do
    run_id="${INCOMPLETE_RUNS[$idx]}"
    orchestrator_executor_add "$run_id"
    GRAPH_DEPS[$idx]=""
    GRAPH_MET_DEPS[$idx]=""
    GRAPH_OUT_OF_SCOPE[$idx]=""
    GRAPH_SKIP_REASON[$idx]=""
    GRAPH_BLOCKER[$idx]=""
    GRAPH_WAVE[$idx]=0
    seen=" "

    while IFS= read -r dep; do
      [[ -n "$dep" ]] || continue
      case "$seen" in
        *" $dep "*) continue ;;
      esac
      seen="$seen$dep "

      if dep_idx="$(graph_index_of_run "$dep")"; then
        GRAPH_DEPS[$idx]="${GRAPH_DEPS[$idx]} $dep_idx"
      elif run_dependency_satisfied "$RALPH_ROOT" "$REPO_ROOT" "$dep"; then
        GRAPH_MET_DEPS[$idx]="${GRAPH_MET_DEPS[$idx]} $dep"
      elif run_dir_exists "$dep"; then
        GRAPH_OUT_OF_SCOPE[$idx]="${GRAPH_OUT_OF_SCOPE[$idx]} $dep"
      else
        echo "Error: run '$run_id' depends on '$dep', which is not a run at all - no ralph/runs/$dep/prd.json exists." >&2
        bad=1
      fi
    done < <(selection_run_deps "$run_id")

    idx=$((idx + 1))
  done

  if [[ "$bad" -eq 1 ]]; then
    echo "Fix those dependsOnRuns references first. No runs were started." >&2
    return 1
  fi
  return 0
}

# Take the runs this selection cannot honestly execute out of the schedule.
#
# A dependency left out of the selection is not a defect: the run exists and is
# simply not being started here. But the dependent's worktree is cut from the
# base branch, so it would not contain that work - ralph.sh refuses such a run
# at startup, and launching it would only turn a scheduling choice into a
# failed run. The reason is kept per run so the report can name it, and it
# travels downstream: whatever depended on a run that cannot start cannot
# start either.
graph_mark_unrunnable() {
  local idx dep changed=1

  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ -n "${GRAPH_OUT_OF_SCOPE[$idx]}" ]]; then
      ORCH_EXEC_STATES[$idx]="skipped"
      GRAPH_SKIP_REASON[$idx]="needs${GRAPH_OUT_OF_SCOPE[$idx]}, not scheduled in this selection"
    fi
    idx=$((idx + 1))
  done

  while [[ "$changed" -eq 1 ]]; do
    changed=0
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      if [[ "${ORCH_EXEC_STATES[$idx]}" == "pending" ]]; then
        for dep in ${GRAPH_DEPS[$idx]}; do
          if [[ "${ORCH_EXEC_STATES[$dep]}" == "skipped" ]]; then
            ORCH_EXEC_STATES[$idx]="skipped"
            GRAPH_SKIP_REASON[$idx]="needs ${INCOMPLETE_RUNS[$dep]}, which cannot run either"
            changed=1
            break
          fi
        done
      fi
      idx=$((idx + 1))
    done
  done
}

graph_skipped_count() {
  local idx=0 count=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "skipped" ]]; then
      count=$((count + 1))
    fi
    idx=$((idx + 1))
  done
  printf '%s\n' "$count"
}

# Kahn peeling: each pass collects every unassigned run whose dependencies all
# have a wave, then assigns them together, so runs in the same pass never see
# each other. Whatever is still unassigned when a pass adds nothing sits in - or
# downstream of - a cycle.
graph_assign_waves() {
  local wave=0 idx dep ready batch cyclic="" cid

  while true; do
    wave=$((wave + 1))
    batch=""
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      if [[ "${GRAPH_WAVE[$idx]}" -eq 0 ]]; then
        ready=1
        for dep in ${GRAPH_DEPS[$idx]}; do
          if [[ "${GRAPH_WAVE[$dep]}" -eq 0 ]]; then
            ready=0
            break
          fi
        done
        if [[ "$ready" -eq 1 ]]; then
          batch="$batch $idx"
        fi
      fi
      idx=$((idx + 1))
    done

    [[ -n "$batch" ]] || break
    for idx in $batch; do
      GRAPH_WAVE[$idx]=$wave
    done
  done

  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${GRAPH_WAVE[$idx]}" -eq 0 ]]; then
      cyclic="$cyclic ${INCOMPLETE_RUNS[$idx]}"
    fi
    idx=$((idx + 1))
  done

  if [[ -n "$cyclic" ]]; then
    echo "Error: dependsOnRuns cycle - these runs can never become ready:" >&2
    for cid in $cyclic; do
      echo "  - $cid" >&2
    done
    echo "Break the cycle in those runs' prd.json. No runs were started." >&2
    return 1
  fi
  return 0
}

graph_show() {
  local idx=0 dep line
  echo ""
  echo "Resolved dependency graph:"
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    line=""
    for dep in ${GRAPH_DEPS[$idx]}; do
      if [[ -z "$line" ]]; then
        line="${INCOMPLETE_RUNS[$dep]}"
      else
        line="$line, ${INCOMPLETE_RUNS[$dep]}"
      fi
    done
    if [[ -z "$line" && -n "${GRAPH_OUT_OF_SCOPE[$idx]}" ]]; then
      printf "  %s  (no dependency scheduled here)\n" "${INCOMPLETE_RUNS[$idx]}"
    elif [[ -z "$line" ]]; then
      printf "  %s  (waits for nothing)\n" "${INCOMPLETE_RUNS[$idx]}"
    else
      printf "  %s  <- %s\n" "${INCOMPLETE_RUNS[$idx]}" "$line"
    fi
    if [[ -n "${GRAPH_MET_DEPS[$idx]}" ]]; then
      printf "      already merged back:%s\n" "${GRAPH_MET_DEPS[$idx]}"
    fi
    if [[ -n "${GRAPH_OUT_OF_SCOPE[$idx]}" ]]; then
      printf "      outside this selection:%s\n" "${GRAPH_OUT_OF_SCOPE[$idx]}"
    fi
    idx=$((idx + 1))
  done
}

# The runs this selection takes off the table, said plainly and before anything
# starts: a selection that quietly dropped a run would read as a run that
# succeeded.
graph_show_unrunnable() {
  local idx=0 any=0

  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "skipped" ]]; then
      if [[ "$any" -eq 0 ]]; then
        echo ""
        echo "Cannot run in this selection:"
        any=1
      fi
      printf "  %s  -  %s\n" "${INCOMPLETE_RUNS[$idx]}" "${GRAPH_SKIP_REASON[$idx]}"
    fi
    idx=$((idx + 1))
  done

  [[ "$any" -eq 1 ]] || return 0
  echo "  Their worktrees would be cut from a base branch without that work, so"
  echo "  they are left untouched. Select the missing run too, or finish and merge"
  echo "  it back first; everything else in the selection still runs."
}

graph_show_waves() {
  local idx max=0 wave=1 line
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${GRAPH_WAVE[$idx]}" -gt "$max" ]]; then
      max="${GRAPH_WAVE[$idx]}"
    fi
    idx=$((idx + 1))
  done

  echo ""
  echo "Wave preview (execution is event-driven: a run starts the moment its own"
  echo "dependencies succeed, so these waves are only a preview):"
  while [[ $wave -le $max ]]; do
    line=""
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      # Unrunnable runs keep their topological wave (the cycle check needs it)
      # but never appear in the preview: they are listed above instead.
      if [[ "${GRAPH_WAVE[$idx]}" -eq "$wave" && "${ORCH_EXEC_STATES[$idx]}" != "skipped" ]]; then
        if [[ -z "$line" ]]; then
          line="${INCOMPLETE_RUNS[$idx]}"
        else
          line="$line  ‖  ${INCOMPLETE_RUNS[$idx]}"
        fi
      fi
      idx=$((idx + 1))
    done
    if [[ -n "$line" ]]; then
      printf "  Wave %d:  %s\n" "$wave" "$line"
    fi
    wave=$((wave + 1))
  done
}

graph_launch() {
  local idx="$1"

  # Graph mode never streams a run to the terminal, not even a lone first one:
  # any other run may start alongside it at any moment, and interleaved live
  # output from several runs is unreadable.
  orchestrator_executor_launch_logged "$idx"
}

# Launch every pending run whose graph dependencies have all succeeded.
graph_launch_ready() {
  local idx=0 dep ready
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "pending" ]]; then
      ready=1
      for dep in ${GRAPH_DEPS[$idx]}; do
        if [[ "${ORCH_EXEC_STATES[$dep]}" != "succeeded" ]]; then
          ready=0
          break
        fi
      done
      if [[ "$ready" -eq 1 ]]; then
        graph_launch "$idx"
      fi
    fi
    idx=$((idx + 1))
  done
}

# A failed run takes its whole downstream with it. Sweep until nothing changes so
# indirect dependents are caught too, and carry the original failure's id down
# the chain instead of naming the intermediate run that was itself only blocked.
graph_propagate_blocks() {
  local changed=1 idx dep
  while [[ "$changed" -eq 1 ]]; do
    changed=0
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      if [[ "${ORCH_EXEC_STATES[$idx]}" == "pending" ]]; then
        for dep in ${GRAPH_DEPS[$idx]}; do
          case "${ORCH_EXEC_STATES[$dep]}" in
            failed|stopped)
              GRAPH_BLOCKER[$idx]="${INCOMPLETE_RUNS[$dep]}"
              ;;
            blocked)
              GRAPH_BLOCKER[$idx]="${GRAPH_BLOCKER[$dep]}"
              ;;
            *)
              # `continue` here belongs to the `for dep` loop; `case` is not one.
              continue
              ;;
          esac
          ORCH_EXEC_STATES[$idx]="blocked"
          echo "  [graph] ${INCOMPLETE_RUNS[$idx]}: BLOCKED (${GRAPH_BLOCKER[$idx]} failed)" >&2
          changed=1
          break
        done
      fi
      idx=$((idx + 1))
    done
  done
}

# What a pending run is still waiting for. The scheduler already knows; without
# it the row would just say "pending" for however long the upstream takes.
graph_pending_note() {
  local idx="$1" dep
  for dep in ${GRAPH_DEPS[$idx]}; do
    if [[ "${ORCH_EXEC_STATES[$dep]}" != "succeeded" ]]; then
      printf '<- %s' "${INCOMPLETE_RUNS[$dep]}"
      return 0
    fi
  done
}

# One board frame from the scheduler's state plus each run's status file.
# Running runs are drawn first: when the terminal cannot hold every row, the
# ones being dropped should be the ones nothing is happening in.
graph_render_board() {
  local idx pass note
  local running=0 succeeded=0 failed=0

  ralph_board_begin_frame

  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    case "${ORCH_EXEC_STATES[$idx]}" in
      running) running=$((running + 1)) ;;
      succeeded) succeeded=$((succeeded + 1)) ;;
      failed | stopped) failed=$((failed + 1)) ;;
    esac
    idx=$((idx + 1))
  done

  for pass in running other; do
    idx=0
    while [[ $idx -lt $TOTAL_RUNS ]]; do
      if [[ "$pass" == "running" && "${ORCH_EXEC_STATES[$idx]}" != "running" ]] \
        || [[ "$pass" == "other" && "${ORCH_EXEC_STATES[$idx]}" == "running" ]]; then
        idx=$((idx + 1))
        continue
      fi

      note=""
      case "${ORCH_EXEC_STATES[$idx]}" in
        blocked) note="<- ${GRAPH_BLOCKER[$idx]}" ;;
        pending) note="$(graph_pending_note "$idx")" ;;
        skipped) note="${GRAPH_SKIP_REASON[$idx]%%,*}" ;;
        failed | stopped) note="exit ${ORCH_EXEC_RCS[$idx]}" ;;
      esac

      ralph_board_row "${INCOMPLETE_RUNS[$idx]}" "${ORCH_EXEC_STATES[$idx]}" "$note"
      idx=$((idx + 1))
    done
  done

  ralph_board_end_frame "$running" "$succeeded" "$failed"
}

# Returns 0 when every runnable run succeeded, RALPH_RATE_LIMIT_EXIT_CODE on a
# rate limit, and 1 when anything failed or was blocked. Runs the selection
# cannot execute are reported, not counted as failures.
graph_execute() {
  local idx completed_idx rate_limited=0 skipped

  skipped="$(graph_skipped_count)"

  echo ""
  echo "==============================================================="
  if [[ "$skipped" -gt 0 ]]; then
    echo "  Graph execution: $((TOTAL_RUNS - skipped)) run(s), $skipped not runnable"
  else
    echo "  Graph execution: $TOTAL_RUNS run(s)"
  fi
  echo "==============================================================="

  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "skipped" ]]; then
      echo "  [graph] ${INCOMPLETE_RUNS[$idx]}: NOT RUN (${GRAPH_SKIP_REASON[$idx]})"
    fi
    idx=$((idx + 1))
  done

  orchestrator_executor_clear_status_files
  ralph_board_start "$STATUS_ROOT" "$TOTAL_RUNS"

  while true; do
    graph_launch_ready
    orchestrator_executor_refresh_pids
    orchestrator_executor_has_running || break

    # Reap in completion order rather than launch order: blocking on one pid
    # would hold back every run that another, already-finished child has just
    # made ready.
    orchestrator_executor_poll_completed
    for completed_idx in "${ORCH_EXEC_COMPLETED[@]}"; do
      case "${ORCH_EXEC_RESULTS[$completed_idx]}" in
        ok)
          echo "  [graph] ${INCOMPLETE_RUNS[$completed_idx]}: ok"
          ;;
        rate-limited)
          rate_limited=1
          echo "  [graph] ${INCOMPLETE_RUNS[$completed_idx]}: rate-limited (exit ${ORCH_EXEC_RCS[$completed_idx]}, see ${ORCH_EXEC_LOGS[$completed_idx]})" >&2
          ;;
        failed)
          echo "  [graph] ${INCOMPLETE_RUNS[$completed_idx]}: FAILED (exit ${ORCH_EXEC_RCS[$completed_idx]}, see ${ORCH_EXEC_LOGS[$completed_idx]})" >&2
          ;;
      esac
    done

    # A rate limit is the one failure that cuts everything short: the remaining
    # runs would only burn requests against the same exhausted quota.
    if [[ "$rate_limited" -eq 1 ]]; then
      orchestrator_executor_refresh_pids
      orchestrator_executor_terminate
      orchestrator_executor_forget_pids
      orchestrator_executor_mark_running_stopped
      graph_propagate_blocks
      ralph_board_stop
      return "$RALPH_RATE_LIMIT_EXIT_CODE"
    fi

    graph_propagate_blocks
    graph_render_board

    if [[ "$ORCH_EXEC_REAPED" -eq 0 ]]; then
      sleep 1
    fi
  done

  ralph_board_stop
  orchestrator_executor_forget_pids
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    case "${ORCH_EXEC_STATES[$idx]}" in
      succeeded | skipped) ;;
      *) return 1 ;;
    esac
    idx=$((idx + 1))
  done
  return 0
}

graph_summary() {
  local idx any

  echo ""
  echo "==============================================================="
  echo "  Graph summary"
  echo "==============================================================="

  echo "Succeeded:"
  any=0
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "succeeded" ]]; then
      echo "  - ${INCOMPLETE_RUNS[$idx]}"
      any=1
    fi
    idx=$((idx + 1))
  done
  [[ "$any" -eq 1 ]] || echo "  (none)"

  echo "Failed:"
  any=0
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    case "${ORCH_EXEC_STATES[$idx]}" in
      failed)
        echo "  - ${INCOMPLETE_RUNS[$idx]} (exit ${ORCH_EXEC_RCS[$idx]}, log: ${ORCH_EXEC_LOGS[$idx]})"
        any=1
        ;;
      stopped)
        echo "  - ${INCOMPLETE_RUNS[$idx]} (stopped after a rate limit, log: ${ORCH_EXEC_LOGS[$idx]})"
        any=1
        ;;
    esac
    idx=$((idx + 1))
  done
  [[ "$any" -eq 1 ]] || echo "  (none)"

  echo "Blocked:"
  any=0
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    case "${ORCH_EXEC_STATES[$idx]}" in
      blocked)
        echo "  - ${INCOMPLETE_RUNS[$idx]} (blocked by failed run '${GRAPH_BLOCKER[$idx]}')"
        any=1
        ;;
      pending)
        # Only reachable when the orchestrator stopped before this run's turn.
        echo "  - ${INCOMPLETE_RUNS[$idx]} (never started: orchestrator stopped early)"
        any=1
        ;;
    esac
    idx=$((idx + 1))
  done
  [[ "$any" -eq 1 ]] || echo "  (none)"

  # Kept separate from Blocked: nothing went wrong with these runs, the
  # selection just does not contain what they need.
  any=0
  idx=0
  while [[ $idx -lt $TOTAL_RUNS ]]; do
    if [[ "${ORCH_EXEC_STATES[$idx]}" == "skipped" ]]; then
      if [[ "$any" -eq 0 ]]; then
        echo "Not runnable in this selection:"
        any=1
      fi
      echo "  - ${INCOMPLETE_RUNS[$idx]} (${GRAPH_SKIP_REASON[$idx]})"
    fi
    idx=$((idx + 1))
  done
}

graph_main() {
  local rc=0 skipped runnable

  graph_build || exit 1
  graph_assign_waves || exit 1
  graph_mark_unrunnable

  graph_show
  graph_show_unrunnable

  skipped="$(graph_skipped_count)"
  runnable=$((TOTAL_RUNS - skipped))

  if [[ "$runnable" -eq 0 ]]; then
    echo ""
    echo "Nothing in this selection can run: every selected run depends on a run" >&2
    echo "left out of it. Widen the selection, or finish those runs first." >&2
    exit 1
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    graph_show_waves
    echo ""
    echo "Dry run: not executing any Ralph runs."
    exit 0
  fi

  if [[ -t 0 ]]; then
    echo ""
    read -r -p "Confirm? [y/N] " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
      echo "Aborted."
      exit 1
    fi
  else
    echo ""
    echo "Graph resolved non-interactively; proceeding without confirmation."
  fi

  # Disable strict mode for the scheduler so a failed run is handled here rather
  # than aborting the orchestrator mid-graph.
  set +e

  START_TIME=$(date +%s)
  graph_execute
  rc=$?
  END_TIME=$(date +%s)

  graph_summary
  echo ""
  echo "Total elapsed: $((END_TIME - START_TIME))s"

  if [[ "$rc" -eq "$RALPH_RATE_LIMIT_EXIT_CODE" ]]; then
    echo "A run detected a 429/rate-limit response. Stopping orchestrator (queued runs skipped)." >&2
    exit "$RALPH_RATE_LIMIT_EXIT_CODE"
  fi
  if [[ "$rc" -ne 0 ]]; then
    echo "Some runs failed or were blocked." >&2
    exit 1
  fi
  if [[ "$skipped" -gt 0 ]]; then
    echo "All $runnable runnable run(s) completed successfully; $skipped left unrun (see above)."
  else
    echo "All $TOTAL_RUNS run(s) completed successfully."
  fi
  exit 0
}
