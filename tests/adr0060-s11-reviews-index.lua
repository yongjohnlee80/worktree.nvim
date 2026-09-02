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

print("\n[8] remove deletes the JSON and FENCES the revision")
-- The property that makes this more than an unlink: `max_recorded_revision`
-- counts canonical + reserved + tombstoned records, so deleting the highest
-- revision without a tombstone puts that number back in circulation and the
-- next review for the commit becomes a SECOND r<N>.
do
  local sha = sha1
  local before_max = review.max_recorded_revision(slug, sha)
  local victim = write_review(sha, {
    verdict = "comment", summary = "to be removed",
    comments = { { path = "auth.go", line = 1, side = "RIGHT", severity = "nit",
                   body = "removable" } },
  })
  ok("[8] fixture: the review was written and claimed the next revision",
    victim.revision == before_max + 1 and vim.fn.filereadable(victim.json_path) == 1,
    ("r%d after max r%d"):format(victim.revision, before_max))
  local doc_before = (review.describe(victim.json_path) or {}).document
  ok("[8] fixture: it names a paired canonical Markdown",
    type(doc_before) == "string" and vim.fn.filereadable(doc_before) == 1,
    tostring(doc_before))

  local rok, rerr, detail = review.remove(slug, sha, victim.revision)
  ok("[8] *** remove reports success ***", rok == true, tostring(rerr))
  ok("[8] *** the JSON is gone ***", vim.fn.filereadable(victim.json_path) == 0)
  ok("[8] it is gone from both listings",
    #vim.tbl_filter(function(r) return r.path == victim.json_path end,
      review.list_all(slug)) == 0
    and #vim.tbl_filter(function(r) return r.revision == victim.revision end,
      review.list_for(slug, sha)) == 0)
  ok("[8] *** and the revision is TOMBSTONED, not merely deleted ***",
    detail ~= nil and detail.tombstoned == true
    and vim.fn.filereadable(detail.tombstone) == 1, vim.inspect(detail))
  ok("[8] *** so the allocator still refuses to re-issue that number ***",
    review.max_recorded_revision(slug, sha) >= victim.revision,
    ("max r%d vs removed r%d"):format(review.max_recorded_revision(slug, sha), victim.revision))
  -- CONTROL: the reuse this prevents. Delete the tombstone — the state a plain
  -- unlink would have left — and the allocator hands the number back.
  local fenced_max = review.max_recorded_revision(slug, sha)
  vim.fn.delete(detail.tombstone)
  ok("[8] *** CONTROL: without the tombstone the number IS re-offered ***",
    review.max_recorded_revision(slug, sha) < fenced_max,
    ("%d vs %d"):format(review.max_recorded_revision(slug, sha), fenced_max))
  -- Put it back and prove the next real write skips the number.
  local reok = review.retire(slug, sha, victim.revision, nil)
  ok("[8] fixture: the fence is restored", reok == true)
  local nxt = write_review(sha, { verdict = "comment", summary = "after the removal" })
  ok("[8] *** the next review claims a NEW revision, never the removed one ***",
    nxt.revision > victim.revision, ("r%d after removing r%d"):format(nxt.revision, victim.revision))

  ok("[8] *** the paired canonical Markdown is KEPT — the JSON is its projection ***",
    vim.fn.filereadable(doc_before) == 1, tostring(doc_before))
  ok("[8] and remove REPORTS the document it left behind",
    detail.document == doc_before, tostring(detail.document))

  -- Guards: nothing destructive fires on a bad address.
  ok("[8] removing a revision that does not exist fails without a tombstone",
    select(1, review.remove(slug, sha, 4242)) == false
    and vim.fn.filereadable(review.tombstone_path(slug, sha, 4242)) == 0)
  ok("[8] guards on slug / sha / revision",
    select(1, review.remove(nil, sha, 1)) == false
    and select(1, review.remove(slug, "", 1)) == false
    and select(1, review.remove(slug, sha, nil)) == false)

  -- remove_path: how a panel row addresses a review, and the one form that
  -- works for a document whose own commit field cannot be trusted.
  local bad2 = store.reviews_dir(slug) .. "/" .. review.filename(slug, sha1, 77)
  vim.fn.writefile({ "{ not json" }, bad2)
  ok("[8] *** remove_path deletes a MALFORMED review — the main reason to want it ***",
    select(1, review.remove_path(bad2)) == true and vim.fn.filereadable(bad2) == 0)
  ok("[8] remove_path refuses a name that is not a review",
    select(1, review.remove_path("/tmp/not-a-review.txt")) == false)
  ok("[8] remove_path guards an empty path", select(1, review.remove_path("")) == false)

  -- The frontend verb is CONTAINED: a path outside this repo's store is refused
  -- before anything is unlinked.
  local outside = sb .. "/outside.review.json"
  vim.fn.writefile({ "{}" }, outside)
  local repo2 = { slug = slug, common_dir = lab .. "/.git", label = "proj" }
  local cok, cerr = repos.remove_review(repo2, outside)
  ok("[8] *** repos.remove_review REFUSES a path outside the repo's store ***",
    cok == false and tostring(cerr):find("refusing to delete outside", 1, true) ~= nil,
    tostring(cerr))
  ok("[8] and the file it refused is untouched", vim.fn.filereadable(outside) == 1)
  local trav = store.reviews_dir(slug) .. "/../../outside.review.json"
  ok("[8] *** a `..` traversal is refused on the RESOLVED path ***",
    select(1, repos.remove_review(repo2, trav)) == false
    and vim.fn.filereadable(outside) == 1)
  ok("[8] repos.remove_review guards a repo with no slug",
    select(1, repos.remove_review({}, victim.json_path)) == false)
  -- And it works through the frontend for a real one.
  local last = write_review(sha1, { verdict = "comment", summary = "via the surface" })
  ok("[8] the frontend verb deletes a contained review",
    select(1, repos.remove_review(repo2, last.json_path)) == true
    and vim.fn.filereadable(last.json_path) == 0)
