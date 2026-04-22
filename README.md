# worktree.nvim

> *Search no more — the Neovim worktree plugin you've all been waiting
> for. Switches, adds, removes, refuses to nuke your unsaved work, and
> doesn't leave ghost buffers haunting the next session.*

Switch between git worktrees that live as children of a single root
directory, plus add and remove worktrees with safety rails. No hard
dependencies -- just Neovim (≥ 0.10 for `vim.system`) and `git`.

Built for the "bare repo with sibling worktrees" layout:

```
~/Source/Projects/
├── repo-a/
│   ├── .bare/        # bare repo
│   ├── main/         # worktree on main
│   └── feature-x/    # worktree on feature-x
└── repo-b/
    └── ...
```

...but also works with regular `.git` repos and classic `repo.git` bare
repos.

## What it does

- **Switch worktree** -- fan out all worktrees reachable from your root
  into a `vim.ui.select` picker; picking one `:cd`s the global cwd.
- **Back to root** -- hop back to the directory nvim was originally
  opened in.
- **Add worktree** -- prompts for name + base branch and runs
  `git worktree add -b <name> <path> <base>`. If you're already inside a
  repo, repo selection is skipped. When the name collides with an
  existing remote-tracking branch (`origin/<name>`), asks whether to
  **track** it, **shadow** with a fresh local branch from a base, or
  cancel -- prevents the silent footgun of branching away from the
  remote by accident.
- **Clone repo** -- prompts for a git URL + destination name (defaults
  derived from the URL), clones as a bare in `<root>/<name>/.bare`, fixes
  the fetch refspec so `origin/*` refs populate, writes a `.git` gitfile
  pointer, and checks out an initial worktree on the default branch.
  Refuses if you're already inside a git repo.
- **Init project** -- prompts for a project name, scaffolds a fresh
  bare+worktree layout under `<root>/<name>/` with an empty initial
  commit on `main` and a ready-to-use `main` worktree. Refuses if you're
  already inside a git repo.
- **Remove worktree** -- pick from the list of reachable worktrees, with
  two safety checks (uncommitted disk changes via `git status --porcelain`
  and unsaved buffer modifications). After removal, any buffer pointing
  at a file inside the removed worktree is force-closed so you don't get
  ghost buffers. Optionally deletes the matching branch too.
- **Workspace LSP re-anchor** -- workspace-rooted LSPs (opt in: e.g.
  `gopls`, `rust_analyzer`, `pyright`) are stopped + restarted on switch
  so `root_dir` resolves against the new cwd.
- **neo-tree refresh** -- if neo-tree's filesystem window is visible, it
  re-anchors at the new cwd after every switch / mutation. No-op
  otherwise.

Terminal buffers keep their own pwd -- they're independent child
processes that inherited cwd at spawn time, and a global `:cd` doesn't
retroactively change them.

## Quick start

