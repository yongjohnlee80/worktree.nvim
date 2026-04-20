-- worktree.nvim -- switch between git worktrees that live as children of a
-- root directory, plus add/remove worktrees with safety rails.
--
-- No hard external dependencies. Integrates optionally with neo-tree
-- (refreshing the file tree after switches/mutations) and workspace-rooted
-- LSP servers (stop+restart so root_dir re-resolves against the new cwd).

local config = require("worktree.config")
local git = require("worktree.git")
local buffers = require("worktree.buffers")

local M = {}

local captured_root = nil

local function notify(msg, level)
  local opts = {}
  if config.options.notify_title then opts.title = config.options.notify_title end
  vim.notify(msg, level or vim.log.levels.INFO, opts)
end

function M.set_root(path)
  captured_root = git.norm(path)
end

function M.get_root()
  return captured_root
end

-- Capture the startup cwd lazily. Called by plugin/worktree.lua on VimEnter
-- if the user hasn't already configured a root via setup().
function M.ensure_root()
  if captured_root then return captured_root end
  M.set_root(vim.fn.getcwd(-1, -1))
  return captured_root
end

function M.setup(opts)
  config.setup(opts)
  if config.options.root then M.set_root(config.options.root) end
end

-- Per-cwd status cache for statusline consumers. Refreshing on every redraw
-- would shell out to git every few ms; gated on cwd change instead.
local status_cache = { cwd = nil }

local function refresh_status()
  local cwd = git.norm(vim.fn.getcwd())
  if status_cache.cwd == cwd then return status_cache end
  status_cache = { cwd = cwd, repo = nil, is_worktree = false }

  local common = git.git_common_dir(cwd)
  if not common then return status_cache end

  -- Derive repo name from the common-dir path:
  --   /foo/repo/.git  or  /foo/repo/.bare  → "repo"
  --   /foo/repo.git                         → "repo"
  --   /foo/repo                             → "repo"
  local base = vim.fn.fnamemodify(common, ":t")
  if base == ".git" or base == ".bare" then
    status_cache.repo = vim.fn.fnamemodify(common, ":h:t")
  elseif base:match("%.git$") then
    status_cache.repo = (base:gsub("%.git$", ""))
  else
    status_cache.repo = base
  end

  -- Linked worktree ⇔ `.git` in the work tree is a file (gitdir pointer),
  -- not a directory.
  local toplevel =
    vim.fn.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })[1]
  if toplevel and toplevel ~= "" then
    status_cache.is_worktree = vim.fn.filereadable(toplevel .. "/.git") == 1
  end

  return status_cache
end

-- { cwd, repo, is_worktree } for the current cwd, cached per-cwd. Meant for
-- statusline integrations where this runs on every redraw.
function M.status()
  return refresh_status()
end

-- `true` if the current cwd is a linked git worktree (not the main checkout
-- or a plain repo). Returns `false` outside any repo.
function M.is_linked_worktree()
  return refresh_status().is_worktree
end

-- Ready-made lualine component: renders "<repo>" or "<repo> (wt)", empty
-- outside a repo. Plug straight into a lualine section.
function M.lualine_component()
  local s = refresh_status()
  if not s.repo then return "" end
  return s.is_worktree and (s.repo .. " (wt)") or s.repo
end

