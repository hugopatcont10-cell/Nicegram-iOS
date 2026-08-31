# nicegram-ios

A fork of **Telegram-iOS**, shipped as **Nicegram**. We periodically merge the
latest upstream Telegram into this repo, so **every change here must be written
to survive that merge with as few conflicts as possible.**

Most standalone feature work does **not** belong here — it lives in the sibling
Swift package **`nicegram-assistant-ios`**. This repo is for code that must
physically live inside the Telegram app.

## Relationship with nicegram-assistant-ios

The assistant is **vendored as a git submodule** at
`packages/nicegram-assistant-ios`, so its sources sit in this working
tree and local edits build immediately. Commits there belong to the assistant
repo and land through its own PR **before** this repo bumps the pointer. See
"Cross-repo feature workflow" below.

Two independent directions — don't conflate them:

- **Calling assistant features (host → assistant):** the Telegram shell invokes
  assistant code **directly** (import the assistant module and call it / its
  `Presenter`). Host-side dependencies are wired into the assistant once at
  launch via `NGEntryPoint.onAppLaunch(...)`.
- **`TelegramBridge` (assistant → host):** the abstraction the assistant uses to
  reach Telegram/host capabilities. **nicegram-ios provides the bridge
  implementations** (typically in `NGUtils`), injected through `NGEntryPoint`. It
  is dependency-injection *into* the assistant — NOT how the host calls assistant
  features.

## Two kinds of change in this repo

1. **Full features inside Telegram** — code that genuinely needs Telegram
   internals (chat UI, `Postbox`, `AccountContext`, navigation, ...).
2. **Call-sites into `nicegram-assistant-ios`** — thin hooks that invoke assistant
   features from the Telegram shell.

## Prime directive: minimize upstream-merge conflicts

Whatever the change, choose the **highest** applicable option:

1. **Keep it out of Telegram code.** Put it in `nicegram-assistant-ios`, or in a
   brand-new **separate file** here (a new file never conflicts on merge). Bridge
   Telegram dependencies through `TelegramBridge`.
2. **Add new code to an existing Telegram file**, wrapped in Nicegram markers.
3. **Modify an existing Telegram line** — last resort, with a marker above it.

Never leave an unmarked edit in Telegram code — the marker is what lets us
re-apply and audit our changes at the next merge. Exact marker syntax and the
`Signal` bridges live in the `telegram-interop` rule.

## Where our code lives

- **`Nicegram/`** — our in-repo `NG*` modules (mainly `NGUtils`). See the
  `nicegram-modules` rule.
- **`submodules/**/Nicegram/`** — whole new Nicegram files inside a Telegram
  submodule.
- **Marked blocks/lines across `submodules/**`** — inline integration.

## Build

Bazel (`BUILD` files; some legacy `BUCK` remain), not hand-managed SPM/Xcode.
When you add a source file or dependency, update that module's build target. Do
not hand-edit generated files.

The build layer is `ci/fastlane`. Do not invoke `build-system/Make/Make.py`
directly — the fastlane lanes resolve the configuration, cache directory, and
codesigning repository for you, and a hand-written `Make.py` command will use the
wrong ones.

    cd ci && ./generate-project.sh                    # generate + open the Xcode project
    cd ci && ./verify-build.sh                        # compile check (debug_sim_arm64, no match/distribution signing)
    cd ci && ./build-to-testflight.sh "1.2.3 (456)"   # QA / TestFlight build

