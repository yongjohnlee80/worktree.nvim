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

-- Multi-repo graph view (ADR 0007 Phase 3 — absorbed from
-- gitsgraph.nvim). Lazy-required so consumers that don't open the
-- panel don't pay the gitgraph.nvim import cost. Use via:
--   require("worktree").graph.open() / .close() / .toggle() / .refresh()
M.graph = setmetatable({}, {
  __index = function(_, key)
    return require("worktree.graph")[key]
  end,
})

-- Local mirror of the workspace root. Per ADR 0007 §1.3 the
-- canonical source-of-truth is `auto-core.git.worktree.{set,get}_workspace_root`
-- when auto-core is available; this mirror is kept in sync so
-- `lualine_component()` and the synchronous read paths don't have
-- to round-trip through auto-core on every redraw.
local captured_root = nil

-- Two emission surfaces — pick by INTENT, not by severity.
--
-- `log(msg, level)` — severity-routed instrumentation. ERROR/WARN
-- toast via auto-core.log's default sink; INFO/DEBUG/TRACE land in the
-- ring only (silent). Use for diagnostics and status that should NOT
-- spam the user.
--
-- `feedback(msg)` — force-toast user-action feedback (`log.notify` at
-- INFO). Use when the user JUST invoked a command (worktree switch,
-- add, remove, clone, init) and is waiting on the outcome. These are
-- not noise — the user typed the command and expects to see the
-- result.
--
-- See shared/conventions/auto-family-logging.md row 5
-- ("Interactive feedback on a user-initiated UI action").
local function log(msg, level)
  local log = require("worktree.log")
  level = level or vim.log.levels.INFO
  if level == vim.log.levels.ERROR then return log.error(msg)
  elseif level == vim.log.levels.WARN then return log.warn(msg)
  elseif level == vim.log.levels.DEBUG then return log.debug(msg)
  elseif level == vim.log.levels.TRACE then return log.trace(msg)
  else return log.info(msg) end
end

local function feedback(msg)
  require("worktree.log").notify(msg, { level = "info" })
end

-- Soft-dep probe for auto-core. Callers above each integration
-- point also pcall, so a missing auto-core is silently tolerated.
local function _core()
  local ok, core = pcall(require, "auto-core")
  if ok and type(core) == "table" then return core end
  return nil
end

function M.set_root(path)
  local norm = git.norm(path)
  captured_root = norm
  -- Write through to the canonical state.namespace key so siblings
  -- (auto-finder repos panel, future status-bar consumers, etc.)
  -- read the same value. Auto-publishes
  -- `core.workspace_root:changed` per the auto-core state contract.
  local core = _core()
  if core and core.git and core.git.worktree
      and type(core.git.worktree.set_workspace_root) == "function" then
    pcall(core.git.worktree.set_workspace_root, norm)
  end
end

function M.get_root()
  -- Read-through: prefer auto-core's value when present so the
  -- "wandering `<leader>gQ`/`<leader>gW`" pain captured in ADR 0006
  -- §9 stays fixed. Fall back to the local mirror when auto-core
  -- isn't installed (legacy users).
  local core = _core()
  if core and core.git and core.git.worktree
      and type(core.git.worktree.get_workspace_root) == "function" then
    local v = core.git.worktree.get_workspace_root()
    if type(v) == "string" and v ~= "" then return v end
  end
  return captured_root
end

-- Capture the workspace root lazily. Called by plugin/worktree.lua on
-- VimEnter if the user hasn't already configured a root via setup().
--
-- Resolves a STABLE project identity from the launch cwd rather than
-- pinning the raw cwd. The old raw-cwd pin made per-project state —
-- auto-finder panel composition and md-harpoon pins, both keyed on
-- `sha256(core.workspace_root)` — hash DIFFERENTLY for every directory
-- nvim happened to be launched from. A panel/pin added from one cwd
-- "vanished" on the next launch from a sibling worktree or subdir.
-- Precedence:
--   1. WORKTREE_ROOT env — explicit operator override (ADR 0006's
--      sticky-workspace escape hatch). Ignored unless it's a real dir.
--   2. auto-core.fs.path.agent_workspace_root — `.auto-agents/` →
--      `.bare` → repo root → cwd. Collapses every worktree/subdir of
--      one project to a single identity.
--   3. raw cwd — legacy fallback when auto-core isn't installed.
function M.ensure_root()
  local existing = M.get_root()
  if existing then return existing end

  local cwd = vim.fn.getcwd(-1, -1)

  local env = os.getenv("WORKTREE_ROOT")
  if type(env) == "string" and env ~= "" then
    local expanded = vim.fn.expand(env)
    if vim.fn.isdirectory(expanded) == 1 then
      M.set_root(expanded)
      return M.get_root()
    end
  end

  local resolved
  local ok, fs_path = pcall(require, "auto-core.fs.path")
  if ok and type(fs_path) == "table"
      and type(fs_path.agent_workspace_root) == "function" then
    local r = fs_path.agent_workspace_root({ start = cwd })
    if type(r) == "string" and r ~= "" then resolved = r end
  end

  M.set_root(resolved or cwd)
  return M.get_root()