local function relative_to_root(path)
  local root = M.ensure_root()
  local p, r = git.norm(path), git.norm(root)
  if p == r then return "." end
  if p:sub(1, #r + 1) == r .. "/" then return p:sub(#r + 2) end
  return p
end

-- Re-anchor the neo-tree filesystem source at the current cwd so the file
-- tree reflects the worktree we just switched into. No-op if neo-tree isn't
-- installed or isn't on screen -- we don't want to *open* neo-tree when the
-- user hasn't asked for it.
local function refresh_file_tree()
  if not config.options.integrations.neotree then return end

  local mgr_ok, manager = pcall(require, "neo-tree.sources.manager")
  if not mgr_ok then return end

  local state = manager.get_state and manager.get_state("filesystem")
  if not (state and state.winid and vim.api.nvim_win_is_valid(state.winid)) then
    return
  end

  local cwd = vim.fn.fnameescape(vim.fn.getcwd())
  local ok = pcall(vim.cmd, "Neotree dir=" .. cwd)
  if not ok then pcall(manager.refresh, "filesystem") end
end

-- Stop workspace-rooted LSP clients and re-fire FileType on every loaded
-- buffer so lspconfig's attach logic runs again with the new cwd as the
-- root-resolution anchor.
local function restart_workspace_lsps()
  if not config.options.integrations.lsp then return end

  local stopped = 0
  for _, name in ipairs(config.options.lsp_servers_to_restart or {}) do
    for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
      vim.lsp.stop_client(client.id, true)
      stopped = stopped + 1
    end
  end
  if stopped == 0 then return end

  -- Stop is async; defer re-attach so the old client is fully gone before
  -- lspconfig's autocmd fires a new launch.
  vim.defer_fn(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
        if vim.bo[bufnr].filetype ~= "" then
          pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = bufnr })
        end
      end
    end
  end, 150)
end

local function switch_to(path)
  local target = git.norm(path)
  vim.cmd.cd(vim.fn.fnameescape(target))
  restart_workspace_lsps()
  refresh_file_tree()
  notify(("worktree → %s"):format(relative_to_root(target)))
end

function M.pick()
  local root = M.ensure_root()
  local worktrees = git.collect_worktrees(root)
  if #worktrees == 0 then
    notify(("no worktrees found under %s"):format(root), vim.log.levels.WARN)
    return
  end

  local cwd = git.norm(vim.fn.getcwd())
  vim.ui.select(worktrees, {
    prompt = "Switch worktree:",
    format_item = function(wt)
      local rel = relative_to_root(wt.path)
      local branch = wt.branch and ("[" .. wt.branch .. "]")
        or wt.detached and "[detached]"
        or ""
      local marker = wt.path == cwd and "●" or " "
      return ("%s %-40s %s"):format(marker, rel, branch)
    end,
  }, function(choice)
    if choice then switch_to(choice.path) end
  end)
end

function M.home()
  local root = M.ensure_root()
  if git.norm(vim.fn.getcwd()) == git.norm(root) then
    notify(("already at root: %s"):format(root))
    return
  end
  vim.cmd.cd(vim.fn.fnameescape(root))
  restart_workspace_lsps()
  refresh_file_tree()
  notify(("worktree ← root (%s)"):format(root))
end

function M.add()
  local cwd = git.norm(vim.fn.getcwd())
  local here_common = git.git_common_dir(cwd)

  local function proceed(repo_common, label)
    local container = git.repo_container(repo_common)

    vim.ui.input({ prompt = ("New worktree in %s: "):format(label) }, function(name)
      if not name then return end
      name = vim.trim(name)
      if name == "" then return end

      local branches = git.list_branches(repo_common)
      if #branches == 0 then
        notify("No branches found in repo", vim.log.levels.ERROR)
        return
      end

      vim.ui.select(branches, {
        prompt = ("Base branch for '%s':"):format(name),
      }, function(base)
        if not base then return end
        local target = container .. "/" .. name
        local code, out = git.run({
          "git", "-C", repo_common, "worktree", "add", "-b", name, target, base,
        })
        if code ~= 0 then
          notify("git worktree add failed:\n" .. out, vim.log.levels.ERROR)
          return
        end
        refresh_file_tree()
        notify(("+ %s (from %s)"):format(relative_to_root(target), base))
      end)
    end)
  end

  if here_common then
    proceed(here_common, vim.fn.fnamemodify(git.repo_container(here_common), ":t"))
    return
  end

  -- At the root: scan child dirs for repos and let the user pick one.
  local root = M.ensure_root()
  local repos = git.list_child_repos(root)
  if #repos == 0 then
    notify(("no repos found under %s"):format(root), vim.log.levels.WARN)
    return
  end
  vim.ui.select(repos, {
    prompt = "Select a repo:",
    format_item = function(r) return r.name end,
  }, function(choice)
    if not choice then return end
    local repo_common = git.git_common_dir(choice.path)
    if not repo_common then
      notify(
        "Could not resolve git-common-dir for " .. choice.path,
        vim.log.levels.ERROR
      )
      return
    end
    proceed(repo_common, choice.name)
  end)
