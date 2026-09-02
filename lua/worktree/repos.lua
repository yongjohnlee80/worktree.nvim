---worktree.repos — the repos-panel backend surface.
---
---ADR-0060 §2.1/§2.2. This is worktree.nvim's equivalent of `autodb.session`:
---the ONE module a frontend consumes. auto-finder's repos view is a renderer
---over this and holds no git knowledge of its own, exactly as its dbase view
---holds no database knowledge.
---
---The tree it describes:
---
---    repo                       repos()
---      worktree      ● watched  worktrees(repo)
---        UNCOMMITTED            children(repo, worktree) -> kind="uncommitted"
---          <changed file>       uncommitted(worktree)
---        <commit>               children(...) -> kind="commit"
---          <changed file>       commit_files(repo, sha)
---          <review json>        reviews(repo, sha)
---
---Every git read is delegated to auto-core (`git.graph.fan_out`,
---`git.worktree.parse_porcelain`, `git.log.*`) — this module owns the POLICY
---(what a watch means, which base a branch is compared against, where reviews
---live), never a git invocation of its own.
---@module 'worktree.repos'

local watch = require("worktree.watch")
local review = require("worktree.review")
local store = require("worktree.store")

local M = {}

---_core returns auto-core, or nil. auto-core is a hard dependency, but a
---frontend probing availability must get nil rather than an error.
local function _core()
  local ok, core = pcall(require, "auto-core")
  if not ok then return nil end
  return core
end

---REQUIRED is every auto-core function this module calls, as a dotted path.
---
---`available()` must probe the WHOLE surface, not a sample. It previously
---checked `git.log.range` and `git.graph.fan_out` only, so an auto-core with
---P1's log module but not P2's diff module advertised availability and then
---`diff()` errored the moment the user pressed `o` (r1 SF2). A semver floor
---cannot substitute for this: auto-core's self-reported `M.version` sat stale
---at 0.1.62 across v0.1.68/69/70, so the declared ">= 0.1.70" floor is
---documentation, not something code can test.
---
---Anything added to this module that reaches into auto-core belongs here too.
M.REQUIRED = {
  "git.log.range",
  "git.log.rev_exists",
  "git.log.working_changes",
  "git.log.commit_files",
  "git.graph.fan_out",
  "git.graph.show_diff",
  "git.graph.working_diff",
  "git.worktree.parse_porcelain",
  "git.worktree.list",
  "git.diff.parse",
}

---REQUIRED_WRITE is the git-ACTION surface, probed separately from the reads.
---
---These were briefly in `M.REQUIRED`, which was wrong in a way worth recording:
---`available()` gates the WHOLE repos panel, so an auto-core without the write
---module made the entire view vanish rather than just disabling `f`/`s`/`c`/`P`.
---Verified — against auto-core v0.2.2, `available()` returned false with
---`missing = auto-core.git.write.stage`, and the panel a user already had would
---simply stop appearing.
---
---That also contradicts ADR-0060 r1 SF2, which asks for a missing capability to
---degrade into a notification rather than break the surface. The reads decide
---whether the panel can exist at all; the writes decide whether four keys work,
---and the panel's handlers already notify when a verb is absent.
M.REQUIRED_WRITE = {
  "git.fetch.fetch_one",
  "git.write.stage",
  "git.write.unstage",
  "git.write.commit",
  "git.write.push",
  "git.write.has_staged",
}

---_resolve walks a dotted path from a root table, returning nil at the first
---missing or non-table link rather than throwing.
local function _resolve(root, dotted)
  local node = root
  for part in dotted:gmatch("[^.]+") do
    if type(node) ~= "table" then return nil end
    node = node[part]
  end
  return node
end

---available reports whether this surface can serve a panel. A frontend calls
---this to decide between the new view and its fallback, the same way
---auto-finder's dbase view probes `autodb.session`.
---@return boolean available, string? missing   the first absent capability
function M.available()
  local core = _core()
  if core == nil then return false, "auto-core" end
  for _, dotted in ipairs(M.REQUIRED) do
    if type(_resolve(core, dotted)) ~= "function" then
      return false, "auto-core." .. dotted
    end
  end
  return true, nil
end

