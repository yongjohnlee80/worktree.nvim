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

vim.api.nvim_create_autocmd("VimEnter", {
  once = true,
  callback = function()
    local wt = require("worktree")
    if not wt.get_root() then wt.set_root(vim.fn.getcwd(-1, -1)) end
  end,
})
