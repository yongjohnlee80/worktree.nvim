-- tests/adr0060-review-json-e2e.lua — exercise the review-json skill's
-- documented flow verbatim (ADR-0060 P7).
--
-- Run:  nvim --headless -u NONE -l tests/adr0060-review-json-e2e.lua
--
-- The plugin root is DERIVED, not hardcoded. An absolute workspace path was
-- baked in here originally, which meant this suite ran on exactly one machine
-- and from exactly one worktree — breaking the family convention
-- (`lua-nvim-plugin-development.md` rule 2) that tests/smoke.lua in this very
-- repo already follows.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
-- Installed copies FIRST, development worktrees LAST: `prepend` pushes to the
-- front, so the last existing entry wins and this suite tests THIS checkout.
for _, p in ipairs({
  LAZY .. "/auto-core.nvim",
  plugins .. "/auto-core.nvim/main",
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
local sb = vim.fn.tempname() .. "-skill"
vim.env.XDG_STATE_HOME = sb .. "/state"
-- $KB_ROOT must be isolated too, not just XDG. ADR-0067 pairs every review with
-- a Markdown document under $KB_ROOT/agents/<reviewer>/reviews/, so a suite
-- that leaves this inheriting the real environment WRITES INTO THE LIVE KB —
-- which this one did until it was caught, leaving six stub files behind and
-- silently skewing revision allocation on every rerun.
vim.env.AUTO_AGENTS_KB_ROOT = sb .. "/kb"
local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

-- a repo with a reviewable commit
local lab = sb .. "/lab"; vim.fn.mkdir(lab, "p")
local function G(...) local a={"git","-C",lab,"-c","user.email=t@t","-c","user.name=t"}
  for _,x in ipairs({...}) do a[#a+1]=x end return vim.system(a,{}):wait() end
G("init","-q","-b","main")
vim.fn.writefile({ "one", "two", "three" }, lab .. "/auth.go")
G("add","."); G("commit","-qm","base")
G("config","remote.origin.url","git@github.com:yongjohnlee80/autodb.git")
vim.fn.writefile({ "one", "TWO-changed", "three", "four" }, lab .. "/auth.go")
G("add","."); G("commit","-qm","fix: the guard")
local sha = vim.trim(G("rev-parse","HEAD").stdout or "")
local base = vim.trim(G("rev-parse","HEAD~1").stdout or "")

local store  = require("worktree.store")
local review = require("worktree.review")
local repos  = require("worktree.repos")
store._root_override = sb .. "/wtstore"
require("worktree.watch")._reset_for_tests(); repos._reset_for_tests()

-- Step 2: the skill says resolve the slug via remote_slug, not by guessing
local slug, url = store.remote_slug(lab .. "/.git")
ok("skill step 2: remote_slug resolves owner__repo from the remote",
  slug == "yongjohnlee80__autodb", slug .. " / " .. tostring(url))

-- Step 3: no revision is computed here — save_next() claims it.
-- This suite claims to exercise the skill VERBATIM, so it must track the skill.
-- It previously computed `latest_revision() + 1` and called `save()`, which is
-- the exact check-then-write race the skill was changed to avoid; a suite
-- running the old flow cannot catch a regression in the real caller (r3 SF1).
ok("skill step 3: nothing is recorded for this commit yet",
  review.latest_revision(slug, sha) == 0,
  tostring(review.latest_revision(slug, sha)))

-- Step 4: build + save exactly as documented
local doc = review.new({
  owner = "yongjohnlee80", name = "autodb", url = url,
  commit = sha, base = base, reviewer = "lector",
  verdict = "change_requested",
  summary = "One must-fix. Also: this module has no tests (unplaceable).",
})
doc.comments = {
  { path = "auth.go", line = 2, side = "RIGHT", severity = "must-fix",
    body = "the guard is inverted here" },
  { path = "auth.go", line = 2, side = "LEFT", severity = "nit",
    body = "the old form read better" },
  { path = "auth.go", line = 900, side = "RIGHT", severity = "question",
    body = "not a line in this diff" },
}
-- ADR-0067 moved the skill's write step from `save_next` (JSON only) to
-- `save_pair`, because the skill was the family's main producer of UNPAIRED
-- canonical reviews — review-json §6 requires a primary Markdown for every
-- projection, and `save_next` never wrote one. The e2e models the skill, so it
-- models the new step.
-- The skill supplies a BODY and a topic; the store owns the path. It also sets
-- `reviewer_slug`, which is the directory the document lands in — the store
-- refuses a write it cannot attribute to a reviewer.
local MARKDOWN = "# Review\n\nprose the JSON cannot carry"
doc.reviewer_slug = "lector"
local res, serr = review.save_pair(slug, doc, MARKDOWN, { topic = "e2e" })
local path, rev = res and res.json_path, res and res.revision
ok("skill step 4: save_pair() writes the JSON", path ~= nil
  and vim.fn.filereadable(path) == 1, tostring(serr))
ok("skill step 4: *** and its primary Markdown beside it ***",
  res ~= nil and vim.fn.filereadable(res.md_path) == 1, res and res.md_path)
ok("skill step 4: and REPORTS the revision it claimed", rev == 1, tostring(rev))
ok("skill step 4: the filename matches the documented grammar",
  vim.fn.fnamemodify(path or "", ":t") == slug .. "@" .. sha:sub(1,7) .. ".r1.review.json",
  vim.fn.fnamemodify(path or "", ":t"))
ok("skill step 4: *** the JSON cross-references the document ***",
  (review.load(slug, sha, 1) or {}).document == res.md_path,
  vim.inspect((review.load(slug, sha, 1) or {}).document))

-- non-negotiable #2: a 0-based line must be REJECTED
local bad = vim.deepcopy(doc); bad.comments[1].line = 0
ok("non-negotiable 2: a 0-based line is refused, not shifted",
  select(1, review.save_pair(slug, bad, MARKDOWN, { topic = "e2e" })) == nil)

-- non-negotiable 4: a re-review is a NEW revision, and save_next assigns it
-- rather than the caller guessing.
local doc2 = vim.deepcopy(doc)
local res2 = (function() doc2.reviewer_slug = "lector"; return review.save_pair(slug, doc2, MARKDOWN, { topic = "e2e" }) end)()
local p2, rev2 = res2 and res2.json_path, res2 and res2.revision
-- ADR-0067: a re-review is a NEW revision, and a FAILED attempt RETIRES the
-- number it reserved rather than recycling it. The refused 0-based review above
-- consumed r2, so the next successful claim is r3 — a gap in the sequence is
-- the deliberate price of an append-only fence, and reusing the number is how a
-- live writer's artifact gets overwritten.
ok("non-negotiable 4: a re-review claims a NEW revision, leaving r1 intact",
  rev2 ~= nil and rev2 > 1 and review.latest_revision(slug, sha) == rev2
    and #review.list_for(slug, sha) == 2,
  tostring(rev2) .. " / " .. tostring(review.latest_revision(slug, sha)))
-- ADR-0067's preflight changed this for the better: a review refused for a
-- SCHEMA reason (here, a 0-based line) is now rejected BEFORE the reservation,
-- so it consumes nothing at all. Previously it reserved, failed late, and
-- retired the number — correct, but wasteful and surprising.
ok("non-negotiable 4: *** a schema refusal consumes NO revision ***",
  rev2 == 2, ("next claim was r%s — the refused attempt reserved nothing")
    :format(tostring(rev2)))
ok("non-negotiable 4: and left no tombstone, because nothing was claimed",
  vim.fn.filereadable(review.tombstone_path(slug, sha, 2)) == 0,
  review.tombstone_path(slug, sha, 2))
ok("non-negotiable 4: the refusal still happened (positive control)",
  select(1, review.save_pair(slug, (function()
    local b = vim.deepcopy(doc); b.comments[1].line = 0; b.reviewer_slug = "lector"
    return b
  end)(), MARKDOWN, { topic = "e2e" })) == nil)
ok("non-negotiable 4: and r1's content is untouched",
  (review.load(slug, sha, 1) or {}).reviewer == "lector", tostring(p2))

-- Step 6: name the unplaceable
local found = repos.repos(lab)
local repo
for _, r in ipairs(found) do if r.common_dir:find(lab, 1, true) then repo = r end end
ok("skill step 6: the repo resolves", repo ~= nil, vim.inspect(found and #found))
local files = repos.diff(repo, sha)
ok("skill step 6: diff() returns parsed files", #files == 1 and files[1].path == "auth.go",
  vim.inspect(#files))
local lost = require("auto-core.ui.diffview").unplaced_for(files, review.by_path(doc))
ok("skill step 6: unplaced_for names the comment on line 900",
  #lost == 1 and lost[1].line == 900, vim.inspect(lost))
ok("skill step 6: and the two placeable comments are NOT reported lost", #lost == 1)

-- Upload projection
local payload = review.github_payload(doc)
ok("upload: event maps to REQUEST_CHANGES", payload.review_event == "REQUEST_CHANGES")
ok("upload: the unplaceable finding still reaches GitHub via the body",
  payload.body:find("no tests", 1, true) ~= nil, payload.body)
ok("upload: severity is folded into each comment body",
  payload.comments[1].body:find("must%-fix") ~= nil, payload.comments[1].body)
ok("upload: comments carry GitHub's own field names",
  payload.comments[1].path ~= nil and payload.comments[1].line ~= nil
  and payload.comments[1].side ~= nil)

vim.fn.delete(sb, "rf")
print(string.format("\n%d passed, %d failed", pass, fail))
-- Exit via os.exit, matching tests/smoke.lua. This used `vim.cmd("cq")` /
-- `"qa!"`; both convey the right status, but two conventions in one repo mean
-- any runner has to handle both, and `cq`'s exit code is `:cquit`'s (1 by
-- default) rather than one we state outright. One convention, stated plainly.
if fail > 0 then
  os.exit(1)
end
os.exit(0)
