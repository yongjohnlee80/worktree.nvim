---worktree.store — the per-repo persistent store.
---
---ADR-0060 P3 §2.7. worktree.nvim had exactly one persistence mechanism:
---`session.lua`, a hashed JSON file per **cwd** holding a buffer list. Reviews
---and watches are neither cwd-scoped nor a single blob:
---
---  * a review belongs to a COMMIT, which belongs to a REPO — not to whichever
---    worktree happened to be current when it was written;
---  * there are many review files per repo, each independently named so it can
---    be applied systematically (§2.6), so `auto-core.state.namespace` is the
---    wrong shape: it stores one table per namespace.
---
---So this module owns a directory layout keyed by repo SLUG:
---
---    $XDG_STATE_HOME/nvim/worktree.nvim/
---      reviews/<owner>__<repo>/<owner>__<repo>@<short-sha>.r<N>.review.json
---      watches.json
---
---Every write goes through `auto-core.fs.atomic.write` (temp → fsync →
---rename), the same primitive `session.lua` and the `.git` gitfile writer use:
---a half-written review file that still parses as JSON is worse than none.
---@module 'worktree.store'

local M = {}

---root is the store's base directory. Overridable for tests only.
---@return string
function M.root()
  return M._root_override or (vim.fn.stdpath("state") .. "/worktree.nvim")
end

---_root_override lets the smoke suite point the store at a temp dir without
---touching the user's real state.
M._root_override = nil

