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
  local ja = vim.system({ "nvim", "--headless", "-u", "NONE", "-l", a }, { text = true })
  local jb = vim.system({ "nvim", "--headless", "-u", "NONE", "-l", b }, { text = true })
  local ra, rb = ja:wait(), jb:wait()
  local outa, outb = vim.trim(ra.stdout or ""), vim.trim(rb.stdout or "")
  ok("both writers succeeded", outa:find("^OK") and outb:find("^OK"),
    outa .. " | " .. outb)
  local revs = review.list_for(SLUG, sha)
  ok("*** two distinct revisions exist ***", #revs == 2,
    vim.inspect(vim.tbl_map(function(r) return r.revision end, revs)))
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
      extra = 'local real = store.create_exclusive\n'
        .. 'store.create_exclusive = function(p, b)\n'
        .. '  local r = real(p, b)\n'
        .. '  if tostring(p):find("%.reserve$") then (vim.uv or vim.loop).kill((vim.uv or vim.loop).os_getpid(), 9) end\n'
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
    vim.system({ "nvim", "--headless", "-u", "NONE", "-l", sc }, { text = true }):wait()
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
    ok(("killed %s: the writer really got that far (positive control)"):format(ph.name),
      reserved, "a reservation must exist, or the kill fired before any work")
    ok(("killed %s: NO canonical JSON was published"):format(ph.name),
      #revs == 0, ("%d revision(s)"):format(#revs))
    if i == 1 then
      ok("killed after the reservation: and no Markdown either", not md_here)
    else
      ok("*** killed after the Markdown claim: the ORPHAN Markdown is on disk ***",
        md_here, vim.inspect(mds))
    end
  end
end

io.stdout:write("\n[3] a write-denied store: tombstone fails, the reservation FENCES\n")
do
  local sha = string.rep("8", 40)
  local doc = review.from_draft({ slug = SLUG }, sha, "lector",
    { comments = { { path = "a", line = 1, side = "RIGHT", severity = "nit", body = "x" } } })
  local dir = store.reviews_dir(SLUG)
  store.ensure_dir(dir)
  -- Deny every create in the reviews dir EXCEPT the reservation, so the JSON
  -- fails and the tombstone that would retire it fails too — the case a
  -- read-only store actually produces, and the one a targeted failure cannot.
  local real = store.create_exclusive
  store.create_exclusive = function(p, b)
    local s = tostring(p)
    if s:find("%.reserve$") then return real(p, b) end
    if s:find("%.review%.json$") or s:find("%.tombstone$") then
      return false, "injected: store is read-only"
    end
    return real(p, b)
  end
  local res, err = review.save_pair(SLUG, doc, "# body", { topic = "denied" })
  store.create_exclusive = real
  ok("the submission fails", res == nil, tostring(res))
  ok("*** and reports BOTH the write failure and the un-tombstoned revision ***",
    err and err:find("not lost", 1, true) and err:find("reservation retained", 1, true),
    tostring(err))
  ok("*** the reservation is RETAINED as the fence ***",
    vim.fn.filereadable(review.reserve_path(SLUG, sha, 1)) == 1,
    review.reserve_path(SLUG, sha, 1))
  ok("*** so the next write SKIPS that revision once writes are possible again ***",
    (function()
      local d2 = review.from_draft({ slug = SLUG }, sha, "lector",
        { comments = { { path = "a", line = 1, side = "RIGHT", severity = "nit", body = "y" } } })
      local r2 = review.save_pair(SLUG, d2, "# body2", { topic = "denied" })
      return r2 ~= nil and r2.revision > 1
    end)(), "the retained reservation must keep r1 out of circulation")
end

io.stdout:write("\n[4] forced interleavings — cleanup against a committing writer\n")
do
  local sha = string.rep("9", 40)
  local doc = review.from_draft({ slug = SLUG }, sha, "lector",
    { comments = { { path = "a", line = 1, side = "RIGHT", severity = "nit", body = "x" } } })
  -- Land a cleanup pass BETWEEN the Markdown claim and the JSON commit.
  local real = store.create_exclusive
  local fired = false
  store.create_exclusive = function(p, b)
    local r, e = real(p, b)
    if not fired and tostring(p):find("%-review%.md$") then
      fired = true
      review.cleanup(SLUG, sha)   -- our lease is CURRENT, so it must not reap us
    end
    return r, e
  end
  local res = review.save_pair(SLUG, doc, "# body", { topic = "interleave" })
  store.create_exclusive = real
  ok("*** a cleanup mid-write does not reap a live lease: the pair commits ***",
    res ~= nil, "a current lease must survive a concurrent cleanup")
  ok("and the committed pair is loadable",
    res and review.load(SLUG, sha, res.revision) ~= nil)

  -- Two cleanups on one expired reservation collapse to a single tombstone.
  local dead = review.max_recorded_revision(SLUG, sha) + 1
  store.create_exclusive(review.reserve_path(SLUG, sha, dead),
    vim.json.encode({ owner = "crashed", lease_until = os.time() - 1 }))
  review.cleanup(SLUG, sha); review.cleanup(SLUG, sha)
  ok("*** two cleanups on one revision yield ONE tombstone ***",
    vim.fn.filereadable(review.tombstone_path(SLUG, sha, dead)) == 1)
  ok("and cleanup refuses to tombstone an already-committed revision",
    res and vim.fn.filereadable(review.tombstone_path(SLUG, sha, res.revision)) == 0,
    res and review.tombstone_path(SLUG, sha, res.revision))
end

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
