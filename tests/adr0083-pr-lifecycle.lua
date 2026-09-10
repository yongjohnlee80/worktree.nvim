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

-- Dead-owner handling: simulate lock left by dead process PID 99999999
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

-- MF1: Automatic reclaim is disabled to eliminate check-then-act race (concurrency-testing §3).
-- Both contenders fail closed and neither deletes the dead lock behind each other's back.
local a_ok, a_err = pcall(function() pr_mod.acquire_lock("github", "test-repo", 42) end)
ok("MF1: acquire_lock fails closed on dead owner lock", a_ok == false)
ok("MF1: error reports dead process and manual recovery",
  a_err and a_err:find("dead/stale process PID 99999999", 1, true) ~= nil
  and a_err:find(":WorktreeRecoverPRLock", 1, true) ~= nil,
  a_err)
ok("MF1: dead owner lock is NOT unlinked by acquire_lock", vim.fn.filereadable(dead_lock_path) == 1)

local b_ok, b_err = pcall(function() pr_mod.acquire_lock("github", "test-repo", 42) end)
ok("MF1: second contender also fails closed on dead owner lock", b_ok == false)
ok("MF1: dead owner lock remains intact after competing contention", vim.fn.filereadable(dead_lock_path) == 1)

-- recover_lock: recovers dead lock cleanly
local rec_ok, rec_err = pr_mod.recover_lock("github", "test-repo", 42)
ok("MF1: recover_lock successfully removes dead owner lock", rec_ok == true, rec_err)
ok("MF1: lock file removed by recover_lock", vim.fn.filereadable(dead_lock_path) == 0)

-- Now acquire succeeds cleanly
local lock2 = pr_mod.acquire_lock("github", "test-repo", 42)
ok("acquire succeeds after recover_lock", lock2 ~= nil)

-- recover_lock refuses to remove live process lock without force
local rec_live_ok, rec_live_err = pr_mod.recover_lock("github", "test-repo", 42)
ok("MF1: recover_lock refuses to remove active process lock", rec_live_ok == false)
ok("MF1: active lock remains intact", vim.fn.filereadable(lock2.path) == 1)
-- with force = true, operator can override
local rec_force_ok = pr_mod.recover_lock("github", "test-repo", 42, { force = true })
ok("MF1: recover_lock with force=true removes active lock", rec_force_ok == true)
ok("MF1: lock file removed after forced recovery", vim.fn.filereadable(lock2.path) == 0)

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
      base = { ref = "main", sha = "ba5e5ha0000000000000000000000000000000f" },
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
-- The authoritative base sha (B6): get_pr must MAP data.base.sha, or the whole
-- base_rev mechanism has no source. Deleting the mapping fails this cell.
ok("get_pr surfaces the forge base sha", pr_data.base_sha == "ba5e5ha0000000000000000000000000000000f", tostring(pr_data.base_sha))

-- 5b. fetch_and_create_worktree reports FAILURE instead of a false {ok=true} (B5).
-- The forge query is mocked to succeed; the git fetch of the PR ref then fails
-- (this scratch repo has no `origin` remote), and the function must say so —
-- the original returned { ok = true } unconditionally, so the UI toasted
-- "fetched PR #42" even when every git call failed.
do
  local scratch = vim.fn.tempname() .. "-fcw"
  vim.fn.mkdir(scratch, "p")
  vim.fn.system({ "git", "-C", scratch, "init", "-q" })
  vim.fn.writefile({ "x" }, scratch .. "/a.txt")
  vim.fn.system({ "git", "-C", scratch, "-c", "user.email=t@t", "-c", "user.name=t", "add", "." })
  vim.fn.system({ "git", "-C", scratch, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "base" })
  local res = pr_mod.fetch_and_create_worktree(
    { slug = "test-repo", remote = "git@github.com:owner/test-repo.git",
      common_dir = scratch .. "/.git", path = scratch }, 42)
  ok("B5: *** a failed PR fetch returns ok=false, not a false success ***",
    res ~= nil and res.ok == false, vim.inspect(res))
  ok("B5: the failure names the PR and comes from git, not the forge query",
    res and type(res.error) == "string" and res.error:find("42", 1, true) ~= nil,
    res and tostring(res.error) or "nil")
  vim.fn.delete(scratch, "rf")
