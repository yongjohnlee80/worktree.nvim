-- tests/adr0083-review-posted.lua — worktree.pr.review_posted / repos.review_posted
-- (ADR-0083 Amendment r9.3): posted state comes from the RECEIPT, never the
-- review JSON (an ADR-0067 immutable artifact).
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
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end

local pass_count, fail_count = 0, 0
local function ok(name, cond, details)
  if cond then
    pass_count = pass_count + 1
    print("  PASS  " .. name)
  else
    fail_count = fail_count + 1
    print("  FAIL  " .. name .. (details and (" — " .. tostring(details)) or ""))
  end
end

local pr = require("worktree.pr")
local repos = require("worktree.repos")

local tmp = vim.fn.tempname() .. "-review-posted"
vim.fn.mkdir(tmp, "p")
pr._custom_receipts_dir = tmp .. "/receipts"
vim.fn.mkdir(pr._custom_receipts_dir, "p")

-- forge=github, slug="owner__myrepo" -> receipt key github__owner__myrepo__prN.json
local repo = { slug = "owner__myrepo", remote = "git@github.com:owner/myrepo.git",
  common_dir = tmp .. "/r.git" }
local sha = "c1a2b3c000000000000000000000000000000000"
local doc = "myrepo@c1a2b3c.r1.review.json"
local function fid(commit, cid) return commit .. ":" .. doc .. ":" .. cid end

-- 1. Every finding of the review is posted -> posted.
pr.save_receipt("github", repo.slug, 7, {
  schema = "worktree.pr.receipt/2", repo = repo.slug, pr_number = 7,
  batches = { [sha] = { state = "committed", commit_sha = sha, comments = {
    [fid(sha, "1")] = { state = "posted", path = "a.lua", line = 1 },
    [fid(sha, "2")] = { state = "posted", path = "b.lua", line = 2 },
  } } },
})
local review = { pr = 7, name = doc, path = "/x/" .. doc, worst = "must-fix" }
ok("*** a review whose every finding is posted reports [posted] ***",
  repos.review_posted(repo, review) == true)
ok("pr.review_posted agrees with the repos delegate",
  pr.review_posted(repo, review) == true)

-- 2. A DIFFERENT review (its doc_name is not in the receipt) -> NOT posted.
ok("*** a review with no receipt entries is NOT posted ***",
  repos.review_posted(repo, { pr = 7, name = "myrepo@deadbee.r1.review.json" }) == false)

-- 3. One finding still in_flight -> NOT posted (partial does not count).
pr.save_receipt("github", repo.slug, 8, {
  schema = "worktree.pr.receipt/2", repo = repo.slug, pr_number = 8,
  batches = { [sha] = { comments = {
    [fid(sha, "1")] = { state = "posted" },
    [fid(sha, "2")] = { state = "in_flight" },
  } } },
})
ok("*** a partially-posted review is NOT posted ***",
  repos.review_posted(repo, { pr = 8, name = doc }) == false)

-- 4. No receipt at all for the PR -> NOT posted.
ok("a review whose PR has no receipt is NOT posted",
  repos.review_posted(repo, { pr = 999, name = doc }) == false)

-- 5. A review with no PR association -> NOT posted (nothing to submit to).
ok("a review with no PR is NOT posted",
  repos.review_posted(repo, { name = doc }) == false)

-- 6. Findings spanning two commits, all posted -> posted (batches are per-commit).
local sha2 = "dddddddddddddddddddddddddddddddddddddddd"
pr.save_receipt("github", repo.slug, 9, {
  schema = "worktree.pr.receipt/2", repo = repo.slug, pr_number = 9,
  batches = {
    [sha]  = { comments = { [fid(sha, "1")]  = { state = "posted" } } },
    [sha2] = { comments = { [fid(sha2, "2")] = { state = "posted" } } },
  },
})
ok("*** findings across two commits, all posted -> posted ***",
  repos.review_posted(repo, { pr = 9, name = doc }) == true)

-- 7. Falls back to the JSON basename when `name` is absent.
ok("resolves doc_name from .path when .name is nil",
  repos.review_posted(repo, { pr = 7, path = "/agents/x/reviews/" .. doc }) == true)

-- 8. The review JSON is never required to exist (receipt is the only source).
ok("posted state needs no review file on disk",
  repos.review_posted(repo, { pr = 7, name = doc, path = "/nonexistent/" .. doc }) == true)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
os.exit(0)