---identity parses a repo identity — a remote URL or a local path — into the
---OWNER and NAME halves that `slug` joins.
---
---Exposed because a REVIEW must carry the pair: `review.validate` requires a
---non-empty url, or owner AND name. This function always computed both and
---then threw them away behind the joined slug, so a caller holding only a slug
---could not build a valid review — and every submit for a repo with NO remote
---was refused with "repo carries no identity". That made the repos panel's
---review submit impossible on any local-only repository, which is most of a
---scratch workspace (Johno, 2026-09-02: "not usable still").
---
---ONE parser, so the pair and the slug can never disagree about what a repo is
---called ([[shared-resolver-single-source-of-truth]]).
---@param identity string  a remote URL, or a path to the repo
---@return string owner, string name   both already path-safe
function M.identity(identity)
  local s = tostring(identity or "")
  -- Order matters: strip trailing slashes FIRST. `…/r.git/` would otherwise
  -- keep its `.git` (it is not at the end), the dot would sanitise to `-`, and
  -- the same repo would key to `o__r-git` with a slash and `o__r` without —
  -- splitting one repo's reviews across two directories.
  s = s:gsub("/+$", ""):gsub("%.git$", ""):gsub("/+$", "")
  local owner, repo

  -- git@host:owner/repo  |  ssh://git@host/owner/repo  |  https://host/owner/repo
  owner, repo = s:match("[:/]([^:/]+)/([^:/]+)$")
  if not owner then
    -- A single-segment name with no separator at all. Use it as the repo and
    -- mark the owner `local` so it cannot collide with a hosted `x/<name>`.
    repo = s:match("([^/\\]+)$") or "repo"
    owner = "local"
  end
  -- NOTE for a local PATH the two trailing segments become owner/repo — e.g.
  -- `/home/j/Source/nvim-plugins/autodb` -> `nvim-plugins__autodb`. That is
  -- deliberate: it is stable, descriptive, and keeps two same-named repos in
  -- different parents distinct, which a flat `local__autodb` would not.

  local function clean(part)
    -- Anything that is not clearly safe becomes `-`. This is the guard that
    -- makes the slug usable as a path segment: no `.`, `/`, `\` or NUL can
    -- survive, so `..` traversal is impossible by construction.
    return (tostring(part):gsub("[^%w%-_]", "-"))
  end
  return clean(owner), clean(repo)
end

---slug joins `identity`'s two halves into the filesystem-safe store key.
---@param identity string
---@return string slug
function M.slug(identity)
  local owner, repo = M.identity(identity)
  return owner .. "__" .. repo
end

---remote_identity resolves everything a caller needs to NAME a repo: the store
---slug, the remote URL when there is one, and the owner/name pair either way.
---
---A repo with no `origin` is named after its container, so it still has an
---identity a review can carry — being unhosted is not the same as being
---anonymous, and refusing to review a local repository was never the intent.
---@param common_dir string
---@return { slug: string, url: string?, owner: string, name: string }
function M.remote_identity(common_dir)
  local source, url
  if not common_dir or common_dir == "" then
    source = "repo"
  else
    local res = vim.system(
      { "git", "--git-dir=" .. common_dir, "config", "--get", "remote.origin.url" },
      {}):wait()
    local got = vim.trim((res.stdout or ""))
    if res.code == 0 and got ~= "" then
      source, url = got, got
    else
      -- No remote: key off the repo container. A bare repo's common dir is the
      -- repo itself (`…/autodb`), a checkout's is `…/autodb/.git`.
      source = common_dir:gsub("/%.git/?$", "")
    end
  end
  local owner, name = M.identity(source)
  return { slug = owner .. "__" .. name, url = url, owner = owner, name = name }
end

---remote_slug is `remote_identity`'s original two-value shape, kept for the
---callers that only ever wanted the key.
---@param common_dir string
---@return string slug, string? url
function M.remote_slug(common_dir)
  local id = M.remote_identity(common_dir)
  return id.slug, id.url
end

---### P4a — the leaf persistence layer DELEGATES (ADR-0081 §2.1)
---
---Everything below used to be implemented here. auto-core owns resource
---allocation, including reading and writing files, so these are now thin calls
---into `auto-core.docstore` — and the public signatures, return conventions and
---test seams are unchanged, which is what makes the phase additive (§5a).
---
---**No fallback.** The old `write_json` degraded to `io.open` when
---`auto-core.fs.atomic` was missing. That shape is deliberately not repeated: a
---fallback re-creates the duplicate implementation P6 exists to delete, and the
---one it falls back to is always the weaker of the two — which is exactly how
---auto-core's first store came to be less capable than this one (§2.2b). A
---missing hard dependency is a loud failure now.
local function _docstore()
  local ok, ds = pcall(require, "auto-core.docstore")
  if not ok or type(ds) ~= "table" or type(ds.write) ~= "function" then
    error("worktree.store: auto-core.docstore is required (auto-core >= v0.2.12)"
      .. " — worktree.nvim does not carry its own document I/O", 0)
  end
  return ds
end

---ensure_dir creates `path` with owner-only permissions and reports success.
---0700 because a review can quote source, and the watch list reveals what a
---user is working on — neither belongs to the group.
---@param path string
---@return boolean
function M.ensure_dir(path)
  return _docstore().ensure_dir(path)
end

---encode_pretty renders a value as indented JSON with stable key order.
---
---THE single family encoder, in auto-core (AC6). Kept as a named function here
---because callers and tests already reach it through `store.encode_pretty`, and
---the point of P4a is that no caller has to change.
---@param value any
---@return string
function M.encode_pretty(value)
  return _docstore().encode_pretty(value)
end

---write_json atomically serialises `value` to `path` as pretty, stable JSON.
---@param path string
---@param value any
---@return boolean ok, string? err
function M.write_json(path, value)
  if not path or path == "" then return false, "no path" end
  return _docstore().write_json(path, value)
end

---read_json reads and decodes, returning nil for ABSENT and an error string
---only for "present but unreadable" — a caller must be able to tell a fresh
---install from a corrupt file. auto-core enforces that only ENOENT is absence.
---@param path string
---@return any? value, string? err
function M.read_json(path)
  if not path or path == "" then return nil, "no path" end
  return _docstore().read_json(path)
end

---mtime returns a file's modification time in nanoseconds, or nil if absent.
---Used to invalidate an in-memory mirror when ANOTHER process has written the
---file — atomic rename keeps the content whole but says nothing about staleness.
---@param path string
---@return integer? mtime_ns
function M.mtime(path)
  return _docstore().mtime(path)
end

---LOCK_WAIT_MS is how long `with_lock` waits for a contested lock before
---refusing. A CONTENTION WINDOW and nothing more: age never establishes that a
---holder is dead (ADR-0060 r2 #1), and no code path breaks a lock.
---
---Still published HERE, and still authoritative: `with_lock` passes it to
---auto-core on every call, so setting it changes both the retry loop and the
---figure quoted in the refusal. A copied constant would have let the two drift
---the moment either side changed — the r5 should-fix 1 defect in a new costume.
M.LOCK_WAIT_MS = 10000

---LOCK_POLL_MS is the retry interval inside that window.
M.LOCK_POLL_MS = 10

---_parse_proc_stat extracts field 22 (starttime) from one /proc/<pid>/stat line.
---@param line string
---@return integer? starttime
function M._parse_proc_stat(line)
  return _docstore().lock._parse_proc_stat(line)
end

---_proc_start returns a process's start time, used to defeat PID REUSE.
---@param pid integer
---@return integer? starttime
function M._proc_start(pid)
  return _docstore().lock._proc_start(pid)
end

M._parse_proc_stat_for_tests = M._parse_proc_stat

---with_lock runs `fn` while holding an exclusive lock on `path`.
---
---Needed because atomic rename prevents a TORN file but not a LOST UPDATE: two
---processes can each read, each modify their own copy, and the second rename
---silently discards the first's change (ADR-0060 r1 MF1/MF2). Any
---read-modify-write of a shared store file must run in here.
---
---The mechanism now lives in `auto-core.docstore.lock`, with every property it
---had here: the JSON owner record (pid, host, process start time), the
---enum-driven liveness verdict, pid-reuse detection, the never-break rule, the
---inode-guarded release, and the offline-recovery text. It also reports a
---release that FAILS instead of returning success over a wedged store — the one
---thing that changed, and it changed in this direction on purpose (§2.2b).
---@param path string          the file being guarded (NOT the lock path)
---@param fn fun():any,any?    critical section; runs at most once
---@return any? value, string? err
function M.with_lock(path, fn)
  if not path or path == "" then return nil, "with_lock: no path" end
  return _docstore().with_lock(path, fn,
    { wait_ms = M.LOCK_WAIT_MS, poll_ms = M.LOCK_POLL_MS })
end

---create_exclusive writes `content` to `path` only if `path` does not exist,
---atomically, and reports whether the claim succeeded.
---
---`rename` cannot do this — it overwrites. auto-core writes a sibling temp in
---full and hard-LINKS it into place: `link` fails with EEXIST when the target
---is taken, which makes "claim this name" a single atomic step that can never
---publish a partially-written file. Used to claim a review revision so two
---agents cannot both take rN (r1 MF2).
---@param path string
---@param content string
---@return boolean claimed, string? err   claimed=false with err=nil means taken
function M.create_exclusive(path, content)
  if not path or path == "" then return false, "no path" end
  return _docstore().create_exclusive(path, content)
end

---Test seam for the liveness model (r3 #1): a test asserts the DECISION rather
---than the wording that happens to describe it.
---@param rec table?
---@return boolean
function M._owner_dead_for_tests(rec)
  return _docstore().lock._owner_dead_for_tests(rec)
end

---reviews_dir is where a repo's review files live.
---@param slug string
---@return string
function M.reviews_dir(slug)
  return M.root() .. "/reviews/" .. tostring(slug)
end

---watches_path is the single persisted watch registry.
---@return string
function M.watches_path()
  return M.root() .. "/watches.json"
end

---list_files returns the names in `dir` matching an optional Lua pattern,
---sorted. A missing directory is empty, not an error.
---@param dir string
---@param pattern string?
---@return string[]
function M.list_files(dir, pattern)
  return _docstore().list(dir or "", pattern)
end

---_reset_for_tests clears the root override.
function M._reset_for_tests() M._root_override = nil end

return M
