-- worktree — ADR-0067 A1: the paired review store.
--
-- Run headless:
--   nvim --headless -u NONE -l tests/adr0067-a1-paired-store.lua
--
-- The protocol's guarantees are all about what a READER can observe and what a
-- concurrent writer can destroy, so the failure paths are driven directly
-- rather than inferred from a happy path. Nothing here asserts an absence where
-- an exact value is available.
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
  -- Later entries win (the same-branch sibling beats a generic checkout), but
  -- ONLY among candidates that can actually satisfy the dependency. A stale
  -- sibling used to win outright: worktree.store delegates to
  -- auto-core.docstore (ADR-0081 P4a), so an auto-core predating it is not an
  -- older version of the dependency, it is a checkout that cannot serve the
  -- request at all -- and the suite failed with "auto-core.docstore is
  -- required" naming no path, while a perfectly good copy sat earlier in this
  -- very list.
  if vim.fn.isdirectory(p) == 1 then
    if vim.fn.isdirectory(p .. "/lua/auto-core/docstore") == 1
      or vim.fn.filereadable(p .. "/lua/auto-core/docstore.lua") == 1 then
      AUTO_CORE = p
    elseif not AUTO_CORE then
      AUTO_CORE = p  -- nothing qualifying seen yet; keep the loud failure informative
    end
  end
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

local sb = vim.fn.tempname() .. "-a1"
vim.env.XDG_STATE_HOME = sb .. "/state"
vim.env.XDG_CONFIG_HOME = sb .. "/config"
vim.env.XDG_CACHE_HOME = sb .. "/cache"
-- $KB_ROOT isolated for the same reason: paired writes land under it.
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

local SLUG, SHA = "o__r", string.rep("d", 40)
-- The STORE owns the path now (ADR-0067 §2.2), so the test asks IT where a
-- given revision will land rather than reproducing the naming — which is the
-- point: a path the caller computes is a path the caller can get wrong.
local TOPIC = "a1"
local function doc_path(rev)
  return review.canonical_document({
    kb_root = vim.env.AUTO_AGENTS_KB_ROOT, reviewer_slug = "lector",
    slug = SLUG, topic = TOPIC, revision = rev })
end
local BODY = "# Review\n\nprose"
local function mk()
  local d = review.new({ slug = SLUG, owner = "o", name = "r", commit = SHA,
                         reviewer = "lector" })
  d.reviewer_slug = "lector"
  d.comments = { { path = "a.go", line = 1, side = "RIGHT", severity = "nit", body = "x" } }
  return d
end

io.stdout:write("\n[1] a pair is written, JSON last\n")
local res, err = review.save_pair(SLUG, mk(), BODY, { topic = TOPIC })
ok("save_pair succeeds", res ~= nil, tostring(err))
ok("the JSON exists", res and vim.fn.filereadable(res.json_path) == 1)
ok("the Markdown exists", res and vim.fn.filereadable(res.md_path) == 1)
ok("*** the JSON cross-references its document ***",
  (review.load(SLUG, SHA, res.revision) or {}).document == res.md_path)
ok("the reservation is released after the commit",
  vim.fn.filereadable(review.reserve_path(SLUG, SHA, res.revision)) == 0,
  review.reserve_path(SLUG, SHA, res.revision))

io.stdout:write("\n[2] non-canonical records are INVISIBLE to readers\n")
do
  -- The reservation and tombstone share the reviews directory. If either were
  -- listable, `latest_revision` would count it and a reader could load it.
  vim.fn.writefile({ "{}" }, review.reserve_path(SLUG, SHA, 90))
  vim.fn.writefile({ "{}" }, review.tombstone_path(SLUG, SHA, 91))
  local revs = review.list_for(SLUG, SHA)
  local seen = {}
  for _, r in ipairs(revs) do seen[r.revision] = true end
  ok("*** a reservation is not listed as a review ***", seen[90] == nil, vim.inspect(seen))
  ok("*** a tombstone is not listed either ***", seen[91] == nil, vim.inspect(seen))
  ok("and latest_revision ignores both", review.latest_revision(SLUG, SHA) == res.revision,
    tostring(review.latest_revision(SLUG, SHA)))
  ok("*** but max_recorded_revision COUNTS them (allocation must not reuse) ***",
    review.max_recorded_revision(SLUG, SHA) == 91,
    tostring(review.max_recorded_revision(SLUG, SHA)))
  vim.fn.delete(review.reserve_path(SLUG, SHA, 90))
  vim.fn.delete(review.tombstone_path(SLUG, SHA, 91))
end