end

function M.remove()
  local cwd = git.norm(vim.fn.getcwd())
  local here_common = git.git_common_dir(cwd)

  local candidates = {}
  if here_common then
    local lines = vim.fn.systemlist({
      "git", "-C", here_common, "worktree", "list", "--porcelain",
    })
    if vim.v.shell_error == 0 then
      for _, wt in ipairs(git.parse_porcelain(lines)) do
        if not wt.bare then
          wt.path = git.norm(wt.path)
          table.insert(candidates, wt)
        end
      end
    end
  else
    candidates = git.collect_worktrees(M.ensure_root())
  end

  -- Don't offer the active worktree -- `git worktree remove` refuses on the
  -- current one, and we'd have to cd away first.
  local removable = {}
  for _, wt in ipairs(candidates) do
    if wt.path ~= cwd then table.insert(removable, wt) end
  end

  if #removable == 0 then
    notify("no removable worktrees found", vim.log.levels.WARN)
    return
  end

  vim.ui.select(removable, {
    prompt = "Remove worktree:",
    format_item = function(wt)
      local rel = relative_to_root(wt.path)
      local branch = wt.branch and ("[" .. wt.branch .. "]")
        or wt.detached and "[detached]"
        or ""
      return ("%-40s %s"):format(rel, branch)
    end,
  }, function(choice)
    if not choice then return end

    if git.has_uncommitted(choice.path) then
      notify(
        ("refusing to remove — uncommitted changes in %s"):format(
          relative_to_root(choice.path)
        ),
        vim.log.levels.ERROR
      )
      return
    end

    local dirty = buffers.modified_under(choice.path)
    if #dirty > 0 then
      notify(
        ("refusing to remove — unsaved buffers in %s:\n  %s"):format(
          relative_to_root(choice.path),
          table.concat(dirty, "\n  ")
        ),
        vim.log.levels.ERROR
      )
      return
    end

    -- Capture repo common-dir BEFORE removing -- afterwards `choice.path` is
    -- gone and can't anchor a `-C` call for the branch cleanup below.
    local repo_common = git.git_common_dir(choice.path)

    local code, out = git.run({
      "git", "-C", choice.path, "worktree", "remove", choice.path,
    })
    if code ~= 0 then
      notify("git worktree remove failed:\n" .. out, vim.log.levels.ERROR)
      return
    end

    local wiped = buffers.wipe_under(choice.path)
    refresh_file_tree()
    notify(("- %s%s"):format(
      relative_to_root(choice.path),
      wiped > 0 and (" (closed %d buffer(s))"):format(wiped) or ""
    ))

    -- Worktree is gone; optionally clean up the branch. Detached HEADs have
    -- no branch to delete, so skip the prompt in that case.
    if not choice.branch or not repo_common then return end
    local answer = vim.fn.confirm(
      ("Also delete branch '%s'?"):format(choice.branch),
      "&Yes\n&No",
      2
    )
    if answer ~= 1 then return end
    local bcode, bout = git.run({
      "git", "-C", repo_common, "branch", "-D", choice.branch,
    })
    if bcode ~= 0 then
      notify("git branch -D failed:\n" .. bout, vim.log.levels.ERROR)
      return
    end
    notify(("- branch %s"):format(choice.branch))
  end)
end

return M