---write_available reports whether the git ACTIONS can run.
---
---Separate from `available()` on purpose: the panel must still render against an
---auto-core that predates the write module, with only `f`/`s`/`c`/`P` inert.
---@return boolean available, string? missing
function M.write_available()
  local core = _core()
  if core == nil then return false, "auto-core" end
  for _, dotted in ipairs(M.REQUIRED_WRITE) do
    if type(_resolve(core, dotted)) ~= "function" then
      return false, "auto-core." .. dotted
    end
  end
  return true, nil
end

---@class WorktreeRepo
---@field common_dir string
---@field label string
---@field is_bare boolean
---@field sample_worktree string?
---@field slug string          the review-store key
---@field url string?          origin remote, when the repo has one

---repos lists the repositories under `root` (defaults to the workspace root).
---
---Discovery is auto-core's `fan_out`, which already handles bare AND regular
---repos and collapses a bare repo plus its N worktrees into one entry by
---canonical common-dir — requirement 3's "most likely the baregit, but it can
---also be the regular git repo".
---@param root string?
---@return WorktreeRepo[]
function M.repos(root)
  local core = _core()
  if not core then return {} end
  if not root or root == "" then
    local ok, wt = pcall(require, "worktree")
    root = ok and (wt.get_root() or wt.ensure_root()) or nil
  end
  if not root or root == "" then return {} end
  local found = core.git.graph.fan_out(root, { max_depth = 3 }) or {}
  local out = {}
  for _, r in ipairs(found) do
    local slug, url = store.remote_slug(r.common_dir)
    out[#out + 1] = {
      common_dir = r.common_dir, label = r.label,
      is_bare = r.is_bare and true or false,
      sample_worktree = r.sample_worktree,
      slug = slug, url = url,
    }
  end
  return out
end

---@class WorktreeWorktree
---@field path string
---@field branch string?
---@field head string?
---@field detached boolean
---@field watched boolean
---@field is_base boolean     this worktree holds the repo's base branch

---worktrees lists a repo's worktrees, each stamped with its watch state.
---
---A regular (non-bare) repo yields its single checked-out branch, which is
---requirement 6 — the caller needs no special case.
---@param repo WorktreeRepo
---@return WorktreeWorktree[] worktrees, string? err
function M.worktrees(repo)
  local core = _core()
  if not core or not repo or not repo.common_dir then return {}, "no repo" end
  -- Delegated to auto-core rather than shelling out here (r1 SF4). This module
  -- owns POLICY — what a watch means, which base a branch compares against —
  -- and `git worktree list` is a primitive auto-core already owns. `git -C
  -- <bare-common-dir>` and `git --git-dir=<bare-common-dir>` were verified to
  -- produce byte-identical porcelain, so this is a pure de-duplication with one
  -- error policy instead of a swallowed exit code.
  local entries, err = core.git.worktree.list(repo.common_dir)
  if not entries then return {}, err end
  local base = M.base_branch(repo)
  local out = {}
  for _, e in ipairs(entries) do
    if not e.bare then
      out[#out + 1] = {
        path = e.path, branch = e.branch, head = e.head,
        detached = e.detached and true or false,
        watched = watch.is_watched(e.path),
        is_base = (e.branch ~= nil and e.branch == base),
      }
    end
  end
  table.sort(out, function(a, b)
    -- Base branch first, then alphabetical: the base is the reference point
    -- every other worktree is compared against.
    if a.is_base ~= b.is_base then return a.is_base end
    return tostring(a.branch or a.path) < tostring(b.branch or b.path)
  end)
  return out
end

local _base_cache = {}

---base_branch resolves the branch a repo's work diverges FROM.
---
---Order: the remote's own default (`origin/HEAD`), then a local `main`, then
---`master`. Cached per common-dir for the process — this shells git and the
---answer changes only when someone re-points origin.
---@param repo WorktreeRepo|string
---@return string? branch
function M.base_branch(repo)
  local common = type(repo) == "table" and repo.common_dir or repo
  if not common or common == "" then return nil end
  if _base_cache[common] ~= nil then
    return _base_cache[common] ~= false and _base_cache[common] or nil
  end
  local core = _core()
  -- worktree.git.default_branch delegates to auto-core and already knows the
  -- origin/HEAD trick; prefer it so the answer matches the rest of the plugin.
  local ok_git, wgit = pcall(require, "worktree.git")
  if ok_git and type(wgit.default_branch) == "function" then
    local ok, b = pcall(wgit.default_branch, common)
    if ok and type(b) == "string" and b ~= "" then
      _base_cache[common] = b
      return b
    end
  end
  if core and core.git and core.git.log then
    for _, cand in ipairs({ "main", "master" }) do
      if core.git.log.rev_exists(common, cand) then
        _base_cache[common] = cand
        return cand
      end
    end
  end
  _base_cache[common] = false
  return nil
