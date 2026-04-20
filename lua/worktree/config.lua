local M = {}

M.defaults = {
  -- Root directory containing your repos (or worktrees).
  -- When nil, the plugin captures the global cwd at VimEnter.
  root = nil,

  -- Workspace-rooted LSP servers that need restarting on cwd switch so
  -- they re-resolve root_dir against the new worktree. Empty by default --
  -- opt in with the servers you actually use, e.g.
  --   { "gopls" }, { "rust_analyzer" }, { "gopls", "pyright" }.
  lsp_servers_to_restart = {},

  integrations = {
    -- Re-anchor the neo-tree filesystem source after :cd and worktree
    -- mutations. Silently no-ops if neo-tree isn't installed.
    neotree = true,
    -- Stop+restart workspace LSPs after :cd.
    lsp = true,
  },

  -- Notification title. Set to false to let vim.notify use its own default.
  notify_title = "worktree",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
