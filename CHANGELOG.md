# Changelog

All notable changes to `worktree.nvim` are documented here.

## [v0.5.17] — 2026-09-11 — bind a branch that already has a PR, and report a credential honestly

Patch. ADR-0083 Amendment r10.7 — the two increments deferred from r10. Pairs
with auto-finder.nvim **v0.4.29**, which adds the panel keys and the preflight.
Reviewed by lector across four rounds; twelve findings, all folded.

**`associate` / `dissociate` (#28).** An association could only be made as a
*side effect* of GetPR or CreatePR, so a branch that already had a PR — opened
with `gh` outside nvim, a colleague's, or one you renamed — could be bound only
by hand-editing the KB document. That is not cosmetic: a review inherits its
`pr` at **draft** time, so an unassociable worktree yields reviews `S` can
never submit.

`pr.associate(repo, branch, n, opts)` and `pr.dissociate(repo, branch, opts)`,
plus `:WorktreeAssociatePR[!] <n>` and `:WorktreeDissociatePR`, both acting on
the cwd branch and the repo that owns it. What they guarantee:

- A branch git cannot resolve is refused — otherwise the document matches
  nothing and reports success.
- **Both ends of the relation are checked.** A branch may hold one PR *and* a
  PR may sit on one branch; either occupancy requires explicit reassignment,
  and the conflict names the incumbent branch and which end collided.
- **A stub is only for "nothing was configured to ask with."** With a usable
  token the record is the forge's. If a credential *is* configured but cannot
  be used, or the forge denies the PR, the write is refused and the existing
  document is left untouched — attempted verification that failed must not be
  papered over with a fictional record. An offline re-point moves only the
  `branch:` line, so a recorded title, base and `base_sha` survive.
- **The whole transition is serialized** under a per-repository association
  lock; forge verification stays outside it, so network latency does not hold
  the lock.
- **Confirmations authorize the state the user saw.** `opts.expect` snapshots
  both ends — the source by PR number, the target by `{number, branch}`,
  because the target's number is the PR you asked for and cannot differ. A
  bare-number target snapshot is refused rather than accepted.
- A branch literally named `pr-<N>` cannot be dissociated: the name *is* the
  association, so it says so and names the remedy.

Also: an explicit `branch:` document now beats the `pr-<N>` naming convention
in `find_for_worktree`. It was first-match-wins over `globpath`, so which badge
appeared depended on filesystem iteration order.

**`credentials.describe` (#29).** ADR-0083 §2.6 Action 1 step 1 ("ensure a
credential profile is configured") was specified and never built. `describe`
reports **selection** (which key wins, and its shape) and **readiness**
(`ready` / `unavailable` / `unknown`) as two separate facts:

- `in_memory` is ready; an `env` profile is resolved by a side-effect-free
  variable lookup; a **command** provider is honestly `unknown`, because
  knowing would mean running it and a status check must not fire a GPG
  passphrase prompt;
- the ambient `$GITHUB_TOKEN` is a *selected* source whenever the host
  qualifies — whether it holds anything is readiness, not selection.

`:WorktreeAuth status` reports all three states for the repo at cwd, in its own
words: "resolves through" only for ready, "selects X … but it is UNAVAILABLE"
for a known-bad source, "readiness unknown" for a command provider.

Profile selection is now shared between `describe` and `resolve_token`, so the
two cannot disagree about which credential applies.

PRs #28 and #29. Tests: `adr0083-pr-lifecycle` 96 → 167, `adr0083-credentials`
62 → 98; `run-all.sh` OK on merged `main`. Every fix carries a falsification —
one revert per claim, including reproductions of each reviewer probe.

## [v0.5.16] — 2026-09-10 — CreatePR reported failure for PRs it created, and associated them with nothing

Patch. Three defects on the PR path, all on the surface auto-finder's repos
panel drives. Found while auditing what that panel's `?` help modal fails to
tell an end user about PR credentials and PR associations — see
auto-finder.nvim **v0.4.28**, which documents both prerequisites, and ADR-0083
Amendment r10.

**`create_pr` returned `(pr, err)` while both call sites read `res.ok`.**
`:WorktreeCreatePR` and auto-finder's `N` both read `res.ok` and
`res.pr.number`, so a PR that had just been opened on the forge reported
`could not create PR — unknown`. Probed against a mocked 201 before the fix:

```
res.number : 77      res.ok : nil
CALLER SEES: could not create PR — unknown
CONTROL    : created PR #77          ← same caller branch, {ok=…} shape
```

It now returns a result envelope like its sibling ACTIONS
(`fetch_and_create_worktree`, `post_feedback`); the `(value, err)` pair stays
with the internal fetchers `get_pr` / `get_comments`.

Why no suite observed it, which is the part worth keeping: auto-finder's own
cell mocked `{ ok = true, pr = { number = 99 } }` — the envelope the caller
*wished for*, never the one the function returned. A mock written from the
caller's intent cannot detect a contract mismatch; it encodes it as correct.

**A created PR was associated with nothing.** ADR-0083 §2.6 Action 6 specifies
"on creation, instantiate the KB PR document"; it was never implemented. A PR
opened with `N` therefore had no local association — no `[#N]` badge, no `S`,
and (because a review inherits its `pr` at *draft* time) every review written
from that worktree afterwards carried no PR and could never be submitted. The
create → review → submit loop was broken end to end for any branch not named
`pr-<N>`.

The writer is now one exported function, `worktree.pr.write_kb_doc`, shared
with `fetch_and_create_worktree` — two writers would be two definitions of what
an association *is*. A created PR's document also gains `base`, `base_sha` and
`author`, which the old projection dropped, leaving `open_pr_diff` to fall back
to the literal `main`. A failed write does **not** fail the action — the PR is
already open and reporting failure would invite a second create — so it returns
as `kb_doc_error` and the panel warns.

**`:WorktreeRecoverPRLock` was dead on arrival, twice over.** It called
`pr_mod.parse_remote_url`, which this module has never exported (`parse_remote`
returns a *table*, not a `forge, owner, name` triple):

```
pr.parse_remote_url : nil
calling it          : attempt to call field 'parse_remote_url' (a nil value)
```

Repairing the name alone was not enough: it derived `owner .. "/" .. name`
while `post_feedback` locks under `repo.slug` (`owner__name`), and
`recover_lock` returns **true** for a lock file that does not exist — so the
wrong key "recovered" successfully and left the real lock in place. Both paths
now derive the key from `pr.lock_key`.

README: the PR-association rules (what makes a worktree PR #N, which paths
write it, how to repoint one by hand), and the three PR commands that were
missing from the command table.

PR #26. Tests: `tests/adr0083-pr-lifecycle.lua` §5g/5h/5i, +21 cells (75 → 96),
`run-all.sh` OK at 605 across 11 suites. The association is asserted through its
consumer (`find_for_worktree`) on an ordinary branch name — `pr-<N>` would match
by naming convention and prove nothing — with an unrelated branch as the decoy;
the lock cells assert the FILE, not the return value, because the return value
is exactly what could not tell the two keys apart; §5i sources
`plugin/worktree.lua` and drives the registered command. Four falsifications
recorded, one reversal per fix.

## [v0.5.15] — 2026-09-09 — `review_posted`, and per-review `post_feedback` that never drops a second review

Patch. Companion to the auto-finder PR-association reframe (ADR-0083
Amendment r9).

`review_posted(repo, review)` answers whether a review's findings are all on
the forge, read from the two-phase posting RECEIPT — never the
ADR-0067-immutable review JSON. The repos panel badges a review `[posted]` from
it. `worktree.repos` exposes the thin panel-facing delegate.

`post_feedback` now merges per-review findings at a shared commit. It batched by
commit SHA and skipped a batch once committed, so submitting a second review at
a commit another review already owned dropped that review's findings while
returning `ok=true`. The batch is now the union of every review's findings for a
sha: each call merges its `finding_id`s in, done is judged against this call's
`finding_id`s, only unposted findings go on the wire, and aggregate state is
recomputed from the comments.

PR #25. Reviewed by lector; approved. New suites `adr0083-review-posted` (9)
and `adr0083-per-review-post` (8); full suite green.

## [v0.5.14] — 2026-09-09 — authoritative PR-diff base, credential surface, and honest GetPR failures

Patch. Two coupled changes landed together (PR #22 and PR #24, the rebased
continuation of the auto-closed #23).

**PR-diff range (#22).** The range ignored a base that had advanced, and
`find_for_worktree` never parsed the base. `pr_diff_commits` now ranges from the
forge's authoritative base sha when it is resolvable (`stale=false`), and
otherwise surfaces a flagged best-effort (`stale=true`) instead of the old
two-dot range that listed the base's own catch-up commits as the PR's.

**Credentials and GetPR robustness (#24).** A real credential surface
(`:WorktreeAuth list/set/clear`) with a slug → host → env `resolve_token` chain;
the `GITHUB_TOKEN` env fallback is now restricted to `github.com` and
`*.github.com` exactly, closing a token-disclosure path where any host
containing the substring "github" borrowed the ambient token. Review posting
threads the host like the other verbs. `:WorktreeGetPR` resolves the cwd's repo
and refuses when cwd is a git repo outside the workspace inventory rather than
silently acting on the first repo. `fetch_and_create_worktree` now reports
failure honestly, checking the fetch, worktree-add, and checkout steps.
Ephemeral curl-config temp names draw from an OS CSPRNG (`vim.uv.random`),
fixing a deterministic `math.random` collision that made concurrent PR
operations fail.

Reviewed by lector across the #22 and #23 rounds; approved. Suite: 813 passed,
0 failed across 11 suites, each new fix covered by a discriminating cell
verified against its reverted form.

## [v0.5.13] — 2026-09-08 — every range diff died on its first commit; the sha was abbreviated

Patch. `pr_diff_commits` read `git log --oneline`, which implies
`--abbrev-commit`, so its `sha` field came back seven characters — while the
next line computed `short = sha:sub(1, 7)`, a truncation of a truncation.

`auto-core.review.draft.scope` requires 40 hex and refuses anything shorter (two
commits can share a prefix, and a colliding scope would silently merge two
reviewers' drafts), so building a range diff over a real repository errored on
its first commit:

```
auto-core.review.draft: cannot bind a draft — sha="d8e6433"
… a sha must be the FULL 40 hex characters
```

Fixed at the producer with `--format=%H %s`. This is the same defect v0.5.12
(#19) fixed in `graph.lua`, where gitgraph handed out a nine-character hash;
that one had to be resolved at the consumer because gitgraph's output was not
ours. One producer was missed in that sweep.

`pr_diff_commits` had **never** been tested: both consumers stubbed it, and both
stubs returned a full 40-hex sha, so auto-finder's PR-diff suite was green for
weeks asserting the fixture's contract rather than this function's. Same failure
mode #19 recorded, one layer down.

Also in this release: CI's auto-core pin was two patches behind its own suites
(v0.2.15 against a v0.2.22 requirement), so the gate had been red on `main`
since #19 and could not distinguish a new failure from the standing one.

PR #21. `tests/pr-range-commits.lua` — 16 cells, five of which go red against
the pre-fix code. The sha is asserted to EQUAL `git rev-parse feature`, not
merely to be 40 characters long. run-all: OK (769 passed, 0 failed across 11
suites), first green CI run on this repo since #19.

## [v0.5.12] — 2026-09-07 — `o` died on every commit; gitgraph abbreviates its hashes

Patch. Fixes a regression shipped in `v0.5.11`.

Pressing `o` on the graph commit tree errored and opened nothing:

```
draft.lua:202: attempt to index local 'd' (a nil value)
graph.lua:606: in function '_open_repos_diff'
```

**gitgraph's commit objects carry a NINE-character hash** — `bd3a4c495`, read
live from a running session rather than reasoned about.
`auto-core.review.draft.scope` requires 40 hex and refuses anything shorter by
returning nil, deliberately: two commits can share a prefix, and a colliding
scope silently merges two reviewers' drafts. `draft()` then indexed the nil the
store handed back, so `o` was broken on **every** commit, not some.

**Resolved rather than relaxed.** The abbreviation is fine for `git show` and
for the diff read; it is only the DRAFT KEY that must be unambiguous, and the
repository is the only thing that can expand it. `git rev-parse <short>^{commit}`
does, and a resolution that fails **refuses** rather than carrying on —
proceeding with the abbreviation would silently disable the annotate surface,
which reads as the feature quietly not working rather than as an error.

Why 28 green cells said nothing, which is the part worth keeping: the fixture
built `{ hash = <full 40-hex> }` from `git rev-parse HEAD`. It pinned an
ASSUMPTION about gitgraph's contract rather than gitgraph's own, so the suite
never exercised the only shape the caller ever sees. It now drives the
abbreviated form and asserts the full sha reaches the view.

Pairs with auto-core **v0.2.23**, which makes the same class fail legibly
instead of as an index error.

## [v0.5.11] — 2026-09-07 — `o` opens a commit in the diff view, without reaching up a layer

Patch. Additive keymap plus two float fixes. **Requires auto-core >= v0.2.22.**

**`o` on the graph commit tree** opens the commit under the cursor in the shared
diff view — a file list, `a/<old>` and `b/<new>` panes, and the annotate
surface — instead of the single flat unified float `<CR>` gives. Asked for
because going back through commit history to see exactly which files a commit
touched is frequent work, and the graph (the good history browser) and the diff
view (the good per-commit reader) had nothing connecting them. `<CR>` keeps the
flat float; the two answer different questions.

**It assembles that itself.** The first implementation called
`auto-finder.views.repos.tree.open_diff`, which meant worktree reaching UP into
auto-finder — the inverse of the family's order
(auto-core ← worktree ← auto-finder). A soft `pcall` made that survivable, not
correct. The shared half moved DOWN into auto-core instead
(`auto-core.review.draft`, v0.2.22), and this now builds from parts worktree
already owns or already depends on:

| piece | from |
|---|---|
| files | `worktree.repos.diff` (ours) |
| annotations | `worktree.repos.reviews` + `worktree.review` (ours) |
| the draft | `auto-core.review.draft` (below us) |
| the render | `auto-core.ui.diffview` (below us) |

No `require("auto-finder")` on any path, and the suite proves it rather than
asserting it: `package.preload` for that module is poisoned to throw, so
anything still reaching for it errors instead of opening.

**The draft is shared.** Keyed `<slug>@<40-hex>` in auto-core's store, so an
annotation made from the graph is the SAME draft auto-finder's repos panel
sees. Annotate from the graph, submit from the panel; neither plugin needs the
other loaded to do its half. Annotate is disabled — with a reason — when the
repository has no remote identity, since a draft with no stable key would be
written where no reader could find it again.

Two fixes to the flat `<CR>` float while here:

- **Folding is set explicitly rather than inherited.** `syntax/git.vim` defines
  a fold region per `diff --git` block, and a new window copies fold options
  from whichever window was current — so the same commit could render expanded
  or as a column of one-line husks depending on where the reader was standing.
  The inherited values were measured, not guessed: `foldmethod=manual`,
  `foldlevel=0`. With `foldmethod=syntax` now set, `zM` / `za` also give
  per-file collapsing for free.
- **A swallowed `nvim_buf_set_lines` was an empty float with no error.** It
  throws on a line containing a newline or a NUL and the bare `pcall` discarded
  that. The failure is now logged and rendered in the float itself.

`f` / `F` keep their meaning here (fetch selected / fetch all). They mean file
navigation in the diff view, which is a different buffer, so there is no
collision — and the suite pins both so a regression cannot silently steal a
fetch key.

## [v0.5.10] — 2026-09-05 — CI on every PR, and a dependency guard that checks the symbol that broke

Patch. No public Lua surface changed.

**This repo now has an automated gate.** Until now every suite ran only
where someone happened to run it — which is how two of them came to be
aborting MID-RUN, reporting a clean-looking partial run rather than a
failure. `tests/run-all.sh` already catches that shape by treating a
missing summary line as a hard failure; CI supplies the environment and
lets the runner be the judge.

The workflow is deliberately shaped:

- **No branch-restoring step.** That step is the one thing that behaves
  differently per trigger entry — `actions/checkout` checks the branch
  out on `push` and detaches on `pull_request`, so `git branch --force
  main` exits 128 there — and an entry whose first firing is the merge
  cannot be witnessed beforehand. Removing the difference beats testing
  it.
- **`fetch-depth: 0` is required here**, unlike the sibling plugins:
  `adr0081-migration-gate` extracts the shipped v0.5.7 reader with
  `git show v0.5.7:lua/...`, so its frozen fixtures are proven against
  the real old code rather than an imitation of it. A shallow clone has
  neither the tag nor its blobs.
- **CI supplies a git identity**, because `repos.commit` shells out to
  git and is right to take the ambient one rather than invent one.
- **`install-deps.sh` asserts that auto-core can SERVE the request**,
  not merely that a checkout exists — the same `{file, symbol}`
  predicate the suite applies. A drift run rides auto-core's default
  branch, so a can't-serve auto-core is reachable by design, and this
  fails naming the missing symbol instead of aborting mid-suite.
- **The pin tradeoff is split rather than traded.** The gating job pins
  auto-core; a `drift` job resolves it at its default branch on schedule
  and manual dispatch only — never on push, where it would redden a
  merge for an upstream change unrelated to the PR.

**`tests/smoke.lua` binds to an auto-core that can answer.** The suite
picked a sibling by path existence alone, so a stale checkout won the
candidate list and the suite died on `attempt to call field 'unpushed'`
— on a machine where a perfectly good auto-core sat earlier in that very
list. Candidates are now matched by FILE AND SYMBOL, and the guard
carries BOTH dependencies the file's own comment names
(`git.log.unpushed` and `docstore.write_json`). Checking one of two
declared dependencies is how the first fix passed while observing the
wrong thing: docstore landed BEFORE unpushed, so auto-core `37d023d`
satisfies a docstore-only guard and still cannot serve.

*(Changelog note: `v0.5.9` shipped without an entry. This one does not
backfill it.)*

## [v0.5.8] — 2026-09-03 — ADR-0081: worktree delegates document I/O, keeps the git meaning

Patch. Every public function keeps its signature and its return
convention; the mechanics behind them moved.

**A gap to record rather than paper over:** this file's previous entry is
`v0.4.10`, and the tags between it and here — the whole `v0.5.x` line —
shipped without entries. They are in the git history; they are not
documented here. That is a real gap in this changelog, noted so the next
reader is not misled into thinking `v0.4.10` was the previous release.

### Changed

- **All document I/O now goes through `auto-core.docstore`** (ADR-0081
  §2.1). 32 raw filesystem calls in production code became 0, counted by
  a contract check rather than asserted. `store`'s leaf functions, the
  revision allocator, and `review`'s pair mechanics all delegate; worktree
  keeps what it owns — the review schema, `document` validation, the
  Markdown/JSON pairing choreography, the canonical filename grammar, and
  the ADR-0067 §2.3a delete contract.
- **No local fallbacks.** The old `io.open` paths beside the auto-core
  calls are gone. A missing hard dependency is a loud failure, because a
  fallback re-creates the duplicate implementation the move exists to
  delete — and the one it falls back to is always the weaker of the two.
  Removing them also revealed that two test suites had never had auto-core
  on their runtimepath at all: the fallback had been hiding it, so they
  were exercising a configuration no user runs.
- `LOCK_WAIT_MS` and `LOCK_POLL_MS` remain published here and are PASSED
  to auto-core on every call rather than copied, so setting them still
  drives both the retry loop and the figure quoted in a refusal.

### Added

- Commit nodes carry `pushed`: `true` on the remote, `false` local-only,
  and **`nil` when the read failed** — a third state, because reporting
  every commit as pushed because git errored is the panel asserting
  something nobody established. "Pushed" means pushed to `origin`, not
  reachable from any remote.
- `tests/adr0081-migration-gate.lua` — the ADR-0081 §3.1 gate, whose
  fixtures were produced by running the shipped `v0.5.7` writer and frozen
  as literals, and which EXECUTES the `v0.5.7` reader extracted from the
  git tag in a child process. **Verdict: no compatibility read path is
  needed** — filenames are byte-identical and old minified JSON decodes
  unchanged.
- `tests/adr0081-io-inventory.lua` — the AC1 contract check, pinning every
  raw filesystem call per file with a scope and a reason, failing on an
  increase *or* a decrease.

### Fixed

- `remove` validates the recorded `document` path before any unlink. A
  tampered review JSON could previously turn a delete into an **arbitrary
  file deletion**, and the same path reported success when only half the
  pair was gone.
- A **malformed** projection is no longer treated as one with a
  known-absent document. It was fenced, deleted, and reported as success
  with its Markdown still on disk. The projection is still removed — an
  unreadable record should not survive — but the document's fate is
  reported, and "left behind" is evidenced from the store's own filename
  rather than assumed.
- Reviews are written as pretty, stable-key-order JSON. A write-side
  change only; existing minified records decode unchanged.
- `describe` projects `reviewer_slug` and `repo`, without which the
  document validator cannot check the path it is handed.

## [v0.4.10] — 2026-06-14 — ADR-0041 Batch D: retire `git_legacy.lua`, auto-core is now a hard dependency

**Breaking (dependency policy):** `auto-core.nvim ≥ 0.1.58` is now a **hard
dependency**. The in-tree `git_legacy.lua` fallback (298 lines) — kept since
the v0.4.0 migration "for one minor release" per ADR-0007, long lapsed — has
been **removed**, and standalone (no-auto-core) operation is no longer
supported. The README has declared auto-core "required as of v0.4.0" since that
release and stated the fallback would retire; this completes that deprecation.
auto-core has been the canonical implementation since its v0.0.7, so installs
that already have it (every AutoVim setup) see **no behavior change**.

**What changed:**
- `git.lua` is now a thin facade: it delegates all 19 git APIs
  **unconditionally** to `auto-core.git.repo` / `auto-core.git.worktree` (the
  soft-dep probe + dispatcher indirection is gone), with a clear error if
  auto-core's git subsystem is somehow absent.
- The 4 worktree-local helpers that had no auto-core equivalent (`norm`,
  `has_uncommitted`, `run`, `run_with_stdin`) are **inlined into `git.lua`**
  verbatim — same signatures, same behavior. External
  `require("worktree.git").*` callers see an identical public surface.
- `lua/worktree/git_legacy.lua` deleted (−298 lines; net −~250 after the
  inlined helpers).

**Public API:** unchanged. `require("worktree.git").*` keeps every function and
signature; only the (undocumented) internal dispatcher and the deleted
`require("worktree.git_legacy")` module are gone.

**Tests.** Smoke `[2]` rewritten: the legacy-fallback masking dance (and its
`worktree.log` reload workaround) is removed; it now asserts the inlined
helpers work, that `parse_porcelain` delegates to auto-core, and that
`require("worktree.git_legacy")` fails. Suite: **62 passed / 2 failed** — the
2 are the pre-existing `ensure_root` macOS `/private/tmp` symlink-class
failures, unchanged.

## [v0.4.9] — 2026-06-14 — ADR-0041 Batches A+B+C: async graph preview, durable writes, correctness sweep

Implements the recommended batches from ADR-0041 (the worktree.nvim instalment
of the family enhancement programme; audit in the KB at
`shared/adrs/0041-worktree-structural-and-performance-enhancements.md`,
lector-reviewed in parallel). Batch D (`git_legacy.lua` retirement via an
auto-core hard dependency) is intentionally **not** in this release — it awaits
an explicit dependency-policy decision. Public API unchanged.

**Batch A — async commit-graph preview** *(redeems the deferred ADR-0038 D1
migration)* *(UX change)*: the graph's right-pane stat preview previously
called auto-core's **synchronous** `show_stat` on every (debounced) cursor
move — a cache miss froze the editor 100–500ms per commit. It now uses
`show_stat_async` (auto-core ≥ 0.1.58): a `(loading <hash> …)` placeholder
appears immediately and the stat fills in from the off-thread callback. A
generation counter guards cross-commit staleness (a slow response for an
earlier commit can't overwrite a newer preview). The `<CR>` commit-diff and the
range-diff float likewise moved to `show_diff_async`. Both fall back to the sync
API when auto-core predates the async surface (soft-dep version skew). Fixed the
range-diff's long-standing double-`git`-invocation (its own `TODO`): it now
opens the float with the lines it already fetched instead of discarding them and
re-running `git show` against a range label.

**Batch B — durable writes** (delegate-when-available under the current
soft-dep): `write_gitfile` — the `.git` pointer written during clone/init, whose
truncation breaks a worktree outright — and the per-worktree session file now
go through `auto-core.fs.atomic.write` (temp→fsync→rename) when auto-core ≥
0.1.58 is present, with the raw write kept only as the fallback. Session load
gained a type guard on the `focused` field (a corrupted/hand-edited non-string
value previously reached `filereadable` raw).

**Batch C — correctness sweep:**
- LSP-restart re-attach is now generation-stamped — two worktree switches inside
  the 150ms defer window previously raced, re-firing `FileType` (and thus LSP
  attach) against the *old* worktree's cwd. Only the newest scheduled re-attach
  runs.
- The graph's per-selection `CursorMoved` autocmd id is captured in state and
  deleted deterministically in `M.close()`, with an explicit augroup guard
  (correctness no longer rests on clear-before-add plus float teardown order).
- The file-tree refresh after a worktree switch logs a warning when both the
  `Neotree dir=` command and the `manager.refresh` fallback fail (was fully
  silent).
- The two diff-float window-option writes are explicit `nvim_set_option_value`
  scope-local (ADR-0028 hardening).
- `git_legacy.lua` gained the `vim.uv or vim.loop` compatibility fallback the
  rest of the codebase uses.

**Tests.** New smoke section `[9]` (+15 assertions): atomic gitfile content +
no temp strays; session save/load roundtrip (this module had **zero** coverage —
a Batch E head-start), malformed-JSON tolerance, the `focused` type guard;
scope-local diff-float options with global-default survival; and the async
commit-diff end-to-end against a real repo (float arrives via the main-loop
callback). Suite: **61 passed / 2 failed** — the 2 are the pre-existing
`ensure_root` macOS `/private/tmp` symlink-class failures, unchanged from the
v0.4.8 baseline of 46/2 (this release added 15 assertions, 0 regressions).

## [v0.4.8] — 2026-06-04 — workspace root pins a stable project identity

**Need**: the session-start capture pinned `core.workspace_root` to
the raw launch cwd (`getcwd(-1,-1)`). Per-project state keyed on
`sha256(core.workspace_root)` — auto-finder panel composition,
md-harpoon pins — therefore keyed DIFFERENTLY for every directory
nvim was launched from, so per-project config "vanished" when launched
from a sibling worktree or subdir.

**Change**: the VimEnter capture (`plugin/worktree.lua`) and
`M.ensure_root()` now resolve a stable project identity instead of
pinning the raw cwd. Precedence:

1. `WORKTREE_ROOT` env — explicit operator override (ignored unless a
   real directory).
2. `auto-core.fs.path.agent_workspace_root` — `.auto-agents/` →
   `.bare` → repo root → cwd. Collapses every worktree/subdir of one
   project to a single identity.
3. raw cwd — legacy fallback when auto-core isn't installed.

The live VimEnter path previously bypassed `ensure_root()` and pinned
the raw cwd directly; it now routes through `ensure_root()` (which
carries its own already-set guard, so the capture stays idempotent).

**Requires** auto-core ≥ v0.1.56 for the `agent_workspace_root`
resolver; older auto-core or no auto-core degrades cleanly to the
raw-cwd fallback. Added `M._reset_root_for_tests()`.

**Back-compat**: launched from a project root the result is unchanged
(the root already equals the resolved identity); only subdir/worktree
launches change — to the more correct project root. A non-project
launch (e.g. `~/`) stays the raw cwd. Smoke `[ensure_root]` +3
assertions; suite green at 45 passed, 0 failed.

## [v0.4.6] — 2026-05-16 — ADR 0021 Phase 2 wrapper

Internal refactor. No user-facing behavior changes — every existing
notify in `worktree.nvim` now flows through `lua/worktree/log.lua`
so the auto-core ring captures the entry for `:AutoCoreLog`
triage. Toast surface is unchanged at every call site.

### Added — `lua/worktree/log.lua`

Per ADR 0021 §6, every auto-family plugin owns one
`lua/<plugin>/log.lua` that delegates to `auto-core.log`. Feature
code in worktree.nvim now calls `require("worktree.log")`
exclusively; `auto-core.log` is reachable only through the
wrapper.

Exposes:

```lua
local log = require("worktree.log")

log.error / .warn / .info / .debug / .trace  -- with worktree.* component prefix
log.notify(msg, opts?)                        -- force-toast single emission
log.notifyIf(event, msg, opts?)               -- toast iff event subscribed
log.register_events(events)                   -- declare at setup
log.is_level_enabled(name)                    -- predicate
```

Soft-dep tolerant: when running against an auto-core older than
v0.1.11 (no `notify` / `notifyIf` / `events.register`), the
wrapper degrades to ring-only emissions and bare `vim.notify`
fallbacks instead of crashing. The pre-existing
`config.options.notify_title` is honored by the legacy fallback
path so users without auto-core keep the v0.4.x title behavior.

### Changed — routed three notify call sites through the wrapper

- `lua/worktree/init.lua` — the `notify` helper used by 30+ call
  sites now delegates to `worktree.log.<level>`. Signature
  unchanged (`notify(msg, level?)`).
- `lua/worktree/graph.lua` — the `notify` helper used by 45 call
  sites now delegates to `worktree.log.<level>` with component
  `graph`. Signature unchanged.
- `lua/worktree/git.lua` — the direct
  `pcall(vim.notify, "worktree.nvim: auto-core.nvim not installed; …")`
  fallback warning now routes through `worktree.log.warn("git",
  …)`. The wrapper's own pre-auto-core fallback path delivers
  the toast in that case.

### Tests

`tests/smoke.lua` 42 passed, 0 failed. No new assertions — this
is a routing change with byte-identical observable behavior at
every call site that flowed through the two `notify()` helpers.

### Migration

Soft. Consumers pin via `version = "^0.4.0"` and auto-update.
The wrapper soft-deps against pre-Phase-1 auto-core so consumers
can stage the upgrade in any order.

## [v0.4.5] — 2026-05-14 — graph: tighten remote-branch row label

Cosmetic. Remote-branch rows in the graph's left pane drop the
verbose `[rt-branch]` prefix and use parentheses instead:

```text
before:  └─ [rt-branch] origin/main
after:   └─ (origin/main)
```

The `origin/` prefix already telegraphs "this is a remote ref" —
the prior `[rt-branch]` label was redundant and ate ~12 columns of
the left pane on every remote row. Parens keep the row visually
distinguishable from worktree rows (which render as
`<branch> @<sha7>`) without the prefix tax.

## [v0.4.4] — 2026-05-14 — remote branch management in the graph dashboard

Feature. Pairs with `auto-core.nvim` v0.1.6 which ships the underlying
git primitives (`git.repo.checkout`, `git.repo.delete_remote`,
`git.repo.create_branch`, `git.worktree.list_remote_branches`,
`git.worktree.track`, `git.worktree.create`).

### Added

- **`R`** in the graph's repo pane toggles remote-branch visibility.
  When on, each repo's selected entry expands with its tracked
  remote refs (excluding `origin/HEAD` pseudo-refs) rendered as
  `└─ [rt-branch] origin/feature-x` rows.
- **`C`** (Checkout) on a remote-branch row:
  - bare repo → prompts for `local-branch-name` + `worktree-path`,
    then `git worktree add --track -b <local> <path> <remote-ref>`.
  - non-bare repo → probes via the new
    `git.checkout_status(path, branch)` and refuses if the branch
    is already checked out in another worktree, the working tree is
    dirty, or the path isn't a git repo — then runs `git checkout
    <branch>`.
- **`W`** (new branch/worktree) on either a worktree row or a
  remote-branch row, deriving the base ref from the cursor target:
  - bare repo → prompts for branch name + path, then `git worktree
    add -b <name> <path> <base>`.
  - non-bare repo → prompts for branch name, then `git checkout -b
    <name> <base>` (refusing on uncommitted changes).
- **`D`** (existing destroy keybind) now overloads to also delete
  remote branches when the cursor sits on a remote-branch row.
  `vim.ui.select` confirmation; on accept, `git push <remote>
  --delete <branch>` followed by a `git fetch --prune` so the
  visible remote tracking ref disappears from the UI. Worktree
  destruction semantics unchanged on worktree rows.

### Notes

- Callback contract: all async wrappers consume the unified
  `on_done(res)` table shape (`res.ok :: boolean`, `res.stderr ::
  string?`) — matches the auto-core primitives. The legacy two-arg
  callback form has been retired from this module.
- Footer hint updated to `D destroy wt/remote` to reflect the
  overload.

## [v0.4.3] — 2026-05-11 — remove max_width constraint from graph dashboard

Bug fix. Removed the hardcoded `max_width = 240` from the graph panel's
outer container. The previous percentage-based inner pane fix was constrained
by this outer limit, preventing the panel from utilizing the full width
of ultrawide monitors.

## [v0.4.2] — 2026-05-11 — responsive layout for the graph dashboard

Improvement. The multi-repo graph dashboard (`<leader>gt`) now uses
percentage-based widths (0.15 for the repo list, 0.40 for the diff
preview) so the layout scales proportionally on ultrawide monitors.
Requires `auto-core.nvim` v0.1.4+.

## [v0.4.1] — 2026-05-11 — worktree mutations now publish events

Bug fix. The multi-repo graph dashboard (`<leader>gt`) reads its repo
list from `auto-core.git.graph.fan_out`, which caches per
`workspace_root` and only invalidates on `worktree:added` /
`worktree:removed` / `worktree:switched` events. v0.4.0 published only
`worktree:switched` (from `M.pick` / `M.home`); the four mutation
paths that change the worktree topology were silent:

- `M.clone()` (`<leader>gC`) — bare-clones + initial worktree
- `M.init()` (`<leader>gc`) — `git init --bare` + initial worktree
- `M.add()` (`<leader>gA`) — `git worktree add` (all four sub-flows)
- `M.remove()` (`<leader>gR`) — `git worktree remove`

Result: cloning or adding a repo via the worktree.nvim commands did
not show up in the graph dashboard until the user ran
`:WorktreeGraphRefresh` (or `r` from the open panel).

### Changed

- `worktree.nvim` now publishes `worktree:added` after every
  successful worktree-creating path (clone, init, add tracking,
  add checkout_local, add from_base) and `worktree:removed` after a
  successful `M.remove()`. Payload: `{ path = string }`.
- `worktree.graph.open()` now calls
  `auto-core.git.graph.invalidate_fan_out(state.root)` on every UI
  entry. Even if the user runs `git clone` or `git worktree add` from
  another terminal, the next `<leader>gt` re-scans the workspace
  and picks up the new repo. The cost is one directory walk per open
  (sub-100ms for a typical workspace; the existing per-repo
  `git rev-parse` / `git status` caches are unchanged).

### Notes for consumers

`worktree:added` and `worktree:removed` were already wired as
subscribers in `auto-core.git.graph`; this release simply starts
firing them. Any other plugin that wants to react to topology
changes can subscribe to the same topics. Topic registry entries in
auto-core's `events/topics.lua` will land in a doc-only follow-up.

## [v0.4.0] — 2026-05-10 — auto-core consumer + absorbed graph dashboard

First release on top of [`auto-core.nvim`](https://github.com/yongjohnlee80/auto-core.nvim)
(`^0.1.0`), and the home of the multi-repo graph dashboard absorbed
from the now-archived
[`gitsgraph.nvim`](https://github.com/yongjohnlee80/gitsgraph.nvim)
(ADR 0007).

### Added

- **Hard dependency on `auto-core ^0.1.0`** — provides the canonical
  `git.worktree` parsers, the multi-pane float primitive
  (`ui.float.multi`), the workspace-root state surface, the tech-
  stack-aware LSP reset on switch, and the `git.fetch` / `git.pull` /
  `git.worktree.destroy` mutating ops. The legacy in-tree
  `git_legacy.lua` fallback retires after one minor release.
- **Multi-repo graph dashboard** (`worktree.graph`, `:WorktreeGraph`,
  `<leader>gt`). One floating panel with three panes:
  - **Left** — numbered repo picker (`1`..`9`); selected repo
    expands to show its worktrees as `├─` / `└─` sub-rows with
    branch label and 7-char HEAD short SHA.
  - **Middle** — [`isakbm/gitgraph.nvim`](https://github.com/isakbm/gitgraph.nvim)
    commit graph for the selected repo. `<CR>` on a commit opens the
    full unified diff in a top-zindex float.
  - **Right (preview)** — `git show --stat` for the cursor commit,
    cached per (repo, sha).
  - **Footer** — key-hint strip.
  - **Tab** / **`<C-h>`** / **`<C-l>`** cycle pane focus. `q` /
    `<Esc>` close from any pane.
- **Cursor-aware action keymaps** in the graph view:
  - `f` fetch the selected repo (notify on completion; `⟳` indicator
    while in flight).
  - `F` fetch every repo, sequentially.
  - `p` **context-aware pull**. Cursor on a repo row → fetch + pull
    every worktree of that repo. Cursor on a worktree row → fetch +
    pull just that worktree. Non-left pane → falls back to the
    selected repo.
  - `D` destroy worktree + local branch (left pane, worktree row only).
  - `r` rescan (drops `auto-core.git.graph` caches and re-fans-out).
- **Consultative round-trip pattern.** Auto-core's `git.fetch` /
  `git.pull` / `git.worktree.destroy` never prompt the user. The
  graph consumer probes status (`pull_status`, `worktree_dirty`),
  prompts via `vim.ui.select` on conflict / dirty, and only retries
  with `mode = "reset"` / `opts.force = true` on confirmation. Same
  prompt UX as the original gitsgraph for muscle-memory parity.
- **`worktree:switched` event.** Every successful switch publishes on
  `auto-core.events`, so siblings (auto-finder repos panel,
  statusline integrations, future agent-side notifiers) refresh
  without polling. Payload: `{ from, to, cwd }`.
- **Standard auto-core git topics** fire on every graph mutation:
  `core.git.fetch:started/completed`, `core.git.pull:started/completed`,
  `core.git.worktree:destroyed`.
- **Tech-stack-aware LSP reset on switch.** Workspace-rooted LSPs are
  stopped only if their detected stack matches the new path's stack
  (`go.mod`, `package.json`, `pyproject.toml`, `Cargo.toml`,
  `lazy-lock.json`, `build.zig`, …). A Go-only switch no longer
  restarts `ts_ls`. Polyglot dirs union the matched stacks. Existing
  `lsp_servers_to_restart` is honored as `extra_servers` (additive).
- **Smoke test driver** at `tests/smoke.lua` (32/0 pass).

### Changed

- **`worktree.git` is now a thin dispatcher.** Parsing, listing, and
  worktree discovery delegate to `auto-core.git.worktree`. The
  pre-migration code lives at `worktree.git_legacy` as a one-minor
  fallback before retirement.
- **Workspace-root through auto-core.** `M.workspace_root()` reads
  `auto-core.git.worktree.get_workspace_root()` directly with a cwd
  fallback when nil.
- **`plugin/worktree.lua`** captures the workspace root eagerly when
  worktree.nvim loads post-VimEnter (lazy plugin spec). Without this,
  the original VimEnter autocmd never fires for lazy-loaded plugins
  and `workspace_root()` returns nil.

### Fixed

- `q` / `<Esc>` close from the middle (gitgraph) pane: gitgraph
  creates its own buffer per draw, so the close stamps from the
  initial scratch buffer were lost. `bind_pane_action_keys` now
  re-runs after every gitgraph draw.
- Tab / `<C-h>` / `<C-l>` from the preview pane: action keys are now
  bound on the preview buffer at open.
- `:WorktreeGraph` "concatenate field 'root' (a nil value)":
  `workspace_root()` returned nil when called before the eager
  capture; added an explicit cwd fallback.

### Migration notes

- Update your lazy.nvim spec to depend on `auto-core.nvim` and
  optionally `isakbm/gitgraph.nvim`:
  ```lua
  {
    "yongjohnlee80/worktree.nvim",
    dependencies = {
      "yongjohnlee80/auto-core.nvim",
      "isakbm/gitgraph.nvim",  -- optional; only for :WorktreeGraph
    },
  }
  ```
- No public API renames. Existing `pick` / `home` / `add` / `remove` /
  `clone` / `init`, the `worktree:switched` event, the lualine
  component, and per-worktree buffer memory all keep their shape.
- `gitsgraph.nvim` is **archived**; replace any
  `<leader>gG` → `gitsgraph` keymaps with
  `<leader>gt` → `require("worktree").graph.toggle()`.

## [v0.3.1] — Per-worktree buffer memory: lightweight JSON tracker

Swapped the `folke/persistence.nvim` backing for a home-grown
JSON-per-cwd tracker. Same option name, same opt-in semantics —
quieter behavior. Existing window layouts no longer get clobbered on
every switch.

## [v0.3.0] — Per-worktree buffer memory (initial impl)

Opt-in restore of file-buffer lists across `:WorktreePick` /
`:WorktreeHome`. Initial implementation via `folke/persistence.nvim`.

## [v0.2.x] — Branch-collision UX, clone/init scaffolding, neo-tree refresh

(See git tags `v0.2.0` … `v0.2.3` for incremental notes.)

## [v0.1.0] — Initial release

Switch / add / remove worktrees with safety rails.
