#!/bin/bash

# The scaffold cleanup round: the last code round on the Ralph branch, run once
# every story passes and before anything is merged back.
#
# A story round is scoped to one slice and has to prove that slice on its own,
# so it builds whatever it needs to see itself work - a `test:us022core` npm
# script, a seeded fixture, a demo route, a stub standing in for a dependency
# that lands two stories later. Each of those is correct for the round that
# wrote it and wrong for the branch that ships: by the time the last story
# passes, the real implementation is there and the propping is dead weight
# nobody asked for. No single story round can remove it either, because each one
# only ever sees its own slice.
#
# Hence one dedicated round that sees the whole branch. It is bounded the same
# way the other wrap-up rounds are (a marker file, a retry budget) and its
# boundary is the mirror of the unblock round's: it may delete what only existed
# to prop up a round, and it may never delete what an acceptance criterion still
# rests on.

scaffold_cleanup_needed() {
  # An escape hatch, not a mode: a run whose scaffolding is deliberate (a spike,
  # a branch handed to a human mid-flight) can skip the round without editing
  # the loop.
  [[ "${RALPH_SKIP_SCAFFOLD_CLEANUP:-0}" != "1" ]]
}

scaffold_cleanup_done() {
  [[ -f "$SCAFFOLD_CLEANUP_STATE_FILE" ]] || return 1

  grep -qx "status=done" "$SCAFFOLD_CLEANUP_STATE_FILE" \
    && grep -qx "run_id=$RUN_ID_LABEL" "$SCAFFOLD_CLEANUP_STATE_FILE"
}
