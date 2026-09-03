-- worktree — ADR-0067 §7: the concurrency and crash controls.
--
-- Run headless:
--   nvim --headless -u NONE -l tests/adr0067-a1-concurrency.lua
--
-- These are the controls the ADR calls load-bearing, and they are separate from
-- the A1 suite because they cannot be expressed in one process. A single-process
-- test cannot open the window it claims to close: `create_exclusive` only races
-- against a real second writer, and a phase crash only happens if something is
-- actually killed. Everything here forces its interleaving rather than hoping
-- for it — a test that runs two writers and sees no failure has proved nothing
-- about a window it never opened.
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path

-- auto-core must be on the rtp of the PARENT and of every CHILD process.
-- worktree.store is a delegation now (ADR-0081 P4a), so a process without
-- auto-core is not running a smaller version of this plugin -- it is running a
-- different program, and before P4a the old `io.open` fallback silently made
-- that look fine. Two suites had never had auto-core on their rtp at all; the
-- fallback was hiding it.
local plugins = vim.fn.fnamemodify(root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local branch_dir = vim.fn.fnamemodify(root, ":t")
local AUTO_CORE
for _, p in ipairs({
  LAZY .. "/auto-core.nvim",
  plugins .. "/auto-core.nvim/main",
  plugins .. "/auto-core.nvim/" .. branch_dir,  -- same-branch sibling wins
}) do
  if vim.fn.isdirectory(p) == 1 then AUTO_CORE = p end
end
if AUTO_CORE then vim.opt.runtimepath:prepend(AUTO_CORE) end
-- Passed to every child nvim, so the templates below need no edits.
local AC_ARGS = AUTO_CORE and { "--cmd", "set runtimepath^=" .. AUTO_CORE } or {}
local function nvim_argv(script)
  local a = { "nvim", "--headless", "-u", "NONE" }
  for _, x in ipairs(AC_ARGS) do a[#a + 1] = x end
  a[#a + 1] = "-l"; a[#a + 1] = script
  return a
end

local sb = vim.fn.tempname() .. "-a1conc"
vim.env.XDG_STATE_HOME = sb .. "/state"
vim.env.XDG_CONFIG_HOME = sb .. "/config"
vim.env.XDG_CACHE_HOME = sb .. "/cache"
vim.env.AUTO_AGENTS_KB_ROOT = sb .. "/kb"

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; io.stdout:write("  PASS  " .. n .. "\n")
  else fail = fail + 1; io.stdout:write("  FAIL  " .. n .. "  " .. tostring(d or "") .. "\n") end
  io.stdout:flush()
end

local store = require("worktree.store")
local review = require("worktree.review")
store._root_override = sb .. "/wtstore"

local SLUG = "o__r"

-- A writer, as a standalone script run by a REAL second nvim.
local WRITER = [[
-- A START SENTINEL, before anything can fail. Its absence means this child
-- never executed Lua at all -- a launch or runtime-isolation problem -- while
-- its presence with no OK means the child ran and the store refused. Without
-- it, both cases looked like "empty stdout" (lector MF7).
io.stderr:write("CHILD-START\n")
local root = "%s"
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. package.path
vim.env.AUTO_AGENTS_KB_ROOT = "%s"
local store = require("worktree.store"); local review = require("worktree.review")
store._root_override = "%s"
local sha = "%s"
local doc = review.from_draft({ slug = "o__r" }, sha, "lector",
  { comments = { { path = "a.go", line = 1, side = "RIGHT", severity = "nit", body = "%s" } } })
%s
local res, err = review.save_pair("o__r", doc, "# review %s", { topic = "%s" })
io.stdout:write((res and ("OK " .. res.revision .. " " .. res.md_path) or ("ERR " .. tostring(err))) .. "\n")
]]

local function writer_script(sha, tag, extra)
  local path = vim.fn.tempname() .. "-writer.lua"
  vim.fn.writefile(vim.split(
    WRITER:format(root, vim.env.AUTO_AGENTS_KB_ROOT, store._root_override,
                  sha, tag, extra or "", tag, tag), "\n"), path)
  return path
end

io.stdout:write("\n[1] two INDEPENDENT processes produce two complete pairs\n")
do
  local sha = string.rep("1", 40)
  local a = writer_script(sha, "alpha")
  local b = writer_script(sha, "beta")
  -- Started together so their reservations genuinely contend.
  local ja = vim.system(nvim_argv(a), { text = true })
  local jb = vim.system(nvim_argv(b), { text = true })
  local ra, rb = ja:wait(), jb:wait()
  local outa, outb = vim.trim(ra.stdout or ""), vim.trim(rb.stdout or "")

  -- DIAGNOSTICS ON FAILURE, and enough of them to tell a child that never ran
  -- from a store that raced (lector MF7). This suite aborted intermittently
  -- with no summary line, and the evidence needed to explain it -- the child's
  -- exit code, its signal, its stderr, the argv it was launched with -- was
  -- discarded before the abort. An empty stdout and a crashed allocator looked
  -- identical, so nine clean re-runs proved nothing either way.
  local function child_detail(tag, res, script)
    return ("%s: code=%s signal=%s stdout=%q stderr=%q argv=%s script=%s")
      :format(tag, tostring(res.code), tostring(res.signal),
              vim.trim(res.stdout or ""), vim.trim(res.stderr or ""),
              vim.inspect(nvim_argv(script)):gsub("%s+", " "), script)
  end
  -- CLASSIFY the failure rather than leaving it to a re-run. Lector asks
  -- whether the intermittent abort is child launch/runtime isolation or the
  -- store; the harness can answer that itself from what each child reported.
  local function classify(res)
    local started = tostring(res.stderr or ""):find("CHILD-START", 1, true) ~= nil
    if not started then return "never-started" end
    if res.signal and res.signal ~= 0 then return "killed-by-signal" end
    if vim.trim(res.stdout or ""):find("^OK") then return "ok" end
    if res.code ~= 0 then return "exited-nonzero" end
    return "ran-but-refused"
  end
  local ca, cb = classify(ra), classify(rb)
  local both_ok = (ca == "ok") and (cb == "ok")
  ok("both writers succeeded", both_ok,
    ("A=%s B=%s\n      %s\n      %s"):format(ca, cb,
      child_detail("A", ra, a), child_detail("B", rb, b)))
  if not both_ok then
    -- Stated as its own assertion so a failing run SAYS which cause it was,
    -- in the summary, instead of leaving it to whoever reads the log.
    local environmental = (ca == "never-started" or ca == "killed-by-signal"
      or cb == "never-started" or cb == "killed-by-signal")
    ok(("the failure is a STORE fault, not child launch/isolation (A=%s B=%s)")
      :format(ca, cb), not environmental,
      environmental
        and "ENVIRONMENTAL: a child did not start or was killed — this gate did"
            .. " not exercise the allocator at all"
        or "the children ran; the store is the suspect")
  end

  local revs = review.list_for(SLUG, sha)
  local two = #revs == 2
  ok("*** two distinct revisions exist ***", two,
    vim.inspect(vim.tbl_map(function(r) return r.revision end, revs))
    .. (two and "" or ("  " .. child_detail("A", ra, a)
                       .. "  ||  " .. child_detail("B", rb, b))))

  -- STOP HERE when the two-writer PRECONDITION failed. Everything below reads
  -- `revs[1]` and `revs[2]`; indexing a missing revision is what turned four
  -- failed assertions into an aborted suite with no summary at all, which is
  -- strictly less information than the failures themselves.
  if not two then
    ok("SKIPPED the pair assertions: the two-writer precondition failed above",
      false, "not run — fix the precondition first")
  else
    local docs, bodies = {}, {}
    for _, r in ipairs(revs) do
      local d = review.load(SLUG, sha, r.revision)
      docs[#docs + 1] = d and d.document
      if d and d.document then
        bodies[#bodies + 1] = table.concat(vim.fn.readfile(d.document), "")
      end
    end
    ok("*** each JSON names its OWN document — no shared Markdown ***",
      #docs == 2 and docs[1] ~= docs[2], vim.inspect(docs))
    ok("and both documents exist with distinct content",
      #bodies == 2 and bodies[1] ~= bodies[2], vim.inspect(bodies))
    ok("neither reservation survives its commit",
      vim.fn.filereadable(review.reserve_path(SLUG, sha, revs[1].revision)) == 0
      and vim.fn.filereadable(review.reserve_path(SLUG, sha, revs[2].revision)) == 0)
  end
end

io.stdout:write("\n[2] a process KILLED at each phase leaves only a tolerable remnant\n")
do
  -- The reader's guarantee is the one that matters: `list_for`/`load` must never
  -- return a review whose document is missing, whatever was interrupted.
  -- NOTE: single `%` in these patterns. They are string.format ARGUMENTS, not
  -- part of the template, and format only reduces escapes in the format string
  -- — so `%%` reached the generated script verbatim and matched nothing. The
  -- kill silently never fired, and the "no unpaired JSON" assertion passed
  -- because there was no JSON at all. Only the positive controls exposed it.
  local phases = {
    { name = "after the reservation",
      -- Patched at auto-core's primitive, not worktree's. ADR-0081 P4b moved
      -- the reservation claim into `auto-core.docstore.revisions`, so a writer
      -- no longer reaches `store.create_exclusive` to reserve -- and this
      -- injection silently stopped firing, which the positive control caught.
      -- The test follows the property to where it now lives; the property
      -- itself (a writer killed after reserving leaves no unpaired JSON) is
      -- unchanged. Both returns are preserved: dropping the error would make a
      -- refused claim look like a successful one.
      extra = 'local _ds = require("auto-core.docstore")\n'
        .. 'local real = _ds.create_exclusive\n'
        .. '_ds.create_exclusive = function(p, b)\n'
        .. '  local r, e = real(p, b)\n'
        .. '  if tostring(p):find("%.reserve$") then (vim.uv or vim.loop).kill((vim.uv or vim.loop).os_getpid(), 9) end\n'
        .. '  return r, e\nend' },
    { name = "after the JSON commit",
      -- The remnant here is a COMPLETE pair: the commit point has passed, so
      -- only the reservation can be left over. Absent from r1, and it is the
      -- phase that proves the commit point is where the ADR says it is.
      after_commit = true,
      extra = 'local real = store.create_exclusive\n'
        .. 'store.create_exclusive = function(p, b)\n'
        .. '  local r = real(p, b)\n'
        .. '  if tostring(p):find("%.review%.json$") then (vim.uv or vim.loop).kill((vim.uv or vim.loop).os_getpid(), 9) end\n'
        .. '  return r\nend' },
    { name = "after the Markdown claim",
      extra = 'local real = store.create_exclusive\n'
        .. 'store.create_exclusive = function(p, b)\n'
        .. '  local r = real(p, b)\n'
        .. '  if tostring(p):find("%-review%.md$") then (vim.uv or vim.loop).kill((vim.uv or vim.loop).os_getpid(), 9) end\n'
        .. '  return r\nend' },
  }
  for i, ph in ipairs(phases) do
    local sha = string.rep(tostring(i + 1), 40)
    local tag = "killed" .. i
    local sc = writer_script(sha, tag, ph.extra)
    vim.system(nvim_argv(sc), { text = true }):wait()
    local revs = review.list_for(SLUG, sha)
    local unpaired = false
    for _, r in ipairs(revs) do
      local d = review.load(SLUG, sha, r.revision)
      if d and (not d.document or vim.fn.filereadable(d.document) == 0) then
        unpaired = true
      end
    end
    -- "No unpaired JSON" is satisfied by having NO JSON at all, so assert the
    -- expected remnant per phase as well. Otherwise a writer that never ran
    -- would pass this control.
    -- The reservation may not be at r1: earlier sections share this reviews
    -- directory, so a name can already be taken and the writer advances. Look
    -- for ANY reservation for this sha, and identify the orphan by its CONTENT
    -- rather than by a revision guessed in the test.
    local reserved = false
    for rev = 1, 8 do
      if vim.fn.filereadable(review.reserve_path(SLUG, sha, rev)) == 1 then reserved = true end
    end
    local mds = vim.fn.glob(
      ("%s/agents/lector/reviews/*-review.md"):format(vim.env.AUTO_AGENTS_KB_ROOT),
      false, true)
    local md_here = false
    for _, f in ipairs(mds) do
      if table.concat(vim.fn.readfile(f), ""):find(tag, 1, true) then md_here = true end
    end
    ok(("*** killed %s: no reader ever sees a JSON without its document ***"):format(ph.name),
      not unpaired, ("%d canonical revision(s)"):format(#revs))
    if ph.after_commit then
      ok(("killed %s: the writer really got that far (positive control)"):format(ph.name),
        #revs == 1, "the commit must have happened before the kill")
    else
      ok(("killed %s: the writer really got that far (positive control)"):format(ph.name),
        reserved, "a reservation must exist, or the kill fired before any work")
    end
    if not ph.after_commit then
      ok(("killed %s: NO canonical JSON was published"):format(ph.name),
        #revs == 0, ("%d revision(s)"):format(#revs))
    end
    if ph.after_commit then
      -- Past the commit point: the pair must be COMPLETE, not a remnant.
      ok("*** killed after the JSON commit: the pair is COMPLETE ***",
        #revs == 1 and md_here, ("%d revision(s), md=%s"):format(#revs, tostring(md_here)))
      local d = revs[1] and review.load(SLUG, sha, revs[1].revision)
      ok("killed after the JSON commit: and the JSON names its document",
        d ~= nil and d.document ~= nil and vim.fn.filereadable(d.document) == 1,
        vim.inspect(d and d.document))
    elseif ph.name == "after the reservation" then
      ok("killed after the reservation: and no Markdown either", not md_here)
    else
      ok("*** killed after the Markdown claim: the ORPHAN Markdown is on disk ***",
        md_here, vim.inspect(mds))
    end
  end
end

io.stdout:write("\n[3] a GENUINELY write-denied store: tombstone fails, reservation FENCES\n")
do
  local sha = string.rep("8", 40)
  local doc = review.from_draft({ slug = SLUG }, sha, "lector",
    { comments = { { path = "a", line = 1, side = "RIGHT", severity = "nit", body = "x" } } })
  local dir = store.reviews_dir(SLUG)
  store.ensure_dir(dir)

  -- REAL permissions, not an injected create_exclusive error. An injected error
  -- is a stub agreeing with the test; `chmod 0500` is the condition a read-only
  -- store actually presents, and it denies the JSON and the tombstone for the
  -- same reason — which is exactly the case the reservation fallback exists for.
  -- The reservation is created while the directory is still writable, then the
  -- permissions drop at the Markdown claim (which lives in the KB, not here).
  local real = store.create_exclusive
  local dropped = false
  store.create_exclusive = function(pth, b)
    local r, e = real(pth, b)
    if not dropped and tostring(pth):find("%-review%.md$") then
      dropped = true
      vim.fn.system({ "chmod", "0500", dir })
    end
    return r, e
  end
  local res, err = review.save_pair(SLUG, doc, "# body", { topic = "denied" })
  store.create_exclusive = real
  vim.fn.system({ "chmod", "0700", dir })

  ok("the write really was denied (positive control)", dropped,
    "the chmod must have fired, or this proves nothing")
  ok("the submission fails", res == nil, tostring(res))
  ok("*** and reports BOTH the write failure and the un-tombstoned revision ***",
    err and err:find("not lost", 1, true) and err:find("reservation retained", 1, true),
    tostring(err))
  ok("*** the reservation is RETAINED as the fence ***",
    vim.fn.filereadable(review.reserve_path(SLUG, sha, 1)) == 1,
    review.reserve_path(SLUG, sha, 1))
  ok("no tombstone could be written either (that is the point)",
    vim.fn.filereadable(review.tombstone_path(SLUG, sha, 1)) == 0)
  ok("*** so the next write SKIPS that revision once writes are possible again ***",
    (function()
      local d2 = review.from_draft({ slug = SLUG }, sha, "lector",
        { comments = { { path = "a", line = 1, side = "RIGHT", severity = "nit", body = "y" } } })
      local r2 = review.save_pair(SLUG, d2, "# body2", { topic = "denied2" })
      return r2 ~= nil and r2.revision > 1
    end)(), "the retained reservation must keep r1 out of circulation")
end

io.stdout:write("\n[4] forced interleavings\n")
do
  -- (a) A cleanup landing AFTER the owner's final recheck and BEFORE the JSON
  -- create — the window the ADR names. Running it while our lease is current
  -- only proves a live lease survives; to prove "complete pair PLUS a redundant
  -- tombstone" the cleanup has to actually tombstone, so the lease is expired
  -- first and the cleanup is fired from inside the JSON create.
  local sha = string.rep("9", 40)
  local doc = review.from_draft({ slug = SLUG }, sha, "lector",
    { comments = { { path = "a", line = 1, side = "RIGHT", severity = "nit", body = "x" } } })
  local real = store.create_exclusive
  local fired, target = false, nil
  store.create_exclusive = function(pth, b)
    if not fired and tostring(pth):find("%.review%.json$") then
      fired = true
      target = tonumber(tostring(pth):match("%.r(%d+)%.review%.json$"))
      -- expire OUR reservation, then let a cleanup reap it, all before the
      -- commit that is already authorised.
      real = real
      local rp = review.reserve_path(SLUG, sha, target)
      vim.fn.writefile({ vim.json.encode({ owner = "ours", lease_until = os.time() - 1 }) }, rp)
      review.cleanup(SLUG, sha)
    end
    return real(pth, b)
  end
  local res = review.save_pair(SLUG, doc, "# body", { topic = "interleave" })
  store.create_exclusive = real

  ok("the interleaving really fired (positive control)", fired,
    "the cleanup must have run inside the JSON create")
  ok("*** the pair still COMMITS despite a cleanup mid-write ***", res ~= nil,
    "an already-authorised commit must not be undone by a concurrent reclaim")
  ok("and the committed pair loads with its document",
    res and (function()
      local d = review.load(SLUG, sha, res.revision)
      return d ~= nil and d.document and vim.fn.filereadable(d.document) == 1
    end)())
  ok("*** leaving a REDUNDANT tombstone beside a complete pair ***",
    target and vim.fn.filereadable(review.tombstone_path(SLUG, sha, target)) == 1,
    tostring(target))
  ok("which is benign: the reader sees a valid pair, not a retired revision",
    res and review.load(SLUG, sha, res.revision) ~= nil)

  -- (b) Two INDEPENDENT concurrent cleanups on one expired reservation.
  -- Sequential calls in one Lua state cannot race; these are separate
  -- processes started together.
  local sha2 = string.rep("7", 40)
  store.ensure_dir(store.reviews_dir(SLUG))
  local dead = 1
  store.create_exclusive(review.reserve_path(SLUG, sha2, dead),
    vim.json.encode({ owner = "crashed", lease_until = os.time() - 1 }))
  local CLEAN = ([[
local root = "%s"
vim.opt.runtimepath:prepend(root)
package.path = root .. "/lua/?.lua;" .. package.path
local store = require("worktree.store"); local review = require("worktree.review")
store._root_override = "%s"
io.stdout:write(tostring(review.cleanup("%s", "%s")) .. "\n")
]]):format(root, store._root_override, SLUG, sha2)
  local cp = vim.fn.tempname() .. "-clean.lua"
  vim.fn.writefile(vim.split(CLEAN, "\n"), cp)
  local j1 = vim.system(nvim_argv(cp), { text = true })
  local j2 = vim.system(nvim_argv(cp), { text = true })
  local o1, o2 = j1:wait(), j2:wait()
  local n1 = tonumber(vim.trim(o1.stdout or "")) or -1
  local n2 = tonumber(vim.trim(o2.stdout or "")) or -1
  -- BOTH may report a retirement, and that is deliberate: `retire` treats "a
  -- tombstone is already there" as success, because the revision is fenced
  -- either way and a loser that reported failure would invite a caller to
  -- retry something already done. The invariant is the ARTIFACT — exactly one
  -- tombstone — not the number of reporters.
  ok("*** two INDEPENDENT cleanups produce exactly ONE tombstone ***",
    vim.fn.filereadable(review.tombstone_path(SLUG, sha2, dead)) == 1
    and #vim.fn.glob(store.reviews_dir(SLUG) .. "/*@" .. sha2:sub(1, 7)
        .. ".r*.tombstone", false, true) == 1,
    ("reported %d + %d"):format(n1, n2))
  ok("and neither process failed", n1 >= 0 and n2 >= 0, ("%d + %d"):format(n1, n2))
  ok("at least one of them did the retiring", (n1 + n2) >= 1, ("%d + %d"):format(n1, n2))

  -- A cleanup run AFTER the commit adds nothing: the committed revision is
  -- fenced by its canonical JSON. (The redundant tombstone above was written
  -- BEFORE that JSON existed, which is why it is redundant rather than wrong —
  -- asserting "no tombstone on a committed revision" here would contradict it.)
  local before_tomb = #vim.fn.glob(store.reviews_dir(SLUG) .. "/*@" .. sha:sub(1, 7)
    .. ".r*.tombstone", false, true)
  review.cleanup(SLUG, sha)
  ok("*** a cleanup after the commit adds no tombstone ***",
    #vim.fn.glob(store.reviews_dir(SLUG) .. "/*@" .. sha:sub(1, 7) .. ".r*.tombstone",
      false, true) == before_tomb,
    ("%d tombstone(s) before and after"):format(before_tomb))
end

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