end

---@class WorktreeNode
---@field kind string        "uncommitted" | "commit"
---@field label string
---@field sha string?        commit only
---@field short string?      commit only
---@field count integer?     uncommitted only: how many files changed
---@field commit table?      the AutoCoreCommit, commit only

---children lists a watched worktree's UNCOMMITTED node and commits.
---
---An UNWATCHED worktree returns nothing at all — that is the whole point of
---§2.3: no `git log`, no `git status`, no cost. The caller renders a collapsed
---row and the user opts in.
---@param repo WorktreeRepo
---@param wt WorktreeWorktree
---@param opts { limit: integer?, skip: integer? }?
---@return WorktreeNode[] nodes, table meta
function M.children(repo, wt, opts)
  opts = opts or {}
  local core = _core()
  if not core or not repo or not wt then return {}, { mode = "none" } end
  if not watch.is_watched(wt.path) then
    return {}, { mode = "unwatched" }
  end

  local nodes = {}

  -- Both reads below return `{}` PLUS an error on failure, and discarding the
  -- error turned a failed git call into `(no commits, clean tree)` — the panel
  -- asserting by omission that there is no uncommitted work (r1 SF3). The
  -- errors are threaded into `meta` so the frontend renders an error row; an
  -- empty result and a failed read must never look the same.
  local status_err, log_err

  -- UNCOMMITTED sorts above the commits: it is the newest state of the tree.
  local changes, cerr = core.git.log.working_changes(wt.path)
  status_err = cerr
  if #changes > 0 then
    nodes[#nodes + 1] = {
      kind = "uncommitted",
      label = string.format("UNCOMMITTED (%d file%s)", #changes, #changes == 1 and "" or "s"),
      count = #changes,
    }
  end

  local base = M.base_branch(repo)
  local rev = wt.branch or wt.head or "HEAD"
  local commits, meta, rerr = core.git.log.range(repo.common_dir, {
    rev = rev, base = base, limit = opts.limit, skip = opts.skip,
  })
  log_err = rerr
  for _, c in ipairs(commits) do
    nodes[#nodes + 1] = {
      kind = "commit", sha = c.sha, short = c.short,
      label = c.short .. "  " .. c.subject, commit = c,
    }
  end
  meta.rev = rev
  meta.status_err = status_err
  meta.log_err = log_err
  return nodes, meta
end

---uncommitted lists the working-tree changes for the UNCOMMITTED node.
---@param wt WorktreeWorktree|string
---@return table[] changes
function M.uncommitted(wt)
  local core = _core()
  if not core then return {} end
  local path = type(wt) == "table" and wt.path or wt
  local changes = core.git.log.working_changes(path)
  return changes
end

---commit_files lists a commit's changed files.
---@param repo WorktreeRepo
---@param sha string
---@return table[] files
function M.commit_files(repo, sha)
  local core = _core()
  if not core or not repo then return {} end
  local files = core.git.log.commit_files(repo.common_dir, sha)
  return files
end

---reviews lists the review files recorded for a commit — the review-JSON rows
---the tree shows beside a commit's changed files (requirement 9).
---@param repo WorktreeRepo
---@param sha string
---@return { revision: integer, path: string, name: string }[]
function M.reviews(repo, sha)
  if not repo or not repo.slug then return {} end
  return review.list_for(repo.slug, sha)
end

---reviews_described describes ONE commit's reviews — the rows a commit expands
---to, with the severity each carries. `reviews(repo, sha)` stays the cheap
---revision listing for callers that need nothing more (the diff view's
---annotation merge is one).
---@param repo WorktreeRepo
---@param sha string
---@return table[] reviews
function M.reviews_described(repo, sha)
  if not repo or not repo.slug or not sha then return {} end
  return review.described_for(repo.slug, sha)
end

---tally_paths merges described reviews into the per-file tally a tree badges
---with. Pure — re-exported so a frontend holding descriptions need not re-read.
---@param described table[]
---@return table<string, { count: integer, worst: string? }>
function M.tally_paths(described) return review.tally_paths(described) end

---reviews_index lists a repo's review FILES without opening any of them —
---the cheap half of `reviews_all`, for a caller that needs only a count.
---
---One directory scan plus a stat per file. The panel draws the section's count
---on a collapsed row, and a listing that had to read every document to say "3"
---would put a per-repaint cost on a row nobody has expanded.
---@param repo WorktreeRepo
---@return { slug: string, short: string, revision: integer, path: string, name: string, mtime: integer }[]
function M.reviews_index(repo)
  if not repo or not repo.slug then return {} end
  return review.list_all(repo.slug)
end

---reviews_dir is where this repo's reviews are stored, for an info view.
---@param repo WorktreeRepo
---@return string?
function M.reviews_dir(repo)
  if not repo or not repo.slug then return nil end
  return store.reviews_dir(repo.slug)
end

---reviews_all lists EVERY review recorded for a repo, described — the
---repo-wide section (ADR-0060 §11), as opposed to `reviews(repo, sha)` which
---answers for one commit.
---
---This is the listing that survives a rebase. A review names a commit in its
---filename, so once history is rewritten `reviews(repo, sha)` can no longer
---find it and the file is invisible in the tree — which is precisely when
---someone needs to see it and re-point it.
---@param repo WorktreeRepo
---@return table[] reviews   `review.describe` records, most recent first
function M.reviews_all(repo)
  if not repo or not repo.slug then return {} end
  local out = {}
  for _, rec in ipairs(review.list_all(repo.slug)) do
    out[#out + 1] = review.describe(rec.path) or rec
  end
  return out
end

---review_meta describes ONE review file by path — what an info view prints.
---@param path string
---@return table? meta
function M.review_meta(path) return (review.describe(path)) end

---reviewed_paths tallies which of a commit's files carry review comments, for
---the tree's per-file feedback badge.
---@param repo WorktreeRepo
---@param sha string
---@return table<string, { count: integer, worst: string? }>
function M.reviewed_paths(repo, sha)
  if not repo or not repo.slug or not sha then return {} end
  return review.reviewed_paths(repo.slug, sha)
end

---diff returns a commit's parsed diff, ready for the three-column view.
---@param repo WorktreeRepo
---@param sha string
---@return table[] files
function M.diff(repo, sha)
  local core = _core()
  if not core or not repo then return {} end
  local raw = core.git.graph.show_diff(repo.common_dir, sha)
  return core.git.diff.parse(raw)
end

---diff_working parses a WORKTREE's uncommitted diff — the UNCOMMITTED node's
---counterpart to `diff(repo, sha)`.
---
---Staged and unstaged changes to tracked files plus every untracked file, in
---one parse, so `o` on UNCOMMITTED opens the same three-column view a commit
---does. Uncached in auto-core, deliberately: a working tree changes between
---keypresses.
---@param wt table  a worktree record (needs `.path`)
---@return table[] files
function M.diff_working(wt)
  local core = _core()
  if not core or not wt or not wt.path then return {} end
  local raw = core.git.graph.working_diff(wt.path)
  return core.git.diff.parse(table.concat(raw, "\n"))
end

---toggle_watch flips a worktree's watch. Re-exported here so a frontend needs
---only this module.
---@param path string
---@return boolean watched, string? err
function M.toggle_watch(path) return watch.toggle(path) end

---is_watched is likewise re-exported for the renderer.
---@param path string
---@return boolean
function M.is_watched(path) return watch.is_watched(path) end

---TOPIC_WATCH lets a frontend subscribe without importing `worktree.watch`.
M.TOPIC_WATCH = watch.TOPIC

---_reset_for_tests clears the base-branch cache.
-- ─── git actions (ADR-0060) ───────────────────────────────────────
--
-- worktree.nvim owns git for the repos surface, so the WRITE verbs live here
-- and auto-finder only binds keys to them. The alternative — the panel calling
-- git itself — is what put a second git owner in the stack once already.
--
-- Every one of these is a thin delegation on purpose. The hardening that
-- matters (no `--no-optional-locks` on a write, `GIT_EDITOR` pinned, refusing
-- a commit with an empty index) belongs in auto-core where the argv is built,
-- not duplicated per consumer.

---_cwd picks the directory a git write should run in.
---
---A bare repo has no working tree, so a write needs one of its worktrees; the
---common dir is the fallback for operations that do not need one (a push of
---already-committed refs works fine from a bare repo).
---@param repo WorktreeRepo
---@return string|nil
local function _cwd(repo)
  if type(repo) ~= "table" then return nil end
  if type(repo.sample_worktree) == "string" and repo.sample_worktree ~= "" then
    return repo.sample_worktree
  end
  if type(repo.common_dir) == "string" and repo.common_dir ~= "" then
    return repo.common_dir
  end
  return nil
end

---_wt_path resolves a worktree argument to its path.
---@param wt table|string
---@return string|nil
local function _wt_path(wt)
  if type(wt) == "string" then return wt ~= "" and wt or nil end
  if type(wt) ~= "table" then return nil end
  for _, k in ipairs({ "path", "dir", "root" }) do
    if type(wt[k]) == "string" and wt[k] ~= "" then return wt[k] end
  end
  return nil
end

---fetch updates a repo's remotes. Delegates to auto-core's existing async
---fetch — this verb adds a worktree-shaped signature, not a second fetch.
---@param repo WorktreeRepo
---@param on_done fun(ok: boolean, err: string?)?
function M.fetch(repo, on_done)
  local core = _core()
  local fetch_one = core and _resolve(core, "git.fetch.fetch_one")
  if not fetch_one then
    if on_done then on_done(false, "auto-core.git.fetch.fetch_one unavailable") end
    return
  end
  if not (type(repo) == "table" and type(repo.common_dir) == "string") then
    if on_done then on_done(false, "fetch: repo.common_dir required") end
    return
  end
  fetch_one({ common_dir = repo.common_dir, label = repo.label }, nil, on_done)
end

---@param wt table|string
---@param paths string|string[]
---@param on_done fun(ok: boolean, err: string?)?
function M.stage(wt, paths, on_done)
  local core = _core()
  local fn = core and _resolve(core, "git.write.stage")
  local cwd = _wt_path(wt)
  if not fn then return on_done and on_done(false, "auto-core.git.write.stage unavailable") end
  if not cwd then return on_done and on_done(false, "stage: worktree path required") end
  fn(cwd, paths, on_done)
end

---@param wt table|string
---@param paths string|string[]
---@param on_done fun(ok: boolean, err: string?)?
function M.unstage(wt, paths, on_done)
  local core = _core()
  local fn = core and _resolve(core, "git.write.unstage")
  local cwd = _wt_path(wt)
  if not fn then return on_done and on_done(false, "auto-core.git.write.unstage unavailable") end
  if not cwd then return on_done and on_done(false, "unstage: worktree path required") end
  fn(cwd, paths, on_done)
end

---has_staged lets a caller decide whether `commit` is worth offering.
---@param wt table|string
---@return boolean
function M.has_staged(wt)
  local core = _core()
  local fn = core and _resolve(core, "git.write.has_staged")
  local cwd = _wt_path(wt)
  if not (fn and cwd) then return false end
  local ok, res = pcall(fn, cwd)
  return ok and res == true
end

---@param wt table|string
---@param msg string
---@param on_done fun(ok: boolean, err: string?)?
function M.commit(wt, msg, on_done)
  local core = _core()
  local fn = core and _resolve(core, "git.write.commit")
  local cwd = _wt_path(wt)
  if not fn then return on_done and on_done(false, "auto-core.git.write.commit unavailable") end
  if not cwd then return on_done and on_done(false, "commit: worktree path required") end
  fn(cwd, msg, nil, on_done)
end

---push publishes a repo's commits.
---
---The CONFIRMATION is deliberately not here. This verb is callable from
---anywhere, including a test; the "are you sure" belongs to the surface holding
---the user's attention, which is the only place that can name what is about to
---be published. See auto-finder's repos panel binding.
---@param repo WorktreeRepo
---@param opts { remote: string?, branch: string?, set_upstream: boolean? }?
---@param on_done fun(ok: boolean, err: string?)?
function M.push(repo, opts, on_done)
  local core = _core()
  local fn = core and _resolve(core, "git.write.push")
  local cwd = _cwd(repo)
  if not fn then return on_done and on_done(false, "auto-core.git.write.push unavailable") end
  if not cwd then return on_done and on_done(false, "push: repo path required") end
  opts = vim.tbl_extend("force", { label = repo and repo.label or nil }, opts or {})
  fn(cwd, opts, on_done)
end

function M._reset_for_tests() _base_cache = {} end

return M
