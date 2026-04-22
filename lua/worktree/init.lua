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
  --
  -- Scope the re-attach to buffers whose path is inside the new cwd.
  -- Buffers pointing into a prior worktree stay detached until the user
  -- navigates into them again. This prevents two problems:
  --   1. Spawning an LSP client rooted at a stale workspace (e.g. gopls
  --      anchoring at an old Go worktree while the user is now on a TS
  --      one), which produces transient "no package metadata" errors and
  --      doubles the running LSP set.
  --   2. LSP attach events triggering neo-tree's `follow_current_file`
  --      to re-anchor the file tree back to the old worktree.
  vim.defer_fn(function()
    local cwd = vim.fn.getcwd()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buftype == "" then
        if vim.bo[bufnr].filetype ~= "" then
          local path = vim.api.nvim_buf_get_name(bufnr)
          if path ~= "" and vim.startswith(path, cwd .. "/") then
            pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = bufnr })
          end
        end
      end
    end
  end, 150)
end

-- Close file-buffers under `old_path` that aren't under `new_path`, and
-- redirect the current window away from any buffer about to disappear so
-- nvim doesn't pick an arbitrary alternate. Returns the notification
-- suffix to append to the switch message (e.g. "closed 3 buffer(s)").
-- No-op when cleanup_on_switch is disabled.
local function cleanup_stale_buffers(old_path, new_path)
  if not config.options.cleanup_on_switch then return "" end
  if old_path == new_path then return "" end

  local win = vim.api.nvim_get_current_win()
  if buffers.win_is_stale(win, old_path, new_path) then
    local landing = buffers.first_under(new_path)
    if landing then
      vim.api.nvim_win_set_buf(win, landing)
    else
      vim.cmd("enew")
    end
  end

  local closed, dirty = buffers.close_between(old_path, new_path)

  if #dirty > 0 then
    vim.schedule(function()
      notify(
        ("%d unsaved buffer(s) left open:\n  %s"):format(
          #dirty, table.concat(dirty, "\n  ")
        ),
        vim.log.levels.WARN
      )
    end)
  end

  if closed > 0 then
    return (" (closed %d buffer(s))"):format(closed)
  end
  return ""
end

-- Per-worktree buffer tracking. Lightweight replacement for v0.3.0's
-- persistence.nvim integration: we save the list of file-buffers
-- belonging to the old worktree BEFORE :cd, then on return to a
-- worktree :badd the saved buffers back. Window layout is never
-- touched, so neo-tree / terminals / dap-view all survive the switch.
-- Gated on the same `integrations.persistence` option.
local function persistence_save(old_cwd)
  if not config.options.integrations.persistence then return end
  require("worktree.session").save(old_cwd)
end

local function persistence_load(new_cwd)
  if not config.options.integrations.persistence then return "" end
  local ok, count = require("worktree.session").load(new_cwd)
  if ok and count > 0 then
    return (" (restored %d buffer(s))"):format(count)
  end
  return ""
end

local function switch_to(path)
  local old_cwd = git.norm(vim.fn.getcwd())
  local target = git.norm(path)
  persistence_save(old_cwd)
  vim.cmd.cd(vim.fn.fnameescape(target))
  local cleanup_suffix = cleanup_stale_buffers(old_cwd, target)
  local session_suffix = persistence_load(target)
  restart_workspace_lsps()
  refresh_file_tree()
  notify(("worktree → %s%s%s"):format(
    relative_to_root(target), cleanup_suffix, session_suffix
  ))
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
  local old_cwd = git.norm(vim.fn.getcwd())
  if old_cwd == git.norm(root) then
    notify(("already at root: %s"):format(root))
    return
  end
  persistence_save(old_cwd)
  vim.cmd.cd(vim.fn.fnameescape(root))
  local new_cwd = git.norm(root)
  local cleanup_suffix = cleanup_stale_buffers(old_cwd, new_cwd)
  local session_suffix = persistence_load(new_cwd)
  restart_workspace_lsps()
  refresh_file_tree()
  notify(("worktree ← root (%s)%s%s"):format(root, cleanup_suffix, session_suffix))
end

