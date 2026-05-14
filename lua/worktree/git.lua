-- Git-adjacent helpers — dispatcher over `auto-core.git.worktree` +
-- `auto-core.git.repo` with a legacy fallback.
--
-- Per ADR 0007 Phase 1 Step 1.2 + ADR 0006 §"worktree.nvim migration
-- plan". The canonical implementations of these functions now live in
-- auto-core (shipped at v0.0.7). worktree.nvim's public surface is
-- preserved verbatim — external users (not just AutoVim) depend on
-- `require("worktree.git").*` so we delegate without breaking
-- signatures. When auto-core isn't installed, we fall back to the
-- bundled `git_legacy.lua` (the previous in-tree implementation).
-- The fallback retires after one minor release.

local M = {}

-- Soft-dep probe (one-shot). Captures references to auto-core's git
-- subsystem; nil means "not installed" or "not loaded yet".
local _probed = false
local _core_wt    ---@type table?
local _core_repo  ---@type table?
local _legacy
local _warned_fallback = false

local function _legacy_mod()
  _legacy = _legacy or require("worktree.git_legacy")
  return _legacy
end

local function _probe()
  if _probed then return end
  _probed = true
  local ok_core, core = pcall(require, "auto-core")
  if ok_core and type(core) == "table" and type(core.git) == "table" then
    if type(core.git.worktree) == "table" then _core_wt   = core.git.worktree end
    if type(core.git.repo)     == "table" then _core_repo = core.git.repo end
  end
  if not _core_wt and not _warned_fallback then
    _warned_fallback = true
    pcall(vim.notify,
      "worktree.nvim: auto-core.nvim not installed; using bundled git_legacy.lua. "
        .. "Install yongjohnlee80/auto-core.nvim to use the canonical implementation. "
        .. "The legacy fallback retires after one minor release.",
      vim.log.levels.WARN, { title = "worktree.nvim" })
  end
end

-- Path normalization stays local — no auto-core equivalent.
function M.norm(path)
  return _legacy_mod().norm(path)
end

-- Subprocess helpers + has_uncommitted: not in auto-core. Per
-- ADR 0007 §1.2, candidates for `auto-core.git.shell` extraction
-- if a second consumer needs them.
function M.has_uncommitted(...) return _legacy_mod().has_uncommitted(...) end
function M.run(...)              return _legacy_mod().run(...) end
function M.run_with_stdin(...)   return _legacy_mod().run_with_stdin(...) end

-- Delegating helpers: prefer auto-core if available, fall back to
-- the legacy module otherwise.
local function delegate_wt(core_fn, legacy_fn)
  legacy_fn = legacy_fn or core_fn
  return function(...)
    _probe()
    if _core_wt and type(_core_wt[core_fn]) == "function" then
      return _core_wt[core_fn](...)
    end
    return _legacy_mod()[legacy_fn](...)
  end
end

local function delegate_repo(core_fn, legacy_fn)
  legacy_fn = legacy_fn or core_fn
  return function(...)
    _probe()
    if _core_repo and type(_core_repo[core_fn]) == "function" then
      return _core_repo[core_fn](...)
    end
    return _legacy_mod()[legacy_fn](...)
  end
end

-- ── git.repo delegations ─────────────────────────────────────
M.is_git         = delegate_repo("is_git")
M.git_common_dir = delegate_repo("common_dir", "git_common_dir")
M.checkout       = delegate_repo("checkout")
M.checkout_status = delegate_repo("checkout_status")
M.delete_remote  = delegate_repo("delete_remote")
M.create_branch  = delegate_repo("create_branch")

-- ── git.worktree delegations ─────────────────────────────────
M.parse_porcelain      = delegate_wt("parse_porcelain")
-- collect_worktrees → core.git.worktree.collect (rename across the boundary).
M.collect_worktrees    = delegate_wt("collect", "collect_worktrees")
M.repo_container       = delegate_wt("repo_container")
M.list_child_repos     = delegate_wt("list_child_repos")
M.list_branches        = delegate_wt("list_branches")
M.list_remote_branches = delegate_wt("list_remote_branches")
M.track                = delegate_wt("track")
M.create               = delegate_wt("create")
M.local_branch_exists  = delegate_wt("local_branch_exists")
M.worktree_for_branch  = delegate_wt("worktree_for_branch")
M.find_remote_branches = delegate_wt("find_remote_branches")
M.repo_name_from_url   = delegate_wt("repo_name_from_url")
M.default_branch       = delegate_wt("default_branch")

-- Test-only: re-arm the soft-dep probe so smoke tests can flip
-- between with/without auto-core configurations.
function M._reset_for_tests()
  _probed = false
  _core_wt = nil
  _core_repo = nil
  _warned_fallback = false
end

return M
