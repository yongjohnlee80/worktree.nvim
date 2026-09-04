-- tests/adr0083-pr-lifecycle.lua — test suite for worktree.pr (ADR-0083 §2.5/§2.6)
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

vim.o.columns = 200
vim.o.lines = 60

local pass_count = 0
local fail_count = 0

local function ok(name, cond, details)
  if cond then
    pass_count = pass_count + 1
    print("  PASS  " .. name)
  else
    fail_count = fail_count + 1
    print("  FAIL  " .. name .. (details and (" — " .. tostring(details)) or ""))
  end
end

local pr_mod = require("worktree.pr")
local creds = require("worktree.credentials")

local tmp_dir = vim.fn.tempname() .. "-worktree-pr"
vim.fn.mkdir(tmp_dir, "p")
pr_mod._custom_receipts_dir = tmp_dir .. "/receipts"

-- 1. parse_remote tests
local gh_ssh = pr_mod.parse_remote("git@github.com:yongjohnlee80/auto-finder.git")
ok("parse_remote parses GitHub SSH owner", gh_ssh.owner == "yongjohnlee80")
ok("parse_remote parses GitHub SSH repo", gh_ssh.repo == "auto-finder")
ok("parse_remote detects github forge", gh_ssh.forge == "github")

local fj_https = pr_mod.parse_remote("https://forgejo.example.com/team/repo.git")
ok("parse_remote parses Forgejo owner", fj_https.owner == "team")
ok("parse_remote parses Forgejo repo", fj_https.repo == "repo")
ok("parse_remote detects forgejo forge", fj_https.forge == "forgejo")
ok("parse_remote sets forgejo api_base", fj_https.api_base == "https://forgejo.example.com/api/v1")

-- 2. Exclusive Locking with Live-Owner Immunity (ADR-0083 §2.6 Action 4)
local lock1 = pr_mod.acquire_lock("github", "test-repo", 42)
ok("acquire_lock succeeds and returns handle", lock1 ~= nil)
ok("lock file exists on disk", vim.fn.filereadable(lock1.path) == 1)

local lock_stat = vim.uv.fs_stat(lock1.path)
ok("lock file has mode 0600 (384)", lock_stat and bit.band(lock_stat.mode, 511) == 384)

local lock_data = vim.json.decode(table.concat(vim.fn.readfile(lock1.path), "\n"))
ok("lock file contains owner_token", lock_data.owner_token == lock1.owner_token)
ok("lock file contains current process pid", lock_data.pid == vim.uv.os_getpid())

-- Attempting second acquire while process is alive MUST be rejected (Live Owner Immunity)
local contention_rejected = false
local contention_err = nil
local c_ok, c_err = pcall(function()
  pr_mod.acquire_lock("github", "test-repo", 42)
end)
if not c_ok then
  contention_rejected = true
  contention_err = tostring(c_err)
end
ok("lock contention by active process is rejected", contention_rejected == true)
ok("error names active PID and PR number",
  contention_err and contention_err:find("locked by active process PID " .. tostring(vim.uv.os_getpid()), 1, true) ~= nil,
  contention_err)

-- Release lock
lock1:release()
ok("release removes lock file", vim.fn.filereadable(lock1.path) == 0)

-- Dead-owner eviction: simulate lock left by dead process PID 99999999
local dead_lock_path = pr_mod._lock_path("github", "test-repo", 42)
local dead_payload = vim.json.encode({
  owner_token = "dead_owner_123",
  pid = 99999999,
  host = vim.uv.os_gethostname(),
  acquired_at = os.time() - 500,
  refreshed_at = os.time() - 500,
})
vim.fn.writefile({ dead_payload }, dead_lock_path)
vim.uv.fs_chmod(dead_lock_path, 384)

local lock2 = pr_mod.acquire_lock("github", "test-repo", 42)
ok("dead owner lock was safely evicted and acquired by contender", lock2 ~= nil and lock2.owner_token ~= "dead_owner_123")
lock2:release()

-- Compare-and-delete release safety
local lock3 = pr_mod.acquire_lock("github", "test-repo", 42)
-- Overwrite lock with another owner_token (simulating reassigned lock)
local reassigned_payload = vim.json.encode({
  owner_token = "other_owner_token",
  pid = vim.uv.os_getpid(),
  host = vim.uv.os_gethostname(),
})
vim.fn.writefile({ reassigned_payload }, lock3.path)
lock3:release()
ok("compare-and-delete leaves lock intact when owner_token does not match", vim.fn.filereadable(lock3.path) == 1)
pcall(vim.uv.fs_unlink, lock3.path)

-- 3. Durable Two-Phase Receipt Store
local receipt = pr_mod.load_receipt("github", "test-repo", 42)
ok("loaded receipt has schema worktree.pr.receipt/2", receipt.schema == "worktree.pr.receipt/2")
ok("loaded receipt pr_number is 42", receipt.pr_number == 42)

