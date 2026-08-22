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

local uv = vim.uv or vim.loop

---root is the store's base directory. Overridable for tests only.
---@return string
function M.root()
  return M._root_override or (vim.fn.stdpath("state") .. "/worktree.nvim")
end

---_root_override lets the smoke suite point the store at a temp dir without
---touching the user's real state.
M._root_override = nil

---slug turns a repo identity into a filesystem-safe `<owner>__<repo>`.
---
---Accepts anything that names a repo: an SSH remote, an HTTPS remote, or a
---bare local path. A local repo with no remote still needs a stable key, so it
---falls back to the directory name — and the result is sanitised, because this
---string becomes a PATH SEGMENT and must never be able to escape the store.
---@param identity string   remote url, or a filesystem path
---@return string slug
function M.slug(identity)
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
  return clean(owner) .. "__" .. clean(repo)
end

---remote_slug resolves a repo's slug from its own git config, falling back to
---the common dir's name when the repo has no `origin`.
---@param common_dir string
---@return string slug, string? url
function M.remote_slug(common_dir)
  if not common_dir or common_dir == "" then return M.slug("repo"), nil end
  local res = vim.system(
    { "git", "--git-dir=" .. common_dir, "config", "--get", "remote.origin.url" },
    {}):wait()
  local url = vim.trim((res.stdout or ""))
  if res.code == 0 and url ~= "" then return M.slug(url), url end
  -- No remote: key off the repo container. A bare repo's common dir is the
  -- repo itself (`…/autodb`), a checkout's is `…/autodb/.git`.
  local dir = common_dir:gsub("/%.git/?$", "")
  return M.slug(dir), nil
end

---ensure_dir creates `path` with owner-only permissions and reports success.
---0700 because a review can quote source, and the watch list reveals what a
---user is working on — neither belongs to the group.
---@param path string
---@return boolean
function M.ensure_dir(path)
  if not path or path == "" then return false end
  if uv.fs_stat(path) then return true end
  return vim.fn.mkdir(path, "p", tonumber("700", 8)) == 1
end

---write_json atomically serialises `value` to `path`.
---@param path string
---@param value any
---@return boolean ok, string? err
function M.write_json(path, value)
  if not path or path == "" then return false, "no path" end
  local ok_enc, encoded = pcall(vim.json.encode, value)
  if not ok_enc then return false, "encode failed: " .. tostring(encoded) end
  if not M.ensure_dir(vim.fn.fnamemodify(path, ":h")) then
    return false, "could not create " .. vim.fn.fnamemodify(path, ":h")
  end
  local ok_atomic, atomic = pcall(require, "auto-core.fs.atomic")
  if ok_atomic and type(atomic.write) == "function" then
    local wok = atomic.write(path, encoded)
    if not wok then return false, "atomic write failed" end
    return true, nil
  end
  -- auto-core is a hard dependency, so this path is a defensive fallback for a
  -- version older than the atomic primitive (>= 0.1.58).
  local fd = io.open(path, "w")
  if not fd then return false, "could not open " .. path end
  fd:write(encoded); fd:close()
  return true, nil
end

---read_json reads and decodes, returning nil for "absent" and an error string
---only for "present but unreadable". A caller must be able to tell a fresh
---install from a corrupt file.
---@param path string
---@return any? value, string? err
function M.read_json(path)
  if not path or path == "" then return nil, "no path" end
  if not uv.fs_stat(path) then return nil, nil end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then return nil, "unreadable: " .. path end
  local ok_dec, value = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_dec then return nil, "malformed json: " .. path end
  return value, nil
end

---mtime returns a file's modification time in nanoseconds, or nil if absent.
---Used to invalidate an in-memory mirror when ANOTHER process has written the
---file — atomic rename keeps the content whole but says nothing about staleness.
---@param path string
---@return integer? mtime_ns
function M.mtime(path)
  local st = path and path ~= "" and uv.fs_stat(path) or nil
  if not st or not st.mtime then return nil end
  return st.mtime.sec * 1000000000 + (st.mtime.nsec or 0)
end

---LOCK_STALE_MS is how long a lock may be held before another process may break
---it. A crashed nvim must not wedge the registry forever, and every critical
---section here is a read-decode-encode-write of a small file.
M.LOCK_STALE_MS = 10000