end

-- 5c. BRIDGE: the forge base sha reaches the consumer end-to-end (lector #22 r1).
--   get_pr(base.sha) -> fetch_and_create_worktree persists base_sha in the doc
--   -> find_for_worktree parses it back -> repos.pr_diff forwards it as base_rev
--   -> pr_diff_commits ranges authoritatively (stale=false).
-- Without any link in this chain the authoritative base never reaches the diff,
-- which is exactly the gap the review named.
do
  local kb = vim.fn.tempname() .. "-bridgekb"
  local slug = "bridge__repo"
  -- Real repo: base advances C1->C2->C3, feature=C3+F1, local base stale at C1,
  -- origin/base stale at C2 — so ONLY the forge sha (C3) yields the correct range.
  local rp = vim.fn.tempname() .. "-bridge"
  local function g(...) return vim.fn.system({ "git", "-C", rp, "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=base", ... }) end
  vim.fn.mkdir(rp, "p"); vim.fn.system({ "git", "-C", rp, "init", "-q", "-b", "base" })
  vim.fn.writefile({ "c1" }, rp .. "/a"); g("add", "."); g("commit", "-qm", "C1")
  local c1 = vim.trim(g("rev-parse", "HEAD"))
  vim.fn.writefile({ "c2" }, rp .. "/b"); g("add", "."); g("commit", "-qm", "C2")
  local c2 = vim.trim(g("rev-parse", "HEAD"))
  vim.fn.writefile({ "c3" }, rp .. "/c"); g("add", "."); g("commit", "-qm", "C3")
  local c3 = vim.trim(g("rev-parse", "HEAD"))
  g("checkout", "-q", "-b", "pr-77"); vim.fn.writefile({ "f1" }, rp .. "/f1"); g("add", "."); g("commit", "-qm", "F1")
  g("checkout", "-q", "base"); g("update-ref", "refs/remotes/origin/base", c2); g("reset", "--hard", c1)
  local repo = { slug = slug, common_dir = rp .. "/.git", path = rp }

  -- get_pr mocked to return base.sha = C3 (the true forge base).
  pr_mod._mock_http = function(method, url)
    if method == "GET" and url:find("/pulls/77$") then
      return 200, vim.json.encode({ number = 77, title = "bridge", body = "b",
        state = "open", draft = false, base = { ref = "base", sha = c3 },
        head = { ref = "pr-77", sha = c3 } })
    end
    return 404, "nf"
  end
  creds.set_profile(slug, { kind = "in_memory", token = "t" })

  -- 1) get_pr surfaces base_sha = C3.
  local pr = pr_mod.get_pr(repo, 77)
  ok("5c: get_pr surfaces the forge base sha (C3)", pr and pr.base_sha == c3, pr and tostring(pr.base_sha))

  -- 2) The KB PR doc persists base_sha, and find_for_worktree parses it back.
  local doc_dir = string.format("%s/shared/prs/%s", kb, slug)
  vim.fn.mkdir(doc_dir, "p")
  vim.fn.writefile({ "---", "number: 77", "branch: pr-77",
    "base: base", "base_sha: " .. c3, "---", "x" },
    string.format("%s/pr-77.md", doc_dir))
  local saved = vim.env.AUTO_AGENTS_KB_ROOT
  vim.env.AUTO_AGENTS_KB_ROOT = kb
  local found = pr_mod.find_for_worktree(repo, { branch = "pr-77" })
  vim.env.AUTO_AGENTS_KB_ROOT = saved
  ok("5c: find_for_worktree parses base_sha back", found and found.base_sha == c3,
    found and tostring(found.base_sha) or "nil")

  -- 3) repos.pr_diff forwards base_rev -> authoritative range (only F1, not C2/C3),
  --    and reports stale=false.
  local repos = require("worktree.repos")
  local commits, stale = repos.pr_diff(repo, "base", "pr-77", { base_rev = found.base_sha })
  local subj = {}
  for _, c in ipairs(commits) do subj[c.subject] = true end
  ok("5c: *** repos.pr_diff forwards base_rev -> only F1 (C2/C3 excluded) ***",
    subj["F1"] and not subj["C2"] and not subj["C3"], vim.inspect(vim.tbl_keys(subj)))
  ok("5c: *** and reports stale=false (authoritative) ***", stale == false)
  -- And WITHOUT base_rev, repos.pr_diff surfaces stale=true (the honest fallback).
  local _, stale2 = repos.pr_diff(repo, "base", "pr-77")
  ok("5c: repos.pr_diff without base_rev reports stale=true", stale2 == true)

  pr_mod._mock_http = nil
  creds.clear_profile(slug)
  vim.fn.delete(rp, "rf"); vim.fn.delete(kb, "rf")