receipt.batches["c1a2b3"] = {
  batch_id = "batch-1",
  state = "committed",
  commit_sha = "c1a2b3",
  started_at = "2026-09-05T01:00:00Z",
  committed_at = "2026-09-05T01:00:02Z",
  comments = {
    ["c1a2b3:rev1:1"] = { remote_id = 12345, path = "a.lua", line = 10, state = "posted" },
  },
}
pr_mod.save_receipt("github", "test-repo", 42, receipt)

local reloaded_receipt = pr_mod.load_receipt("github", "test-repo", 42)
ok("reloaded receipt preserved committed batch", reloaded_receipt.batches["c1a2b3"] and reloaded_receipt.batches["c1a2b3"].state == "committed")
ok("reloaded receipt preserved comment remote_id", reloaded_receipt.batches["c1a2b3"].comments["c1a2b3:rev1:1"].remote_id == 12345)

-- 4. Mock HTTP Dispatcher & Resilient Posting Lifecycle (Steps 1-4)
creds.set_profile("test-repo", { kind = "in_memory", token = "test_pat_secret" })

local fake_remote_comments = {}
pr_mod._mock_http = function(method, url, token, body)
  if method == "GET" and url:find("/pulls/42/comments") then
    return 200, vim.json.encode(fake_remote_comments)
  elseif method == "POST" and url:find("/pulls/42/reviews") then
    local data = vim.json.decode(body)
    for _, c in ipairs(data.comments) do
      table.insert(fake_remote_comments, {
        id = #fake_remote_comments + 100,
        path = c.path,
        line = c.line,
        body = c.body,
      })
    end
    return 200, vim.json.encode({ id = 999, state = "COMMENTED" })
  elseif method == "GET" and url:find("/pulls/42$") then
    return 200, vim.json.encode({
      number = 42,
      title = "Implement Feature X",
      body = "PR description here",
      state = "open",
      draft = false,
      base = { ref = "main" },
      head = { ref = "feat/x", sha = "abc1234" },
    })
  end
  return 404, "not found"
end

local mock_repo = {
  slug = "test-repo",
  remote = "git@github.com:owner/test-repo.git",
}

local review_batch = {
  {
    commit = "931d6c5",
    doc_name = "rev1",
    comments = {
      { id = "find1", path = "lua/file.lua", line = 15, body = "must-fix finding text" },
      { id = "find2", path = "lua/file.lua", line = 25, body = "nit finding text" },
    },
  },
}

-- Execute post_feedback (initial delivery)
local post_res = pr_mod.post_feedback(mock_repo, 42, review_batch)
ok("post_feedback succeeded", post_res.ok == true)

local r_after = pr_mod.load_receipt("github", "test-repo", 42)
local batch_res = r_after.batches["931d6c5"]
ok("batch transitioned to committed", batch_res and batch_res.state == "committed")
ok("finding 1 marked posted", batch_res.comments["931d6c5:rev1:find1"].state == "posted")
ok("finding 2 marked posted", batch_res.comments["931d6c5:rev1:find2"].state == "posted")
ok("remote comment body includes invisible finding_id marker",
  fake_remote_comments[1] and fake_remote_comments[1].body:find("<!-- worktree:finding_id=931d6c5:rev1:find1 -->", 1, true) ~= nil)

-- Step 4 Reconciliation test:
-- Reset receipt to in_flight (simulating network dropped response)
r_after.batches["931d6c5"].state = "in_flight"
r_after.batches["931d6c5"].comments["931d6c5:rev1:find1"].state = "in_flight"
r_after.batches["931d6c5"].comments["931d6c5:rev1:find2"].state = "in_flight"
pr_mod.save_receipt("github", "test-repo", 42, r_after)

-- Calling post_feedback again must reconcile via remote markers without posting duplicate comments
local comment_count_before = #fake_remote_comments
local post_res2 = pr_mod.post_feedback(mock_repo, 42, review_batch)
ok("post_feedback retry succeeded", post_res2.ok == true)
ok("no duplicate comments were posted to forge during reconciliation", #fake_remote_comments == comment_count_before)

local r_reconciled = pr_mod.load_receipt("github", "test-repo", 42)
ok("batch transitioned back to committed after reconciliation", r_reconciled.batches["931d6c5"].state == "committed")

-- 5. get_pr validation
local pr_data, pr_err = pr_mod.get_pr(mock_repo, 42)
ok("get_pr succeeds", pr_data ~= nil, pr_err)
ok("get_pr title parsed", pr_data.title == "Implement Feature X")
ok("get_pr state is open", pr_data.state == "open")
ok("get_pr base_ref is main", pr_data.base_ref == "main")

-- 6. dissociate_review validation
local test_rev_doc = {
  sha = "931d6c5",
  pr = 42,
}
ok("dissociate_review detects matching PR", pr_mod.dissociate_review(test_rev_doc, 42) == true)
ok("dissociate_review removes pr field", test_rev_doc.pr == nil)
ok("dissociate_review returns false when pr is already nil", pr_mod.dissociate_review(test_rev_doc, 42) == false)

-- Cleanup
vim.fn.delete(tmp_dir, "rf")

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
