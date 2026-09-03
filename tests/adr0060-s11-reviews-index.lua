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
  -- The PAIR is deleted, not just the projection (Johno, 2026-09-03 — the two
  -- files ARE one review). §11.6 originally KEPT the Markdown; this reverses it.
  ok("[8] *** and the paired Markdown is gone too ***",
    vim.fn.filereadable(doc_before) == 0, tostring(doc_before))
  ok("[8] *** remove reports that it removed the document ***",
    detail ~= nil and detail.document == doc_before and detail.document_removed == true,
    vim.inspect(detail))
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

  -- (The pair-both-gone assertions moved up beside the JSON check.) A CONTROL
  -- that the delete is not a no-op that merely reported success: neither half
  -- of the removed review is readable, and describe finds nothing for it.
  ok("[8] *** neither half of the removed review remains ***",
    vim.fn.filereadable(victim.json_path) == 0 and vim.fn.filereadable(doc_before) == 0)

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

print("\n[11] the KB root resolves with $AUTO_AGENTS_KB_ROOT UNSET")
-- The environment that broke the feature and that no suite could see. Every
-- test in this family sets AUTO_AGENTS_KB_ROOT — and must, since `save_pair`
-- writes a real document and inheriting the live value writes into the real
-- knowledge base. That isolation is exactly what hid the defect: the editor
-- process has no such variable, `save_pair` read it raw, and every submit from
-- the panel died at the preflight while every agent and every test passed.
--
-- So this section isolates through a LATER hop of the same chain. auto-core
-- resolves KB_ROOT as $AUTO_AGENTS_KB_ROOT > $AUTO_AGENTS_KB_READ[0] >
-- $AUTO_AGENTS_KB_WRITE > auto-agents.kb.root(); unsetting the first two and
-- pointing the third at a temp dir keeps the test safe while proving the
-- RESOLVER is consulted rather than the raw variable — a raw read of
-- AUTO_AGENTS_KB_ROOT cannot see a value that arrives via KB_WRITE, which is
-- what makes the assertion discriminating.
--
-- EVERY hop before the chosen one must be neutralised, and the isolation is
-- ASSERTED BEFORE anything is written. The first cut of this section unset only
-- AUTO_AGENTS_KB_ROOT, so KB_READ[0] — inherited from an agent environment —
-- won the chain and the test wrote a Markdown review into the REAL knowledge
-- base. Isolating one variable out of four is not isolation, and the guard
-- below is what turns that from a silent leak into a failed fixture.
do
  local kb_root_before  = vim.env.AUTO_AGENTS_KB_ROOT
  local kb_read_before  = vim.env.AUTO_AGENTS_KB_READ
  local kb_write_before = vim.env.AUTO_AGENTS_KB_WRITE
  local alt = sb .. "/kb-via-resolver"
  vim.fn.mkdir(alt, "p")
  vim.env.AUTO_AGENTS_KB_ROOT  = nil
  vim.env.AUTO_AGENTS_KB_READ  = nil
  vim.env.AUTO_AGENTS_KB_WRITE = alt

  ok("[11] fixture: the variable the old code read is UNSET",
    (vim.env.AUTO_AGENTS_KB_ROOT == nil or vim.env.AUTO_AGENTS_KB_ROOT == ""),
    tostring(vim.env.AUTO_AGENTS_KB_ROOT))
  local vok, vars = pcall(require, "auto-core.todo.vars")
  ok("[11] fixture: auto-core's resolver is available", vok and type(vars.get) == "function")
  local resolved = select(2, pcall(vars.get, "KB_ROOT"))
  ok("[11] *** and it answers from a later hop in the chain ***",
    resolved == alt, tostring(resolved))
  -- FAIL-FAST: never exercise a real write against an unproven root. `sb` is
  -- this suite's temp sandbox, so anything resolving outside it would be the
  -- live knowledge base.
  local isolated = type(resolved) == "string" and resolved:sub(1, #sb) == sb
  ok("[11] *** the resolved root is INSIDE the sandbox — isolation proven first ***",
    isolated, tostring(resolved))
  if not isolated then
    print("  ABORT [11]: refusing to write — the resolved KB root is outside the sandbox")
  end

  if isolated then

    -- canonical_document with NO kb_root supplied: the unit that refused before.
    local doc, derr = review.canonical_document({
      reviewer_slug = "lector", revision = 1, slug = slug, topic = "resolver",
      kb_root = nil,
    })
    ok("[11] canonical_document still requires an explicit root (it is pure)",
      doc == nil and tostring(derr):find("KB_ROOT", 1, true) ~= nil, tostring(derr))

    -- save_pair with NO kb_root: this is the path the panel takes.
    local d2 = review.new({
      owner = "yongjohnlee80", name = "proj", url = "git@github.com:yongjohnlee80/proj.git",
      commit = sha2, reviewer = "lector", verdict = "comment",
      summary = "written with AUTO_AGENTS_KB_ROOT unset",
    })
    d2.comments = { { path = "auth.go", line = 1, side = "RIGHT", severity = "nit",
                      body = "resolved through auto-core, not the raw env" } }
    d2.reviewer_slug = "lector"
    local res, serr = review.save_pair(slug, d2, MD, { topic = "resolver" })
    ok("[11] *** save_pair writes with NO kb_root and NO $AUTO_AGENTS_KB_ROOT ***",
      res ~= nil and vim.fn.filereadable(res.json_path) == 1, tostring(serr))
    ok("[11] *** and the Markdown landed under the RESOLVED root ***",
      res ~= nil and res.md_path:sub(1, #alt) == alt, res and res.md_path)
    -- The PAIR invariant, asserted so it can fail. This was written as
    -- `select(1, validate_pair(...)) ~= nil`, and `validate_pair` returns a
    -- BOOLEAN first — so both true and false satisfied `~= nil` and the
    -- assertion could not express failure. Worse, it was fed
    -- `review.describe()` metadata, which omits `reviewer_slug` and `repo` and
    -- is therefore REJECTED by `validate_pair`: it was passing on input that
    -- should fail (lector, worktree#6 r0 should-fix).
    --
    -- The full record is what carries the fields the pair check needs, so it is
    -- loaded rather than projected, and the boolean is compared to `true`.
    local full, lerr = review.load(slug, sha2, res and res.revision or 0)
    ok("[11] the written review loads back as a full record",
      full ~= nil and full.document ~= nil, tostring(lerr))
    local pair_ok, pair_problems = review.validate_pair(full or {}, { kb_root = alt })
    ok("[11] *** and it validates as a PAIR — document, reviewer and repo agree ***",
      pair_ok == true, vim.inspect(pair_problems))

    -- MF3: a MALFORMED projection is not a projection with an absent document.
    -- `describe` is tolerant, so a truncated JSON still yields metadata plus an
    -- error; binding only the first result made "unreadable" look like "known
    -- absent", and `remove` fenced the revision, deleted the JSON, and returned
    -- SUCCESS with the Markdown still on disk.
    do
      local d4 = review.new({ owner = "yongjohnlee80", name = "proj",
        url = "git@github.com:yongjohnlee80/proj.git", commit = sha2,
        reviewer = "lector", verdict = "comment", summary = "to be broken" })
      d4.reviewer_slug = "lector"
      local res4 = review.save_pair(slug, d4, "# review\n\nbody\n",
        { topic = "proj", kb_root = alt })
      ok("[11] fixture: a valid pair exists to break",
        res4 ~= nil and res4.json_path ~= nil and res4.md_path ~= nil)
      -- Truncate the projection so it parses as nothing useful.
      vim.fn.writefile({ '{"document":' }, res4.json_path)
      local mok, merr2, mdetail = review.remove(slug, sha2, res4.revision)
      ok("[11] *** MF3: removing a MALFORMED pair is NOT reported as success ***",
        mok == false and merr2 ~= nil, tostring(merr2))
      ok("[11] *** MF3: and the Markdown is reported UNKNOWN, not absent ***",
        mdetail ~= nil and mdetail.document_unknown == true
        and mdetail.document_absent ~= true
        and mdetail.document_removed == false, vim.inspect(mdetail))
      ok("[11] MF3: the projection IS removed and the revision fenced",
        mdetail.json_removed == true and mdetail.fenced == true
        and vim.fn.filereadable(res4.json_path) == 0)
      ok("[11] MF3: the Markdown really is still there — the report is truthful",
        vim.fn.filereadable(res4.md_path) == 1, res4.md_path)
      ok("[11] MF3: the error names the malformed cause",
        tostring(merr2):find("MALFORMED", 1, true) ~= nil, tostring(merr2))
      ok("[11] MF3: and the revision stays fenced, so its number is never reused",
        vim.fn.filereadable(review.tombstone_path(slug, sha2, res4.revision)) == 1)
    end

    -- MF1 (r3): "could not look" is not "found nothing". With the KB root
    -- unresolvable, the search cannot run -- and returning an empty list for
    -- both cases meant a malformed pair was fenced, deleted, and reported as a
    -- COMPLETE removal with its Markdown still on disk.
    do
      local d5 = review.new({ owner = "yongjohnlee80", name = "proj",
        url = "git@github.com:yongjohnlee80/proj.git", commit = sha2,
        reviewer = "lector", verdict = "comment", summary = "search failure" })
      d5.reviewer_slug = "lector"
      local res5 = review.save_pair(slug, d5, "# review\n\nbody\n",
        { topic = "proj", kb_root = alt })
      ok("[11] fixture: a second valid pair exists", res5 ~= nil)
      vim.fn.writefile({ '{"document":' }, res5.json_path)

      -- Make the KB root unresolvable for the duration.
      local saved_kb  = vim.env.AUTO_AGENTS_KB_ROOT
      local saved_rd  = vim.env.AUTO_AGENTS_KB_READ
      local saved_wr  = vim.env.AUTO_AGENTS_KB_WRITE
      vim.env.AUTO_AGENTS_KB_ROOT, vim.env.AUTO_AGENTS_KB_READ,
        vim.env.AUTO_AGENTS_KB_WRITE = nil, nil, nil
      local sok, serr, sdetail = review.remove(slug, sha2, res5.revision)
      vim.env.AUTO_AGENTS_KB_ROOT, vim.env.AUTO_AGENTS_KB_READ,
        vim.env.AUTO_AGENTS_KB_WRITE = saved_kb, saved_rd, saved_wr

      ok("[11] *** MF1: a search that could NOT RUN is not a clean removal ***",
        sok == false and sdetail ~= nil and sdetail.document_unknown == true
        and sdetail.document_absent ~= true, vim.inspect(sdetail))
      ok("[11] MF1: and it says the search itself failed",
        sdetail.document_search_failed ~= nil
        and tostring(serr):find("could not be searched", 1, true) ~= nil,
        tostring(serr))
      ok("[11] MF1: the Markdown really is still there",
        vim.fn.filereadable(res5.md_path) == 1)
      ok("[11] CONTROL — with the KB resolvable, the same shape SEARCHES",
        (function()
          -- Same malformed situation, KB available: the search runs and finds
          -- the real orphan, so this is about the search STATUS and not about
          -- malformed records always failing.
          local _, _, d6 = review.remove(slug, sha2, res5.revision)
          return d6 == nil or d6.document_search_failed == nil
        end)())
    end

    -- MF1 (r4): the SAME conflation survived one layer down, in
    -- `auto-core.docstore.glob`. lector's probe keeps the KB root resolvable
    -- and makes `$KB_ROOT/agents` UNREADABLE: `vim.fn.glob` reports no error,
    -- so the search returned what "nothing matched" returns, and `remove`
    -- reported ok=true / document_absent=true with the Markdown still there.
    -- Fixing the caller was not enough; the primitive had to report it too.
    do
      local d7 = review.new({ owner = "yongjohnlee80", name = "proj",
        url = "git@github.com:yongjohnlee80/proj.git", commit = sha2,
        reviewer = "lector", verdict = "comment", summary = "unreadable agents" })
      d7.reviewer_slug = "lector"
      local res7 = review.save_pair(slug, d7, "# review\n\nbody\n",
        { topic = "proj", kb_root = alt })
      ok("[11] fixture: a third valid pair exists", res7 ~= nil)
      vim.fn.writefile({ '{"document":' }, res7.json_path)

      -- The root RESOLVES; only the traversal is denied.
      vim.fn.system({ "chmod", "000", alt .. "/agents" })
      local uok, uerr, udetail = review.remove(slug, sha2, res7.revision)
      vim.fn.system({ "chmod", "755", alt .. "/agents" })

      ok("[11] *** MF1(r4): an UNREADABLE search root is not a clean removal ***",
        uok == false and udetail ~= nil and udetail.document_unknown == true
        and udetail.document_absent ~= true
        and udetail.document_searched ~= true, vim.inspect(udetail))
      ok("[11] MF1(r4): and it names the traversal failure",
        tostring(udetail.document_search_failed):find("traversed", 1, true) ~= nil
        or tostring(uerr):find("could not be searched", 1, true) ~= nil,
        tostring(udetail.document_search_failed) .. " | " .. tostring(uerr))
      ok("[11] MF1(r4): the Markdown really is still there",
        vim.fn.filereadable(res7.md_path) == 1, res7.md_path)
      ok("[11] CONTROL — with the root READABLE the same shape finds the orphan",
        (function()
          local _, cerr2, cdetail = review.remove(slug, sha2, res7.revision)
          -- The projection is already gone from the failed attempt, so this
          -- reports "no such review" -- what matters is that it does NOT
          -- report a search failure.
          return (cdetail == nil or cdetail.document_search_failed == nil)
            and tostring(cerr2):find("traversed", 1, true) == nil
        end)())
    end

    -- A DIRECTORY at the document's path is not a primary review.
    -- `validate_pair` distinguishes "absent" from "present but not a regular
    -- file", and nothing exercised the second branch -- deleting it changed no
    -- result, which the mutation matrix reported. It matters because the pair
    -- invariant is "the Markdown IS the review": a directory there means the
    -- projection points at something that cannot be read as prose.
    do
      local dir_doc = sb .. "/kb-dir/agents/lector/reviews"
      vim.fn.mkdir(dir_doc, "p")
      local as_dir = dir_doc .. "/2026-09-03-proj-proj-r1-review.md"
      vim.fn.mkdir(as_dir, "p")   -- a DIRECTORY where the document belongs
      local rec = vim.deepcopy(full or {})
      rec.document = as_dir
      local dok, dproblems = review.validate_pair(rec, { kb_root = sb .. "/kb-dir" })
      ok("[11] *** a DIRECTORY at the document path is refused ***",
        dok == false and vim.iter(dproblems or {}):any(function(p2)
          return tostring(p2):find("not a regular file", 1, true) ~= nil
        end), vim.inspect(dproblems))
      -- CONTROL: the same path as a real FILE validates, so the assertion above
      -- is about the file KIND and not about the path being wrong.
      vim.fn.delete(as_dir, "d")
      vim.fn.writefile({ "# review" }, as_dir)
      local fok = review.validate_pair(rec, { kb_root = sb .. "/kb-dir" })
      ok("[11] CONTROL — the same path as a FILE gets past the kind check",
        fok == true or not vim.iter(select(2, review.validate_pair(rec,
          { kb_root = sb .. "/kb-dir" })) or {}):any(function(p2)
            return tostring(p2):find("not a regular file", 1, true) ~= nil
          end))
    end

    -- CONTROL: an explicit kb_root still wins over the resolver, so callers that
    -- do supply one are unaffected.
    local alt2 = sb .. "/kb-explicit"; vim.fn.mkdir(alt2, "p")
    local d3 = review.new({
      owner = "yongjohnlee80", name = "proj", url = "git@github.com:yongjohnlee80/proj.git",
      commit = sha2, reviewer = "lector", verdict = "comment", summary = "explicit root",
    })
    d3.comments = {}
    d3.reviewer_slug = "lector"
    local res3 = review.save_pair(slug, d3, MD, { topic = "explicit", kb_root = alt2 })
    ok("[11] *** CONTROL: an explicit kb_root still overrides the resolver ***",
      res3 ~= nil and res3.md_path:sub(1, #alt2) == alt2, res3 and res3.md_path)

  end

  vim.env.AUTO_AGENTS_KB_ROOT  = kb_root_before
  vim.env.AUTO_AGENTS_KB_READ  = kb_read_before
  vim.env.AUTO_AGENTS_KB_WRITE = kb_write_before
end

print("\n[12] review JSON is written pretty, with stable key order")
-- Johno, 2026-09-03: a review store holds tens of small documents, not
-- millions, so a human-readable multi-line file beats a minified one, and a
-- stable key order keeps a store's history diffing cleanly.
do
  local enc = store.encode_pretty({ b = 2, a = "x",
    comments = { { line = 1, path = "a.go" } }, empty = {} })
  ok("[12] *** output is multi-line, not a single minified line ***",
    enc:find("\n", 1, true) ~= nil, enc)
  -- Ten keys, whole order compared. The two-key form of this assertion was
  -- FLAKY: LuaJIT's `pairs` order for string keys varies between processes
  -- (measured: 1 run in 6 emitted `a` before `b` unprompted), so it passed
  -- roughly one run in six with the sort deleted.
  ok("[12] *** keys are sorted, so a store's history diffs cleanly ***", (function()
    local wide = { revision = 1, repo = "r", path = "p", note = "n", line = 2,
                   kind = "k", id = "i", hash = "h", file = "f", date = "d" }
    local emitted = {}
    for k in store.encode_pretty(wide):gmatch('\n  "([%w_]+)":') do
      emitted[#emitted + 1] = k
    end
    local want = {}
    for k in pairs(wide) do want[#want + 1] = k end
    table.sort(want)
    return #emitted == 10 and table.concat(emitted, ",") == table.concat(want, ",")
  end)(), enc)
  ok("[12] it is valid JSON that round-trips", (function()
    local ok_d, d = pcall(vim.json.decode, enc)
    return ok_d and d.a == "x" and d.b == 2 and d.comments[1].path == "a.go"
  end)())
  ok("[12] two-space indent", enc:find('\n  "a"', 1, true) ~= nil, enc)

  -- End to end: a saved review is pretty on disk.
  local d = review.new({ owner = "yongjohnlee80", name = "proj",
    url = "git@github.com:yongjohnlee80/proj.git", commit = sha1,
    reviewer = "lector", verdict = "comment", summary = "pretty on disk" })
  d.comments = { { path = "auth.go", line = 1, side = "RIGHT", severity = "nit", body = "b" } }
  d.reviewer_slug = "lector"
  local res = review.save_pair(slug, d, MD, { topic = "pretty" })
  ok("[12] fixture: the review saved", res ~= nil)
  local raw = table.concat(vim.fn.readfile(res.json_path), "\n")
  ok("[12] *** the review file on disk is multi-line ***",
    #vim.fn.readfile(res.json_path) > 5, tostring(#vim.fn.readfile(res.json_path)))
  ok("[12] and still parses to the review it wrote",
    (vim.json.decode(raw) or {}).commit == sha1)
end

print("\n[13] a TAMPERED document path is never unlinked (ADR-0081 MF1)")
-- lector, ADR-0081 MF1. `describe()` is deliberately tolerant, so it surfaces
-- the `document` field of a malformed or tampered JSON. The first cut of
-- `remove` passed that value straight to `fs_unlink` — so a review file whose
-- `document` pointed anywhere on disk was an ARBITRARY FILE DELETION. The
-- document must be proved to be this review's canonical paired path first, and
-- half a pair must never report success.
do
  local victim = sb .. "/victim-do-not-delete.txt"
  vim.fn.writefile({ "a file that has nothing to do with any review" }, victim)

  local prey = write_review(sha1, {
    verdict = "comment", summary = "its document will be tampered with",
    comments = { { path = "auth.go", line = 1, side = "RIGHT", severity = "nit",
                   body = "x" } },
  })
  local real_doc = (review.describe(prey.json_path) or {}).document
  ok("[13] fixture: the pair was written with a real document",
    type(real_doc) == "string" and vim.fn.filereadable(real_doc) == 1, tostring(real_doc))

  -- Tamper: repoint `document` at the unrelated file.
  local raw = vim.json.decode(table.concat(vim.fn.readfile(prey.json_path), "\n"))
  raw.document = victim
  vim.fn.writefile(vim.split(store.encode_pretty(raw), "\n"), prey.json_path)
  ok("[13] fixture: the JSON now claims an unrelated file as its document",
    (review.describe(prey.json_path) or {}).document == victim)

  local rok, rerr, detail = review.remove(slug, sha1, prey.revision)
  ok("[13] *** the VICTIM file still exists — it was never unlinked ***",
    vim.fn.filereadable(victim) == 1, victim)
  ok("[13] *** and remove REFUSES to report success on a half pair ***",
    rok == false and tostring(rerr):find("NOT deleted", 1, true) ~= nil, tostring(rerr))
  ok("[13] the refusal is reported structurally, with the path it refused",
    detail ~= nil and detail.document_refused == victim
    and detail.document_removed == false, vim.inspect(detail))
  ok("[13] the projection is still removed and the revision still fenced",
    vim.fn.filereadable(prey.json_path) == 0
    and detail.json_removed == true and detail.fenced == true
    and vim.fn.filereadable(detail.tombstone) == 1, vim.inspect(detail))
  ok("[13] and the review's own real Markdown is untouched by the refusal",
    vim.fn.filereadable(real_doc) == 1, tostring(real_doc))

  -- The OTHER half of §2.3a step 4: a VALID document that cannot be deleted.
  -- The mutation matrix showed this guard was unexercised — reverting it changed
  -- nothing, which means it was untested code in a destructive path. Made
  -- unlinkable by removing write permission from the containing directory, so
  -- the file still exists and still VALIDATES; only the unlink fails.
  do
    local stuck = write_review(sha1, { verdict = "comment", summary = "undeletable doc" })
    local stuck_doc = (review.describe(stuck.json_path) or {}).document
    local dir = vim.fn.fnamemodify(stuck_doc, ":h")
    vim.fn.system({ "chmod", "500", dir })
    local sok, serr, sdetail = review.remove(slug, sha1, stuck.revision)
    vim.fn.system({ "chmod", "700", dir })   -- restore before asserting
    ok("[13] *** a valid document that cannot be unlinked is NOT success ***",
      sok == false and tostring(serr):find("could not be deleted", 1, true) ~= nil,
      tostring(serr))
    ok("[13] and the partial failure names fenced / json_removed / the remaining path",
      sdetail ~= nil and sdetail.fenced == true and sdetail.json_removed == true
      and sdetail.document_removed == false and sdetail.document_error ~= nil,
      vim.inspect(sdetail))
    ok("[13] the JSON really is gone and the document really does remain",
      vim.fn.filereadable(stuck.json_path) == 0
      and vim.fn.filereadable(stuck_doc) == 1, tostring(stuck_doc))
  end

  -- CONTROL: a VALID pair still deletes both and reports success, so the guard
  -- is not a blanket refusal.
  local good = write_review(sha1, { verdict = "comment", summary = "valid pair" })
  local good_doc = (review.describe(good.json_path) or {}).document
  local gok, gerr, gdetail = review.remove(slug, sha1, good.revision)
  ok("[13] *** CONTROL: a valid pair is still removed, both halves, success ***",
    gok == true and vim.fn.filereadable(good.json_path) == 0
    and vim.fn.filereadable(good_doc) == 0 and gdetail.document_removed == true,
    tostring(gerr) .. " " .. vim.inspect(gdetail))
end

vim.fn.delete(sb, "rf")
print(string.format("\n%d passed, %d failed", pass, fail))
os.exit(fail > 0 and 1 or 0)
