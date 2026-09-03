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
---encode_pretty renders a value as INDENTED JSON with stable key order.
---
---`vim.json.encode` produces a single minified line with keys in hash order —
---fine for a wire format, poor for a file a human opens and a git history that
---should diff cleanly. A review store holds tens of small documents, not
---millions, so the few extra bytes buy readability and a stable order across
---rewrites (Johno, 2026-09-03).
---
---Two-space indent, keys sorted, arrays kept in order. It handles exactly the
---JSON value shapes a review carries — table, string, number, boolean, nil — and
---leans on `vim.json.encode` for scalar escaping so string quoting stays
---correct. `vim.json.encode(nil)` yields "null", so an explicit nil check keeps
---an absent field from becoming the string "null".
---@param value any
---@param indent string?  internal — current indentation
---@return string
function M.encode_pretty(value, indent)
  indent = indent or ""
  local child = indent .. "  "
  local t = type(value)
  if t == "table" then
    -- An array iff its keys are exactly 1..n with no holes.
    local n, is_array = 0, true
    for k in pairs(value) do
      n = n + 1
      if type(k) ~= "number" then is_array = false end
    end
    if is_array and n == #value then
      if n == 0 then return "[]" end
      local parts = {}
      for _, v in ipairs(value) do
        parts[#parts + 1] = child .. M.encode_pretty(v, child)
      end
      return "[\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "]"
    end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = tostring(k) end
    if #keys == 0 then return "{}" end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      parts[#parts + 1] = child .. vim.json.encode(k) .. ": "
        .. M.encode_pretty(value[k], child)
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
  end
  -- Scalars: let vim.json.encode handle escaping and number/bool formatting.
  return vim.json.encode(value)
end

---write_json writes `value` as pretty, stable-ordered JSON.
function M.write_json(path, value)
  if not path or path == "" then return false, "no path" end
  local ok_enc, encoded = pcall(M.encode_pretty, value)
  if not ok_enc then return false, "encode failed: " .. tostring(encoded) end
  encoded = encoded .. "\n"
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

