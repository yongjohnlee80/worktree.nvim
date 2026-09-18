-- tests/adr0083-r11-pr-association.lua — the one amendment a written review allows.
--
-- A review drafted from a COMMIT context never acquired a `pr`, and nothing
-- could give it one afterwards, so `S` refused it forever and the only route to
-- posting was to delete the review and redo it — losing the findings.
--
-- r11 adds the missing inverse. `pr` was already mutable in one direction (`d`
-- cleared it), so this completes an asymmetry rather than introducing
-- mutability. What it must NOT do is reopen general amendment of a written
-- review, which ADR-0067 forbids.
--
-- The cells below are the four parts of the named exemption:
--   by NAME        — one function, one field
--   reason AT the guard
--   guard the PREMISE — content cannot be reached through this path
--   the exemption is LIVE — it is actually exercised
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
local siblings = vim.fn.fnamemodify(plugin_root, ":h:h")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, c in ipairs({
  LAZY .. "/auto-core.nvim",
  siblings .. "/auto-core.nvim/main",
  siblings .. "/auto-core.nvim/" .. branch_dir,
}) do
  if vim.fn.filereadable(c .. "/lua/auto-core/docstore/init.lua") == 1 then
    vim.opt.runtimepath:prepend(c)
  end
end
for _, p in ipairs({ LAZY .. "/plenary.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end

io.stdout:write("ADR-0083 r11 — a review acquires its PR after the fact\n")
io.stdout:flush()

local state = vim.fn.tempname() .. "-r11"
vim.fn.mkdir(state, "p")
vim.env.XDG_STATE_HOME = state

local review = require("worktree.review")
local store = require("worktree.store")

local SLUG = "owner__repo"
local SHA = string.rep("c", 40)
-- Reviews are addressed by PATH: the caller amends the file it is looking at.
local function RPATH(rev)
  return store.reviews_dir(SLUG) .. "/" .. review.filename(SLUG, SHA, rev)
end

-- A paired review on disk: the store refuses an unpaired one, so the document
-- has to exist before the JSON will be accepted.
local kb = vim.fn.tempname() .. "-kb"
vim.fn.mkdir(kb .. "/agents/tester/reviews", "p")
vim.env.AUTO_AGENTS_KB_ROOT = kb

-- The pair check is strict: the document lives under
-- $KB_ROOT/agents/<reviewer_slug>/reviews/ and is named
-- <date>-<repo>-<topic>-r<N>-review.md, with the revision matching the JSON's.
local function make(rev, summary)
  local doc = ("%s/agents/tester/reviews/2026-09-18-repo-r11-association-r%d-review.md")
    :format(kb, rev)
  vim.fn.writefile({ "# review" }, doc)
  return {
    schema = "worktree.review/1",
    repo = { owner = "owner", name = "repo" },
    commit = SHA,
    revision = rev,
    reviewer = "tester",
    reviewer_slug = "tester",
    document = doc,
    verdict = "comment",
    summary = summary,
    comments = {},
  }
end

local first = make(1, "the findings as written")
local path, serr = review.save(SLUG, first)
ok("a commit-context review is on disk", path ~= nil, tostring(serr))

local on_disk = review.load(SLUG, SHA, 1)
ok("*** and it has NO pr — the defect r11 fixes ***",
  on_disk ~= nil and on_disk.pr == nil, on_disk and tostring(on_disk.pr))

-- ── 1. the missing inverse ──────────────────────────────────────────
local aok, aerr = review.amend_pr_association(RPATH(1), 3522)
ok("amend_pr_association attaches a PR to a written review", aok, tostring(aerr))
ok("and the association is on disk",
  (review.load(SLUG, SHA, 1) or {}).pr == 3522,
  tostring((review.load(SLUG, SHA, 1) or {}).pr))

-- ── 2. the same writer clears it (both directions, one path) ────────
ok("the same writer clears the association",
  select(1, review.amend_pr_association(RPATH(1), nil)))
ok("and the pr key is gone, not set to something falsy",
  (review.load(SLUG, SHA, 1) or {}).pr == nil)
review.amend_pr_association(RPATH(1), 3522)

-- ── 3. GUARD THE PREMISE: content is unreachable through this path ──
-- The premise of the exemption is that `pr` is routing metadata and this path
-- cannot touch what the reviewer wrote. It is narrow by CONSTRUCTION — the
-- caller passes a number, never a body — so the assertion is that the
-- surrounding fields survive an amendment untouched.
local after = review.load(SLUG, SHA, 1)
ok("*** the summary is untouched by an amendment ***",
  after and after.summary == "the findings as written", after and after.summary)
ok("the verdict is untouched", after and after.verdict == "comment", after and after.verdict)
ok("the revision is untouched", after and after.revision == 1, after and after.revision)
ok("the reviewer is untouched", after and after.reviewer == "tester", after and after.reviewer)
ok("the comment list is untouched",
  after and type(after.comments) == "table" and #after.comments == 0)

-- ── 4. the generic escape hatch is GONE ─────────────────────────────
-- This is the cell that makes the narrowness a mechanism rather than a
-- convention: if `save` still accepted `overwrite`, every caller would retain
-- the content-amend path and the guarantee above would hold only by etiquette.
local rewritten = make(1, "REWRITTEN BY A GENERIC OVERWRITE")
local rp = review.save(SLUG, rewritten, { overwrite = true })
ok("*** save() refuses a replace even when asked to overwrite ***", rp == nil,
  tostring(rp))
ok("*** and the original findings survive the attempt ***",
  (review.load(SLUG, SHA, 1) or {}).summary == "the findings as written",
  (review.load(SLUG, SHA, 1) or {}).summary)

-- ── 5. refusals are reported, not silent ────────────────────────────
local mok, merr = review.amend_pr_association(store.reviews_dir(SLUG) .. "/nope.json", 1)
ok("amending a review that does not exist fails with a reason",
  mok == false and merr ~= nil, tostring(merr))
local bok, berr = review.amend_pr_association(nil, 1)
ok("a missing path fails with a reason", bok == false and berr ~= nil, tostring(berr))

-- A structurally broken record is not silently rewritten just because we
-- touched one field of it.
vim.fn.mkdir(store.reviews_dir(SLUG), "p")
local broken = store.reviews_dir(SLUG) .. "/" .. review.filename(SLUG, SHA, 2)
vim.fn.writefile({ vim.json.encode({ schema = "worktree.review/1" }) }, broken)
local iok, ierr = review.amend_pr_association(RPATH(2), 9)
ok("an invalid review is refused rather than rewritten",
  iok == false and ierr ~= nil, tostring(ierr))

-- ── 6. an UNPAIRED review is refused, not rewritten ─────────────────
-- `validate` ignores unknown fields and says nothing about the Markdown the
-- JSON points at, so a schema-valid record whose document has been deleted is
-- still invalid as a PAIR. Amending it would republish exactly the unpaired
-- artifact `save` refuses to create. (agent:zen, PR #34 r0.)
local paired = make(3, "pair intact")
local p3 = review.save(SLUG, paired)
ok("a third review is on disk, paired", p3 ~= nil)
ok("it amends while the pair is intact",
  select(1, review.amend_pr_association(RPATH(3), 11)))

-- Delete the Markdown out from under it. The JSON is untouched and still
-- schema-valid; only the pair is broken.
vim.fn.delete(paired.document)
local uok, uerr = review.amend_pr_association(RPATH(3), 22)
ok("*** amending an UNPAIRED review is refused ***", uok == false, tostring(uerr))
ok("the refusal says the pair is the problem",
  tostring(uerr):find("unpaired", 1, true) ~= nil, tostring(uerr))
ok("*** and nothing was written — the earlier pr survives ***",
  (review.load(SLUG, SHA, 3) or {}).pr == 11,
  tostring((review.load(SLUG, SHA, 3) or {}).pr))

io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail)); io.stdout:flush()
vim.cmd(fail > 0 and "cq!" or "qa!")
