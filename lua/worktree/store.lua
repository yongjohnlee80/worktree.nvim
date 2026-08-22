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

---LOCK_STALE_MS is the contention window before `with_lock` gives up. It is NOT
---a staleness proof: age cannot establish that a holder is dead (ADR-0060 r2
---#1). Liveness is decided by `_owner_dead` below.
M.LOCK_STALE_MS = 10000

---LOCK_ABANDONED_MS is the LAST-RESORT backstop for a lock we cannot judge —
---one with no parseable owner record (a legacy zero-byte lock, or a truncated
---write). Deliberately far longer than any plausible critical section here,
---because breaking on age is exactly the mistake this module made before.
M.LOCK_ABANDONED_MS = 15 * 60 * 1000

---_proc_start returns a process's start time, used to defeat PID REUSE: a pid
---alone is not an identity, because the OS reuses pids and a recycled one would
---make a dead owner look alive (or worse, a live stranger look like our
---holder).
---
---Linux exposes it as field 22 of /proc/<pid>/stat. Elsewhere this returns nil
---and the liveness check degrades to pid-only, which is still strictly better
---than age.
---@param pid integer
---@return integer? starttime
function M._proc_start(pid)
  if type(pid) ~= "number" then return nil end
  local fd = io.open("/proc/" .. pid .. "/stat", "r")
  if not fd then return nil end
  local line = fd:read("*l") or ""
  fd:close()
  -- The comm field can contain spaces and parentheses, so count from the LAST
  -- ")" rather than splitting the whole line.
  local tail = line:match("%)%s+(.*)$")
  if not tail then return nil end
  local n, i = nil, 0
  for word in tail:gmatch("%S+") do
    i = i + 1
    if i == 20 then n = tonumber(word) break end -- field 22 overall
  end
  return n
end

---_owner_record describes THIS process as the lock's owner.
local function _owner_record()
  return {
    pid = uv.os_getpid and uv.os_getpid() or nil,
    host = uv.os_gethostname and uv.os_gethostname() or nil,
    start = M._proc_start(uv.os_getpid and uv.os_getpid() or -1),
  }
end

---_owner_dead reports whether a lock's owner is PROVABLY gone.
---
---Conservative by design: every uncertain answer is "not dead", because
---breaking a live holder's lock lets two writers into the same
---read-modify-write — the lost update this lock exists to prevent.
---@param rec table?   decoded owner record
---@return boolean
local function _owner_dead(rec)
  if type(rec) ~= "table" or type(rec.pid) ~= "number" then return false end
  -- Another machine's lock is not ours to judge: its pids mean nothing here.
  local host = uv.os_gethostname and uv.os_gethostname() or nil
  if rec.host and host and rec.host ~= host then return false end
  if not (uv.kill and uv.os_getpid) then return false end
  if rec.pid == uv.os_getpid() then return false end -- ourselves, re-entering

  local ok_sig, sig_err = uv.kill(rec.pid, 0)
  if ok_sig ~= 0 then
    -- Only "no such process" proves death. EPERM means the process EXISTS and
    -- this user may not signal it — treating that as dead was a direct
    -- contradiction of this function's own contract (r3 #1). Anything we cannot
    -- positively read as ESRCH is alive.
    local msg = tostring(sig_err or "")
    if msg:find("ESRCH") or msg:find("no such process") then return true end
    return false
  end
  do
    -- The pid is live. Is it still the SAME process, or a reused pid?
    local now_start = M._proc_start(rec.pid)
    if rec.start and now_start and rec.start ~= now_start then
      return true -- pid reused: the original owner is gone
    end
    return false  -- genuinely alive; never break it
  end
end

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
---_break_stale removes `lock` ONLY if it is still the inode we judged.
---
---An unconditional unlink here was a takeover race (r3 #1): two contenders read
---the same dead owner, A unlinked and acquired, then B executed the unlink its
---now-STALE read had justified and deleted A's LIVE successor, admitting a
---second writer. The release path was already inode-checked; acquisition was
---not, and a release-time check cannot undo an unlink that already happened.
---@param lock string
---@param seen_ino integer?   the inode the caller's decision was based on
---@return boolean removed
local function _break_stale(lock, seen_ino)
  local st = uv.fs_stat(lock)
  if not st then return false end                 -- already gone
  if seen_ino and st.ino ~= seen_ino then return false end  -- a successor: not ours
  return (pcall(uv.fs_unlink, lock))
end

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

    -- Held. Break it ONLY on proven death of the owner. Age is not liveness: a
    -- live holder can exceed any window on a filesystem stall, a scheduler
    -- suspension or a debugger, and breaking it admits a second writer to the
    -- same read-modify-write — the lost update this lock exists to prevent
    -- (ADR-0060 r2 #1). A heartbeat would not help either: a process stalled
    -- in fsync cannot refresh its own mtime, which is precisely when the old
    -- age check fired.
    -- Capture the inode our decision is based on, so the unlink below cannot
    -- act on a lock that was replaced in the meantime (r3 #1).
    local seen = uv.fs_stat(lock)
    local seen_ino = seen and seen.ino or nil
    local rec = select(1, M.read_json(lock))
    if _owner_dead(rec) then
      _break_stale(lock, seen_ino)
    elseif rec == nil then
      -- No parseable owner (a legacy zero-byte lock, or a torn write). We
      -- cannot judge it, so fall back to age at a MUCH longer horizon — this
      -- is a backstop against a permanently wedged registry, not a routine
      -- path. Nothing on the system garbage-collects this file, so refusing
      -- forever would turn one SIGKILL into an unrecoverable failure.
      local secs = seen and seen.mtime and seen.mtime.sec or nil
      if secs and (os.time() - secs) * 1000 > M.LOCK_ABANDONED_MS then
        -- DOCUMENTED RESIDUAL RISK (r3 #1). This is the one path where age
        -- still decides, and it is therefore a LEASE, not strict mutual
        -- exclusion: a live holder whose owner record was torn mid-write and
        -- which then stalls past the horizon can still be broken. Accepted
        -- deliberately — the alternative is a permanently wedged registry that
        -- only manual removal of a dotfile can clear — but it is logged, so a
        -- forced break is never silent.
        if _break_stale(lock, seen_ino) then
          local ok_log, log = pcall(require, "worktree.log")
          if ok_log then
            log.warn("store", ("force-broke an unreadable lock after %d minutes: %s"
              .. " — if this recurs, a writer is failing mid-write")
              :format(M.LOCK_ABANDONED_MS / 60000, lock))
          end
        end
      end
    end
    vim.wait(10)
  end
  if not fd then return nil, "with_lock: could not acquire " .. lock end

  -- Stamp ownership INTO the lock so a contender can judge us the same way.
  -- The file used to be created and never written — zero bytes, no identity.
  local ok_enc, encoded = pcall(vim.json.encode, _owner_record())
  if ok_enc then pcall(uv.fs_write, fd, encoded, 0) end
  local mine = uv.fs_fstat(fd)

  -- Release on EVERY path, including a throw: a leaked lock would block the
  -- next writer until the abandoned-lock backstop expires.
  local ok, value, err = pcall(fn)
  pcall(uv.fs_close, fd)

  -- Unlink only if the pathname STILL refers to the file we created. After any
  -- break — including a legitimate one — a straggler reaching this line would
  -- otherwise delete the SUCCESSOR's lock by pathname and admit a third writer.
  local now = uv.fs_stat(lock)
  if now and mine and now.ino == mine.ino then
    pcall(uv.fs_unlink, lock)
  end

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

---Test seams for the takeover protocol and the liveness model (r3 #1).
M._break_stale_for_tests = _break_stale
M._owner_dead_for_tests = _owner_dead

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
