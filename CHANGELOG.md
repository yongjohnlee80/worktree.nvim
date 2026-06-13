# Changelog

All notable changes to `worktree.nvim` are documented here.

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
