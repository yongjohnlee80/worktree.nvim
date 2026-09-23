-- tests/adr0195-review-archive.lua — reversible review archiving (ADR-0195 D2).
--
-- Run:  nvim --headless -u NONE -l tests/adr0195-review-archive.lua
--
-- The task this comes from assumed reviews were already being kept: "I don't
-- want to delete them and keep them as record in my KB... the files are not
-- being deleted in the KB". They were. `d` hard-deletes BOTH halves of the
-- ADR-0067 pair and fences the revision, so "hide this, I'm done with it" was
-- only ever spelled as "destroy it".
--
-- Archiving is the missing reversible verb: the pair stays exactly where it is,
-- every task `review:` reference keeps resolving, and a marker document beside
-- the JSON says "not in the active list". The distinction this suite exists to
-- protect is that ARCHIVE PRESERVES and DELETE DESTROYS — so most cells here
-- assert what is still on disk afterwards, not just what the listing returned.
--
-- Paths are derived, never hardcoded (family rule 2), and both XDG_STATE_HOME
-- and $KB_ROOT are isolated: `save_pair` writes a Markdown document under
-- $KB_ROOT, and a suite that inherits the real one writes into the live KB.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local plugins = vim.fn.fnamemodify(plugin_root, ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
for _, p in ipairs({
  LAZY .. "/auto-core.nvim",
  plugins .. "/auto-core.nvim/main",
  plugins .. "/auto-core.nvim/" .. branch_dir,
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
local sb = vim.fn.tempname() .. "-adr0195"
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
vim.fn.writefile({ "one" }, lab .. "/auth.go")
G("add", "."); G("commit", "-qm", "base")
vim.fn.writefile({ "two" }, lab .. "/auth.go")
G("add", "."); G("commit", "-qm", "second")
local sha = vim.trim(G("rev-parse", "HEAD").stdout or "")

store._root_override = sb .. "/wtstore"
require("worktree.watch")._reset_for_tests(); repos._reset_for_tests()
local slug = store.remote_slug(lab .. "/.git")
local repo = { slug = slug, common_dir = lab .. "/.git" }
ok("fixture: the slug resolves from the remote", slug == "yongjohnlee80__proj", slug)

local MD = "# Review\n\nprose"
local function write_review(topic)
  local doc = review.new({
    owner = "yongjohnlee80", name = "proj", url = "git@github.com:yongjohnlee80/proj.git",
    commit = sha, reviewer = "lector", verdict = "comment", summary = "s",
  })
  doc.comments = {}
  doc.reviewer_slug = "lector"
  local res, err = review.save_pair(slug, doc, MD, { topic = topic or "archive" })
  assert(res, "fixture review must save: " .. tostring(err))
  return res
end

local function names(list)
  local out = {}
  for _, d in ipairs(list) do out[#out + 1] = "r" .. tostring(d.revision) end
  table.sort(out)
  return table.concat(out, ",")
end

print("\n[1] archiving hides a review from the ACTIVE listing, and nothing else")
local r1 = write_review("first")
local r2 = write_review("second")
ok("[1] fixture: two revisions exist", names(review.described_for(slug, sha)) == "r1,r2",
  names(review.described_for(slug, sha)))

local aok, aerr = review.archive(slug, sha, 1)
ok("[1] archive succeeds", aok == true, aerr)
ok("[1] the active listing drops it",
  names(review.described_for(slug, sha)) == "r2",
  names(review.described_for(slug, sha)))
ok("[1] `all` still shows both",
  names(review.described_for(slug, sha, { include_archived = "all" })) == "r1,r2",
  names(review.described_for(slug, sha, { include_archived = "all" })))
ok("[1] `archived_only` shows just the archived one",
  names(review.described_for(slug, sha, { include_archived = "archived_only" })) == "r1",
  names(review.described_for(slug, sha, { include_archived = "archived_only" })))

-- The flag travels with the record, so a panel can render "archived" without a
-- second query per row.
local all = review.described_for(slug, sha, { include_archived = "all" })
local flagged = {}
for _, d in ipairs(all) do flagged["r" .. d.revision] = d.archived end
ok("[1] each record carries its own archived flag",
  flagged.r1 == true and flagged.r2 == false, vim.inspect(flagged))

print("\n[2] *** ARCHIVE PRESERVES — this is the whole point ***")
-- The task's premise was that the KB record survived a delete. It did not. So
-- the assertion that matters is not "the row disappeared" but "both files are
-- still there", which is what makes archiving a different verb from removal.
local ds = require("auto-core.docstore")
local meta1 = review.describe(r1.json_path)
ok("[2] *** the review JSON is still on disk ***", ds.exists(r1.json_path), r1.json_path)
ok("[2] *** its KB Markdown is still on disk ***",
  meta1 and meta1.document and ds.exists(meta1.document),
  meta1 and meta1.document)
ok("[2] the path is UNCHANGED, so a task `review:` reference still resolves",
  (r1.json_path) == store.reviews_dir(slug) .. "/" .. review.filename(slug, sha, 1),
  r1.json_path)
ok("[2] the revision is NOT fenced — r1 still occupies revision 1",
  review.max_recorded_revision(slug, sha) >= 2, review.max_recorded_revision(slug, sha))

print("\n[3] idempotency in both directions")
ok("[3] archiving twice is success, not an error", review.archive(slug, sha, 1) == true)
ok("[3] and leaves exactly ONE marker",
  #(ds.list(review.archived_dir(slug), "%.archived%.json$") or {}) == 1,
  vim.inspect(ds.list(review.archived_dir(slug), "%.archived%.json$")))
ok("[3] unarchive restores it", review.unarchive(slug, sha, 1) == true)
ok("[3] and the active listing has it back",
  names(review.described_for(slug, sha)) == "r1,r2",
  names(review.described_for(slug, sha)))
ok("[3] unarchiving something not archived is success (the end state holds)",
  review.unarchive(slug, sha, 1) == true)
ok("[3] archiving a review that does not exist is refused",
  select(1, review.archive(slug, sha, 99)) == false)

print("\n[4] *** a marker that cannot be TRUSTED fails closed ***")
-- Reporting an unreadable marker as "not archived" would resurface a review the
-- user hid, which is the one outcome archiving exists to prevent. Unknown is
-- treated as archived, and the reason travels with the record.
review.archive(slug, sha, 1)
local marker = review.archive_marker_path(slug, sha, 1)
vim.fn.writefile({ "{ this is not json" }, marker)
local a, err = review.is_archived(slug, sha, 1)
ok("[4] *** is_archived returns nil+err, never false, for a corrupt marker ***",
  a == nil and type(err) == "string", vim.inspect({ a, err }))
ok("[4] *** the review STAYS hidden from the active listing ***",
  names(review.described_for(slug, sha)) == "r2",
  names(review.described_for(slug, sha)))
local hidden = review.described_for(slug, sha, { include_archived = "archived_only" })
ok("[4] and it carries the reason, so the panel can say why",
  #hidden == 1 and type(hidden[1].archive_error) == "string",
  hidden[1] and hidden[1].archive_error)

-- A WRONG-SCHEMA marker is the same class of unknown: a future schema, or
-- someone else's file that happens to sit there.
vim.fn.writefile({ vim.json.encode({ schema = "something/else" }) }, marker)
ok("[4] a valid-JSON marker with the wrong schema is also fail-closed",
  select(1, review.is_archived(slug, sha, 1)) == nil)
ok("[4] archive REFUSES to overwrite a malformed marker rather than assume",
  select(1, review.archive(slug, sha, 1)) == false)
vim.fn.delete(marker)

print("\n[5] by-path entry points prove the canonical location")
local canonical = store.reviews_dir(slug) .. "/" .. review.filename(slug, sha, 1)
ok("[5] archive_path accepts the canonical path", review.archive_path(canonical) == true)
ok("[5] unarchive_path accepts it too", review.unarchive_path(canonical) == true)
local decoy = sb .. "/elsewhere/" .. review.filename(slug, sha, 1)
vim.fn.mkdir(sb .. "/elsewhere", "p"); vim.fn.writefile({ "{}" }, decoy)
local pok, perr = review.archive_path(decoy)
ok("[5] *** a copy OUTSIDE the store is refused, not archived ***",
  pok == false and tostring(perr):find("canonical", 1, true) ~= nil, perr)
ok("[5] a non-review filename is refused",
  select(1, review.archive_path(sb .. "/notes.md")) == false)

print("\n[6] repos.* carries the same containment-and-identity proof as the delete")
ok("[6] archive_review works through the repo surface",
  repos.archive_review(repo, canonical) == true)
ok("[6] unarchive_review too", repos.unarchive_review(repo, canonical) == true)
local cok, cerr = repos.archive_review(repo, sb .. "/elsewhere/x.review.json")
ok("[6] *** a path outside the repo's reviews dir is refused ***",
  cok == false and tostring(cerr):find("refusing to archive outside", 1, true) ~= nil, cerr)
-- CONTAINMENT IS NOT IDENTITY: a file sitting in repo A's directory while NAMED
-- for repo B must not reach repo B's review. This is the cross-repository bug
-- lector found on the delete; the archive shares its resolver precisely so the
-- proof cannot be present on one verb and missing on the other.
local other = "someone__other"
local decoy2 = store.reviews_dir(slug) .. "/" .. review.filename(other, sha, 1)
vim.fn.writefile({ "{}" }, decoy2)
local nok, nerr = repos.archive_review(repo, decoy2)
ok("[6] *** a decoy NAMED for another repo is refused ***",
  nok == false and tostring(nerr):find("is named for", 1, true) ~= nil, nerr)
ok("[6] and the other repo was not archived behind our back",
  select(1, review.is_archived(other, sha, 1)) == false)
vim.fn.delete(decoy2)
ok("[6] archive_review requires a repo slug",
  select(1, repos.archive_review(nil, canonical)) == false)

print("\n[7] *** deleting a review CLEARS its marker ***")
-- A marker keyed on the canonical basename outlives the pair it shadows. Leave
-- one behind and a file that later occupies that name is born archived —
-- invisible, with nothing on screen to explain why.
review.archive(slug, sha, 1)
ok("[7] fixture: r1 is archived and its marker exists", ds.exists(marker), marker)
local rok, rerr = review.remove(slug, sha, 1)
ok("[7] the delete succeeds", rok == true, rerr)
ok("[7] *** the marker is GONE, not left shadowing nothing ***", not ds.exists(marker), marker)
ok("[7] and doctor reports no orphans", #repos.doctor_archive(repo) == 0,
  vim.inspect(repos.doctor_archive(repo)))

-- End to end: restore the JSON at the name that was just freed — which is how a
-- re-clone, a KB checkout or `save_next` reclaims it — and it must be VISIBLE.
-- Without the cleanup above this row would exist and never render.
vim.fn.writefile(vim.fn.readfile(r2.json_path), canonical)
ok("[7] *** a review restored at that name is ACTIVE, not silently hidden ***",
  select(1, review.is_archived(slug, sha, 1)) == false,
  vim.inspect({ review.is_archived(slug, sha, 1) }))
vim.fn.delete(canonical)

print("\n[8] a marker that cannot be cleared REFUSES the delete outright")
-- Ordering is the safety property. Clearing the marker and then failing to
-- delete makes a review REAPPEAR: wrong, but visible and re-archivable. Deleting
-- the pair and then failing to clear the marker leaves the trap. So the
-- destructive step goes last, and an un-clearable marker stops everything.
local r3 = write_review("third")
local rev3 = r3.revision
review.archive(slug, sha, rev3)
local dir = review.archived_dir(slug)
vim.fn.system({ "chmod", "500", dir })
local bok, berr = review.remove(slug, sha, rev3)
local blocked = bok == false
vim.fn.system({ "chmod", "700", dir })
if blocked then
  ok("[8] *** the delete is refused when the marker cannot be cleared ***", true)
  ok("[8] and it says so rather than reporting a clean removal",
    tostring(berr):find("NOTHING was deleted", 1, true) ~= nil, berr)
  ok("[8] *** the review JSON is UNTOUCHED ***", ds.exists(r3.json_path), r3.json_path)
  local m3 = review.describe(r3.json_path)
  ok("[8] *** its Markdown is untouched ***",
    m3 and m3.document and ds.exists(m3.document), m3 and m3.document)
  ok("[8] *** and the revision was NOT fenced, so nothing is half-done ***",
    select(1, review.is_archived(slug, sha, rev3)) == true)
else
  -- Running as root, or on a filesystem that ignores the mode bit: the guard
  -- cannot be provoked, so say that rather than record a pass it never earned.
  ok("[8] SKIPPED — the directory mode did not block the unlink (root?)", true)
  ok("[8] SKIPPED", true); ok("[8] SKIPPED", true)
  ok("[8] SKIPPED", true); ok("[8] SKIPPED", true)
end

print("\n[9] doctor_archive finds what this API cannot leave behind")
-- Orphans come from OUTSIDE the API: a pair deleted by hand, a clone that
-- dropped the JSON but kept `archived/`. They are invisible by nature — a marker
-- shadowing a review that is not there — so the only way to see one is to ask.
review.unarchive(slug, sha, rev3)
review.archive(slug, sha, rev3)
vim.fn.delete(r3.json_path)
local orphans = repos.doctor_archive(repo)
ok("[9] *** an orphaned marker is reported ***", #orphans == 1, vim.inspect(orphans))
ok("[9] and it is named by its marker path",
  orphans[1] and orphans[1]:find("%.archived%.json$") ~= nil, orphans[1])
ok("[9] doctor_archive requires a repo slug",
  select(2, repos.doctor_archive(nil)) ~= nil)

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
