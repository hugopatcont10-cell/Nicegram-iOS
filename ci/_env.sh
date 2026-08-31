#
# Sources the untracked ci/fastlane-env.sh that holds this machine's
# credentials (API keys, signing secrets, TELEGRAM_CODESIGNING_GIT_PASSWORD),
# falling back to the main clone's copy when this tree is a worktree --
# worktrees never get their own copy of an untracked file, since git only
# checks out tracked content into them.
#
# Must be *sourced* (". ./_env.sh"), never executed directly: its only job
# is to export variables into the caller's shell, which a subprocess can't
# do for its parent.
#
# The `||` fallback below only works because every caller starts with
# `#!/bin/bash`. Under /bin/sh -- on macOS that's bash itself running in
# POSIX mode, not dash, but the failure mode is identical and was
# reproduced directly: `sh -c '. ./missing || echo fallback'` never prints
# "fallback" -- a `.` on a missing file is fatal and kills the shell
# immediately, so the `||` alternative never gets a chance to run. That
# failure mode is silent: the shell just exits 1 with no output. So every
# wrapper that sources this file MUST keep its `#!/bin/bash` line;
# dropping it quietly breaks the worktree fallback this file exists to
# provide.
#
# When neither copy exists, say so and stop. Without this the second `.` fails,
# bash carries on regardless (a non-fatal `.` is the whole reason the `||` above
# works), and the caller runs its fastlane lane with no credentials at all --
# failing much later, somewhere unrelated, with an error about a missing signing
# identity or a 401. Note this `exit` ends the *caller*, which is what every
# wrapper wants; it would also end an interactive shell that sourced this file
# by hand, so don't.
# Resolved once into a variable so the path we try and the path we name in the
# error cannot drift apart, and so `git rev-parse` runs once. `--git-common-dir`
# answers absolutely from a linked worktree -- the case this fallback exists
# for -- and relatively from a normal clone, where the first candidate is the
# one that matters anyway.
_ng_main_env="$(dirname "$(git rev-parse --git-common-dir 2>/dev/null)")/ci/fastlane-env.sh"
. ./fastlane-env.sh 2>/dev/null \
  || . "$_ng_main_env" 2>/dev/null \
  || {
    echo "error: ci/fastlane-env.sh not found." >&2
    echo "  looked in: $(pwd)/fastlane-env.sh" >&2
    echo "         and: $_ng_main_env" >&2
    echo "  It is untracked because it holds this machine's credentials." >&2
    echo "  Obtain it from the shared env store (as with Demo/Composition/Env/Env.swift)." >&2
    unset _ng_main_env
    exit 1
  }
unset _ng_main_env

# SOURCE_PATH must be re-derived here, in a file this repo tracks, even
# though the untracked fastlane-env.sh sourced above also happens to set
# it today (its own line 18: export SOURCE_PATH="$(cd .. && pwd)").
# Relying on that alone means the guarantee "a build from a worktree
# builds that worktree" depends on every teammate's local, unversioned
# copy deriving the path the same way -- one copy that hardcodes an
# absolute path and a worktree build silently builds the main clone
# instead, with no error. Owning the override here makes it impossible
# for an untracked file to regress. (The Fastfile's own
# File.expand_path("../..", __dir__) fallback is a separate, independent
# safety net for a lane invoked directly, without going through any
# wrapper -- it doesn't replace this line, this line is what makes the
# guarantee tracked on the normal wrapper path.)
#
# Derived from this file's own location (${BASH_SOURCE[0]}), not the
# caller's cwd: `cd .. && pwd` would silently compute the wrong path if
# a future caller ever sources this file from somewhere other than ci/
# (all four current callers do cd there first, so this isn't a live bug
# today, but the failure would be a wrong path, not a loud one).
# Verified with a real script-file source in both directions: a relative
# ". ./_env.sh" from ci/, and an absolute-path source from the repo
# root -- both land on the worktree root, and a bogus pre-exported
# SOURCE_PATH is overridden either way.
SOURCE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; export SOURCE_PATH
