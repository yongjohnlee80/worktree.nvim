-- Git-adjacent helpers — a thin facade over auto-core's git surface
-- (`auto-core.git.repo` + `auto-core.git.worktree`), plus a few
-- worktree-local shell helpers that have no auto-core equivalent.
--
-- auto-core is a HARD dependency as of v0.4.10 (ADR-0041 Batch D).
-- The previous in-tree `git_legacy.lua` fallback — kept since the
-- v0.4.0 migration "for one minor release" (ADR-0007 / ADR-0006
-- §"worktree.nvim migration plan") — has been removed; auto-core has
-- been the canonical implementation since its v0.0.7. worktree.nvim's
-- public surface (`require("worktree.git").*`) is preserved verbatim,
-- so external consumers see no signature change.

local M = {}

-- Resolve auto-core's git subsystem once. Errors with a clear message
-- if absent — auto-core is now a hard dependency (see header), so a
-- missing install is a setup error, not a soft-dep fallback.
local _core_repo ---@type table?
local _core_wt   ---@type table?
local function _resolve()
  if _core_repo and _core_wt then return end
  local ok, core = pcall(require, "auto-core")
  assert(ok and type(core) == "table" and type(core.git) == "table"
      and type(core.git.repo) == "table" and type(core.git.worktree) == "table",
    "worktree.nvim requires auto-core.nvim (>= 0.1.58) with its git "
    .. "subsystem — install yongjohnlee80/auto-core.nvim")
  _core_repo = core.git.repo
  _core_wt   = core.git.worktree
end

-- ── worktree-local helpers (no auto-core equivalent) ─────────
-- Relocated inline from the retired git_legacy.lua. Per ADR-0007
-- §1.2 these remain candidates for an `auto-core.git.shell`
-- extraction if a second consumer ever needs them.

-- Path normalization: absolute, trailing slash stripped.
function M.norm(path)
  return (vim.fn.fnamemodify(path, ":p"):gsub("/$", ""))
end

-- `true` if the worktree has staged or unstaged changes.
function M.has_uncommitted(worktree_path)
  local lines =
    vim.fn.systemlist({ "git", "-C", worktree_path, "status", "--porcelain" })
  return vim.v.shell_error == 0 and #lines > 0
end

-- Run a git subcommand; returns (exit_code, combined_output). Uses
-- vim.system so stderr is captured (systemlist swallows it).
function M.run(args)
  local res = vim.system(args, { text = true }):wait()
  return res.code, (res.stdout or "") .. (res.stderr or "")
end

-- Same as run() but pipes `stdin` into the subprocess (e.g.
-- `hash-object --stdin`).
function M.run_with_stdin(args, stdin)
  local res = vim.system(args, { text = true, stdin = stdin }):wait()
  return res.code, (res.stdout or "") .. (res.stderr or "")
end

-- ── delegations to auto-core ─────────────────────────────────
-- The public name is preserved; only the auto-core method name
-- differs in a couple of cases (common_dir, collect).
local function repo_fn(name)
  return function(...) _resolve(); return _core_repo[name](...) end
end
local function wt_fn(name)
  return function(...) _resolve(); return _core_wt[name](...) end
end

-- git.repo
M.is_git          = repo_fn("is_git")
M.git_common_dir  = repo_fn("common_dir")
M.checkout        = repo_fn("checkout")
M.checkout_status = repo_fn("checkout_status")
M.delete_remote   = repo_fn("delete_remote")
M.create_branch   = repo_fn("create_branch")

-- git.worktree
M.parse_porcelain      = wt_fn("parse_porcelain")
M.collect_worktrees    = wt_fn("collect") -- renamed across the boundary
M.repo_container       = wt_fn("repo_container")
M.list_child_repos     = wt_fn("list_child_repos")
M.list_branches        = wt_fn("list_branches")
M.list_remote_branches = wt_fn("list_remote_branches")
M.track                = wt_fn("track")
M.create               = wt_fn("create")
M.local_branch_exists  = wt_fn("local_branch_exists")
M.worktree_for_branch  = wt_fn("worktree_for_branch")
M.find_remote_branches = wt_fn("find_remote_branches")
M.repo_name_from_url   = wt_fn("repo_name_from_url")
M.default_branch       = wt_fn("default_branch")

-- Test-only: drop the cached auto-core references so a smoke run can
-- force re-resolution.
function M._reset_for_tests()
  _core_repo = nil
  _core_wt = nil
end

return M
