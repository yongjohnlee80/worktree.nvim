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


print("\n[8] *** the marker is unlinked AFTER the pair, and a failure is a PARTIAL ***")
-- The ordering is the accepted D2 contract, and my first cut reversed it. I
-- pre-cleared the marker before the fence, arguing a reappearing review is a
-- lesser harm than an invisible one. The deciding point is not which wrong state
-- looks worse: a pre-clear followed by ANY later failure silently UNARCHIVES a
-- review the user deliberately hid, and nothing recovers that. Unlinking last
-- leaves an orphan marker instead — which doctor_archive exists to reconcile.
local r3 = write_review("third")
local rev3 = r3.revision
review.archive(slug, sha, rev3)
local dir = review.archived_dir(slug)
vim.fn.system({ "chmod", "500", dir })
local bok, berr, bdetail = review.remove(slug, sha, rev3)
vim.fn.system({ "chmod", "700", dir })
if bok == false and tostring(berr):find("archive marker", 1, true) then
  ok("[8] *** the pair delete is NOT refused by an un-unlinkable marker ***",
    bdetail and bdetail.json_removed == true, vim.inspect(bdetail))
  ok("[8] *** the partial is reported, not swallowed as success ***", bok == false, berr)
  ok("[8] and it names doctor_archive as the recovery",
    tostring(berr):find("doctor_archive", 1, true) ~= nil, berr)
  ok("[8] *** the review JSON really is gone — the delete did happen ***",
    not ds.exists(r3.json_path), r3.json_path)
  ok("[8] the leftover marker is named in the detail",
    bdetail and bdetail.marker_error ~= nil and bdetail.marker ~= nil, vim.inspect(bdetail))
else
  -- Running as root, or a filesystem ignoring the mode bit: the partial cannot
  -- be provoked. Say so rather than record five passes it never earned.
  ok("[8] SKIPPED — the directory mode did not block the unlink (root?)", true)
  ok("[8] SKIPPED", true); ok("[8] SKIPPED", true)
  ok("[8] SKIPPED", true); ok("[8] SKIPPED", true)
end

