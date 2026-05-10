-- worktree.nvim -- plugin entry. Registers user commands and lazily
-- captures the startup cwd as the default "root" so require-order doesn't
-- matter. User config / keymaps live in the user's setup(opts) call.

if vim.g.loaded_worktree == 1 then return end
vim.g.loaded_worktree = 1

local function user_cmd(name, fn, desc)
  vim.api.nvim_create_user_command(name, function()
    require("worktree")[fn]()
  end, { desc = desc })
end

user_cmd("WorktreePick", "pick", "Worktree: switch")
user_cmd("WorktreeHome", "home", "Worktree: back to root")
user_cmd("WorktreeAdd", "add", "Worktree: add")
user_cmd("WorktreeRemove", "remove", "Worktree: remove")
user_cmd("WorktreeClone", "clone", "Worktree: clone a remote into a bare+worktree layout")
user_cmd("WorktreeInit", "init", "Worktree: init a new project in a bare+worktree layout")

-- ADR 0007 Phase 3: multi-repo graph view absorbed from gitsgraph.
-- `:WorktreeGraph` toggles the panel; `:WorktreeGraphRefresh` drops
-- caches and re-fans-out under the workspace root.
vim.api.nvim_create_user_command("WorktreeGraph", function()
  require("worktree").graph.toggle()
end, { desc = "Worktree: toggle multi-repo graph view" })
vim.api.nvim_create_user_command("WorktreeGraphRefresh", function()
  require("worktree").graph.refresh()
end, { desc = "Worktree: refresh graph view (drops caches)" })

-- Capture the startup cwd as the workspace root.
--
-- Two paths because lazy.nvim can source plugin/ either BEFORE
-- VimEnter (eager spec) or AFTER (lazy on event/cmd/keys). For the
-- eager case, register a VimEnter autocmd. For the lazy case, run
-- immediately — `vim.v.vim_did_enter` is set once VimEnter fired,
-- so we know our autocmd above will never trigger and capture now
-- instead. ensure-root is idempotent (no-op if already set).
local function _ensure_root_now()
  local wt = require("worktree")
  if not wt.get_root() then wt.set_root(vim.fn.getcwd(-1, -1)) end
end

if vim.v.vim_did_enter == 1 then
  -- Lazy-loaded post-VimEnter: capture immediately. Without this,
  -- worktree.set_workspace_root never fires (the VimEnter autocmd
  -- below registers a handler for an event that already happened),
  -- which leaves auto-core's core.workspace_root nil and starves
  -- every consumer (auto-finder repos panel, md-harpoon's per-
  -- project pin keying, etc.) of the canonical workspace key.
  _ensure_root_now()
else
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = _ensure_root_now,
  })
end