`verify-build.sh` and `generate-project.sh` both run `ci/bootstrap-submodules.sh`
first and abort if it fails. This matters because a freshly created worktree
starts with **every** submodule uninitialized — neither the "create worktree"
checkbox nor the harness's `EnterWorktree` tool runs `git submodule update
--init`, and no single harness hook covers every path that creates a
worktree — so without this, the first build fails ~30s into Bazel with a `No
MODULE.bazel, REPO.bazel, or WORKSPACE file found in .../rules_xcodeproj`
error that names neither "submodule" nor "worktree". The script is idempotent
and near-instant when nothing is missing (one `git submodule status` call);
when something is missing it prefers cloning from the main clone's own
gitdirs over the network (see "Starting a feature" below for why), and if it
still can't fully initialize everything — most likely
`packages/nicegram-assistant-ios`, which needs Bitbucket SSH access — it
prints exactly which paths failed and exits non-zero rather than letting the
build proceed into the confusing Bazel error above. `build-to-testflight.sh`
skips this step: it doesn't build locally, it just pushes the branch and
triggers the Bitbucket pipeline, which does its own recursive submodule
checkout.

All three wrappers then source `ci/_env.sh`, which sources
`ci/fastlane-env.sh` — **untracked** because it holds credentials, obtain it
from the shared env store, like the demo app's `Env.swift`. From a worktree,
where that untracked file does not exist, it falls back to the main clone's
copy automatically, so the same three commands work everywhere. (That
fallback depends on every wrapper starting with `#!/bin/bash`: under
`/bin/sh` — on macOS that's bash itself running in POSIX mode, reproduced
directly — a failed `.` on a missing file aborts the shell before the `||`
alternative runs, so the fallback would silently never fire.) `ci/_env.sh`
then re-derives `SOURCE_PATH` itself and re-exports it, derived from its
own file location rather than the caller's working directory
(`SOURCE_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`), so it
resolves correctly however `_env.sh` is sourced, not only when the
caller happens to be sitting in `ci/`. This overrides whatever the
untracked `fastlane-env.sh` happened to set. That's deliberate: leaving the
guarantee "a build from a worktree builds that worktree" resting only on
the untracked file would make it depend on every teammate's local,
unversioned copy deriving the path the same way — one copy that
hardcodes a stale absolute path and a worktree build silently builds the
main clone instead, with no error. The Fastfile has its own separate
fallback, `SOURCE_PATH = ENV["SOURCE_PATH"] || File.expand_path("../..",
__dir__)` — a second, independent safety net for a lane invoked directly
without going through any wrapper, not the mechanism the guarantee above
actually rests on (`__dir__` evaluates to `"."` in fastlane's `eval`; the
fallback only lands on the repo root because fastlane wraps that eval in
`Dir.chdir(FastlaneFolder.path)`, i.e. `ci/fastlane`). CI sets
`SOURCE_PATH` directly as job env before invoking a lane, so
`ENV["SOURCE_PATH"]` wins there without ever touching `_env.sh`.

The target environment comes from `ng-env.txt` (`test` or `prod`), which
`resolve_telegram_configuration` reads to pick between
`TELEGRAM_CONFIGURATION_TEST` and `TELEGRAM_CONFIGURATION_PROD`.

Add `--continueOnError` to a `Make.py` call only if you are debugging the build
system itself; for normal work, use the wrappers.

`./verify-build.sh` is the supported way to answer "does this still compile" —
for any change, not just an upstream merge. It uses `--continueOnError` so one
pass reports every broken module, and it refuses to start while Xcode is
running, because the two builds share a module cache and deadlock rather than
fail.

### One build at a time

An Xcode build and a CLI build share the same Bazel output base and, via
`--features=swift.use_global_module_cache` in `xcodeproj.bazelrc`, one global
module cache. Running both at once wedges `swift-frontend` on the module-cache
lock: the processes stay alive, use **no CPU**, and never finish. It does not
fail — it hangs, which is easy to mistake for a slow build. Quit Xcode before a
CLI build.

Diagnosing a suspected wedge — check all three:

    ps -eo pid,etime,%cpu,command | grep -E "[s]wift-frontend|[s]wiftc"
    find -L /private/var/tmp/_bazel_*/ -newermt '-60 seconds' -type f | head
    # and whether progress lines are still advancing in the build output

Several compilers at 0.0% CPU with growing elapsed time, plus no writes for
minutes, means wedged. Recovery: kill the stuck `swift-frontend` processes, then
the bazel server, then re-run the build alone.

## Cross-repo feature workflow

`nicegram-assistant-ios` is vendored as a git submodule at
`packages/nicegram-assistant-ios` and consumed as a local SwiftPM path
package, so **assistant edits reach the build with no push and no re-pin**.

A feature spanning both repos uses **one worktree and two same-named branches**:

    .claude/worktrees/<slug>/                     branch feat/<slug>
      packages/nicegram-assistant-ios/            branch feat/<slug>

### Starting a feature

Create the worktree with the harness's `EnterWorktree` tool (see the
`using-git-worktrees` skill; falls back to plain `git worktree add` if
unavailable) from the main clone while it is on `develop`.
`.claude/settings.json` configures it to branch from the current HEAD rather
than `origin/master`:

    { "worktree": { "baseRef": "head" } }

