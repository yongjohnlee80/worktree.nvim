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
---_parse_proc_stat extracts field 22 (starttime) from one /proc/<pid>/stat
---line. Split out from `_proc_start` so the parsing can be tested against a
---hostile comm without needing a real process to be named that way.
---@param line string
---@return integer? starttime
function M._parse_proc_stat(line)
  line = tostring(line or "")
  -- The comm field is parenthesised and may itself contain spaces AND
  -- parentheses, so the fields after it begin at the LAST ")" on the line.
  -- `line:match("%)%s+(.*)$")` did NOT do that: Lua takes the leftmost match,
  -- so a comm like `(nvim) shifted` made it start from the FIRST ") " and
  -- return the wrong field — the start time read as 0, which `_owner_dead`
  -- then reads as pid reuse and a live holder becomes "dead" (r4 #2). The
  -- comment claimed "LAST" while the code took the first: the fourth
  -- comment-contradicts-code defect found in this module, so it is now
  -- computed rather than pattern-matched.
  local close = nil
  for i = #line, 1, -1 do
    if line:sub(i, i) == ")" then close = i break end
  end
  if not close then return nil end
  local tail = line:sub(close + 1):match("^%s*(.*)$")
  if not tail or tail == "" then return nil end
  local n, i = nil, 0
  for word in tail:gmatch("%S+") do
    i = i + 1
    if i == 20 then n = tonumber(word) break end -- field 22 overall
  end
  return n
end

---@param pid integer
---@return integer? starttime
function M._proc_start(pid)
  if type(pid) ~= "number" then return nil end
  local fd = io.open("/proc/" .. pid .. "/stat", "r")
  if not fd then return nil end
  local line = fd:read("*l") or ""
  fd:close()
  return M._parse_proc_stat(line)
end

M._parse_proc_stat_for_tests = M._parse_proc_stat

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

  -- luv returns `0` on success, or `nil, message, CODE`. The third result is the
  -- stable errno name; matching the human-readable message was fragile across
  -- platforms and would silently mean "never break" if the wording differed
  -- (r4 should-fix 1).
  local ok_sig, _, sig_code = uv.kill(rec.pid, 0)
  if ok_sig ~= 0 then
    -- Only ESRCH proves death. EPERM means the process EXISTS and this user may
    -- not signal it; treating that as dead contradicted this function's own
    -- contract (r3 #1). Anything not positively ESRCH is alive.
    if sig_code == "ESRCH" then return true end
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
---every filesystem we target, and it CARRIES its owner (pid, host, process
---start time) so a contender can say who holds it.
---
---**A lock is never broken automatically.** Three revisions of this module tried
---to reclaim a dead owner's lock and each only moved the race: libuv exposes no
---atomic conditional unlink, so any `fs_stat` then `fs_unlink` leaves a window
---in which a successor is installed and then deleted by a decision that is
---already stale. `LOCK_STALE_MS` is therefore a CONTENTION WINDOW, not a
---staleness proof — after it, acquisition fails and reports the recorded owner.
---
---The trade, stated plainly: a crashed holder leaves a lock that must be removed
---by hand. That is chosen over automatic reclamation because a lost update in a
---shared registry is silent and unbounded, whereas a stuck lock is loud, names
---its own cause, and clears with one `rm`. The error text includes the pid, the
---host, and whether that process is still running.
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
  -- The owner record we last read off a contested lock, so the refusal can say
  -- WHO holds it rather than only that acquisition failed.
  local held_by

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
    -- NO automatic takeover (r4 #1). There is no atomic conditional unlink in
    -- libuv: any `fs_stat` then `fs_unlink` leaves a window in which a
    -- successor is installed and then deleted by our stale decision — moving
    -- the race rather than closing it, which is exactly what the previous two
    -- attempts here did. `pcall(uv.fs_unlink, ...)` also reports whether Lua
    -- threw, not whether libuv removed anything.
    --
    -- So we never remove a lock we do not own. A dead owner's lock is REPORTED,
    -- with the identity needed to clear it by hand. That trades automatic
    -- crash recovery for provable mutual exclusion, deliberately: a rare lost
    -- update in a shared registry is silent and unbounded, whereas a stuck lock
    -- is loud, diagnosable, and cleared by removing one named file.
    local rec = select(1, M.read_json(lock))
    held_by = rec
    vim.wait(10)
  end
  if not fd then
    local who
    if type(held_by) == "table" and held_by.pid then
      who = ("pid %s on %s"):format(tostring(held_by.pid), tostring(held_by.host or "?"))
      if _owner_dead(held_by) then
        who = who .. " — that process is NO LONGER RUNNING, so this lock is"
          .. " stale; remove it to recover"
      end
    else
      who = "an unreadable owner record (likely written by an older version)"
    end
    return nil, ("with_lock: could not acquire %s (held by %s)"):format(lock, who)
  end

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
    -- `pcall` would report only whether Lua threw, so bind libuv's own result
    -- (r4 #1). Nothing can replace our lock while we hold it now that automatic
    -- takeover is gone, which is what makes this stat-then-unlink sound.
    local removed, unlink_err = uv.fs_unlink(lock)
    if not removed then
      local ok_log, log = pcall(require, "worktree.log")
      if ok_log then
        log.warn("store", ("could not release %s: %s — the next writer will"
          .. " refuse until it is removed"):format(lock, tostring(unlink_err)))
      end
    end
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
