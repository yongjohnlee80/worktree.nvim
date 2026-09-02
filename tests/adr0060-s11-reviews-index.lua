-- tests/adr0060-s11-reviews-index.lua — the repo-wide review index (§11).
--
-- Run:  nvim --headless -u NONE -l tests/adr0060-s11-reviews-index.lua
--
-- `list_for(slug, sha)` answers "what reviews does THIS commit have", which is
-- the question that stops working after a rebase: the file names the sha it
-- reviewed, so once history is rewritten no commit row can show it. §11 adds a
-- listing keyed on the REPO, plus the metadata a panel puts beside each file
-- and the per-file tally a tree badges changed files with.
--
-- Paths are derived, never hardcoded (family rule 2), and both XDG_STATE_HOME
-- and $KB_ROOT are isolated: `save_pair` writes a Markdown document under
-- $KB_ROOT, and a suite that inherits the real one writes into the live KB.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
-- Installed copy first, then this repo's `main`, then the SAME-BRANCH sibling
-- worktree, then this checkout: `prepend` pushes to the front, so the last
-- existing entry wins. The same-branch sibling is what pairs a cross-repo fix
-- with its other half before either merges.
for _, p in ipairs({
  LAZY .. "/auto-core.nvim",
  plugins .. "/auto-core.nvim/main",
  plugins .. "/auto-core.nvim/" .. branch_dir,
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
local sb = vim.fn.tempname() .. "-s11"
vim.env.XDG_STATE_HOME = sb .. "/state"
vim.env.AUTO_AGENTS_KB_ROOT = sb .. "/kb"

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

local store  = require("worktree.store")
local review = require("worktree.review")
local repos  = require("worktree.repos")

local lab = sb .. "/lab"; vim.fn.mkdir(lab, "p")
local function G(...)
  local a = { "git", "-C", lab, "-c", "user.email=t@t", "-c", "user.name=t" }
  for _, x in ipairs({ ... }) do a[#a + 1] = x end
  return vim.system(a, {}):wait()
end
G("init", "-q", "-b", "main")
G("config", "remote.origin.url", "git@github.com:yongjohnlee80/proj.git")
vim.fn.writefile({ "one", "two", "three" }, lab .. "/auth.go")
vim.fn.writefile({ "x" }, lab .. "/util.go")
G("add", "."); G("commit", "-qm", "base")
vim.fn.writefile({ "one", "TWO", "three" }, lab .. "/auth.go")
G("add", "."); G("commit", "-qm", "second")
local sha2 = vim.trim(G("rev-parse", "HEAD").stdout or "")
local sha1 = vim.trim(G("rev-parse", "HEAD~1").stdout or "")

store._root_override = sb .. "/wtstore"
require("worktree.watch")._reset_for_tests(); repos._reset_for_tests()
local slug = store.remote_slug(lab .. "/.git")
ok("fixture: the slug resolves from the remote", slug == "yongjohnlee80__proj", slug)

local MD = "# Review\n\nprose"
local function write_review(sha, opts)
  local doc = review.new({
    owner = "yongjohnlee80", name = "proj", url = "git@github.com:yongjohnlee80/proj.git",
    commit = sha, reviewer = opts.reviewer or "lector",
    verdict = opts.verdict, summary = opts.summary,
  })
  doc.comments = opts.comments or {}
  doc.reviewer_slug = opts.reviewer or "lector"
  local res, err = review.save_pair(slug, doc, MD, { topic = opts.topic or "s11" })
  assert(res, "fixture review must save: " .. tostring(err))
  return res
end

print("\n[1] worst_severity ranks the ladder")
ok("must-fix outranks the rest",
  review.worst_severity({ ["must-fix"] = 1, nit = 9, question = 3 }) == "must-fix")
ok("should-fix outranks nit and question",
  review.worst_severity({ ["should-fix"] = 1, nit = 9 }) == "should-fix")
ok("nit outranks question", review.worst_severity({ nit = 1, question = 4 }) == "nit")
ok("*** a review with no comments has NO worst severity ***",
  review.worst_severity({}) == nil and review.worst_severity(nil) == nil)
ok("a zero tally does not count as a finding",
  review.worst_severity({ ["must-fix"] = 0, nit = 1 }) == "nit")

print("\n[2] describe projects one file into listing + info metadata")
local r1 = write_review(sha2, {
  verdict = "change_requested", summary = "one must-fix",
  comments = {
    { path = "auth.go", line = 2, side = "RIGHT", severity = "must-fix",
      body = "the guard is inverted" },
    { path = "auth.go", line = 3, side = "RIGHT", severity = "nit", body = "naming" },
    { path = "util.go", line = 1, side = "RIGHT", severity = "question",
      body = "is this reachable?", resolved = true },
  },
})
local m = review.describe(r1.json_path)
ok("it names the commit the review belongs to", m.commit == sha2, tostring(m.commit))
ok("the short sha and revision come from the FILENAME",
  m.short == sha2:sub(1, 7) and m.revision == 1,
  ("%s r%s"):format(tostring(m.short), tostring(m.revision)))
ok("it carries the reviewer, verdict and summary",
  m.reviewer == "lector" and m.verdict == "change_requested" and m.summary == "one must-fix",
  vim.inspect({ m.reviewer, m.verdict, m.summary }))
ok("created is recorded", type(m.created) == "string" and m.created ~= "", tostring(m.created))
ok("comments are counted, resolved among them",
  m.comments == 3 and m.resolved == 1, ("%d/%d"):format(m.comments, m.resolved))
ok("*** severities are tallied and the WORST is reported ***",
  m.severities["must-fix"] == 1 and m.severities["nit"] == 1
  and m.severities["question"] == 1 and m.worst == "must-fix",
  vim.inspect({ m.severities, m.worst }))
ok("*** per-file tallies carry their own worst ***",
  m.files["auth.go"].count == 2 and m.files["auth.go"].worst == "must-fix"
  and m.files["util.go"].count == 1 and m.files["util.go"].worst == "question",
  vim.inspect(m.files))
ok("the file list is sorted", vim.deep_equal(m.file_list, { "auth.go", "util.go" }),
  vim.inspect(m.file_list))
ok("a well-formed review reports no error", m.err == nil, tostring(m.err))
ok("describe guards a missing path", select(2, review.describe("")) ~= nil)

print("\n[3] describe is TOLERANT — a malformed review must stay visible")
-- The strict reader refuses it; the listing must not, or a file the user cannot
-- see is a file the user cannot delete.
local bad_name = review.filename(slug, sha1, 9)
local bad_path = store.reviews_dir(slug) .. "/" .. bad_name
vim.fn.writefile({ "{ this is not json" }, bad_path)
local bm, berr = review.describe(bad_path)
ok("*** an unparseable review still yields a record ***", bm ~= nil, tostring(berr))
ok("and it still names its commit and revision from the filename",
  bm.short == sha1:sub(1, 7) and bm.revision == 9,
  ("%s r%s"):format(tostring(bm.short), tostring(bm.revision)))
ok("with err set, and no invented findings",
  bm.err ~= nil and bm.comments == 0 and bm.worst == nil, tostring(bm.err))
ok("the STRICT reader still refuses it",
  select(1, review.load(slug, sha1, 9)) == nil)
-- Valid JSON that is not a valid review: read what is there, flag the rest.
local half_path = store.reviews_dir(slug) .. "/" .. review.filename(slug, sha1, 8)
store.write_json(half_path, {
  schema = review.SCHEMA, commit = sha1, revision = 8,
  comments = { { path = "auth.go", line = 1, severity = "must-fix", body = "real finding" } },
})
local hm = review.describe(half_path)
ok("*** a review that fails VALIDATION keeps its findings and gains an err ***",
  hm.comments == 1 and hm.worst == "must-fix" and hm.err ~= nil, tostring(hm.err))

print("\n[4] list_all is keyed on the REPO — the rebase property")
local r2 = write_review(sha1, { verdict = "approved", summary = "fine", comments = {} })
local all = review.list_all(slug)
ok("every review file is listed, across commits and revisions", #all == 4,
  vim.inspect(vim.tbl_map(function(r) return r.name end, all)))
ok("each record names its commit, revision and path",
  all[1].short ~= nil and all[1].revision ~= nil
  and vim.fn.filereadable(all[1].path) == 1, vim.inspect(all[1]))
ok("the malformed file is listed too", (function()
  for _, r in ipairs(all) do if r.name == bad_name then return true end end
end)() == true, vim.inspect(vim.tbl_map(function(r) return r.name end, all)))
-- The property this exists for: rewrite history, and the commit-keyed lookup
-- goes blind while the repo-keyed one does not.
G("commit", "-q", "--amend", "-m", "second, amended")
local sha2b = vim.trim(G("rev-parse", "HEAD").stdout or "")
ok("fixture: the amend moved the sha", sha2b ~= sha2, sha2b)
ok("*** CONTROL: list_for on the rewritten commit finds nothing ***",
  #review.list_for(slug, sha2b) == 0, tostring(#review.list_for(slug, sha2b)))
ok("*** and the review is STILL in the repo-wide listing ***",
  #review.list_all(slug) == 4 and (function()
    for _, r in ipairs(review.list_all(slug)) do
      if r.short == sha2:sub(1, 7) then return true end
    end
  end)() == true)
ok("an unknown slug lists nothing rather than erroring",
  #review.list_all("no__such__repo") == 0)

print("\n[5] reviewed_paths tallies a commit's files, merged across revisions")
local r3 = write_review(sha1, {
  comments = {
    { path = "auth.go", line = 1, side = "RIGHT", severity = "should-fix", body = "again" },
  },
})
ok("fixture: two well-formed revisions now exist for that commit",
  r3.revision > r2.revision, ("r%d then r%d"):format(r2.revision, r3.revision))
local tally = review.reviewed_paths(slug, sha1)
ok("*** a file commented on in ANY revision is reported ***",
  tally["auth.go"] ~= nil, vim.inspect(tally))
ok("counts merge across revisions", tally["auth.go"].count >= 2,
  vim.inspect(tally["auth.go"]))
ok("*** and the malformed revision's finding counts too ***",
  tally["auth.go"].worst == "must-fix", vim.inspect(tally["auth.go"]))
ok("a file nobody reviewed is absent", tally["util.go"] == nil, vim.inspect(tally))
ok("a commit with no reviews tallies nothing",
  next(review.reviewed_paths(slug, sha2b)) == nil)

print("\n[6] the repos surface — the only module a frontend talks to")
local repo = { slug = slug, common_dir = lab .. "/.git", label = "proj" }
-- Sourced from the store rather than hardcoded: [5] adds a revision, and a
-- literal here would have to be re-counted every time a section above grows.
-- Pinned absolutely once, so drift is still visible.
local total = #review.list_all(slug)
ok("fixture: the store holds every review written above", total == 5, tostring(total))
ok("reviews_dir names the store", repos.reviews_dir(repo) == store.reviews_dir(slug),
  tostring(repos.reviews_dir(repo)))
ok("reviews_index counts without describing", #repos.reviews_index(repo) == total)
local described = repos.reviews_all(repo)
ok("reviews_all describes every one of them", #described == total
  and described[1].name ~= nil and described[1].comments ~= nil,
  vim.inspect(described[1] and described[1].name))
ok("review_meta describes one by path",
  (repos.review_meta(r1.json_path) or {}).commit == sha2)
ok("reviewed_paths reaches the tally", repos.reviewed_paths(repo, sha1)["auth.go"] ~= nil)
ok("every one guards a repo with no slug",
  #repos.reviews_index({}) == 0 and #repos.reviews_all({}) == 0
  and next(repos.reviewed_paths({}, sha1)) == nil and repos.reviews_dir({}) == nil)

print("\n[7] CONTROL: the two tiers really do cost differently")
-- The claim in the comments — and the reason the panel draws a count on a
-- collapsed row — is that the index opens no documents. Counted at the one
-- function both paths must go through to read a file.
local real_read = store.read_json
local reads = 0
store.read_json = function(...) reads = reads + 1; return real_read(...) end
reads = 0; repos.reviews_index(repo)
local index_reads = reads
reads = 0; repos.reviews_all(repo)
local all_reads = reads
store.read_json = real_read
ok("*** reviews_index opens NO review documents ***", index_reads == 0,
  tostring(index_reads))
ok("*** reviews_all opens one per review ***", all_reads == total,
  ("%d vs %d"):format(all_reads, total))

vim.fn.delete(sb, "rf")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