The nested-key shape matches how `permissions`/`hooks` are nested and is
confirmed correct: the Claude Code changelog shows `worktree.baseRef` (values
`fresh` | `head`) shipping in v2.1.133, and the CLI installed here is newer, so
the key takes effect and the silent-misconfiguration failure mode described in
an earlier draft of this doc doesn't apply. Still assert it immediately after
creating the worktree — it costs two commands and catches a different, real
failure: the main clone being on the wrong branch when the worktree was
created:

    git -C .claude/worktrees/<slug> log --oneline -1
    git log --oneline -1 develop        # the two should match

If they don't match, branch the worktree onto `develop` manually before
continuing.

**From here on, work inside the worktree** — `cd .claude/worktrees/<slug>`
before running any of the following commands. Both the submodule init and the
branch it creates must happen on the worktree's own submodule checkout, never
on the main clone's: doing it from the main clone silently creates the
feature's assistant branch on the wrong checkout — the exact stranded-branch
failure the landing guard below exists to catch.

    cd .claude/worktrees/<slug>

**The loop below is now optional for build purposes** — `ci/verify-build.sh`
and `ci/generate-project.sh` both run `ci/bootstrap-submodules.sh` before they
do anything else and initialize whatever's missing on their own (see "Build"
above for why this exists: the worktree-creation flow — neither the "create
worktree" checkbox nor the harness's `EnterWorktree` tool — ever runs `git
submodule update --init`, and no single harness hook covers every path that
creates one). You only need to run the loop by hand if you want the assistant
submodule populated **and** switched onto `feat/<slug>` in one go before your
first build — `bootstrap-submodules.sh` brings submodules to their currently
pinned commit, it doesn't create branches.

Plain bootstrap (works, but see the faster alternative just below):

    git submodule update --init
    git -C packages/nicegram-assistant-ios switch -c feat/<slug> origin/develop

Instead of the command above, clone the submodules from the main clone's local
gitdirs (hardlinked; measured ~4s for all 14 submodules versus refetching
~550 MB over the network — this is the same trick `ci/bootstrap-submodules.sh`
uses under the hood). Needs `protocol.file.allow=always` — git blocks
file-protocol submodule transports by default (CVE-2022-39253 mitigation) and
fails with `fatal: transport 'file' not allowed` without it. Don't construct
`$MAIN/.git/modules/<path>` by hand: it's wrong for at least one submodule —
`packages/nicegram-assistant-ios` stores its gitdir at the legacy path
`.git/modules/Nicegram/packages/nicegram-assistant-ios` — so ask git for the
real gitdir instead, and guard that lookup: `git -C <dir> rev-parse
--absolute-git-dir` walks *up* to the enclosing repo and returns *its*
gitdir with exit 0 when `<dir>` exists but isn't itself a git repo (e.g. a
submodule path that's also uninitialized in the main clone) — confirmed
empirically with an empty directory inside a throwaway repo. Skip the
lookup unless `$MAIN/$p/.git` actually exists, exactly like
`ci/bootstrap-submodules.sh` does; without the guard this loop would
clone the *superproject* into the submodule's path, fail confusingly, and
leave a non-empty directory that blocks a retry. The loop below also
scopes `git submodule sync` to just the path it initializes and parses
`git submodule status` with `sed` instead of `awk '{print $2}'`, for the
same two reasons `ci/bootstrap-submodules.sh` does: an unscoped sync
rewrites `submodule.<name>.url` for *every* submodule in `.git/config` —
which this worktree **shares with the main clone**, clobbering any
deliberate local URL override — and `awk`'s whitespace field-split
silently truncates any submodule path containing a space to its first
word (this repo has 1661 tracked paths with spaces). Run this from
inside the worktree (after the `cd` above):

    MAIN="$(dirname "$(git rev-parse --git-common-dir)")"
    git submodule status | sed -E 's/^.[0-9a-fA-F]+ //; s/ \([^)]*\)$//' | while read -r p; do
      gitdir=""
      if [ -e "$MAIN/$p/.git" ]; then
        gitdir="$(git -C "$MAIN/$p" rev-parse --absolute-git-dir 2>/dev/null)"
      fi
      git -c protocol.file.allow=always \
          -c "submodule.$p.url=${gitdir:-$MAIN/.git/modules/$p}" submodule update --init -- "$p"
      git submodule sync -- "$p"
    done
    git -C packages/nicegram-assistant-ios switch -c feat/<slug> origin/develop

Nothing else is needed: `Make.py` regenerates `build-input/`,
`build-input/configuration-repository`, and `xcodeproj.bazelrc` itself.

Builds from the worktree need `TELEGRAM_CODESIGNING_GIT_PASSWORD`; `ci/fastlane-env.sh`
is untracked and absent in a fresh worktree, but the `ci/` wrappers fall back to the
main clone's copy automatically — see "Build" above. No manual sourcing needed.

### Conventions

- Branch names are `feat/<slug>` in **both** repos, with no ticket key. The
  ticket goes only in the commit trailer (`Task: NCG-XXXX`).
- One spec and one plan, both in this repo under `docs/superpowers/`, with plan
  tasks tagged `[ios]` / `[assistant]`.
- Worktrees live under `.claude/worktrees/`, which is listed in `.bazelignore`
  (a nested worktree copies the root BUILD files and Bazel would otherwise
  discover it as a package) and covered by `.gitignore`'s pre-existing blanket
  `/.claude/*` rule — it has no entry of its own.
- **When the assistant gains a new dependency**, re-resolve this repo's
  `Package.resolved` (`swift package resolve`) and commit it with the feature.
  This is the only case left that touches `Package.resolved`; ordinary code edits
  never do.
- **Merge-watch files** — an upstream merge can clobber either of these; check
  both after every upstream merge:
  - `.gitmodules` — carries a `# MARK:` comment marking the private submodule
    stanza; re-add the stanza if a merge drops it. Note that any future
    `git submodule add` / `git submodule deinit` rewrites this file from
    scratch and silently drops the `# MARK:` comments, so re-mark it by hand
    afterward.
  - `Package.swift` — must stay `.package(path: "packages/nicegram-assistant-ios")`;
    never let a merge revert it back to a remote git URL dependency.
  - `docs/tg-merge/state.json` — the merge skill's only record of the last
    merged upstream commit. Never hand-edit the sha to make a check pass; a
    wrong base silently produces a plausible merge against the wrong upstream.
    Both this file and `docs/tg-merge/reports/` are stripped from the public
    mirror by `bitbucket-pipelines.yml`.

### Building for QA

    cd ci && ./build-to-testflight.sh "<version> (<build>)"

**Preconditions, in this order:**

1. The assistant feature branch is **pushed** (not merged — the branch stays open).
2. The host's submodule pointer is **committed** at that pushed commit.

The script pushes the current host branch, then triggers the Bitbucket
`push-to-github-repo` pipeline on it, which mirrors to GitHub `beta`, where
`.github/workflows/beta.yml` checks out with `submodules: 'recursive'` and builds.
An assistant commit that exists only locally fails at that checkout, so both
preconditions are about making the SHA fetchable — not about merging.

The mirror step also strips `.claude/` and `docs/superpowers/` before pushing,
so fork-internal tooling and process docs never reach the public GitHub repo;
both stay fully tracked in Bitbucket. This only stops **future** disclosure —
`docs/superpowers/` predates this exclusion, so if the mirror was pushed while
those files existed, that content may already be public, and the next mirror
push will simply record their deletion. (The private submodule's URL still
appears in the mirror's `.gitmodules` by necessity, since the release build
needs it to resolve; that is unchanged and already documented above.) Any new
fork-internal-only tree added later needs the same `rm -rf` plus a staged-path
assertion in `bitbucket-pipelines.yml` — otherwise it quietly starts shipping
to the public mirror.

### Landing a feature

Use the `merge-to-develop` skill. It merges the assistant first, then bumps and
merges the host, verifying before each branch deletion that the merged `develop`
tree matches the branch being deleted.

The order is not a preference: the host records a submodule SHA, so a host PR
merged while pointing at an unmerged assistant commit leaves `develop`
referencing a commit nobody else can resolve.

### Verifying

- Full app: `cd ci && ./generate-project.sh` in the worktree, then Xcode. Note
  that project generation runs `killall Xcode`, so one project is open at a time.
- Assistant only: the `Demo/` app inside the submodule — a plain SwiftPM build,
  no Bazel. See its `README.md`.

`nicegram-wallet-ios` is still a **remote** dependency of the assistant, so
features touching the wallet still need the old push-and-re-pin loop. It is the
next candidate for `packages/`.

## Delegating to subagents

The rules in `.claude/rules/` auto-attach by path for *your* session. A subagent
you dispatch does not inherit your context, so whatever you paste into its
prompt becomes its entire rulebook.

**Never hand a subagent a hand-written summary of these conventions.** A
summary silently replaces the real rules with your recollection of them, and
the subagent has no way to know something is missing. Instead, name the files:

> Binding conventions: read `packages/nicegram-assistant-ios/.claude/rules/swift-conventions.md`
> and `module-structure.md` before writing code. The constraints below are
> supplementary to those files, never a replacement.

The same applies to reviewers — a reviewer never asked to check against
`swift-conventions.md` will not check against it. Give every reviewer the rules
files that match the paths in its diff as a named check.

**When a reviewer flags a convention violation, do not triage it away as
"pre-existing pattern".** That adjudication has already been wrong once: it let
a hand-written initializer ship in a package whose rules say to use
`@MemberwiseInit`, and the human caught it in review instead.

## A plan is where conventions are won or lost

`.claude/rules/` attach by the path of a file in context. A spec or a plan is
markdown, so **no Swift rule ever attaches while you write one** — and a plan is
exactly where type shape, field order, initializers and DI wiring get decided.
Every implementer then transcribes it verbatim.

This is not hypothetical. The `CoreRemoteConfig` migration plan specified a
hand-written `init`, non-alphabetical stored properties, a computed `var` on a
class whose other members were functions, a service constructing its own
`HttpClient` instead of receiving it from the container, and redundant
transitive dependencies. Every one reached the code, and the human caught all of
them in review. Note that `module-structure.md` — which is always loaded — says
"Build initializers with `@MemberwiseInit`" and was in context the whole time.
**Presence in context is not application.** The check has to be deliberate.

So, before a spec or plan containing code blocks is shown to the human:

1. List the paths the plan will create or modify.
2. Read every `.claude/rules/*.md` whose `paths:` match them, in both repos,
   plus the always-on ones.
3. Check **each code block** against them — field order, initializers, access
   modifiers, DI wiring, dependency declarations, error handling.
4. Then dispatch a **plan conventions reviewer**: a subagent given the plan and
   those rules files, asked only "which code blocks violate these?" Self-review
   does not catch your own blind spots — the self-review on that same plan
   passed while all eight violations sat in it.

## Plans are test-first where tests are worth having

`packages/nicegram-assistant-ios` has a test target and a ~10-40s test loop, so
"this repo has no test framework" is no longer a reason to skip TDD. It was the
standing, never-negotiated excuse through the whole `CoreRemoteConfig`
migration, and it expired.

A plan task touching **pure logic** — a use case, parsing or mapping, a cache,
value resolution — states its test first and its implementation second, so the
implementer can watch it fail before making it pass. A task touching UI, DI
wiring, a `TelegramBridge` or network transport does not: a test there asserts a
mock and proves nothing, and the review rubric counts one as a defect.

See "Testing" in `packages/nicegram-assistant-ios/AGENTS.md` for the framework,
the run command, and the two ways a test run can look green without having run.

## Learning from review feedback

When the human gives feedback on a spec, a plan, or code, they may ask you to
**invoke the `learn-from-feedback` skill**. It applies the corrections and then
repairs whatever let each one through, so the same correction is not needed
twice.

**Only invoke it when asked.** Not all feedback should change the instructions —
corrections during brainstorming are the design converging, not a rule failing.
The human decides. The skill never commits an instruction change without
showing it for approval first.

## Detailed conventions (`.claude/rules/`, auto-attached by path)

- `telegram-interop.md` — editing `submodules/**`: marker syntax + SSignalKit
  bridges.
- `nicegram-modules.md` — `Nicegram/**` modules, `NGUtils`, resources.
- `swift-conventions.md` — Swift style for our code.
- `assistant-package.md` — `packages/**` — vendored submodule, read
  the assistant's own rules.

`CLAUDE.md` at the repo root is upstream Telegram's own file, not ours — except
for three fork-owned spots: its marked "Nicegram branding overrides" subsection
(hand-maintained, preserved across every upstream merge), the two-line import at
the top that pulls this file in, and the `<!-- Nicegram: … -->` build-values
marker comment near the top of the file, flagging that its Build section's
values are upstream's, not this fork's. Aside from those fork-owned spots,
`CLAUDE.md` stays the authority on the embedded watch app, the Postbox →
TelegramEngine refactor, and the tgcalls testbench — but its Build section's
cache dir, config path,
codesigning repo, and password source are upstream's own values and don't work
here; see "Build" above for the ones that do. This file covers what the fork
adds.