io.stdout:write("\n[3] a taken Markdown name RETIRES the revision\n")
do
  local nextrev = review.max_recorded_revision(SLUG, SHA) + 1
  local taken = doc_path(nextrev)
  vim.fn.mkdir(vim.fn.fnamemodify(taken, ":h"), "p")
  vim.fn.writefile({ "squatter" }, taken)
  local r2, e2 = review.save_pair(SLUG, mk(), BODY, { topic = TOPIC })
  ok("save_pair still succeeds, at a later revision", r2 ~= nil and r2.revision > nextrev,
    tostring(e2) .. " " .. tostring(r2 and r2.revision))
  ok("*** the squatted file is untouched ***",
    table.concat(vim.fn.readfile(taken), "") == "squatter")
  ok("*** and the skipped revision is TOMBSTONED, not silently reused ***",
    vim.fn.filereadable(review.tombstone_path(SLUG, SHA, nextrev)) == 1,
    review.tombstone_path(SLUG, SHA, nextrev))
  local r3 = review.save_pair(SLUG, mk(), BODY, { topic = TOPIC })
  ok("a later write never re-offers the tombstoned number",
    r3 ~= nil and r3.revision ~= nextrev, tostring(r3 and r3.revision))
end

io.stdout:write("\n[4] a live lease is not reaped; an expired one is\n")
do
  local live = review.max_recorded_revision(SLUG, SHA) + 1
  store.create_exclusive(review.reserve_path(SLUG, SHA, live),
    vim.json.encode({ owner = "someone-else", created_at = os.time(),
                      lease_until = os.time() + 600 }))
  local retired = review.cleanup(SLUG, SHA)
  ok("*** a paused writer with a CURRENT lease survives cleanup ***",
    vim.fn.filereadable(review.reserve_path(SLUG, SHA, live)) == 1
    and vim.fn.filereadable(review.tombstone_path(SLUG, SHA, live)) == 0,
    ("retired=%d"):format(retired))

  local dead = live + 1
  store.create_exclusive(review.reserve_path(SLUG, SHA, dead),
    vim.json.encode({ owner = "crashed", created_at = os.time() - 9999,
                      lease_until = os.time() - 1 }))
  review.cleanup(SLUG, SHA)
  ok("*** an EXPIRED lease is tombstoned ***",
    vim.fn.filereadable(review.tombstone_path(SLUG, SHA, dead)) == 1)
  -- Was an A-or-B disjunction, which the tombstone alone satisfied — it could
  -- not distinguish "reclaimed by tombstone" from "reclaimed by deletion",
  -- which is the entire claim in its label. Assert the retirement RECORD
  -- exists and that the revision is out of circulation.
  ok("*** the retirement is a tombstone RECORD, not a deletion ***",
    vim.fn.filereadable(review.tombstone_path(SLUG, SHA, dead)) == 1,
    review.tombstone_path(SLUG, SHA, dead))
  ok("*** and the retired revision is never re-offered ***",
    review.max_recorded_revision(SLUG, SHA) >= dead,
    ("max_recorded=%d dead=%d"):format(review.max_recorded_revision(SLUG, SHA), dead))
  ok("the live reservation is still untouched afterwards",
    vim.fn.filereadable(review.reserve_path(SLUG, SHA, live)) == 1)
  vim.fn.delete(review.reserve_path(SLUG, SHA, live))
end

io.stdout:write("\n[5] cleanup never tombstones a COMMITTED revision\n")
do
  local committed = review.load(SLUG, SHA, res.revision)
  ok("the committed review is still loadable (positive control)", committed ~= nil)
  store.create_exclusive(review.reserve_path(SLUG, SHA, res.revision),
    vim.json.encode({ owner = "stale", lease_until = os.time() - 1 }))
  review.cleanup(SLUG, SHA)
  ok("*** a stale reservation beside a committed pair is NOT tombstoned ***",
    vim.fn.filereadable(review.tombstone_path(SLUG, SHA, res.revision)) == 0,
    review.tombstone_path(SLUG, SHA, res.revision))
  vim.fn.delete(review.reserve_path(SLUG, SHA, res.revision))
end

io.stdout:write("\n[6] the legacy writers refuse an unpaired review\n")
do
  local bare = mk()
  local p1, e1 = review.save(SLUG, bare)
  ok("*** save() refuses a review with no document ***", p1 == nil and e1 ~= nil, tostring(e1))
  ok("and names save_pair in the refusal", (e1 or ""):find("save_pair", 1, true) ~= nil)

  local ghost = mk()
  ghost.revision = 500
  ghost.document = vim.env.AUTO_AGENTS_KB_ROOT .. "/agents/lector/reviews/2026-08-24-ghost-r500-review.md"
  local p2, e2 = review.save(SLUG, ghost)
  ok("*** and one whose document does NOT EXIST — presence is not existence ***",
    p2 == nil and e2 ~= nil, tostring(e2))
  ok("*** with no artifact created by the refusal ***",
    vim.fn.filereadable(store.reviews_dir(SLUG) .. "/" .. review.filename(SLUG, SHA, 500)) == 0)

  local esc = mk()
  esc.revision = 501
  esc.document = vim.env.AUTO_AGENTS_KB_ROOT .. "/agents/lector/reviews/../../../etc/2026-08-24-x-r501-review.md"
  ok("*** a traversal out of $KB_ROOT/agents is refused ***",
    select(1, review.save(SLUG, esc)) == nil)

  local other = mk()
  other.revision = 502
  other.reviewer_slug = "lector"
  local dir = ("%s/agents/someone-else/reviews"):format(vim.env.AUTO_AGENTS_KB_ROOT)
  vim.fn.mkdir(dir, "p")
  other.document = dir .. "/2026-08-24-x-r502-review.md"
  vim.fn.writefile({ "# theirs" }, other.document)
  ok("*** and a document under ANOTHER reviewer's directory is refused ***",
    select(1, review.save(SLUG, other)) == nil)

  local mism = mk()
  mism.revision = 503
  local mp = doc_path(999)
  vim.fn.writefile({ "# r999" }, mp)
  mism.document = mp
  ok("*** a document whose rN disagrees with the review is refused ***",
    select(1, review.save(SLUG, mism)) == nil)