end

-- 5d. post_feedback honours the slug -> HOST -> env chain (lector PR #23 MF2).
-- A profile registered ONLY under the host `github.com` (no per-slug profile,
-- no env token) must let review posting resolve a token — because post_feedback
-- passes remote_info.host to resolve_token like get/create/comments do. If it
-- resolved with the slug alone, the host profile is invisible and posting fails
-- with "failed to resolve auth token" while every other verb works. The mock
-- captures the token that reaches the HTTP layer, so we also prove it is the
-- HOST profile's token, not something else.
do
  local slug = "hostonly__repo"
  local repo = { slug = slug, remote = "git@github.com:owner/hostonly-repo.git" }
  -- Only a host-scoped profile exists; ensure no slug profile lingers.
  creds.clear_profile(slug)
  creds.set_profile("github.com", { kind = "in_memory", token = "HOSTTOK-9x" })
  local seen_post_token = nil
  pr_mod._mock_http = function(method, url, token, _body)
    if method == "GET" and url:find("/comments$") then return 200, "[]" end
    if method == "POST" and url:find("/reviews$") then
      seen_post_token = token
      return 201, vim.json.encode({ id = 1 })
    end
    return 404, "nf"
  end
  local res = pr_mod.post_feedback(repo, 7, {
    { commit = "deadbeef", doc_name = "rev", comments = {
      { path = "a.lua", line = 1, body = "nit" } } },
  })
  ok("5d: *** post_feedback resolves via the host profile (ok=true) ***",
    res ~= nil and res.ok == true, res and tostring(res.error) or "nil")
  ok("5d: the HOST profile's token is what reached the POST /reviews call",
    seen_post_token == "HOSTTOK-9x", tostring(seen_post_token))
  pr_mod._mock_http = nil
  creds.clear_profile("github.com")
end

-- 5e. fetch_and_create_worktree checks BOTH checkout branches (lector PR #23 MF4).
-- The original returned { ok = true } no matter what git did; the fix checks the
-- exit code of `worktree add` (bare path) AND `checkout` (non-bare path). One
-- cell per branch, each engineered so the fetch SUCCEEDS (a real local origin
-- carrying refs/pull/42/head) and only the checkout step fails — so deleting
-- EITHER of the two checks (not just the fetch check) turns the cell green.
local function make_origin_with_pr()
  -- origin: main has base.txt; refs/pull/42/head additionally adds collide.txt.
  local origin = vim.fn.tempname() .. "-origin"
  local function g(...) return vim.fn.system({ "git", "-C", origin,
    "-c", "user.email=t@t", "-c", "user.name=t", "-c", "init.defaultBranch=main", ... }) end
  vim.fn.mkdir(origin, "p"); vim.fn.system({ "git", "-C", origin, "init", "-q", "-b", "main" })
  vim.fn.writefile({ "base" }, origin .. "/base.txt"); g("add", "."); g("commit", "-qm", "base")
  g("checkout", "-q", "-b", "prhead")
  vim.fn.writefile({ "from-pr" }, origin .. "/collide.txt"); g("add", "."); g("commit", "-qm", "pr")
  g("update-ref", "refs/pull/42/head", "prhead")
  g("checkout", "-q", "main"); g("branch", "-qD", "prhead")
  return origin
end

do
  -- MF4 branch A — BARE repo: `git worktree add` fails because wt_path is a file.
  -- Everything lives under ONE uniquely-owned parent (lector PR #23 r1 MF2):
  -- the code derives wt_path = dirname(common_dir)/pr-42, so putting the bare
  -- repo inside `root` makes that sibling `root/pr-42` — owned by this cell, not
  -- the shared /tmp. Cleanup removes only `root`, never a path we don't own.
  local origin = make_origin_with_pr()
  local root = vim.fn.tempname() .. "-mf4a"
  vim.fn.mkdir(root, "p")
  local bare = root .. "/repo.git"
  vim.fn.system({ "git", "clone", "-q", "--bare", origin, bare })
  -- Pre-create wt_path (== root/pr-42) as a FILE so `worktree add` refuses
  -- ("already exists"), AFTER the fetch has already succeeded.
  local wt_path = vim.fs.dirname(bare) .. "/pr-42"
  vim.fn.writefile({ "block" }, wt_path)
  local slug = "mf4a__repo"
  creds.set_profile(slug, { kind = "in_memory", token = "t" })
  pr_mod._mock_http = function(method, url)
    if method == "GET" and url:find("/pulls/42$") then
      return 200, vim.json.encode({ number = 42, title = "x", body = "b",
        state = "open", draft = false, base = { ref = "main", sha = "" },
        head = { ref = "pr-42", sha = "" } })
    end
    return 404, "nf"
  end
  local res = pr_mod.fetch_and_create_worktree(
    { slug = slug, remote = "git@github.com:owner/mf4a.git", bare = true,
      common_dir = bare }, 42)
  ok("5e-A: *** fetch OK but `worktree add` fails -> ok=false (bare check) ***",
    res ~= nil and res.ok == false, vim.inspect(res))
  ok("5e-A: the error names the checkout-into-worktree step",
    res and type(res.error) == "string" and res.error:find("check it out", 1, true) ~= nil,
    res and tostring(res.error) or "nil")
  pr_mod._mock_http = nil; creds.clear_profile(slug)
  vim.fn.delete(origin, "rf"); vim.fn.delete(root, "rf") -- only owned paths
end

do
  -- MF4 branch B — NON-BARE repo: `git checkout pr-42` fails because an untracked
  -- collide.txt would be overwritten. The fetch of the PR head still succeeds.
  local origin = make_origin_with_pr()
  local work = vim.fn.tempname() .. "-work"
  vim.fn.system({ "git", "clone", "-q", origin, work })
  vim.fn.writefile({ "local-untracked" }, work .. "/collide.txt") -- collides with pr-42
  local slug = "mf4b__repo"
  creds.set_profile(slug, { kind = "in_memory", token = "t" })
  pr_mod._mock_http = function(method, url)
    if method == "GET" and url:find("/pulls/42$") then
      return 200, vim.json.encode({ number = 42, title = "x", body = "b",
        state = "open", draft = false, base = { ref = "main", sha = "" },
        head = { ref = "pr-42", sha = "" } })
    end
    return 404, "nf"
  end
  -- No common_dir / not bare: dir = repo.path = the worktree, so checkout runs
  -- in a work tree and fails on the untracked collision.
  local res = pr_mod.fetch_and_create_worktree(
    { slug = slug, remote = "git@github.com:owner/mf4b.git", path = work }, 42)
  ok("5e-B: *** fetch OK but `checkout` fails -> ok=false (non-bare check) ***",
    res ~= nil and res.ok == false, vim.inspect(res))
  ok("5e-B: the error names the checkout-into-worktree step",
    res and type(res.error) == "string" and res.error:find("check it out", 1, true) ~= nil,
    res and tostring(res.error) or "nil")
  pr_mod._mock_http = nil; creds.clear_profile(slug)
  vim.fn.delete(origin, "rf"); vim.fn.delete(work, "rf")
end

-- 5f. repos.getpr_target_repo — the :WorktreeGetPR cwd resolver (lector PR #23 MF3).
-- Three outcomes, unit-tested rather than living inline in the command: cwd in a
-- matching repo -> that repo; cwd not in any repo -> inventory[1]; cwd in a repo
-- NOT in the inventory -> REFUSE (nil + err), never silently target repo 1.
do
  local repos = require("worktree.repos")
  local function mkrepo(name)
    local d = vim.fn.tempname() .. "-" .. name
    vim.fn.mkdir(d, "p"); vim.fn.system({ "git", "-C", d, "init", "-q" })
    local cd = vim.trim(vim.fn.system({ "git", "-C", d,
      "rev-parse", "--path-format=absolute", "--git-common-dir" }))
    return d, cd
  end
  local d1, cd1 = mkrepo("gp1")
  local d2, cd2 = mkrepo("gp2")     -- a second, standalone in-inventory repo
  local dX, _   = mkrepo("gpX")     -- a repo NOT in the inventory
  local outside  = vim.fn.tempname() .. "-notrepo"
  vim.fn.mkdir(outside, "p")
  local inv = { { slug = "gp1", common_dir = cd1 }, { slug = "gp2", common_dir = cd2 } }

  local r, e = repos.getpr_target_repo(d1, inv)
  ok("5f: cwd inside an inventory repo resolves to THAT repo", r and r.slug == "gp1", e)
  local r2 = repos.getpr_target_repo(d2, inv)
  ok("5f: a second standalone inventory repo also resolves to itself", r2 and r2.slug == "gp2")
  local rc, ec = repos.getpr_target_repo(outside, inv)
  ok("5f: cwd NOT inside any repo falls back to inventory[1]", rc and rc.slug == "gp1", ec)
  local rx, ex = repos.getpr_target_repo(dX, inv)
  ok("5f: *** cwd inside a repo NOT in inventory REFUSES (nil + err) ***",
    rx == nil and type(ex) == "string" and ex:find("not in the workspace", 1, true) ~= nil,
    tostring(rx) .. " / " .. tostring(ex))
  local rn, en = repos.getpr_target_repo(outside, {})
  ok("5f: empty inventory yields nil + err", rn == nil and type(en) == "string")

  -- LINKED worktree (lector PR #23 r1 evidence gap): a real `git worktree add`,
  -- not a standalone `git init`. Its git-common-dir is the PARENT repo's .git
  -- (cd1), so a cwd inside the linked worktree must resolve to gp1 — this is the
  -- bare-repo-family case the resolver exists for, and only a genuine linked
  -- worktree exercises the common-dir-points-elsewhere path.
  vim.fn.system({ "git", "-C", d1, "-c", "user.email=t@t", "-c", "user.name=t",
    "commit", "-q", "--allow-empty", "-m", "seed" })
  local wtlink = vim.fn.tempname() .. "-gp1-linked"
  vim.fn.system({ "git", "-C", d1, "worktree", "add", "-q", "-b", "linkbr", wtlink })
  local link_cd = vim.trim(vim.fn.system({ "git", "-C", wtlink,
    "rev-parse", "--path-format=absolute", "--git-common-dir" }))
  ok("5f: (precondition) linked worktree's common-dir IS the parent repo's .git",
    vim.fs.normalize((link_cd:gsub("/+$", ""))) == vim.fs.normalize((cd1:gsub("/+$", ""))),
    link_cd .. " vs " .. cd1)
  local rl, el = repos.getpr_target_repo(wtlink, inv)
  ok("5f: *** cwd inside a LINKED worktree resolves to its parent inventory repo (gp1) ***",
    rl and rl.slug == "gp1", (rl and rl.slug or "nil") .. " / " .. tostring(el))

  vim.fn.delete(d1, "rf"); vim.fn.delete(d2, "rf"); vim.fn.delete(dX, "rf")
  vim.fn.delete(outside, "rf"); vim.fn.delete(wtlink, "rf")
end

-- 5g. create_pr — the RESULT ENVELOPE, and the association it must write.
--
-- Two defects in one call.
--   1. create_pr returned `(pr, err)` while BOTH call sites — :WorktreeCreatePR
--      and auto-finder's `N` — read `res.ok`, so a PR that had just been opened
--      on the forge reported "could not create PR — unknown". No suite observed
--      it because auto-finder's own test MOCKED `{ ok = true, pr = {…} }`: the
--      shape it wished for, never the one the function returned
--      ([[validate-the-verifier]]).
--   2. nothing wrote the KB PR doc (ADR-0083 §2.6 Action 6: "on creation,
--      instantiate the KB PR document"), so the new PR was associated with
--      NOTHING — no `[#N]` badge, no `S`, and every review drafted afterwards
--      carried no `pr`, hence could never be submitted.
--
-- The association cells assert through its CONSUMER (`find_for_worktree`),
-- not by re-reading the file the code just wrote.
do
  local kb = vim.fn.tempname() .. "-kb-createpr"
  local saved_kb = vim.env.AUTO_AGENTS_KB_ROOT
  vim.env.AUTO_AGENTS_KB_ROOT = kb

  local slug = "acme__widget"
  local repo = { slug = slug, remote = "git@github.com:acme/widget.git" }
  creds.set_profile(slug, { kind = "in_memory", token = "cr34te" })

  pr_mod._mock_http = function(method, url)
    if method == "POST" and url:find("/pulls$") then
      return 201, vim.json.encode({
        number = 77, title = "Widget X", body = "why", state = "open", draft = false,
        base = { ref = "develop", sha = "b45e5ha000000000000000000000000000000000" },
        head = { ref = "feat/widget-x", sha = "h34d5ha000000000000000000000000000000000" },
        user = { login = "johno" },
        html_url = "https://github.com/acme/widget/pull/77",
        created_at = "2026-09-10T00:00:00Z", updated_at = "2026-09-10T01:00:00Z",
      })
    end
    return 404, "nf"
  end

  local res = pr_mod.create_pr(repo,
    { title = "Widget X", body = "why", head = "feat/widget-x", base = "develop" })

  -- (1) the envelope, read exactly as the callers read it
  ok("5g: *** create_pr reports ok=true for a PR it created (callers read res.ok) ***",
    type(res) == "table" and res.ok == true, vim.inspect(res))
  ok("5g: the envelope carries the number the callers print (res.pr.number)",
    res and res.pr and res.pr.number == 77, res and vim.inspect(res.pr) or "nil")
  -- The caller's literal branch, so the cell fails if either half regresses.
  local caller_says = (res and res.ok)
    and ("created PR #" .. tostring(res.pr and res.pr.number or ""))
    or ("could not create PR — " .. tostring(res and res.error or "unknown"))
  ok("5g: *** the caller's own branch renders the success message ***",
    caller_says == "created PR #77", caller_says)

  -- (2) the association — proven through find_for_worktree, on an ORDINARY
  -- branch name. `pr-<N>` would match by naming convention alone and would
  -- prove nothing about the doc.
  local found = pr_mod.find_for_worktree(repo, { branch = "feat/widget-x" })
  ok("5g: *** the created PR is now ASSOCIATED with its head branch ***",
    found ~= nil and tostring(found.number) == "77", vim.inspect(found))
  ok("5g: the association records the real base, not the 'main' fallback",
    found and found.base == "develop", found and tostring(found.base) or "nil")
  ok("5g: the association records the forge's authoritative base sha",
    found and found.base_sha == "b45e5ha000000000000000000000000000000000",
    found and tostring(found.base_sha) or "nil")
  ok("5g: the association records the author",
    res.kb_doc ~= nil and table.concat(vim.fn.readfile(res.kb_doc), "\n"):find("author: johno", 1, true) ~= nil)
  -- Specificity: a DIFFERENT branch in the same repo must NOT inherit it,
  -- or "associated" would mean "any doc matches any worktree".
  local decoy = pr_mod.find_for_worktree(repo, { branch = "feat/something-else" })
  ok("5g: an unrelated branch in the same repo is NOT associated with #77",
    decoy == nil, vim.inspect(decoy))
  ok("5g: the envelope names the branch the PR is associated with",
    res.branch == "feat/widget-x", tostring(res and res.branch))

  -- (3) failures are envelopes too — a bare nil would crash `res.ok` callers.
  pr_mod._mock_http = function() return 422, '{"message":"No commits between"}' end
  local bad = pr_mod.create_pr(repo, { title = "T", head = "feat/x", base = "develop" })
  ok("5g: a forge rejection returns ok=false, not a bare nil",
    type(bad) == "table" and bad.ok == false, vim.inspect(bad))
  ok("5g: the rejection carries the HTTP status in its error",
    bad and type(bad.error) == "string" and bad.error:find("422", 1, true) ~= nil,
    bad and tostring(bad.error) or "nil")

  creds.clear_profile(slug)
  local noauth = pr_mod.create_pr({ slug = "nobody__nothing", remote = "git@example.invalid:n/n.git" },
    { title = "T", head = "b", base = "main" })
  ok("5g: a missing credential returns ok=false and names :WorktreeAuth",
    type(noauth) == "table" and noauth.ok == false
      and tostring(noauth.error):find("WorktreeAuth", 1, true) ~= nil,
    vim.inspect(noauth))

  -- write_kb_doc refuses a record it cannot name, rather than writing pr-nil.md
  local nopath, noerr = pr_mod.write_kb_doc(repo, { title = "x" }, "b")
  ok("5g: write_kb_doc refuses a PR record with no number",
    nopath == nil and type(noerr) == "string", tostring(nopath) .. " / " .. tostring(noerr))

  pr_mod._mock_http = nil
  vim.env.AUTO_AGENTS_KB_ROOT = saved_kb
  vim.fn.delete(kb, "rf")
end

-- 5h. lock_key — the poster and the recoverer must name the SAME lock file.
--
-- `:WorktreeRecoverPRLock` derived `owner .. "/" .. name` while post_feedback
-- locks under `repo.slug` (`owner__name`). recover_lock returns TRUE for a lock
-- file that does not exist, so the wrong key "recovered" successfully and left
-- the real lock in place — the return value could not tell the two apart. These
-- cells assert the FILE, not the return.
do
  local repo = { slug = "acme__widget", url = "git@github.com:acme/widget.git" }
  local forge, key = pr_mod.lock_key(repo)
  ok("5h: lock_key returns the repo slug the poster locks under",
    forge == "github" and key == "acme__widget", tostring(forge) .. " / " .. tostring(key))

  local lock = pr_mod.acquire_lock(forge, key, 77)
  local real_path = lock.path
  ok("5h: the taken lock is at _lock_path(lock_key(repo), n)",
    real_path == pr_mod._lock_path(forge, key, 77), real_path)

  -- The OLD derivation, verbatim, as a decoy.
  local remote = pr_mod.parse_remote(repo.url)
  local old_key = remote.owner .. "/" .. remote.repo
  local old_ok = pr_mod.recover_lock(remote.forge, old_key, 77, { force = true })
  ok("5h: *** the old owner/name key reports success while the lock SURVIVES ***",
    old_ok == true and vim.fn.filereadable(real_path) == 1,
    "returned " .. tostring(old_ok) .. ", lock present=" .. tostring(vim.fn.filereadable(real_path)))

  local new_ok = pr_mod.recover_lock(forge, key, 77, { force = true })
  ok("5h: *** lock_key's key actually removes the lock ***",
    new_ok == true and vim.fn.filereadable(real_path) == 0,
    "returned " .. tostring(new_ok) .. ", lock present=" .. tostring(vim.fn.filereadable(real_path)))
  pcall(function() lock:release() end)
end

-- 5i. :WorktreeRecoverPRLock actually runs, and removes the REAL lock.
--
-- The command called `pr_mod.parse_remote_url` — a function `worktree.pr` has
-- never exported — so it died on its first line with "attempt to call field
-- 'parse_remote_url' (a nil value)". Nothing exercised the command, so the
-- crash shipped. This drives the registered command itself, with the repo
-- inventory stubbed, and asserts the lock file the poster would have taken is
-- the one that goes away.
do
  local repos_mod = require("worktree.repos")
  local saved_repos = repos_mod.repos
  repos_mod.repos = function()
    return { { slug = "acme__widget", url = "git@github.com:acme/widget.git" } }
  end

  vim.g.loaded_worktree = nil -- the plugin file guards on this
  local sourced = pcall(vim.cmd, "source " .. plugin_root .. "/plugin/worktree.lua")
  ok("5i: plugin/worktree.lua sources and registers the command",
    sourced and vim.fn.exists(":WorktreeRecoverPRLock") == 2)

  local forge, key = pr_mod.lock_key({ slug = "acme__widget", url = "git@github.com:acme/widget.git" })
  local lock = pr_mod.acquire_lock(forge, key, 88)
  local notified = {}
  local saved_notify = vim.notify
  vim.notify = function(msg) notified[#notified + 1] = tostring(msg) end
  -- `!` is force, which skips the vim.ui.select confirmation.
  local ran, cmd_err = pcall(vim.cmd, "WorktreeRecoverPRLock! 88")
  vim.notify = saved_notify

  ok("5i: *** the command runs instead of raising a nil-call ***",
    ran == true, tostring(cmd_err))
  ok("5i: *** it removes the lock the poster would have taken ***",
    vim.fn.filereadable(lock.path) == 0, lock.path)
  ok("5i: it reports the recovery",
    #notified > 0 and table.concat(notified, "\n"):find("recovered lock for PR #88", 1, true) ~= nil,
    table.concat(notified, " | "))

  pcall(function() lock:release() end)
  repos_mod.repos = saved_repos
end

-- 6. dissociate_review validation
local test_rev_doc = {
  sha = "931d6c5",
  pr = 42,
}
ok("dissociate_review detects matching PR", pr_mod.dissociate_review(test_rev_doc, 42) == true)
ok("dissociate_review removes pr field", test_rev_doc.pr == nil)
ok("dissociate_review returns false when pr is already nil", pr_mod.dissociate_review(test_rev_doc, 42) == false)

-- 7. Spawned argv non-disclosure inspection for _http_request (ADR §2.5.2 MUST)
pr_mod._mock_http = nil -- clear mock to exercise real curl transport
local canary_token = "CANARY_PAT_SECRET_9876543210"
local curl_spawned = nil
local real_sys = vim.system
local inspected_cfg_mode = nil
local inspected_cfg_text = nil

vim.system = function(cmd, opts, on_exit)
  if cmd[1] == "curl" then
    curl_spawned = { cmd = cmd, opts = opts }
    -- Locate -K flag and verify ephemeral config permissions before synchronous deletion
    for i, c in ipairs(cmd) do
      if c == "-K" and cmd[i + 1] then
        local st = vim.uv.fs_stat(cmd[i + 1])
        if st then
          inspected_cfg_mode = bit.band(st.mode, 511)
          local ok_r, l = pcall(vim.fn.readfile, cmd[i + 1])
          if ok_r and l then
            inspected_cfg_text = table.concat(l, "\n")
          end
        end
      end
    end
    -- Return synthetic 200 response with http_code appended
    local obj = {
      wait = function()
        return { code = 0, stdout = '{"message":"ok"}\n200', stderr = "" }
      end
    }
    return obj
  end
  return real_sys(cmd, opts, on_exit)
end

local code, body = pr_mod._http_request("POST", "https://api.github.com/repos/owner/test-repo/issues", canary_token, '{"title":"test"}')
vim.system = real_sys

ok("MF3: _http_request invoked curl via vim.system", curl_spawned ~= nil)
ok("MF3: response parsed correctly", code == 200 and body:find('"ok"', 1, true) ~= nil)
if curl_spawned then
  local token_found_in_argv = false
  for _, arg in ipairs(curl_spawned.cmd) do
    if arg:find(canary_token, 1, true) ~= nil then
      token_found_in_argv = true
    end
  end
  ok("MF3: argv array does NOT disclose canary secret token", token_found_in_argv == false)
  local has_k = false
  for _, arg in ipairs(curl_spawned.cmd) do
    if arg == "-K" then has_k = true end
  end
  ok("MF3: -K flag is used for credentials header", has_k == true)
  ok("MF3: ephemeral config file has mode 0600 (384)", inspected_cfg_mode == 384, tostring(inspected_cfg_mode))
  ok("MF3: ephemeral config file transmitted bearer token safely",
    inspected_cfg_text and inspected_cfg_text:find("Authorization: Bearer " .. canary_token, 1, true) ~= nil)
  ok("MF3: body streamed via stdin --data-binary @-",
    curl_spawned.opts and curl_spawned.opts.stdin == '{"title":"test"}')
end

-- Cleanup
vim.fn.delete(tmp_dir, "rf")

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
