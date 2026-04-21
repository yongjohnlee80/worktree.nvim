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

  -- When switching worktrees (pick/home), close unmodified buffers that
  -- live under the OLD worktree path but NOT under the new one. Fixes two
  -- related issues that bite when buffers outlive a switch:
  --   * neo-tree's `follow_current_file` snaps the tree back to the old
  --     worktree when the current window is still showing an old buffer.
  --   * Stale LSP diagnostics from the old workspace keep rendering in
  --     the new tree / sign column.
  -- Modified buffers are always left intact and reported in a notification
  -- so unsaved work never disappears silently.
  cleanup_on_switch = true,

  -- Directory name that holds the bare repo for projects created by
  -- :WorktreeClone / :WorktreeInit. Two conventions in the wild:
  --   ".bare"  (default) -- bare lives in .bare/, .git is a gitfile pointing
  --                        at it. Canonical pattern in most worktree guides.
  --   ".git"             -- bare lives directly in .git/ (clone --bare <url>
  --                        .git style). No gitfile written; core.bare = true
  --                        tells git the dir is bare.
  -- Detection handles both regardless of this setting -- only new projects
  -- you scaffold via this plugin are affected.
  bare_dir = ".bare",
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