end

io.stdout:write("\n[6b] a NON-CANONICAL document name is refused by the public writers\n")
do
  -- The regression this pins, verbatim: a REAL regular file whose name carries
  -- neither the repo component nor a separate topic. The whole r2 suite passed
  -- while this bug was live, because `validate_pair` reduced its slug to nil
  -- unconditionally and the component was never checked.
  local RSLUG = "own__realrepo"
  local d = review.new({ slug = RSLUG, owner = "own", name = "realrepo",
                         commit = SHA, reviewer = "lector" })
  d.reviewer_slug = "lector"
  d.revision = 1
  d.comments = { { path = "a.go", line = 1, side = "RIGHT", severity = "nit", body = "x" } }
  local dir = ("%s/agents/lector/reviews"):format(vim.env.AUTO_AGENTS_KB_ROOT)
  vim.fn.mkdir(dir, "p")
  d.document = dir .. "/2026-08-25-x-r1-review.md"
  vim.fn.writefile({ "# a real file" }, d.document)
  ok("the document really exists (positive control — this is not a missing-file test)",
    vim.fn.filereadable(d.document) == 1)

  local p1, e1 = review.save(RSLUG, d)
  ok("*** save() refuses a non-canonical document name ***", p1 == nil, tostring(p1))
  ok("and names the required shape", (e1 or ""):find("realrepo", 1, true) ~= nil, tostring(e1))
  ok("*** and publishes NO canonical JSON ***",
    vim.fn.filereadable(store.reviews_dir(RSLUG) .. "/" .. review.filename(RSLUG, SHA, 1)) == 0)

  local p2 = review.save_next(RSLUG, vim.deepcopy(d))
  ok("save_next() refuses it too", p2 == nil)

  -- The canonical POSITIVE: the same review, named by the store, is accepted.
  local d2 = vim.deepcopy(d)
  d2.revision = 2
  d2.document = review.canonical_document({
    kb_root = vim.env.AUTO_AGENTS_KB_ROOT, reviewer_slug = "lector",
    slug = RSLUG, topic = "sessions", revision = 2 })
  vim.fn.writefile({ "# a real file" }, d2.document)
  ok("*** but the store's own canonical name IS accepted ***",
    review.save(RSLUG, d2) ~= nil, d2.document)
end

io.stdout:write("\n[6c] the uv.random fallback produces a usable token\n")
do
  -- Forced, because every other test takes the `uv.random` path — so moving
  -- `_now` back below `_token` would leave the whole suite green while the
  -- fallback crashed with "attempt to call global '_now'".
  local uv = vim.uv or vim.loop
  local real_random = uv.random
  uv.random = nil
  local FSHA = string.rep("c", 40)
  local d = review.from_draft({ slug = SLUG }, FSHA, "lector",
    { comments = { { path = "a.go", line = 1, side = "RIGHT", severity = "nit", body = "x" } } })
  local okc, res, err = pcall(review.save_pair, SLUG, d, "# fallback", { topic = "fallback" })
  uv.random = real_random
  ok("*** the fallback does not crash ***", okc, tostring(res))
  ok("*** and still writes a complete pair ***",
    okc and res ~= nil and vim.fn.filereadable(res.json_path) == 1
    and vim.fn.filereadable(res.md_path) == 1, tostring(err or (res and res.json_path)))
  ok("whose JSON cross-references its document",
    okc and res and (review.load(SLUG, FSHA, res.revision) or {}).document == res.md_path)
end

io.stdout:write("\n[7] reads stay tolerant of pre-ADR artifacts\n")
do
  local legacy = mk()
  legacy.revision = 1
  ok("*** validate() still accepts a review with NO document (old files load) ***",
    select(1, review.validate(legacy)) == true,
    vim.inspect(select(2, review.validate(legacy))))
  ok("*** but validate(for_write) requires one ***",
    select(1, review.validate(legacy, { for_write = true })) == false)
  -- A refusal that also broke reading old reviews would be worse than the bug.
  local onfile = review.load(SLUG, SHA, res.revision)
  ok("and a real stored review still loads", onfile ~= nil and onfile.commit == SHA)
end

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