---LOCK_WAIT_MS is how long `with_lock` waits for a contested lock before
---refusing. It is a CONTENTION WINDOW and nothing more: age never establishes
---that a holder is dead (ADR-0060 r2 #1), and no code path breaks a lock.
---
---Renamed from `LOCK_STALE_MS`, which advertised 10000 ms while the retry loop
---was hard-coded to 50 iterations of 10 ms — a measured 505 ms (r5 should-fix
---1). The constant now DRIVES the loop, so the documented figure and the
---behaviour cannot drift apart again.
M.LOCK_WAIT_MS = 10000

---LOCK_POLL_MS is the retry interval inside that window.
M.LOCK_POLL_MS = 10


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
---already stale. `LOCK_WAIT_MS` is therefore a CONTENTION WINDOW, not a
---staleness proof — after it, acquisition fails and reports the recorded owner.
---
---The trade, stated plainly: a crashed holder leaves a lock that must be removed
---**offline**. That is chosen over automatic reclamation because a lost update in
---a shared registry is silent and unbounded, whereas a stuck lock is loud and
---names its own cause.
---
---Recovery is NOT a single `rm`. An earlier version of this docstring said it
---was, which is the same unsafe shortcut the error text had to drop: removing
---the file while any writer is running can delete a LIVE successor lock, because
---`rm` resolves a pathname and cannot be conditional on the inode any more than
---`fs_unlink` could. The procedure requires every writer stopped first, and it
---is written down in README.md ("Recovering a stuck lock") because the error
---message disappears the moment you follow its own first step.
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

  -- Deadline derived from the constant, not a hard-coded iteration count.
  local attempts = math.max(1, math.floor(M.LOCK_WAIT_MS / M.LOCK_POLL_MS))
  local open_err, open_code
  for _ = 1, attempts do
    -- Bind libuv's error (r5 should-fix 2). Previously any failure was treated
    -- as contention, so an EACCES on a directory we cannot write was reported
    -- as "an unreadable owner record from an older version" — a misleading
    -- diagnosis of a permissions problem. Only EEXIST means "someone holds it".
    local nfd, err, code = uv.fs_open(lock, "wx", tonumber("600", 8))
    if nfd then fd = nfd break end
    open_err, open_code = err, code
    if code ~= "EEXIST" then break end   -- not contention; stop and report it

    -- NO automatic takeover (r4 #1). libuv has no atomic conditional unlink:
    -- any `fs_stat` then `fs_unlink` leaves a window in which a successor is
    -- installed and then deleted by an already-stale decision. Three revisions
    -- of this code proved that a second check only moves the race. So a lock we
    -- do not own is never removed — it is REPORTED, with the identity needed to
    -- clear it deliberately and offline.
    held_by = select(1, M.read_json(lock))
    vim.wait(M.LOCK_POLL_MS)
  end

  if not fd then
    -- A non-EEXIST failure is not contention at all; say what it really was.
    if open_code and open_code ~= "EEXIST" then
      return nil, ("with_lock: cannot create %s (%s: %s)")
        :format(lock, tostring(open_code), tostring(open_err))
    end

    -- MANUAL RECOVERY REQUIRES GLOBAL QUIESCENCE (r5 must-fix). Saying "remove
    -- it to recover" moved the race out of the code and into the operator's
    -- hands: two repairers can both diagnose the same stale lock L, the first
    -- removes it, a writer acquires successor L2, and the second's `rm` — still
    -- justified by its own stale read — deletes L2, letting a fourth writer in
    -- beside the third. A pathname `rm` is no more conditional than
    -- `fs_unlink` was.
    --
    -- So the instruction is offline repair, not a one-liner: every Neovim that
    -- may write this directory must be stopped FIRST, so no writer can acquire
    -- a successor while the file is being removed.
    -- `liveness` is an ENUM driving the branch; the prose is derived FROM it.
    -- It was the other way round — `status:find("STILL RUNNING")` — which made
    -- a reworded sentence able to start advertising repair for a LIVE holder
    -- (r6 should-fix 2). I had just fixed a TEST for being coupled to prose and
    -- then coupled production control flow to prose in the same change.
    local who, liveness
    if type(held_by) == "table" and held_by.pid then
      who = ("pid %s on %s"):format(tostring(held_by.pid), tostring(held_by.host or "?"))
      local host = uv.os_gethostname and uv.os_gethostname() or nil
      if held_by.host and host and held_by.host ~= host then
        liveness = "unknown_host"
      elseif _owner_dead(held_by) then
        liveness = "dead"
      else
        liveness = "alive"
      end
    else
      who = "an owner record this version cannot read"
      liveness = "unknown_record"
    end

    local status = ({
      alive = "that process is STILL RUNNING, so this is normal contention",
      dead = "that process is NO LONGER RUNNING, so the lock is stale",
      unknown_host = "on another host, so its liveness is UNKNOWN from here",
      unknown_record = "liveness UNKNOWN (likely written by an older version)",
    })[liveness]

    -- Repair instructions are offered ONLY when the holder is not alive, keyed
    -- off the enum rather than off the wording above.
    local repair = ""
    if liveness ~= "alive" then
      repair = (" To clear a stale lock: QUIT EVERY Neovim that writes %s (on"
        .. " every host that mounts it), THEN remove %s, then restart. Removing"
        .. " it while any writer is running can delete a live successor lock."
        .. " Full procedure: README.md, \"Recovering a stuck lock\".")
        :format(M.root(), lock)
    end
    return nil, ("with_lock: could not acquire %s after %dms (held by %s — %s).%s")
      :format(lock, M.LOCK_WAIT_MS, who, status, repair)
  end

  -- Stamp ownership INTO the lock so a contender can judge us the same way.
  -- The file used to be created and never written — zero bytes, no identity.
  -- A lock we cannot STAMP is a lock nobody can diagnose, so a failed or PARTIAL
  -- write aborts rather than proceeding (r6 should-fix 1). Logging and carrying
  -- on left exactly the "unreadable owner record" state that costs the next
  -- writer its diagnosis — and reported success while doing it.
  ---_abandon closes and removes the lock we just created, and reports whether
  ---the removal actually happened. Binding libuv's result matters here for the
  ---same reason it mattered in the release path: `pcall` reports only whether
  ---Lua threw. This is the SEVENTH place in this module where an unbound
  ---`fs_unlink` had to be corrected — written into new cleanup code after the
  ---identical fix was made elsewhere — so it is a named helper now rather than
  ---a line to be re-typed.
  ---
  ---Removing OUR OWN lock is not the contested-pathname case: we created it a
  ---moment ago with O_EXCL and nothing else can hold it yet.
  ---@return string suffix  "" when clean, otherwise recovery text for the error
  local function _abandon()
    pcall(uv.fs_close, fd)
    local removed, uerr = uv.fs_unlink(lock)
    if removed then return "" end
    return (". The lock file %s COULD NOT be removed (%s) and will block the"
      .. " next writer — see README.md \"Recovering a stuck lock\"")
      :format(lock, tostring(uerr))
  end

  local ok_enc, encoded = pcall(vim.json.encode, _owner_record())
  if not ok_enc then
    return nil, ("with_lock: could not encode the owner record: %s%s")
      :format(tostring(encoded), _abandon())
  end
  local wrote, werr = uv.fs_write(fd, encoded, 0)
  if wrote ~= #encoded then
    return nil, ("with_lock: could not stamp the owner record on %s (wrote %s of"
      .. " %d bytes%s) — refusing rather than holding an unidentifiable lock%s")
      :format(lock, tostring(wrote), #encoded,
        werr and (": " .. tostring(werr)) or "", _abandon())
  end
  local mine = uv.fs_fstat(fd)

  -- Release on EVERY path, including a throw. There is no backstop that will
  -- clean up after us: a leaked lock blocks the next writer until someone
  -- removes it offline.
  local ok, value, err = pcall(fn)
  pcall(uv.fs_close, fd)

  -- Unlink only if the pathname STILL refers to the file we created. This is
  -- sound only because nothing removes a lock automatically any more; if
  -- takeover ever returns, this stat-then-unlink becomes a race again.
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

---Test seams for the liveness model (r3 #1). `_owner_dead_for_tests` backs the
---enum that drives the refusal text, so a test can assert the DECISION rather
---than the wording.
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
