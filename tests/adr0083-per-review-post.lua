-- tests/adr0083-per-review-post.lua — post_feedback must post EACH review's
-- findings even when two distinct reviews share a commit SHA (lector PR #45 MF1).
-- The receipt batches by commit; the per-review S contract (ADR-0083 r9) submits
-- one review at a time, so a second review at the same SHA must not be dropped.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local siblings = vim.fn.fnamemodify(plugin_root, ":h:h")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
for _, p in ipairs({
  LAZY .. "/plenary.nvim", LAZY .. "/auto-core.nvim",
  siblings .. "/auto-core.nvim/main", siblings .. "/auto-core.nvim/" .. branch_dir,
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end

local pass_count, fail_count = 0, 0
local function ok(name, cond, details)
  if cond then pass_count = pass_count + 1; print("  PASS  " .. name)
  else fail_count = fail_count + 1; print("  FAIL  " .. name .. (details and (" — " .. tostring(details)) or "")) end
end

local pr = require("worktree.pr")
local creds = require("worktree.credentials")

local tmp = vim.fn.tempname() .. "-perrev"
vim.fn.mkdir(tmp, "p")
pr._custom_receipts_dir = tmp .. "/receipts"
vim.fn.mkdir(pr._custom_receipts_dir, "p")

local repo = { slug = "owner__myrepo", remote = "git@github.com:owner/myrepo.git", common_dir = tmp .. "/r.git" }
creds.set_profile(repo.slug, { kind = "in_memory", token = "t" })

-- A fake forge that STORES posted review comments and returns them on GET, so we
-- can count exactly what landed remotely (Lector's independent probe).
local remote = {} -- finding_id -> body
pr._mock_http = function(method, url, _token, body)
  if method == "GET" and url:find("/comments", 1, true) then
    local arr = {}
    for fid, b in pairs(remote) do
      arr[#arr + 1] = { id = math.random(1, 1e9), body = b }
    end
    return 200, vim.json.encode(arr)
  end
  if method == "POST" and url:find("/reviews", 1, true) then
    local data = vim.json.decode(body)
    for _, c in ipairs(data.comments or {}) do
      local fid = (c.body or ""):match("<!%-%- worktree:finding_id=([^%s]+) %-%->")
      if fid then remote[fid] = c.body end
    end
    return 201, vim.json.encode({ id = 1 })
  end
  return 404, "nf"
end

local sha = "c1a2b3c000000000000000000000000000000000"
-- Two DISTINCT reviews, both anchored to the SAME commit sha.
local r1 = { commit = sha, doc_name = "myrepo@c1a2b3c.r1.review.json",
  comments = { { path = "a.lua", line = 1, severity = "must-fix", body = "r1 finding" } } }
local r2 = { commit = sha, doc_name = "myrepo@c1a2b3c.r2.review.json",
  comments = { { path = "b.lua", line = 2, severity = "nit", body = "r2 finding" } } }

-- Submit r1, then r2 — exactly what pressing S on each review entry does.
local res1 = pr.post_feedback(repo, 7, { r1 })
ok("submitting r1 succeeds", res1 and res1.ok == true, vim.inspect(res1))
local res2 = pr.post_feedback(repo, 7, { r2 })
ok("submitting r2 succeeds", res2 and res2.ok == true, vim.inspect(res2))

-- The crux: BOTH findings must be on the remote. The old code batched by sha and
-- skipped the committed batch, so r2 silently never posted (remote_count == 1).
local n = 0
for _ in pairs(remote) do n = n + 1 end
ok("*** BOTH reviews' findings reached the forge (r2 not dropped) ***", n == 2,
  "remote_count=" .. n)

-- And review_posted must be TRUE for each — the whole point of the S badge.
ok("*** r1 is [posted] ***", pr.review_posted(repo, { pr = 7, name = r1.doc_name }) == true)
ok("*** r2 is [posted] ***", pr.review_posted(repo, { pr = 7, name = r2.doc_name }) == true)

-- Idempotency preserved: re-submitting r1 posts nothing new.
local before = n
pr.post_feedback(repo, 7, { r1 })
local after = 0
for _ in pairs(remote) do after = after + 1 end
ok("re-submitting r1 is idempotent (no duplicate)", after == before, "before=" .. before .. " after=" .. after)

pr._mock_http = nil
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
os.exit(0)
