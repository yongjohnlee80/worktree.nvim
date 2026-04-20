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
  repo, repo selection is skipped.
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

| Command            | Function                      |
|--------------------|-------------------------------|
| `:WorktreePick`    | Pick a worktree, `:cd` to it  |
| `:WorktreeHome`    | `:cd` back to root            |
| `:WorktreeAdd`     | Create a new worktree         |
| `:WorktreeRemove`  | Remove a worktree             |

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
    neotree = true, -- re-anchor the neo-tree filesystem source after :cd
    lsp = true,     -- restart workspace LSPs after :cd
  },

  notify_title = "worktree",
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

## How worktree paths are chosen

New worktrees are placed at `<parent-of-git-common-dir>/<name>`:

| common-dir layout      | new worktree path          |
|------------------------|----------------------------|
| `/foo/repo/.bare`      | `/foo/repo/<name>`         |
| `/foo/repo/.git`       | `/foo/repo/<name>`         |
| `/foo/repo.git`        | `/foo/<name>`              |

Branch name = worktree name (via `git worktree add -b`). If that's not
what you want, pass `-b` yourself with `:!git worktree add ...`.

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
