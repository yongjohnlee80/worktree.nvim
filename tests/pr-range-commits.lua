-- `worktree.pr.pr_diff_commits` — the commits a branch adds on top of a base,
-- with their changed files. This is what every range diff view is built from:
-- the PR diff (ADR-0083 §2.6 Action 2) and, as of 2026-09-08, auto-finder's
-- Git Diff View over a worktree's branch.
--
-- IT HAD NEVER BEEN TESTED. The two consumers both stubbed it, so the only
-- assertions about its output were assertions about the stubs — and the stubs
-- supplied a full 40-hex `sha` while the real function, reading `git log
-- --oneline`, returned an ABBREVIATED one. `auto-core.review.draft.scope`
-- requires 40 hex and refuses anything shorter, so opening a range diff over
-- a real repository died on the first commit.
--
-- Run headless:  nvim --headless -u NONE -l tests/pr-range-commits.lua
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local siblings = vim.fn.fnamemodify(plugin_root, ":h:h")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
for _, p in ipairs({
  LAZY .. "/plenary.nvim",
  LAZY .. "/auto-core.nvim",
  siblings .. "/auto-core.nvim/main",
  siblings .. "/auto-core.nvim/" .. branch_dir,
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

local pr_mod = require("worktree.pr")

local sb = vim.fn.tempname() .. "-prrange"
vim.fn.mkdir(sb, "p")
local function G(dir, ...)
  local a = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" }
  for _, x in ipairs({ ... }) do a[#a + 1] = x end
  return vim.system(a, { text = true }):wait()
end

-- A real repo. The base branch is deliberately not called "main", so a
-- consumer that defaults to that literal cannot accidentally agree.
local proj = sb .. "/proj"
vim.fn.mkdir(proj, "p")
G(proj, "init", "-q", "-b", "trunk")
vim.fn.writefile({ "base" }, proj .. "/a.txt")
G(proj, "add", "."); G(proj, "commit", "-q", "-m", "base one")
G(proj, "checkout", "-q", "-b", "feature")
vim.fn.writefile({ "one" }, proj .. "/first.txt")
G(proj, "add", "."); G(proj, "commit", "-q", "-m", "add first")
vim.fn.writefile({ "two" }, proj .. "/second.txt")
vim.fn.writefile({ "edited" }, proj .. "/a.txt")
G(proj, "add", "."); G(proj, "commit", "-q", "-m", "add second and edit a")

local repo = { common_dir = proj .. "/.git", path = proj, sample_worktree = proj }

print("[1] the range is base..head, oldest first")
local commits = pr_mod.pr_diff_commits(repo, "trunk", "feature")
ok("[1] two commits — exactly what the branch adds", #commits == 2,
  vim.inspect(vim.tbl_map(function(c) return c.subject end, commits)))
ok("[1] oldest first, so a reader walks the branch forwards",
  commits[1] and commits[1].subject == "add first"
    and commits[2] and commits[2].subject == "add second and edit a",
  vim.inspect(vim.tbl_map(function(c) return c.subject end, commits)))
ok("[1] the base's own commit is excluded", (function()
  for _, c in ipairs(commits) do
    if c.subject == "base one" then return false end
  end
  return true
end)())

print("\n[2] *** `sha` is the FULL 40-hex commit id ***")
-- The defect. `--oneline` implies `--abbrev-commit`, so this field came back
-- abbreviated while `short` was computed as `sha:sub(1, 7)` — a truncation of
-- a truncation. `auto-core.review.draft.scope` refuses anything under 40 hex,
-- deliberately: two commits can share a prefix and a colliding scope would
-- silently merge two reviewers' drafts.
for i, c in ipairs(commits) do
  ok(("[2] commit %d: sha is 40 hex characters"):format(i),
    type(c.sha) == "string" and c.sha:match("^" .. ("%x"):rep(40) .. "$") ~= nil,
    ("%s (len %d)"):format(tostring(c.sha), #tostring(c.sha)))
end
-- And it is the RIGHT sha, not merely 40 characters of something. A cell that
-- only checks the length would pass on a padded abbreviation.
local head_sha = vim.trim(G(proj, "rev-parse", "feature").stdout or "")
ok("[2] *** and the last commit's sha IS `feature`'s HEAD ***",
  commits[2] and commits[2].sha == head_sha,
  ("got %s want %s"):format(tostring(commits[2] and commits[2].sha), head_sha))
ok("[2] a full sha keys an auto-core review draft scope", (function()
  local ok_d, draft = pcall(require, "auto-core.review.draft")
  if not ok_d or type(draft.scope) ~= "function" then return true end  -- not installed
  local s = draft.scope("proj", commits[2].sha)
  return s ~= nil
end)(), "draft.scope refused the sha")

print("\n[3] `short` is a real abbreviation of that sha")
for i, c in ipairs(commits) do
  ok(("[3] commit %d: short is the sha's first 7"):format(i),
    type(c.short) == "string" and #c.short == 7 and c.sha:sub(1, 7) == c.short,
    ("short=%s sha=%s"):format(tostring(c.short), tostring(c.sha)))
end

print("\n[4] each commit carries the files it changed")
local files_by_subject = {}
for _, c in ipairs(commits) do
  local paths = {}
  for _, f in ipairs(c.files or {}) do paths[f.path] = true end
  files_by_subject[c.subject] = paths
end
ok("[4] the first commit lists only its own new file",
  files_by_subject["add first"] and files_by_subject["add first"]["first.txt"]
    and files_by_subject["add first"]["second.txt"] == nil,
  vim.inspect(files_by_subject["add first"]))
ok("[4] *** the second lists BOTH the added and the modified file ***",
  files_by_subject["add second and edit a"]
    and files_by_subject["add second and edit a"]["second.txt"]
    and files_by_subject["add second and edit a"]["a.txt"],
  vim.inspect(files_by_subject["add second and edit a"]))

print("\n[5] degenerate ranges answer empty, not garbage")
ok("[5] a branch level with its base adds nothing",
  #pr_mod.pr_diff_commits(repo, "trunk", "trunk") == 0)
ok("[5] a nonexistent ref answers empty rather than erroring", (function()
  local okc, res = pcall(pr_mod.pr_diff_commits, repo, "trunk", "no-such-branch")
  return okc and type(res) == "table" and #res == 0
end)())
ok("[5] a repo with no resolvable directory answers empty",
  #pr_mod.pr_diff_commits({}, "trunk", "feature") == 0)

-- A subject containing hex-looking words must not confuse the sha parse: the
-- pattern anchors on the first whitespace run, and a subject beginning with
-- `deadbeef` is the case that would break a looser one.
print("\n[6] the parse is not fooled by a hex-looking subject")
G(proj, "checkout", "-q", "-b", "hexy")
vim.fn.writefile({ "x" }, proj .. "/hex.txt")
G(proj, "add", "."); G(proj, "commit", "-q", "-m", "deadbeef cafe fix the thing")
local hexy = pr_mod.pr_diff_commits(repo, "feature", "hexy")
ok("[6] one commit found", #hexy == 1, vim.inspect(hexy))
ok("[6] *** the sha is still 40 hex and the subject is intact ***",
  hexy[1] and hexy[1].sha:match("^" .. ("%x"):rep(40) .. "$") ~= nil
    and hexy[1].subject == "deadbeef cafe fix the thing",
  hexy[1] and ("%s | %s"):format(hexy[1].sha, hexy[1].subject) or "nil")

print("\n[7] a STALE local base does not inflate the range (B6)")
-- The bug: `pr_diff_commits` used a two-dot `local_base..pr_branch`. When the
-- LOCAL base branch lags the remote (peers push; nobody pulled), and the PR
-- branch was built on the NEWER base, the range lists the base's own catch-up
-- commits as if the PR added them. The fix resolves the base to the freshest
-- ref available (origin/<base> when present) and ranges from the merge-base.
do
  -- Build a "remote": trunk C1 -> C2 -> C3. A feature branched at C1 then
  -- rebased onto C3, adding F1, F2. Clone it, then REWIND the clone's local
  -- trunk to C1 so it is stale, while origin/trunk stays at C3.
  local up = sb .. "/upstream"; vim.fn.mkdir(up, "p")
  G(up, "init", "-q", "-b", "trunk")
  vim.fn.writefile({ "c1" }, up .. "/a.txt"); G(up, "add", "."); G(up, "commit", "-q", "-m", "C1")
  local c1 = vim.trim(G(up, "rev-parse", "HEAD").stdout or "")
  vim.fn.writefile({ "c2" }, up .. "/b.txt"); G(up, "add", "."); G(up, "commit", "-q", "-m", "C2")
  vim.fn.writefile({ "c3" }, up .. "/c.txt"); G(up, "add", "."); G(up, "commit", "-q", "-m", "C3")
  -- feature = C3 + F1 + F2 (as if rebased onto the current trunk).
  G(up, "checkout", "-q", "-b", "feature")
  vim.fn.writefile({ "f1" }, up .. "/f1.txt"); G(up, "add", "."); G(up, "commit", "-q", "-m", "F1")
  vim.fn.writefile({ "f2" }, up .. "/f2.txt"); G(up, "add", "."); G(up, "commit", "-q", "-m", "F2")
  G(up, "checkout", "-q", "trunk")

  local clone = sb .. "/clone"
  G(sb, "clone", "-q", up, clone)
  G(clone, "fetch", "-q", "origin", "feature:feature")
  -- Rewind LOCAL trunk to C1 (stale), leaving origin/trunk at C3. `reset --hard`,
  -- NOT `branch -f`: trunk is the checked-out branch and `branch -f` refuses it,
  -- which silently left an earlier draft's trunk at C3 and the whole cell green
  -- against the bug (fixture-preconditions-must-survive-the-action).
  G(clone, "reset", "--hard", c1)

  local rc = { common_dir = clone .. "/.git", path = clone, sample_worktree = clone }
  -- PRECONDITION: the bug only exists when local base is behind the remote.
  -- Assert the stale state actually landed, or this cell proves nothing.
  local local_trunk = vim.trim(G(clone, "rev-parse", "trunk").stdout or "")
  local origin_trunk = vim.trim(G(clone, "rev-parse", "origin/trunk").stdout or "")
  ok("[7] fixture precondition: local trunk is C1 while origin/trunk is ahead",
    local_trunk == c1 and origin_trunk ~= c1,
    ("local=%s origin=%s c1=%s"):format(local_trunk:sub(1,7), origin_trunk:sub(1,7), c1:sub(1,7)))

  local commits = pr_mod.pr_diff_commits(rc, "trunk", "feature")
  local subjects = {}
  for _, c in ipairs(commits) do subjects[c.subject] = true end
  ok("[7] *** only the PR's own commits are listed (F1, F2) ***",
    subjects["F1"] and subjects["F2"] and vim.tbl_count(subjects) == 2,
    "got: " .. vim.inspect(vim.tbl_keys(subjects)))
  ok("[7] *** the stale base's catch-up commits (C2, C3) are NOT listed ***",
    not subjects["C2"] and not subjects["C3"],
    "got: " .. vim.inspect(vim.tbl_keys(subjects)))
end

print("\n[8] find_for_worktree parses base: from the KB PR doc (B7)")
do
  -- open_pr_diff read the PR's base branch from find_for_worktree, which parsed
  -- number/title/state/branch/draft but NOT base — so it silently fell back to
  -- "main" and diffed against the wrong branch on any PR based elsewhere.
  local kb = sb .. "/kb"
  local slug = "acme__thing"
  vim.fn.mkdir(string.format("%s/shared/prs/%s", kb, slug), "p")
  vim.fn.writefile({
    "---",
    "number: 77",
    'title: "a PR based on develop"',
    "state: open",
    "branch: feature/x",
    "base: develop",
    "draft: false",
    "---",
    "body",
  }, string.format("%s/shared/prs/%s/pr-77.md", kb, slug))

  local saved = vim.env.AUTO_AGENTS_KB_ROOT
  vim.env.AUTO_AGENTS_KB_ROOT = kb
  local pr = pr_mod.find_for_worktree({ slug = slug }, { branch = "feature/x" })
  vim.env.AUTO_AGENTS_KB_ROOT = saved

  ok("[8] the PR doc is found by branch", pr ~= nil and pr.number == 77,
    vim.inspect(pr))
  ok("[8] *** base: is parsed, not defaulted to main ***",
    pr ~= nil and pr.base == "develop", pr and tostring(pr.base) or "nil")
end

vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
