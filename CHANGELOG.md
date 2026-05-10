# Changelog

All notable changes to `worktree.nvim` are documented here.

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
