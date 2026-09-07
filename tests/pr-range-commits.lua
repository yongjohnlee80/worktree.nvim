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

vim.fn.delete(sb, "rf")
io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