function M.add()
  local cwd = git.norm(vim.fn.getcwd())
  local here_common = git.git_common_dir(cwd)

  -- `--track -b <name> <path> <remote>/<name>` -- new local branch tracking
  -- the remote. Use when the user picks "Track" on a name collision.
  local function create_tracking(repo_common, container, name, remote_ref)
    local target = container .. "/" .. name
    local code, out = git.run({
      "git", "-C", repo_common, "worktree", "add", "--track",
      "-b", name, target, remote_ref,
    })
    if code ~= 0 then
      notify("git worktree add failed:\n" .. out, vim.log.levels.ERROR)
      return
    end
    refresh_file_tree()
    notify(("+ %s (tracking %s)"):format(relative_to_root(target), remote_ref))
  end

  -- `worktree add <path> <branch>` (no `-b`) -- checks out the existing
  -- local branch into a new worktree. Used when the user picks
  -- "Check out existing local" on a name collision.
  local function create_checkout_local(repo_common, container, name)
    local target = container .. "/" .. name
    local code, out = git.run({
      "git", "-C", repo_common, "worktree", "add", target, name,
    })
    if code ~= 0 then
      notify("git worktree add failed:\n" .. out, vim.log.levels.ERROR)
      return
    end
    refresh_file_tree()
    notify(("+ %s (checked out existing local '%s')"):format(
      relative_to_root(target), name
    ))
  end

  -- `-b <name> <path> <base>` -- plain new branch from a local base. Used
  -- when there's no collision, or when the user explicitly picks
  -- "shadow" past one.
  local function create_from_base(repo_common, container, name)
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
  end

  local function proceed(repo_common, label)
    local container = git.repo_container(repo_common)

    vim.ui.input({ prompt = ("New worktree in %s: "):format(label) }, function(name)
      if not name then return end
      name = vim.trim(name)
      if name == "" then return end

      -- Sniff existing branches that match the requested name. Three things
      -- matter: does a local branch exist, is it already checked out by
      -- another worktree (hard conflict), and does any remote have it too.
      local local_exists = git.local_branch_exists(repo_common, name)
      local wt_path = local_exists
        and git.worktree_for_branch(repo_common, name)
        or nil
      local remote_matches = git.find_remote_branches(repo_common, name)

      -- Hard stop: git refuses to check out the same branch in two
      -- worktrees. Tell the user where it lives so they can switch instead.
      if wt_path then
        notify(
          ("'%s' is already checked out in worktree %s"):format(
            name, relative_to_root(wt_path)
          ),
          vim.log.levels.ERROR
        )
        return
      end

      -- No collision at all → straight to the base-branch prompt.
      if not local_exists and #remote_matches == 0 then
        create_from_base(repo_common, container, name)
        return
      end

      -- Build a dynamic option list across the collision cases. The plain
      -- `-b <name>` git would run by default silently shadows either the
      -- local branch (error) or the remote branch (footgun), so we always
      -- ask when there's a name collision.
      local options = {}
      if local_exists then
        table.insert(options, {
          kind = "checkout_local",
          label = ("Check out existing local '%s' into a new worktree")
            :format(name),
        })
      end
      for _, m in ipairs(remote_matches) do
        table.insert(options, {
          kind = "track",
          ref = m.ref,
          label = ("Track %s (new local '%s' tracking it)")
            :format(m.ref, name),
        })
      end
      table.insert(options, {
        kind = "shadow",
        label = ("Create new local '%s' from a base branch"):format(name),
      })
      table.insert(options, { kind = "cancel", label = "Cancel" })

      local prompt
      if local_exists and #remote_matches > 0 then
        prompt = ("'%s' exists locally and on a remote -- what to do?")
          :format(name)
      elseif local_exists then
        prompt = ("'%s' exists as a local branch -- what to do?"):format(name)
      else
        prompt = ("'%s' already exists on a remote -- what to do?")
          :format(name)
      end

      vim.ui.select(options, {
        prompt = prompt,
        format_item = function(o) return o.label end,
      }, function(choice)
        if not choice or choice.kind == "cancel" then return end
        if choice.kind == "track" then
          create_tracking(repo_common, container, name, choice.ref)
        elseif choice.kind == "checkout_local" then
          create_checkout_local(repo_common, container, name)
        else
          create_from_base(repo_common, container, name)
        end
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
    -- Drop the saved session for the removed worktree so we don't keep
    -- stale JSON files around. Silently no-ops if sessions aren't in use.
    if config.options.integrations.persistence then
      require("worktree.session").forget(choice.path)
    end
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

-- Guard: refuse an operation if the cwd is inside a git repo. Used by the
-- clone/init commands -- both want to land at the root layout and would do
-- the wrong thing if run from inside an existing checkout.
local function require_not_in_repo(op_label)
  local cwd = git.norm(vim.fn.getcwd())
  if git.git_common_dir(cwd) then
    notify(
      ("refusing to %s -- cwd is inside a git repo (%s). Hop back to root first (<leader>gW).")
        :format(op_label, cwd),
      vim.log.levels.ERROR
    )
    return false
  end
  return true
end

-- Write a gitfile at `<dir>/.git` pointing at `./<bare_rel>`. Makes
-- `git -C <dir>` discover the bare repo automatically so the rest of the
-- plugin (collect_worktrees, list_child_repos, etc.) finds it.
local function write_gitfile(dir, bare_rel)
  local path = dir .. "/.git"
  local f, err = io.open(path, "w")
  if not f then return false, err or "unknown error" end
  f:write("gitdir: ./" .. bare_rel .. "\n")
  f:close()
  return true
end

-- Create the first worktree on `branch` under `<repo_dir>/<branch>` and
-- `:cd` into it. Called after clone/init so the user lands in a usable
-- checkout instead of staring at a bare dir.
local function add_initial_worktree(bare_path, repo_dir, branch)
  local target = repo_dir .. "/" .. branch
  local code, out = git.run({
    "git", "-C", bare_path, "worktree", "add", target, branch,
  })
  if code ~= 0 then
    notify("git worktree add failed:\n" .. out, vim.log.levels.ERROR)
    return false
  end
  vim.cmd.cd(vim.fn.fnameescape(target))
  refresh_file_tree()
  return true
end

function M.clone()
  if not require_not_in_repo("clone") then return end

  vim.ui.input({ prompt = "Git URL to clone: " }, function(url)
    if not url or vim.trim(url) == "" then return end
    url = vim.trim(url)

    vim.ui.input({
      prompt = "Repo directory name: ",
      default = git.repo_name_from_url(url),
    }, function(name)
      if not name or vim.trim(name) == "" then return end
      name = vim.trim(name)

      local root = M.ensure_root()
      local repo_dir = root .. "/" .. name
      local bare_dir = config.options.bare_dir or ".bare"
      local bare_path = repo_dir .. "/" .. bare_dir

      if vim.fn.isdirectory(repo_dir) == 1 then
        notify(
          ("'%s' already exists under %s"):format(name, root),
          vim.log.levels.ERROR
        )
        return
      end

      notify(("cloning %s → %s ..."):format(url, relative_to_root(repo_dir)))
      local code, out = git.run({ "git", "clone", "--bare", url, bare_path })
      if code ~= 0 then
        notify("git clone --bare failed:\n" .. out, vim.log.levels.ERROR)
        return
      end

      -- `clone --bare` defaults the fetch refspec to mirror-style
      -- (+refs/heads/*:refs/heads/*), which breaks the worktree layout
      -- because remote branches won't land under refs/remotes/origin/*.
      -- Rewrite the refspec and re-fetch so `origin/*` refs populate.
      git.run({
        "git", "-C", bare_path, "config",
        "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*",
      })
      git.run({ "git", "-C", bare_path, "fetch", "origin" })

      -- Only write a gitfile when the bare is in a sibling dir (e.g. .bare/).
      -- When bare_dir == ".git", the .git/ dir *is* the bare and git finds
      -- it natively via core.bare = true.
      if bare_dir ~= ".git" then
        local ok, err = write_gitfile(repo_dir, bare_dir)
        if not ok then
          notify("failed to write .git gitfile: " .. err, vim.log.levels.ERROR)
          return
        end
      end

      local default = git.default_branch(bare_path)
      if add_initial_worktree(bare_path, repo_dir, default) then
        notify(("cloned → %s (worktree on %s)"):format(
          relative_to_root(repo_dir), default
        ))
      end
    end)
  end)
end

function M.init()
  if not require_not_in_repo("init") then return end

  vim.ui.input({ prompt = "New project name: " }, function(name)
    if not name or vim.trim(name) == "" then return end
    name = vim.trim(name)

    local root = M.ensure_root()
    local repo_dir = root .. "/" .. name
    local bare_dir = config.options.bare_dir or ".bare"
    local bare_path = repo_dir .. "/" .. bare_dir

    if vim.fn.isdirectory(repo_dir) == 1 then
      notify(
        ("'%s' already exists under %s"):format(name, root),
        vim.log.levels.ERROR
      )
      return
    end

    local code, out = git.run({
      "git", "init", "--bare", "-b", "main", bare_path,
    })
    if code ~= 0 then
      notify("git init --bare failed:\n" .. out, vim.log.levels.ERROR)
      return
    end

    -- Seed an initial empty commit on main. Without it `worktree add` has
    -- nothing to check out (no ref exists yet) and fails on a fresh bare.
    -- Plumbing-only so we don't need a working tree to make the commit.
    local hc, empty_tree = git.run_with_stdin(
      { "git", "-C", bare_path, "hash-object", "-t", "tree", "--stdin" }, ""
    )
    if hc ~= 0 then
      notify("hash-object failed:\n" .. empty_tree, vim.log.levels.ERROR)
      return
    end
    empty_tree = vim.trim(empty_tree)

    local cc, commit = git.run({
      "git", "-C", bare_path, "commit-tree", empty_tree, "-m", "Initial commit",
    })
    if cc ~= 0 then
      notify("commit-tree failed:\n" .. commit, vim.log.levels.ERROR)
      return
    end
    commit = vim.trim(commit)

    local uc, uout = git.run({
      "git", "-C", bare_path, "update-ref", "refs/heads/main", commit,
    })
    if uc ~= 0 then
      notify("update-ref failed:\n" .. uout, vim.log.levels.ERROR)
      return
    end

    -- See clone() for the bare_dir == ".git" case -- no gitfile needed.
    if bare_dir ~= ".git" then
      local ok, err = write_gitfile(repo_dir, bare_dir)
      if not ok then
        notify("failed to write .git gitfile: " .. err, vim.log.levels.ERROR)
        return
      end
    end

    if add_initial_worktree(bare_path, repo_dir, "main") then
      notify(("initialized → %s (empty commit on main)"):format(
        relative_to_root(repo_dir)
      ))
    end
  end)
end

return M