end

print("\n[9] CONTROL: containment is not identity — the cross-repo delete")
-- lector, worktree#4 must-fix (2026-09-02). `remove_review` proved the supplied
-- path sat under repo A, then `remove_path` parsed the slug from the BASENAME
-- and `remove` rebuilt its target under THAT slug — so a path contained in A
-- while named for B tombstoned and unlinked B's real review, and the claimed
-- A-side file did not even have to exist. Observed at the public boundary:
-- {ok:true, claimed_a_existed:false, real_b_survived:false, b_tombstoned:true}.
-- The prior controls covered an outside path, a `..` traversal and a normal
-- contained file; a contained path whose FILENAME embeds a different slug is
-- the discriminating case they all missed.
do
  local labB = sb .. "/labB"; vim.fn.mkdir(labB, "p")
  local function GB(...)
    local a = { "git", "-C", labB, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    return vim.system(a, {}):wait()
  end
  GB("init", "-q", "-b", "main")
  GB("config", "remote.origin.url", "git@github.com:yongjohnlee80/proj-b.git")
  vim.fn.writefile({ "b" }, labB .. "/b.go")
  GB("add", "."); GB("commit", "-qm", "b base")
  local shaB = vim.trim(GB("rev-parse", "HEAD").stdout or "")
  local slugB = store.remote_slug(labB .. "/.git")
  ok("[9] fixture: repo B is a DIFFERENT repository", slugB ~= slug and slugB ~= "", slugB)

  local docB = review.new({
    owner = "yongjohnlee80", name = "proj-b",
    url = "git@github.com:yongjohnlee80/proj-b.git",
    commit = shaB, reviewer = "lector", verdict = "comment", summary = "B's own review",
  })
  docB.comments = { { path = "b.go", line = 1, side = "RIGHT", severity = "must-fix",
                      body = "B's finding" } }
  docB.reviewer_slug = "lector"
  local resB, berr = review.save_pair(slugB, docB, MD, { topic = "s11b" })
  assert(resB, "fixture: B's review must save: " .. tostring(berr))
  local b_tomb = review.tombstone_path(slugB, shaB, resB.revision)
  ok("[9] fixture: B has a real review and no tombstone",
    vim.fn.filereadable(resB.json_path) == 1 and vim.fn.filereadable(b_tomb) == 0)

  -- The attack shape: inside repo A's directory, named for repo B.
  local decoy = store.reviews_dir(slug) .. "/" .. review.filename(slugB, shaB, resB.revision)
  local repoA = { slug = slug, common_dir = lab .. "/.git", label = "proj" }
  local repoB = { slug = slugB, common_dir = labB .. "/.git", label = "proj-b" }
  ok("[9] fixture: the decoy path is INSIDE repo A's store and ABSENT",
    decoy:sub(1, #store.reviews_dir(slug)) == store.reviews_dir(slug)
    and vim.fn.filereadable(decoy) == 0, decoy)

  local rok, rerr = repos.remove_review(repoA, decoy)
  ok("[9] *** the repo-A call is REFUSED ***", rok == false, tostring(rerr))
  ok("[9] and it names the repo the caller confused",
    tostring(rerr):find(slugB, 1, true) ~= nil, tostring(rerr))
  ok("[9] *** repo B's review SURVIVES ***", vim.fn.filereadable(resB.json_path) == 1)
  ok("[9] *** and NO tombstone was created for repo B ***",
    vim.fn.filereadable(b_tomb) == 0)

  -- Again with the decoy actually PRESENT in A's directory: the earlier probe
  -- needed no such file, but a real one must not change the answer either.
  vim.fn.writefile({ "{}" }, decoy)
  local rok2, rerr2 = repos.remove_review(repoA, decoy)
  ok("[9] *** still refused when the decoy really exists ***", rok2 == false, tostring(rerr2))
  ok("[9] repo B still survives, still untombstoned",
    vim.fn.filereadable(resB.json_path) == 1 and vim.fn.filereadable(b_tomb) == 0)
  ok("[9] and the decoy itself was not deleted either", vim.fn.filereadable(decoy) == 1)

  -- The PRIMITIVE refuses on its own, not merely the frontend that was audited.
  local pok, perr = review.remove_path(decoy)
  ok("[9] *** review.remove_path refuses a non-canonical location too ***",
    pok == false and tostring(perr):find("canonical", 1, true) ~= nil, tostring(perr))
  ok("[9] repo B survives that call as well",
    vim.fn.filereadable(resB.json_path) == 1 and vim.fn.filereadable(b_tomb) == 0)
  vim.fn.delete(decoy)

  -- CONTROL: the guard is not a blanket refusal — B's own review is still
  -- removable through B. Without this, every assertion above would also pass
  -- if `remove_review` had simply stopped working.
  local gok, gerr = repos.remove_review(repoB, resB.json_path)
  ok("[9] *** CONTROL: a genuine canonical review is still removable ***",
    gok == true and vim.fn.filereadable(resB.json_path) == 0, tostring(gerr))
  ok("[9] and THAT delete did fence its revision", vim.fn.filereadable(b_tomb) == 1)
end

print("\n[10] a repo with NO remote can still be reviewed")
-- Johno, 2026-09-02: submitting a review was impossible on `example`, a bare
-- repo with no origin. `review.validate` requires identity — a url, or owner
-- AND name — and `repos.repos()` carried only the joined slug, so the frontend
-- had nothing to build one from and every submit was refused with "repo
-- carries no identity". `store.slug` had always computed the pair and thrown
-- it away.
do
  -- SLUG STABILITY FIRST. Existing review directories are named by `slug`, so
  -- exposing the pair must not change a single key. Any drift here silently
  -- orphans every review already on disk.
  local cases = {
    { "git@github.com:yongjohnlee80/autodb.git", "yongjohnlee80__autodb", "yongjohnlee80", "autodb" },
    { "ssh://git@github.com/yongjohnlee80/golib", "yongjohnlee80__golib", "yongjohnlee80", "golib" },
    { "https://github.com/o/r.git/",             "o__r",                 "o",             "r" },
    { "/home/j/Source/nvim-plugins/autodb",      "nvim-plugins__autodb", "nvim-plugins",  "autodb" },
    { "example",                                 "local__example",       "local",         "example" },
    -- The empty identity has always fallen back to `repo` (`or "repo"` in the
    -- single-segment branch), which is the behaviour this row pins. My first
    -- attempt asserted `local__` and this guard caught it — which is the point
    -- of pinning the slug rather than trusting the refactor.
    { "",                                        "local__repo",          "local",         "repo" },
  }
  local stable, broke = true, nil
  for _, c in ipairs(cases) do
    if store.slug(c[1]) ~= c[2] then stable = false; broke = c[1] .. " -> " .. store.slug(c[1]) end
  end
  ok("[10] *** every slug is byte-identical to before the refactor ***", stable, tostring(broke))
  local pairs_ok = true
  for _, c in ipairs(cases) do
    local o, n = store.identity(c[1])
    if o ~= c[3] or n ~= c[4] then
      pairs_ok = false
      print("      " .. c[1] .. " -> " .. tostring(o) .. " / " .. tostring(n))
    end
  end
  ok("[10] identity() returns the two halves the slug is joined from", pairs_ok)
  ok("[10] and the slug is exactly those halves joined",
    (function()
      local o, n = store.identity("git@github.com:a/b.git")
      return o .. "__" .. n == store.slug("git@github.com:a/b.git")
    end)())

  -- A repo with a remote keeps reporting it.
  local hosted = store.remote_identity(lab .. "/.git")
  ok("[10] a hosted repo reports its url, owner and name",
    hosted.url ~= nil and hosted.owner == "yongjohnlee80" and hosted.name == "proj"
    and hosted.slug == slug, vim.inspect(hosted))

  -- The case that failed: no origin at all.
  local bare = sb .. "/nolocal"; vim.fn.mkdir(bare, "p")
  local function GN(...)
    local a = { "git", "-C", bare, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, x in ipairs({ ... }) do a[#a + 1] = x end
    return vim.system(a, {}):wait()
  end
  GN("init", "-q", "-b", "main")
  vim.fn.writefile({ "x" }, bare .. "/x.go")
  GN("add", "."); GN("commit", "-qm", "local only")
  local nsha = vim.trim(GN("rev-parse", "HEAD").stdout or "")
  ok("[10] fixture: the repo really has no origin",
    vim.trim(GN("config", "--get", "remote.origin.url").stdout or "") == "")

  local nid = store.remote_identity(bare .. "/.git")
  ok("[10] *** it has NO url but still has an owner and a name ***",
    nid.url == nil and nid.owner ~= nil and nid.owner ~= ""
    and nid.name ~= nil and nid.name ~= "", vim.inspect(nid))
  ok("[10] named after its container, which is stable and descriptive",
    nid.name == "nolocal", vim.inspect(nid))

  -- The end-to-end property: a review for it VALIDATES and writes.
  local doc = review.new({
    slug = nid.slug, url = nid.url, owner = nid.owner, name = nid.name,
    commit = nsha, reviewer = "lector", verdict = "comment", summary = "local repos are reviewable",
  })
  doc.comments = { { path = "x.go", line = 1, side = "RIGHT", severity = "nit", body = "fine" } }
  doc.reviewer_slug = "lector"
  local vok, problems = review.validate(doc)
  ok("[10] *** a review built from that identity VALIDATES ***", vok == true,
    vim.inspect(problems))
  local res, rerr = review.save_pair(nid.slug, doc, MD, { topic = "nolocal" })
  ok("[10] *** and it writes ***", res ~= nil and vim.fn.filereadable(res.json_path) == 1,
    tostring(rerr))

  -- CONTROL: without the pair the schema still refuses, so [10] is not passing
  -- because validation went soft.
  local blind = review.new({
    slug = nid.slug, commit = nsha, reviewer = "lector", verdict = "comment",
  })
  blind.comments = {}
  blind.reviewer_slug = "lector"
  local bok, bproblems = review.validate(blind)
  ok("[10] *** CONTROL: an identity-less review is STILL refused ***",
    bok == false and table.concat(bproblems, ";"):find("no identity", 1, true) ~= nil,
    vim.inspect(bproblems))

  -- And the frontend record carries the pair, which is what the panel reads.
  local recs = repos.repos(sb)
  local seen
  for _, r in ipairs(recs) do if r.slug == nid.slug then seen = r end end
  ok("[10] *** repos.repos() carries owner and name on the record ***",
    seen ~= nil and seen.owner == nid.owner and seen.name == nid.name,
    vim.inspect(seen))
end

vim.fn.delete(sb, "rf")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