Minimal [lazy.nvim](https://github.com/folke/lazy.nvim) spec -- no config
needed, zero external deps:

```lua
{
  "yongjohnlee80/worktree.nvim",
  event = "VeryLazy",
  opts = {},
  keys = {
    { "<leader>gw", function() require("worktree").pick() end,   desc = "Worktree: switch" },
    { "<leader>gW", function() require("worktree").home() end,   desc = "Worktree: back to root" },
    { "<leader>gA", function() require("worktree").add() end,    desc = "Worktree: add" },
    { "<leader>gR", function() require("worktree").remove() end, desc = "Worktree: remove" },
    { "<leader>gC", function() require("worktree").clone() end,  desc = "Worktree: clone" },
    { "<leader>gc", function() require("worktree").init() end,   desc = "Worktree: init new project" },
  },
}
```

Realistic spec with LSP + statusline + neo-tree integration:

```lua
{
  "yongjohnlee80/worktree.nvim",
  event = "VeryLazy",
  opts = {
    -- Restart these servers on :cd so root_dir re-resolves against the
    -- new worktree. Pick whatever matches your stack.
    lsp_servers_to_restart = { "gopls", "rust_analyzer", "pyright" },
  },
  keys = {
    { "<leader>gw", function() require("worktree").pick() end,   desc = "Worktree: switch" },
    { "<leader>gW", function() require("worktree").home() end,   desc = "Worktree: back to root" },
    { "<leader>gA", function() require("worktree").add() end,    desc = "Worktree: add" },
    { "<leader>gR", function() require("worktree").remove() end, desc = "Worktree: remove" },
    { "<leader>gC", function() require("worktree").clone() end,  desc = "Worktree: clone" },
    { "<leader>gc", function() require("worktree").init() end,   desc = "Worktree: init new project" },
  },
}
```

[packer.nvim](https://github.com/wbthomason/packer.nvim):

```lua
use {
  "yongjohnlee80/worktree.nvim",
  config = function() require("worktree").setup() end,
}
```

## Commands

| Command            | Function                                   |
|--------------------|--------------------------------------------|
| `:WorktreePick`    | Pick a worktree, `:cd` to it               |
| `:WorktreeHome`    | `:cd` back to root                         |
| `:WorktreeAdd`     | Create a new worktree                      |
| `:WorktreeRemove`  | Remove a worktree                          |
| `:WorktreeClone`   | Clone a remote into a bare+worktree layout |
| `:WorktreeInit`    | Init a new project in the same layout      |

## Configuration

All options are optional. Defaults:

```lua
require("worktree").setup({
  -- Directory containing your repos. nil = capture the global cwd at
  -- VimEnter (usually what you want).
  root = nil,

  -- Workspace-rooted LSPs to stop + restart on switch so root_dir
  -- re-resolves. Empty by default -- opt in with the servers you
  -- actually use. Common ones: "gopls", "rust_analyzer", "pyright",
  -- "tsserver", "lua_ls". Leave {} to skip the LSP dance entirely.
  lsp_servers_to_restart = {},

  integrations = {
    neotree = true,     -- re-anchor the neo-tree filesystem source after :cd
    lsp = true,         -- restart workspace LSPs after :cd
    persistence = false, -- per-worktree session save/load via folke/persistence.nvim
  },

  notify_title = "worktree",

  -- When switching worktrees (pick/home), close UNMODIFIED file-buffers
  -- that live under the old worktree but not under the new one. Fixes
  -- neo-tree's `follow_current_file` snapping back to the old worktree
  -- when the current window is still showing an old buffer, plus stale
  -- LSP diagnostics from the old workspace rendering in the new tree.
  -- Modified buffers are always left intact and surfaced in a warning
  -- notification so unsaved work never disappears silently.
  cleanup_on_switch = true,

  -- Directory holding the bare repo for new projects scaffolded by
  -- :WorktreeClone / :WorktreeInit. Two common conventions:
  --   ".bare"  (default) -- bare lives in .bare/, .git is a gitfile pointing
  --                        at it. Canonical in most bare+worktree guides.
  --   ".git"             -- bare lives directly in .git/ (core.bare = true).
  --                        Simpler, no gitfile. What you get from
  --                        `git clone --bare <url> .git`.
  -- Detection supports both regardless of this setting; only new projects
  -- scaffolded by this plugin are affected.
  bare_dir = ".bare",
})
```

## Integrations

### LSP servers

Workspace-rooted language servers cache their `root_dir` at first attach.
After `:cd` into a different worktree they keep resolving against the old
one, which means go-to-definition and workspace diagnostics point at the
wrong files. The plugin fixes this by stopping the configured servers
after every switch and re-firing `FileType` so lspconfig relaunches them
against the new cwd.

List the servers you actually run (empty list = opt out entirely):

```lua
require("worktree").setup({
  lsp_servers_to_restart = { "gopls" },                    -- Go-only
  -- lsp_servers_to_restart = { "rust_analyzer" },         -- Rust-only
  -- lsp_servers_to_restart = { "gopls", "pyright",        -- polyglot
  --                            "tsserver", "rust_analyzer" },
})
```

Disable the whole LSP dance with `integrations.lsp = false`.

### neo-tree

If [neo-tree.nvim](https://github.com/nvim-neo-tree/neo-tree.nvim)'s
filesystem source is visible when you switch/add/remove a worktree, it
gets re-anchored at the new cwd automatically. No configuration needed --
the integration is detected at runtime via `pcall(require, ...)` and
silently no-ops when neo-tree isn't installed.

Disable with `integrations.neotree = false` if you use a different file
explorer.

### lualine

The plugin exposes a ready-made component that renders the current repo
name and a `(wt)` marker when you're inside a linked worktree. Drop it
into any lualine section next to the stock `branch` component:

```lua
require("lualine").setup({
  sections = {
    lualine_b = {
      require("worktree").lualine_component,
      "branch",
    },
  },
})
```

For custom rendering, use the lower-level API:

```lua
-- Returns { cwd, repo, is_worktree }, cached per-cwd so it's safe to
-- call on every statusline redraw.
local s = require("worktree").status()

-- Just the boolean:
if require("worktree").is_linked_worktree() then ... end
```

### Per-worktree buffer memory

Opt-in integration that gives each worktree its own remembered set of file-buffers across switches, without touching your neo-tree / terminal / dap-view panels. Enable it with:

```lua
require("worktree").setup({
  integrations = { persistence = true },
})
```

When enabled, every `:WorktreePick` / `<leader>gw` and `:WorktreeHome` / `<leader>gW` does:

1. Snapshots the list of normal file-buffers under the OLD cwd to `~/.local/state/nvim/worktree-sessions/<hash>.json` (file paths + the currently focused file — nothing else).
2. `:cd` into the target worktree.
3. Runs `cleanup_on_switch` as usual (closes stale buffers).
4. `:badd`s every saved buffer for the NEW cwd (if a snapshot exists) so they show up in `:ls`, your buffer picker, and `:bnext`/`:bprev`. If the current window is a blank no-name buffer (what cleanup leaves you on when the new worktree has no existing open files), the last-focused file is `:edit`ed into it.

**What's preserved vs not.** Restore only touches the buffer list. Ad-hoc panels — neo-tree, `:terminal`, dap-view, whatever splits you had open — stay exactly where they were. No `:source session.vim`, no window layout replay.

First visit to a worktree has no snapshot → step 4 is a silent no-op. Every subsequent return replays what you had loaded last time. The notification on switch appends `(restored N buffer(s))` when a snapshot was actually read.

**Pairs best with `cleanup_on_switch = true`** (default) so the old worktree's buffers are gone before the new worktree's get `:badd`ed, keeping the buffer list tidy.

Snapshots for a removed worktree are deleted automatically when you `<leader>gR` that worktree, so stale JSON files don't accumulate.

> *History:* v0.3.0 implemented this via [folke/persistence.nvim](https://github.com/folke/persistence.nvim), which clobbered existing window layouts on every switch. v0.3.1 swapped the backing to a home-grown JSON-per-cwd tracker to fix that — same option name, same opt-in semantics, quieter behavior.

## How worktree paths are chosen

New worktrees are placed at `<parent-of-git-common-dir>/<name>`:

| common-dir layout      | new worktree path          |
|------------------------|----------------------------|
| `/foo/repo/.bare`      | `/foo/repo/<name>`         |
| `/foo/repo/.git`       | `/foo/repo/<name>`         |
| `/foo/repo.git`        | `/foo/<name>`              |

Branch name = worktree name (via `git worktree add -b`). If that's not
what you want, pass `-b` yourself with `:!git worktree add ...`.

## Branch-name collisions on add

`git worktree add -b <name>` silently does the wrong thing when the name
is already taken: it errors if a local branch exists, and it *doesn't*
error if only a remote exists (instead creating a fresh local branch
disconnected from `origin/<name>`). The plugin detects both cases up
front and asks what you want to do. The options shown depend on the
kind of collision:

| Existing branch | Worktree for it? | Options shown                                                |
|-----------------|------------------|--------------------------------------------------------------|
| None            | —                | (no prompt) create new from base                             |
| Local only      | No               | Check out local / Shadow with new branch / Cancel            |
| Remote only     | —                | Track `<remote>/<name>` / Shadow / Cancel                    |
| Both            | Local has none   | Check out local / Track each remote / Shadow / Cancel        |
| Local only      | **Yes**          | Hard error — git refuses two worktrees on the same branch    |

**Action details:**

- **Check out existing local** — runs `git worktree add <path> <name>`
  (no `-b`), so the new worktree uses the existing branch as-is.
- **Track `<remote>/<name>`** — runs
  `git worktree add --track -b <name> <path> <remote>/<name>`, so the
  new local branch tracks the remote. Multiple remotes with the same
  branch name each get their own track option.
- **Shadow with new branch** — falls through to the base-branch prompt
  and runs `git worktree add -b <name> <path> <base>`. Creates a fresh
  branch independent of any existing one. Only the right choice when
  you genuinely want to start over under the same name.
- **Cancel** — no-op.

## Clone / init layout

`<leader>gC` (`:WorktreeClone`) and `<leader>gc` (`:WorktreeInit`) both
scaffold a bare+worktree layout under the plugin's root directory. The
exact shape depends on `bare_dir` (see [Configuration](#configuration)):

```
# bare_dir = ".bare"  (default)
<root>/
└── <name>/
    ├── .bare/        # bare repository
    ├── .git          # gitfile: "gitdir: ./.bare"
    └── <branch>/     # initial worktree

# bare_dir = ".git"
<root>/
└── <name>/
    ├── .git/         # bare repository (core.bare = true)
    └── <branch>/     # initial worktree
```

Detection (switching, adding, removing worktrees) works regardless of
which layout a given project uses -- the plugin's `is_git` check treats
`.git` as either a dir (regular repo or bare-as-git) or a file (gitfile
pointing at a sibling bare). You can mix conventions across projects
under the same root without issues; `bare_dir` only controls what gets
created for *new* projects.

Both commands refuse to run if your cwd is already inside a git repo --
they want to land at the root, not nest repos inside each other.
`<leader>gW` first if you need to hop back.

For init, an empty initial commit on `main` is seeded via plumbing
(`hash-object` → `commit-tree` → `update-ref`) because `git worktree
add` needs a ref to check out and a fresh `--bare` has none.

## Safety rails on remove

`<leader>gR` (or `:WorktreeRemove`) refuses to proceed if either:

1. `git status --porcelain` on the target worktree reports any changes
   (staged, unstaged, or untracked).
2. Any loaded buffer under the target path has nvim's `modified` flag
   set (unsaved edits that `git status` can't see).

After a successful remove:

- Every buffer whose file lived under the removed path is force-closed
  via `nvim_buf_delete(..., { force = true })` -- prevents ghost buffers.
- If the worktree was on a branch (not detached HEAD), you're asked
  whether to also delete the branch via `git branch -D`.

The currently-active worktree is excluded from the remove picker
entirely.

## License

MIT.