end

function M.setup(opts)
  config.setup(opts)
  if config.options.root then M.set_root(config.options.root) end
end

-- Test-only: clear the captured workspace root (local mirror + the
-- canonical auto-core value) so a smoke can exercise `ensure_root`'s
-- resolution path from a clean slate. Production code never calls this.
function M._reset_root_for_tests()
  captured_root = nil
  local core = _core()
  if core and core.git and core.git.worktree
      and type(core.git.worktree._reset_for_tests) == "function" then
    pcall(core.git.worktree._reset_for_tests)
  end
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
  -- ADR-0041 C4: a failed tree refresh was completely silent (both
  -- the command and the fallback swallowed) — the user just saw a
  -- stale tree with no diagnostic.
  local ok = pcall(vim.cmd, "Neotree dir=" .. cwd)
  if not ok then
    local fb_ok = pcall(manager.refresh, "filesystem")
    if not fb_ok then
      require("worktree.log").warn(
        "file-tree refresh failed after worktree switch (Neotree dir + manager.refresh both errored)")
    end
  end
end

-- Stop workspace-rooted LSP clients and re-fire FileType on every loaded
-- buffer so lspconfig's attach logic runs again with the new cwd as the
-- root-resolution anchor.
--
-- Per ADR 0007 §1.5 the STOP step prefers `auto-core.lsp.reset.reset_for`
-- (tech-stack-aware: only stops clients whose root_dir doesn't fit the
-- new path AND that belong to the detected stack — go.mod, package.json,
-- etc.). This fixes the false-error-on-switch UX (a Go-only switch no
-- longer restarts ts_ls). The user's existing
-- `config.options.lsp_servers_to_restart` is folded in as
-- `extra_servers` so explicit overrides keep working — additive over
-- the auto-detected stack.
--
-- Re-attach (the FileType re-fire) stays here. Auto-core's reset
-- explicitly delegates re-attach to the existing LspAttach autocmd
-- on next BufEnter, but worktree.nvim's prior UX was eager
-- (re-fire FileType on all buffers under the new cwd). We keep that
-- eagerness so already-open buffers re-attach immediately rather
-- than waiting for the user to BufEnter into them.
local function restart_workspace_lsps()
  if not config.options.integrations.lsp then return end
  local cwd = vim.fn.getcwd()

  local stopped_count
  local core = _core()
  if core and core.lsp and core.lsp.reset
      and type(core.lsp.reset.reset_for) == "function" then
    local result = core.lsp.reset.reset_for(cwd, {
      extra_servers = config.options.lsp_servers_to_restart or {},
    })
    stopped_count = #(result.stopped or {})
  else
    -- Legacy fallback: stop every server in the configured list.
    stopped_count = 0
    for _, name in ipairs(config.options.lsp_servers_to_restart or {}) do
      for _, client in ipairs(vim.lsp.get_clients({ name = name })) do
        vim.lsp.stop_client(client.id, true)
        stopped_count = stopped_count + 1
      end
    end
  end
  if stopped_count == 0 then return end

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
  --
  -- ADR-0041 C2: generation-stamp the deferred re-attach. Two
  -- switches inside the 150ms window previously raced — the stale
  -- timer re-fired FileType against the OLD worktree's cwd,
  -- re-attaching LSPs to the workspace the user just left. Only the
  -- newest scheduled re-attach may run.
  M._lsp_reattach_generation = (M._lsp_reattach_generation or 0) + 1
  local gen = M._lsp_reattach_generation
  vim.defer_fn(function()
    if gen ~= M._lsp_reattach_generation then return end
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

-- Publish `worktree:added` on the auto-core events bus. Fired from
-- every successful worktree-creating path: clone (initial worktree),
-- init (initial worktree), and the four add() flows (tracking,
-- checkout_local, from_base, plus the initial-worktree wrapper).
-- Drops auto-core.git.graph's fan_out cache so <leader>gt picks up
-- the new repo on the next render without a manual :WorktreeGraphRefresh.
local function publish_added(path)
  local core = _core()
  if not core then return end
  if core.events and type(core.events.publish) == "function" then
    pcall(core.events.publish, "worktree:added", { path = path })
  end
end

-- Publish `worktree:removed` on the auto-core events bus after a
-- successful `git worktree remove`. Same cache-invalidation rationale
-- as publish_added.
local function publish_removed(path)
  local core = _core()
  if not core then return end
  if core.events and type(core.events.publish) == "function" then
    pcall(core.events.publish, "worktree:removed", { path = path })
  end
end

-- Publish `worktree:switched` on the auto-core events bus + update
-- `core.active_worktree` state. Per ADR 0007 §1.4: closes the
-- dangling subscription that auto-finder v0.2.0 step 4 wired
-- (commit `a72bc7a`). Today only worktree.nvim's deliberate switch
-- paths (M.pick callback, M.home) publish; an arbitrary :cd does NOT.
local function publish_switch(old_cwd, new_cwd)
  local core = _core()
  if not core then return end
  if core.events and type(core.events.publish) == "function" then
    pcall(core.events.publish, "worktree:switched",
      { from = old_cwd, to = new_cwd, cwd = new_cwd })
  end
  if core.git and core.git.worktree
      and type(core.git.worktree.set_active) == "function" then
    pcall(core.git.worktree.set_active, new_cwd)
  end
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
      log(
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
  publish_switch(old_cwd, target)
  feedback(("worktree → %s%s%s"):format(
    relative_to_root(target), cleanup_suffix, session_suffix
  ))
end

function M.pick()
  local root = M.ensure_root()
  local worktrees = git.collect_worktrees(root)
  if #worktrees == 0 then
    log(("no worktrees found under %s"):format(root), vim.log.levels.WARN)
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
    feedback(("already at root: %s"):format(root))
    return
  end
  persistence_save(old_cwd)
  vim.cmd.cd(vim.fn.fnameescape(root))
  local new_cwd = git.norm(root)
  local cleanup_suffix = cleanup_stale_buffers(old_cwd, new_cwd)
  local session_suffix = persistence_load(new_cwd)
  restart_workspace_lsps()
  refresh_file_tree()
  publish_switch(old_cwd, new_cwd)
  feedback(("worktree ← root (%s)%s%s"):format(root, cleanup_suffix, session_suffix))
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
      log("git worktree add failed:\n" .. out, vim.log.levels.ERROR)
      return
    end
    publish_added(target)
    refresh_file_tree()
    feedback(("+ %s (tracking %s)"):format(relative_to_root(target), remote_ref))
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
      log("git worktree add failed:\n" .. out, vim.log.levels.ERROR)
      return
    end
    publish_added(target)
    refresh_file_tree()
    feedback(("+ %s (checked out existing local '%s')"):format(
      relative_to_root(target), name
    ))
  end

  -- `-b <name> <path> <base>` -- plain new branch from a local base. Used
  -- when there's no collision, or when the user explicitly picks
  -- "shadow" past one.
  local function create_from_base(repo_common, container, name)
    local branches = git.list_branches(repo_common)
    if #branches == 0 then
      log("No branches found in repo", vim.log.levels.ERROR)
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
        log("git worktree add failed:\n" .. out, vim.log.levels.ERROR)
        return
      end
      publish_added(target)
      refresh_file_tree()
      feedback(("+ %s (from %s)"):format(relative_to_root(target), base))
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
        log(
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
    log(("no repos found under %s"):format(root), vim.log.levels.WARN)
    return
  end
  vim.ui.select(repos, {
    prompt = "Select a repo:",
    format_item = function(r) return r.name end,
  }, function(choice)
    if not choice then return end
    local repo_common = git.git_common_dir(choice.path)
    if not repo_common then
      log(
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
    log("no removable worktrees found", vim.log.levels.WARN)
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
      log(
        ("refusing to remove — uncommitted changes in %s"):format(
          relative_to_root(choice.path)
        ),
        vim.log.levels.ERROR
      )
      return
    end

    local dirty = buffers.modified_under(choice.path)
    if #dirty > 0 then
      log(
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
      log("git worktree remove failed:\n" .. out, vim.log.levels.ERROR)
      return
    end
    publish_removed(choice.path)

    local wiped = buffers.wipe_under(choice.path)
    -- Drop the saved session for the removed worktree so we don't keep
    -- stale JSON files around. Silently no-ops if sessions aren't in use.
    if config.options.integrations.persistence then
      require("worktree.session").forget(choice.path)
    end
    refresh_file_tree()
    feedback(("- %s%s"):format(
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
      log("git branch -D failed:\n" .. bout, vim.log.levels.ERROR)
      return
    end
    feedback(("- branch %s"):format(choice.branch))
  end)
end

-- Guard: refuse an operation if the cwd is inside a git repo. Used by the
-- clone/init commands -- both want to land at the root layout and would do
-- the wrong thing if run from inside an existing checkout.
local function require_not_in_repo(op_label)
  local cwd = git.norm(vim.fn.getcwd())
  if git.git_common_dir(cwd) then
    log(
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
--
-- ADR-0041 Batch B: this is the single worst-consequence write in the
-- plugin — a truncated gitfile means git can't resolve the repo at all.
-- Delegate to auto-core's temp→fsync→rename primitive when available
-- (>= 0.1.58); keep the raw write only as the soft-dep fallback.
local function write_gitfile(dir, bare_rel)
  local path = dir .. "/.git"
  local content = "gitdir: ./" .. bare_rel .. "\n"
  local ok_atomic, atomic = pcall(require, "auto-core.fs.atomic")
  if ok_atomic and type(atomic.write) == "function" then
    return atomic.write(path, content)
  end
  local f, err = io.open(path, "w")
  if not f then return false, err or "unknown error" end
  f:write(content)
  f:close()
  return true
end
M._write_gitfile = write_gitfile -- ADR-0041 test hook

-- Create the first worktree on `branch` under `<repo_dir>/<branch>` and
-- `:cd` into it. Called after clone/init so the user lands in a usable
-- checkout instead of staring at a bare dir.
local function add_initial_worktree(bare_path, repo_dir, branch)
  local target = repo_dir .. "/" .. branch
  local code, out = git.run({
    "git", "-C", bare_path, "worktree", "add", target, branch,
  })
  if code ~= 0 then
    log("git worktree add failed:\n" .. out, vim.log.levels.ERROR)
    return false
  end
  publish_added(target)
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
        log(
          ("'%s' already exists under %s"):format(name, root),
          vim.log.levels.ERROR
        )
        return
      end

      feedback(("cloning %s → %s ..."):format(url, relative_to_root(repo_dir)))
      local code, out = git.run({ "git", "clone", "--bare", url, bare_path })
      if code ~= 0 then
        log("git clone --bare failed:\n" .. out, vim.log.levels.ERROR)
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
          log("failed to write .git gitfile: " .. err, vim.log.levels.ERROR)
          return
        end
      end

      local default = git.default_branch(bare_path)
      if add_initial_worktree(bare_path, repo_dir, default) then
        feedback(("cloned → %s (worktree on %s)"):format(
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
      log(
        ("'%s' already exists under %s"):format(name, root),
        vim.log.levels.ERROR
      )
      return
    end

    local code, out = git.run({
      "git", "init", "--bare", "-b", "main", bare_path,
    })
    if code ~= 0 then
      log("git init --bare failed:\n" .. out, vim.log.levels.ERROR)
      return
    end

    -- Seed an initial empty commit on main. Without it `worktree add` has
    -- nothing to check out (no ref exists yet) and fails on a fresh bare.
    -- Plumbing-only so we don't need a working tree to make the commit.
    local hc, empty_tree = git.run_with_stdin(
      { "git", "-C", bare_path, "hash-object", "-t", "tree", "--stdin" }, ""
    )
    if hc ~= 0 then
      log("hash-object failed:\n" .. empty_tree, vim.log.levels.ERROR)
      return
    end
    empty_tree = vim.trim(empty_tree)

    local cc, commit = git.run({
      "git", "-C", bare_path, "commit-tree", empty_tree, "-m", "Initial commit",
    })
    if cc ~= 0 then
      log("commit-tree failed:\n" .. commit, vim.log.levels.ERROR)
      return
    end
    commit = vim.trim(commit)

    local uc, uout = git.run({
      "git", "-C", bare_path, "update-ref", "refs/heads/main", commit,
    })
    if uc ~= 0 then
      log("update-ref failed:\n" .. uout, vim.log.levels.ERROR)
      return
    end

    -- See clone() for the bare_dir == ".git" case -- no gitfile needed.
    if bare_dir ~= ".git" then
      local ok, err = write_gitfile(repo_dir, bare_dir)
      if not ok then
        log("failed to write .git gitfile: " .. err, vim.log.levels.ERROR)
        return
      end
    end

    if add_initial_worktree(bare_path, repo_dir, "main") then
      feedback(("initialized → %s (empty commit on main)"):format(
        relative_to_root(repo_dir)
      ))
    end
  end)
end

return M