---with_lock runs `fn` while holding an exclusive lock on `path`.
---
---Needed because atomic rename prevents a TORN file but not a LOST UPDATE:
---two processes can each read, each modify their own copy, and the second
---rename silently discards the first's change (ADR-0060 r1 MF1/MF2). Any
---read-modify-write of a shared store file must run in here.
---
---The lock is a sibling `<path>.lock` created with O_EXCL, which is atomic on
---every filesystem we target. A lock older than `LOCK_STALE_MS` is assumed
---orphaned by a crash and broken, because refusing forever is worse than
---racing once.
---Returns at most TWO values from `fn`, which is all any caller here needs
---(`value, err`). Kept deliberately narrow: threading true varargs out would
---need `table.maxn`/`unpack`, whose availability differs across the Lua
---versions Neovim has shipped, for no benefit at these call sites.
---@param path string          the file being guarded (NOT the lock path)
---@param fn fun():any,any?    critical section; runs at most once
---@return any? value, string? err
function M.with_lock(path, fn)
  if not path or path == "" then return nil, "with_lock: no path" end
  if not M.ensure_dir(vim.fn.fnamemodify(path, ":h")) then
    return nil, "with_lock: could not create " .. vim.fn.fnamemodify(path, ":h")
  end
  local lock = path .. ".lock"
  local fd

  for _ = 1, 50 do -- ~500ms of contention before we give up
    fd = uv.fs_open(lock, "wx", tonumber("600", 8))
    if fd then break end
    -- Held. Break it only if it is provably stale; otherwise wait and retry.
    -- Wall clock is the right clock here: the holder may be another PROCESS,
    -- so a monotonic in-process timer says nothing about its age.
    local st = uv.fs_stat(lock)
    local held_secs = st and st.mtime and st.mtime.sec or nil
    if held_secs and (os.time() - held_secs) * 1000 > M.LOCK_STALE_MS then
      pcall(uv.fs_unlink, lock)
    end
    vim.wait(10)
  end
  if not fd then return nil, "with_lock: could not acquire " .. lock end

  -- Release on EVERY path, including a throw: a leaked lock would wedge the
  -- registry for LOCK_STALE_MS and make the next writer look broken.
  local ok, value, err = pcall(fn)
  pcall(uv.fs_close, fd)
  pcall(uv.fs_unlink, lock)

  if not ok then return nil, "with_lock: " .. tostring(value) end
  return value, err
end

---create_exclusive writes `content` to `path` only if `path` does not exist,
---atomically, and reports whether the claim succeeded.
---
---`rename` cannot do this — it overwrites. So the content is written to a
---sibling temp file in full and then hard-LINKED into place: `link` fails with
---EEXIST when the target is taken, which makes "claim this name" a single
---atomic step that can never publish a partially-written file. Used to claim a
---review revision so two agents cannot both take rN (r1 MF2).
---@param path string
---@param content string
---@return boolean claimed, string? err   claimed=false with err=nil means taken
function M.create_exclusive(path, content)
  if not path or path == "" then return false, "no path" end
  if not M.ensure_dir(vim.fn.fnamemodify(path, ":h")) then
    return false, "could not create " .. vim.fn.fnamemodify(path, ":h")
  end
  if uv.fs_stat(path) then return false, nil end -- cheap pre-check; link is the real gate

  local tmp = path .. ".claim." .. tostring(uv.os_getpid and uv.os_getpid() or 0)
  local fd, oerr = uv.fs_open(tmp, "w", tonumber("600", 8))
  if not fd then return false, "temp open failed: " .. tostring(oerr) end
  local wrote = uv.fs_write(fd, content, 0)
  pcall(uv.fs_fsync, fd)
  pcall(uv.fs_close, fd)
  if not wrote then
    pcall(uv.fs_unlink, tmp)
    return false, "temp write failed"
  end

  local linked, lerr = uv.fs_link(tmp, path)
  pcall(uv.fs_unlink, tmp)
  if linked then return true, nil end
  -- EEXIST is the expected "someone else claimed it" outcome, not a failure.
  if tostring(lerr):match("EEXIST") then return false, nil end
  return false, "link failed: " .. tostring(lerr)
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
  local out = {}
  local handle = uv.fs_scandir(dir or "")
  if not handle then return out end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then break end
    if typ ~= "directory" and (not pattern or name:match(pattern)) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---_reset_for_tests clears the root override.
function M._reset_for_tests() M._root_override = nil end

return M
