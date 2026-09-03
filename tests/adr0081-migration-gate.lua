-- ADR-0081 §3.1 — THE MIGRATION GATE.
--
-- "The on-disk format is unchanged by construction" is an assumption until it
-- is executable. This suite must be green BEFORE P4 delegates any of worktree's
-- store mechanics to auto-core, and it answers exactly one question: does the
-- new allocator find, count and extend the records the SHIPPED plugin already
-- wrote to users' disks?
--
-- The fixtures below are not hand-written from what I believe v0.5.7 wrote.
-- They were PRODUCED by running v0.5.7's own `review.save_pair` and
-- `store.create_exclusive` in a sandbox and copying the bytes out, then frozen
-- here as literals. That distinction is the whole point: a fixture I compose
-- from my beliefs tests my beliefs, and this suite exists because comparing
-- implementations rather than trusting a shared constant is what caught the
-- capability regressions recorded in ADR-0081 §2.2b.
--
-- Frozen as literals, they also lock the format: if a future change alters a
-- filename or a control record's fields, this fails rather than migrating
-- silently.
--
-- Paths are derived, never hardcoded (family rule 2), and both XDG_STATE_HOME
-- and $KB_ROOT are isolated — a suite that inherits the real ones writes into
-- the live knowledge base, which has happened once.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
-- Installed copy first, then this repo's `main`, then the SAME-BRANCH sibling
-- worktree, then this checkout: `prepend` pushes to the front, so the last
-- existing entry wins. The same-branch sibling is what pairs a cross-repo
-- change with its other half before either merges — and this suite REQUIRES it,
-- since the handle it exercises only exists in auto-core's unreleased branch.
for _, p in ipairs({
  LAZY .. "/auto-core.nvim",
  plugins .. "/auto-core.nvim/main",
  plugins .. "/auto-core.nvim/" .. branch_dir,
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
local sb = vim.fn.tempname() .. "-gate"
vim.env.XDG_STATE_HOME = sb .. "/state"
vim.env.AUTO_AGENTS_KB_ROOT = sb .. "/kb"

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

local review = require("worktree.review")
local store = require("worktree.store")
local ds = require("auto-core.docstore")
local rv = ds.revisions

-- ── THE FROZEN OLD FORMAT (produced by worktree.nvim v0.5.7) ──
local SLUG = "yongjohnlee80__godiff"
local SHA = "c2f104dabcdef0123456789abcdef0123456789a"
local SHORT = "c2f104d"
local KEY = SLUG .. "@" .. SHORT
local SUFFIX = ".review.json"

-- Minified, as every shipped release wrote it. Key order is v0.5.7's hash
-- order, deliberately preserved: this is a byte record, not a re-encoding.
local OLD_CANONICAL = '{"reviewer_slug":"lector","comments":[{"line":12,"path":"diff.go",'
  .. '"severity":"must-fix","body":"guard this"}],"revision":1,'
  .. '"commit":"c2f104dabcdef0123456789abcdef0123456789a",'
  .. '"created":"2026-09-03T03:05:57Z",'
  .. '"repo":{"url":"git@github.com:yongjohnlee80/godiff.git",'
  .. '"owner":"yongjohnlee80","name":"godiff"},"reviewer":"lector",'
  .. '"document":"KB_ROOT_PLACEHOLDER/agents/lector/reviews/2026-09-03-godiff-godiff-r1-review.md",'
  .. '"verdict":"change_requested","schema":"worktree.review/1","summary":"one must-fix"}'
-- A LIVE reservation (lease in absolute epoch SECONDS) and a tombstone.
local OLD_RESERVE = '{"lease_until":1788000120,"owner":"old-token","created_at":1788000000}'
local OLD_TOMBSTONE = '{"retired_at":1788000200,"by":"old-token"}'

local dir = store.reviews_dir(SLUG)
ds.ensure_dir(dir)

-- FAIL FAST if the sandbox is not where we think it is. A gate that writes into
-- the live store proves nothing and damages something.
if not (dir:find(sb, 1, true) == 1) then
  print("  FAIL  sandbox containment: reviews_dir escaped the sandbox — " .. dir)
  os.exit(1)
end

local canonical = dir .. "/" .. KEY .. ".r1" .. SUFFIX
ds.write(canonical, (OLD_CANONICAL:gsub("KB_ROOT_PLACEHOLDER", sb .. "/kb")))
ds.write(dir .. "/" .. KEY .. ".r2.reserve", OLD_RESERVE)
ds.write(dir .. "/" .. KEY .. ".r3.tombstone", OLD_TOMBSTONE)

print("[1] the frozen fixture is what the shipped plugin wrote")
ok("[1] fixture: three old-format records exist",
  ds.exists(canonical) and ds.exists(dir .. "/" .. KEY .. ".r2.reserve")
  and ds.exists(dir .. "/" .. KEY .. ".r3.tombstone"))
ok("[1] fixture: the canonical record is MINIFIED, as every release wrote it",
  (select(1, ds.read(canonical)) or ""):find("\n") == nil)
ok("[1] *** and the SHIPPED reader still parses its filename ***", (function()
  local slug, short, rev = review.parse_filename(KEY .. ".r1" .. SUFFIX)
  return slug == SLUG and short == SHORT and rev == 1
end)())

print("\n[2] IDENTICAL DISCOVERY — same root, same filename, byte for byte")
local h, herr = rv.open({ dir = dir, key = KEY, suffix = SUFFIX })
ok("[2] a handle opens over the EXISTING store directory", h ~= nil, herr)
ok("[2] *** the handle's canonical path IS the legacy path ***",
  h:record_path(1) == canonical, h and h:record_path(1))
ok("[2] *** and so are both control-record paths ***",
  h:reserve_path(2) == dir .. "/" .. KEY .. ".r2.reserve"
  and h:tombstone_path(3) == dir .. "/" .. KEY .. ".r3.tombstone")
ok("[2] the legacy writer would compute the same name",
  review.filename(SLUG, SHA, 1) == KEY .. ".r1" .. SUFFIX,
  review.filename(SLUG, SHA, 1))
ok("[2] *** the existing document is readable through the new store ***",
  (function()
    local v, err = ds.read_json(canonical)
    return err == nil and type(v) == "table" and v.revision == 1
      and v.commit == SHA and v.reviewer_slug == "lector"
      and v.comments[1].severity == "must-fix"
  end)())

print("\n[3] CONTROL RECORDS PARTICIPATE in the next allocation")
ok("[3] *** the new allocator counts the old .reserve and .tombstone ***",
  h:max_recorded() == 3, tostring(h:max_recorded()))
ok("[3] *** and agrees with the SHIPPED implementation exactly ***",
  h:max_recorded() == review.max_recorded_revision(SLUG, SHA),
  ("new=%s shipped=%s"):format(h:max_recorded(),
    review.max_recorded_revision(SLUG, SHA)))
ok("[3] *** so the next revision is r4 — no old number is re-issued ***",
  (function()
    local rev, tok = h:claim_next()
    return rev == 4 and type(tok) == "string"
      and ds.exists(h:reserve_path(4))
  end)())
ok("[3] the tombstoned r3 cannot be claimed even directly",
  select(1, h:claim(3, "anyone")) == false)
ok("[3] CONTROL: remove the old records and the maximum drops", (function()
  -- Proves the two control records are what held the number, not the canonical
  -- r1 alone. Done on a COPY of the directory so the fixture survives.
  local copy = sb .. "/copy"
  ds.ensure_dir(copy)
  ds.write(copy .. "/" .. KEY .. ".r1" .. SUFFIX, "{}")
  local ch = rv.open({ dir = copy, key = KEY, suffix = SUFFIX })
  return ch:max_recorded() == 1
end)())

print("\n[4] RESERVATION FIELDS AND LEASE UNITS keep their meaning")
ok("[4] the old reservation decodes with its fields intact", (function()
  local r = ds.read_json(dir .. "/" .. KEY .. ".r2.reserve")
  return type(r) == "table" and r.owner == "old-token"
    and r.created_at == 1788000000 and r.lease_until == 1788000120
end)())
ok("[4] *** lease_until is ABSOLUTE EPOCH SECONDS in both implementations ***",
  rv.LEASE_SECONDS == review.LEASE_SECONDS
  and rv.LEASE_SECONDS == 120,
  ("new=%s shipped=%s"):format(rv.LEASE_SECONDS, review.LEASE_SECONDS))
ok("[4] *** an old LIVE reservation is not reaped by the new cleanup ***",
  (function()
    -- 1788000120 is in the past relative to now, so make it live first: the
    -- point under test is the UNIT, not the value frozen in the fixture.
    local p = dir .. "/" .. KEY .. ".r2.reserve"
    ds.write(p, ('{"lease_until":%d,"owner":"old-token","created_at":%d}')
      :format(os.time() + 120, os.time()))
    local n, report = h:cleanup()
    return n == 0 and ds.exists(p) and #report.indeterminate == 0
  end)())
ok("[4] *** an old EXPIRED reservation IS reaped, on the old field name ***",
  (function()
    local p = dir .. "/" .. KEY .. ".r2.reserve"
    ds.write(p, '{"lease_until":1788000120,"owner":"old-token","created_at":1788000000}')
    local n = h:cleanup()
    -- Reading seconds as milliseconds (or the reverse) would make an expired
    -- lease look live for ~50 years, so this is the unit assertion that matters.
    return n >= 1 and ds.exists(dir .. "/" .. KEY .. ".r2.tombstone")
  end)())
ok("[4] the shipped reader still recognises the tombstone the new code wrote",
  ds.exists(dir .. "/" .. KEY .. ".r2.tombstone")
  and review.max_recorded_revision(SLUG, SHA) >= 4)

print("\n[5] A NEW WRITER AND AN OLD FIXTURE INTEROPERATE — no rename, no migration")
ok("[5] *** the new writer's record is parsed by the SHIPPED filename reader ***",
  (function()
    local rev = h:max_recorded() + 1
    local claimed, tok = h:claim(rev, "new-writer")
    if not claimed then return false end
    ds.write_json(h:record_path(rev), { schema = review.SCHEMA, revision = rev,
      commit = SHA, reviewer = "jarvis", verdict = "comment", comments = {} })
    local name = vim.fn.fnamemodify(h:record_path(rev), ":t")
    local slug, short, parsed = review.parse_filename(name)
    return slug == SLUG and short == SHORT and parsed == rev
  end)())
ok("[5] *** and the SHIPPED lister finds old and new records together ***",
  (function()
    local seen = review.list_for(SLUG, SHA)
    if type(seen) ~= "table" then return false end
    local revs = {}
    for _, entry in ipairs(seen) do
      revs[tonumber(entry.revision) or tonumber(entry) or -1] = true
    end
    -- r1 was written by v0.5.7; the newest was written through the handle.
    return revs[1] == true and #vim.tbl_keys(revs) >= 2
  end)(), vim.inspect(review.list_for(SLUG, SHA)):gsub("%s+", " "):sub(1, 200))
ok("[5] no record was renamed: the original r1 filename is untouched",
  ds.exists(canonical))
ok("[5] *** the new writer's PRETTY json is still valid to the old reader ***",
  (function()
    local rev = h:max_recorded()
    local raw = select(1, ds.read(h:record_path(rev))) or ""
    local decoded = select(1, store.read_json(h:record_path(rev)))
    -- Multi-line on disk (the batch #4 change) and decoded by the shipped
    -- reader all the same: the format change is write-side only.
    return raw:find("\n") ~= nil and type(decoded) == "table"
      and decoded.commit == SHA
  end)())

print("\n[6] PRETTY JSON IS BYTE-STABLE where stability is promised")
ok("[6] *** the same value encodes to identical bytes every time ***",
  (function()
    local v = { b = 2, a = "x", nested = { z = 1, y = { 2, 3 } } }
    local first = ds.encode_pretty(v)
    for _ = 1, 20 do
      if ds.encode_pretty(v) ~= first then return false end
    end
    return true
  end)())
ok("[6] *** and a DECODED old record re-encodes stably ***", (function()
  local decoded = ds.read_json(canonical)
  local a = ds.encode_pretty(decoded)
  local b = ds.encode_pretty(vim.json.decode(a))
  -- Round-tripping must reach a fixed point, or every rewrite churns the diff.
  return a == b
end)())
ok("[6] two tables built in DIFFERENT insertion orders encode identically",
  (function()
    local one = {}; one.alpha = 1; one.beta = 2; one.gamma = 3
    local two = {}; two.gamma = 3; two.beta = 2; two.alpha = 1
    return ds.encode_pretty(one) == ds.encode_pretty(two)
  end)())

print("\n[7] NO COMPATIBILITY READ PATH IS NEEDED — recorded explicitly (§3.1)")
-- §3.1: "If they pass, record 'no compatibility read path' explicitly." These
-- are the assertions that license that sentence in the ADR.
ok("[7] old minified and new pretty records coexist in one directory",
  (function()
    local names = ds.list(dir, "%.review%.json$")
    local minified, pretty = 0, 0
    for _, n in ipairs(names) do
      local raw = select(1, ds.read(dir .. "/" .. n)) or ""
      if raw:find("\n") then pretty = pretty + 1 else minified = minified + 1 end
    end
    return minified >= 1 and pretty >= 1
  end)())
ok("[7] *** every record in the directory decodes, whichever wrote it ***",
  (function()
    for _, n in ipairs(ds.list(dir, "%.review%.json$")) do
      local v, err = ds.read_json(dir .. "/" .. n)
      if err or type(v) ~= "table" then return false end
    end
    return true
  end)())
ok("[7] the store root itself is unchanged by the move",
  dir == store.root() .. "/reviews/" .. SLUG, dir)

vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