local function rnames(list)
  local out = {}
  for _, d in ipairs(list) do out[#out + 1] = "r" .. tostring(d.revision) end
  table.sort(out)
  return table.concat(out, ",")
end
local function has_rev(list, rev)
  for _, d in ipairs(list) do if d.revision == rev then return true end end
  return false
end

print("\n[8b] *** a FAILED delete must not silently unarchive ***")
-- This is the cell that tells the two orderings apart, and its absence is why
-- my first falsification of the ordering came back green: every other cell here
-- observes the SUCCESS path, where pre-clear and unlink-last agree. The
-- difference only shows when a step AFTER the marker fails.
--
-- Make the PAIR DELETE fail (the reviews dir is unwritable) while the archived/
-- subdir stays writable, so a pre-clear would succeed and then strand the
-- review UNARCHIVED — visible again, with no record that the user ever hid it
-- and nothing designed to recover the intent.
local k = write_review("ordering")
review.archive(slug, sha, k.revision)
vim.fn.system({ "chmod", "500", store.reviews_dir(slug) })
local kok = review.remove(slug, sha, k.revision)
vim.fn.system({ "chmod", "700", store.reviews_dir(slug) })
if kok == false and ds.exists(k.json_path) then
  ok("[8b] fixture: the delete really did fail with the pair intact", true)
  ok("[8b] *** the review is STILL ARCHIVED — intent survived the failure ***",
    select(1, review.is_archived(slug, sha, k.revision)) == true,
    vim.inspect({ review.is_archived(slug, sha, k.revision) }))
  ok("[8b] *** and it did not silently reappear in the active listing ***",
    not has_rev(review.described_for(slug, sha), k.revision),
    rnames(review.described_for(slug, sha)))
else
  ok("[8b] SKIPPED — the directory mode did not block the delete (root?)", true)
  ok("[8b] SKIPPED", true); ok("[8b] SKIPPED", true)
end
review.unarchive(slug, sha, k.revision)
review.remove(slug, sha, k.revision)

print("\n[9] *** the REPO-WIDE listing honours archiving too ***")
-- This is the listing the repos panel's Reviews section actually reads, and the
-- first cut wired described_for (per commit) while leaving it alone: per-commit
-- rows honoured an archive while the section listing every review still showed
-- it, and the collapsed count still counted it. Archiving the main listing
-- ignores is not archiving. Lector's probe: described_for(active) returned r2
-- while reviews_all returned r1,r2.
local w1 = write_review("wide-one")
local w2 = write_review("wide-two")
review.archive(slug, sha, w1.revision)
-- Membership, not set equality: this listing is REPO-WIDE, so it also carries
-- every review the earlier sections left behind. Asserting the whole set would
-- be asserting those sections' bookkeeping, which is not what this cell is for.
local has = has_rev
local active_all = repos.reviews_all(repo)
ok("[9] *** reviews_all DEFAULTS to active and drops the archived row ***",
  not has(active_all, w1.revision), rnames(active_all))
ok("[9] *** the collapsed COUNT is honest — it counts what it shows ***",
  #active_all == #repos.reviews_all(repo, { include_archived = "all" }) - 1,
  ("active=%d all=%d"):format(#active_all,
    #repos.reviews_all(repo, { include_archived = "all" })))
ok("[9] the un-archived sibling is still listed", has(active_all, w2.revision),
  rnames(active_all))
ok("[9] `all` still reaches both",
  has(repos.reviews_all(repo, { include_archived = "all" }), w1.revision)
    and has(repos.reviews_all(repo, { include_archived = "all" }), w2.revision),
  rnames(repos.reviews_all(repo, { include_archived = "all" })))
ok("[9] `archived_only` reaches the archived one and not its sibling",
  has(repos.reviews_all(repo, { include_archived = "archived_only" }), w1.revision)
    and not has(repos.reviews_all(repo, { include_archived = "archived_only" }), w2.revision),
  rnames(repos.reviews_all(repo, { include_archived = "archived_only" })))
ok("[9] and the two listings AGREE about this review",
  has(review.described_for(slug, sha, { include_archived = "archived_only" }), w1.revision),
  "per-commit vs repo-wide")
review.unarchive(slug, sha, w1.revision)

print("\n[10] *** an UNKNOWN marker blocks every mutation, and costs no bytes ***")
-- Validating only on the READ path is not a guard. The first cut checked the
-- schema in is_archived and then let unarchive and remove unlink whatever sat
-- at that path without parsing it — so the operations that most needed to
-- understand a corrupt marker were the ones that destroyed it.
review.archive(slug, sha, w1.revision)
local m1 = review.archive_marker_path(slug, sha, w1.revision)
vim.fn.writefile({ "{ not json" }, m1)

local uok, uerr = review.unarchive(slug, sha, w1.revision)
ok("[10] *** unarchive REFUSES an unvalidatable marker ***", uok == false, uerr)
ok("[10] *** and the marker's bytes are still there ***", ds.exists(m1), m1)
ok("[10] the refusal points at the deliberate recovery",
  tostring(uerr):find("force", 1, true) ~= nil, uerr)

local dok2, derr2 = review.remove(slug, sha, w1.revision)
ok("[10] *** remove REFUSES too — nothing is destroyed in an unknown state ***",
  dok2 == false, derr2)
ok("[10] *** and the review JSON is untouched ***", ds.exists(w1.json_path), w1.json_path)
ok("[10] *** and the marker is untouched ***", ds.exists(m1), m1)

-- Refusing must not be a dead end, so force is the named, deliberate escape.
ok("[10] force removes it ON PURPOSE",
  review.unarchive(slug, sha, w1.revision, { force = true }) == true)
ok("[10] and only then are the bytes gone", not ds.exists(m1), m1)

print("\n[11] *** the marker's persisted identity is CHECKED, not just written ***")
-- Every marker records `review = <canonical basename>`. Nothing read it back,
-- so it was decoration: a field asserting an identity that no code consults.
review.archive(slug, sha, w1.revision)
local raw = table.concat(vim.fn.readfile(m1), "\n")
ok("[11] fixture: the marker really does persist the review name",
  raw:find(review.filename(slug, sha, w1.revision), 1, true) ~= nil, raw)
-- A marker copied or renamed between reviews keeps the OTHER review's name.
vim.fn.writefile({ vim.json.encode({
  schema = "worktree.review.archived/1",
  review = review.filename(slug, sha, w2.revision),
  archived_at = "2026-01-01T00:00:00Z",
}) }, m1)
local idok, iderr = review.is_archived(slug, sha, w1.revision)
ok("[11] *** a marker naming a DIFFERENT review is not trusted ***",
  idok == nil and type(iderr) == "string", vim.inspect({ idok, iderr }))
ok("[11] and the error names both sides",
  tostring(iderr):find(review.filename(slug, sha, w2.revision), 1, true) ~= nil, iderr)
ok("[11] the review stays hidden rather than resurfacing",
  rnames(review.described_for(slug, sha, { include_archived = "active" })):find(
    "r" .. w1.revision, 1, true) == nil,
  rnames(review.described_for(slug, sha, { include_archived = "active" })))
review.unarchive(slug, sha, w1.revision, { force = true })

print("\n[12] *** doctor_archive REPAIRS, and reports every failure explicitly ***")
-- Listing is a report, not a repair. A doctor that only names invisible state
-- leaves it exactly as invisible as it found it.
review.archive(slug, sha, w1.revision)
local orphan = review.archive_marker_path(slug, sha, w1.revision)
vim.fn.delete(w1.json_path)          -- the pair is gone; the marker is now an orphan
ok("[12] fixture: the orphan exists", ds.exists(orphan), orphan)
local function lists(paths, p) for _, x in ipairs(paths) do if x == p then return true end end return false end
ok("[12] archive_orphans REPORTS without repairing",
  lists(repos.archive_orphans(repo), orphan) and ds.exists(orphan), orphan)

local res = repos.doctor_archive(repo)
ok("[12] *** the orphan is DROPPED, not merely listed ***",
  lists(res.dropped, orphan) and not ds.exists(orphan), vim.inspect(res))
ok("[12] with no failures reported", #res.failed == 0, vim.inspect(res.failed))
ok("[12] and it is idempotent — a second run finds nothing left",
  #repos.doctor_archive(repo).dropped == 0)
ok("[12] the earlier partial delete's orphan was reconciled too",
  #repos.archive_orphans(repo) == 0, vim.inspect(repos.archive_orphans(repo)))

-- A marker that will not validate but whose review is STILL THERE is hiding a
-- real review. Dropping it would silently unarchive something the user hid.
review.archive(slug, sha, w2.revision)
local m2 = review.archive_marker_path(slug, sha, w2.revision)
vim.fn.writefile({ "{ corrupt" }, m2)
local res2 = repos.doctor_archive(repo)
ok("[12] *** a corrupt marker over a LIVE review is NOT dropped ***",
  ds.exists(m2), m2)
ok("[12] it is reported under `unreadable` instead",
  #res2.unreadable == 1 and res2.unreadable[1] == m2, vim.inspect(res2))
ok("[12] and that review is still hidden, not resurfaced",
  rnames(repos.reviews_all(repo)):find("r" .. w2.revision, 1, true) == nil,
  rnames(repos.reviews_all(repo)))

-- An un-droppable orphan is an explicit failure, never a silent zero.
vim.fn.writefile({ "{ corrupt" }, m2)
review.unarchive(slug, sha, w2.revision, { force = true })
review.archive(slug, sha, w2.revision)
vim.fn.delete(w2.json_path)
vim.fn.system({ "chmod", "500", review.archived_dir(slug) })
local res3 = repos.doctor_archive(repo)
vim.fn.system({ "chmod", "700", review.archived_dir(slug) })
if #res3.dropped == 0 then
  ok("[12] *** a cleanup failure is REPORTED, not counted as clean ***",
    #res3.failed >= 1 and res3.failed[1].err ~= nil, vim.inspect(res3))
else
  ok("[12] SKIPPED — the directory mode did not block the unlink (root?)", true)
end
ok("[12] doctor_archive requires a repo slug",
  select(2, repos.doctor_archive(nil)) ~= nil)

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail)); io.stdout:flush()
if fail > 0 then os.exit(1) end
os.exit(0)
