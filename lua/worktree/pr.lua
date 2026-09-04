---worktree.pr — Pull Request lifecycle, forge client, and resilient posting (ADR-0083 §2.5/§2.6).
---
---Two-phase resilient posting with exclusive file locking (live owner immunity),
---ephemeral curl config bearer auth, remote identity markers, and forge reconciliation.
---@module 'worktree.pr'

local credentials = require("worktree.credentials")
local config = require("worktree.config")

local M = {}

M._custom_receipts_dir = nil
M._mock_http = nil

---_receipts_dir returns the durable directory for receipts and locks.
function M._receipts_dir()
  if M._custom_receipts_dir then return M._custom_receipts_dir end
  return vim.fn.stdpath("state") .. "/worktree/receipts"
end

---_ensure_receipts_dir creates the receipts directory if missing.
function M._ensure_receipts_dir()
  local dir = M._receipts_dir()
  if vim.fn.isdirectory(dir) ~= 1 then
    pcall(vim.fn.mkdir, dir, "p")
  end
  return dir
end

---_receipt_path returns the JSON receipt file path.
function M._receipt_path(forge, repo_slug, pr_number)
  return string.format("%s/%s__%s__pr%s.json", M._receipts_dir(), forge, repo_slug, tostring(pr_number))
end

---_lock_path returns the exclusive lock file path.
function M._lock_path(forge, repo_slug, pr_number)
  return string.format("%s/%s__%s__pr%s.lock", M._receipts_dir(), forge, repo_slug, tostring(pr_number))
end

---parse_remote parses a git remote URL into forge, host, owner, repo.
---@param url string
---@return table
function M.parse_remote(url)
  if type(url) ~= "string" or url == "" then
    return { forge = "github", host = "github.com", owner = "", repo = "", api_base = "https://api.github.com" }
  end

  local host, path
  if url:match("^git@") then
    host, path = url:match("^git@([^:]+):(.+)$")
  elseif url:match("^https?://") then
    host, path = url:match("^https?://([^/]+)/(.+)$")
  elseif url:match("^ssh://") then
    host, path = url:match("^ssh://[^@]+@([^/]+)/(.+)$")
  end

  host = host or "github.com"
  path = (path or url):gsub("%.git$", "")
  local parts = vim.split(path, "/", { trimempty = true })
  local owner = parts[#parts - 1] or ""
  local repo = parts[#parts] or ""

  local forge = "github"
  local api_base = "https://api.github.com"
  if host:find("github") then
    forge = "github"
    api_base = "https://api.github.com"
  elseif host:find("forgejo") or host:find("gitea") then
    forge = "forgejo"
    api_base = string.format("https://%s/api/v1", host)
  elseif host:find("gitlab") then
    forge = "gitlab"
    api_base = string.format("https://%s/api/v4", host)
  end

  return {
    forge = forge,
    host = host,
    owner = owner,
    repo = repo,
    api_base = api_base,
  }
end

---acquire_lock acquires an exclusive lock on a PR receipt with live-owner immunity (ADR-0083 §2.6).
---@param forge string
---@param repo_slug string
---@param pr_number integer|string
---@return table lock_handle
function M.acquire_lock(forge, repo_slug, pr_number)
  M._ensure_receipts_dir()
  local lock_path = M._lock_path(forge, repo_slug, pr_number)
  local my_host = vim.uv.os_gethostname()
  local my_pid = vim.uv.os_getpid()
  local owner_token = string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))

  local fd = vim.uv.fs_open(lock_path, "wx", 384) -- O_CREAT | O_EXCL, mode 0600
  if not fd then
    -- Lock exists, evaluate contention & live-owner immunity
    local ok_read, lines = pcall(vim.fn.readfile, lock_path)
    if not ok_read or not lines or #lines == 0 then
      error("worktree.pr: malformed or unreadable lock at " .. lock_path .. "; manual resolution required")
    end
    local dok, lock_data = pcall(vim.json.decode, table.concat(lines, "\n"))
    if not dok or type(lock_data) ~= "table" or not lock_data.owner_token or not lock_data.pid then
      error("worktree.pr: malformed or unreadable lock at " .. lock_path .. "; manual resolution required")
    end

    -- Cross-Host Safety
    if lock_data.host and lock_data.host ~= my_host then
      error(string.format("worktree.pr: PR #%s review posting locked by host '%s'", tostring(pr_number), lock_data.host))
    end

    -- Live Owner Immunity check
    local alive_ret = vim.uv.kill(lock_data.pid, 0)
    if alive_ret == 0 or alive_ret == true then
      -- Live owner: NEVER evicted regardless of age
      error(string.format(
        "worktree.pr: PR #%s review posting locked by active process PID %d on %s",
        tostring(pr_number), lock_data.pid, tostring(lock_data.host or my_host)
      ))
    end

    -- Dead owner (ESRCH): break lock and retry acquire
    pcall(vim.uv.fs_unlink, lock_path)
    fd = vim.uv.fs_open(lock_path, "wx", 384)
    if not fd then
      error("worktree.pr: failed to acquire lock after breaking dead lock at " .. lock_path)
    end
  end

  local lock_payload = vim.json.encode({
    owner_token = owner_token,
    pid = my_pid,
    host = my_host,
    acquired_at = os.time(),
    refreshed_at = os.time(),
  })
  vim.uv.fs_write(fd, lock_payload)
  vim.uv.fs_close(fd)

  local handle = {
    owner_token = owner_token,
    path = lock_path,
    released = false,
  }

  function handle:refresh()
    if self.released then return end
    local ok, lines = pcall(vim.fn.readfile, self.path)
    if ok and lines and #lines > 0 then
      local data = vim.json.decode(table.concat(lines, "\n"))
      if data and data.owner_token == self.owner_token then
        data.refreshed_at = os.time()
        pcall(vim.fn.writefile, { vim.json.encode(data) }, self.path)
      end
    end
  end

  function handle:release()
    if self.released then return end
    self.released = true
    local ok, lines = pcall(vim.fn.readfile, self.path)
    if ok and lines and #lines > 0 then
      local dok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
      if dok and type(data) == "table" and data.owner_token == self.owner_token then
        pcall(vim.uv.fs_unlink, self.path)
      end
    end
  end

  return handle
end

---load_receipt loads the receipt document for a PR.
---@param forge string
---@param repo_slug string
---@param pr_number integer|string
---@return table receipt
function M.load_receipt(forge, repo_slug, pr_number)
  local path = M._receipt_path(forge, repo_slug, pr_number)
  if vim.fn.filereadable(path) ~= 1 then
    return {
      schema = "worktree.pr.receipt/2",
      repo = repo_slug,
      pr_number = tonumber(pr_number) or pr_number,
      batches = {},
    }
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then
    return { schema = "worktree.pr.receipt/2", repo = repo_slug, pr_number = tonumber(pr_number) or pr_number, batches = {} }
  end
  local dok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not dok or type(data) ~= "table" then
    return { schema = "worktree.pr.receipt/2", repo = repo_slug, pr_number = tonumber(pr_number) or pr_number, batches = {} }
  end
  data.batches = data.batches or {}
  return data
end

---save_receipt atomically persists the receipt document.
---@param forge string
---@param repo_slug string
---@param pr_number integer|string
---@param receipt table
function M.save_receipt(forge, repo_slug, pr_number, receipt)
  M._ensure_receipts_dir()
  local path = M._receipt_path(forge, repo_slug, pr_number)
  local text = vim.json.encode(receipt)
  local ok_atomic, fs_atomic = pcall(require, "auto-core.fs.atomic")
  if ok_atomic and type(fs_atomic.write) == "function" then
    return fs_atomic.write(path, text, { mkdir = true })
  else
    local tmp = path .. ".tmp-" .. tostring(math.random(1, 1e9))
    local ok_w = pcall(vim.fn.writefile, { text }, tmp)
    if ok_w then
      pcall(vim.uv.fs_rename, tmp, path)
      return true
    end
    pcall(vim.uv.fs_unlink, tmp)
    return false
  end
end

---_http_request performs an authenticated HTTP request using curl and ephemeral header config.
---@param method string
---@param url string
---@param token string
---@param body string?
---@return integer status_code, string body
function M._http_request(method, url, token, body)
  if M._mock_http then
    return M._mock_http(method, url, token, body)
  end

  local cfg_path, cleanup = credentials.open_exclusive_config(token)
  local cmd = {
    "curl", "-sS",
    "-w", "\n%{http_code}",
    "-X", method,
    "-K", cfg_path,
  }
  if body and body ~= "" then
    table.insert(cmd, "--data-binary")
    table.insert(cmd, "@-")
  end
  table.insert(cmd, url)

  local ok, res = pcall(function()
    return vim.system(cmd, { stdin = body, text = true }):wait()
  end)
  cleanup()

  if not ok or not res then
    error("worktree.pr: curl invocation failed: " .. credentials.redact(tostring(res)))
  end

  local stdout = res.stdout or ""
  local lines = vim.split(stdout, "\n", { trimempty = true })
  local status_code = 0
  local resp_body = ""
  if #lines > 0 then
    status_code = tonumber(lines[#lines]) or 0
    table.remove(lines, #lines)
    resp_body = table.concat(lines, "\n")
  end

  if res.code ~= 0 and status_code == 0 then
    error("worktree.pr: curl network error: " .. credentials.redact(vim.trim(res.stderr or "")))
  end

  return status_code, resp_body
end

---_get_repo_remote_url returns the remote origin URL for a repository.
local function _get_repo_remote_url(repo)
  if repo.remote then return repo.remote end
  if repo.remotes and repo.remotes.origin then return repo.remotes.origin end
  local dir = repo.common_dir or repo.sample_worktree or repo.path
  if not dir then return "" end
  local out = vim.system({ "git", "-C", dir, "config", "--get", "remote.origin.url" }, { text = true }):wait()
  if out.code == 0 then return vim.trim(out.stdout or "") end
  return ""
end

---get_pr fetches pull request metadata from the forge.
---@param repo table
---@param pr_number integer|string
---@return table pr, string? err
function M.get_pr(repo, pr_number)
  local remote_url = _get_repo_remote_url(repo)
  local remote_info = M.parse_remote(remote_url)
  local token, terr = credentials.resolve_token(repo.slug or remote_info.host)
  if not token then return nil, terr end

  local url = string.format("%s/repos/%s/%s/pulls/%s", remote_info.api_base, remote_info.owner, remote_info.repo, tostring(pr_number))
  local code, body = M._http_request("GET", url, token, nil)
  if code ~= 200 then
    return nil, string.format("forge returned HTTP %d: %s", code, credentials.redact(body))
  end

  local dok, data = pcall(vim.json.decode, body)
  if not dok or type(data) ~= "table" then
    return nil, "failed to parse forge PR response JSON"
  end

  return {
    number = data.number,
    title = data.title or "",
    body = data.body or "",
    state = data.state or "open",
    draft = data.draft == true,
    base_ref = (data.base and data.base.ref) or "main",
    head_ref = (data.head and data.head.ref) or "",
    head_sha = (data.head and data.head.sha) or "",
    commits = data.commits or 0,
    author = (data.user and data.user.login) or "",
    html_url = data.html_url or "",
    created_at = data.created_at or "",
    updated_at = data.updated_at or "",
    forge = remote_info.forge,
  }, nil
end

---get_comments fetches all line review comments on a pull request.
---@param repo table
---@param pr_number integer|string
---@return table[] comments, string? err
function M.get_comments(repo, pr_number)
  local remote_url = _get_repo_remote_url(repo)
  local remote_info = M.parse_remote(remote_url)
  local token, terr = credentials.resolve_token(repo.slug or remote_info.host)
  if not token then return {}, terr end

  local url = string.format("%s/repos/%s/%s/pulls/%s/comments", remote_info.api_base, remote_info.owner, remote_info.repo, tostring(pr_number))
  local code, body = M._http_request("GET", url, token, nil)
  if code ~= 200 then
    return {}, string.format("forge returned HTTP %d: %s", code, credentials.redact(body))
  end

  local dok, data = pcall(vim.json.decode, body)
  if not dok or type(data) ~= "table" then
    return {}, "failed to parse comments JSON"
  end
  return data, nil
end

---create_pr creates a new pull request on the forge (Action 6).
---@param repo table
---@param opts table { title: string, body: string, head: string, base: string, draft: boolean? }
---@return table pr, string? err
function M.create_pr(repo, opts)
  opts = opts or {}
  local remote_url = _get_repo_remote_url(repo)
  local remote_info = M.parse_remote(remote_url)
  local token, terr = credentials.resolve_token(repo.slug or remote_info.host)
  if not token then return nil, terr end

  local payload = vim.json.encode({
    title = opts.title or "PR",
    body = opts.body or "",
    head = opts.head,
    base = opts.base or "main",
    draft = opts.draft == true,
  })

  local url = string.format("%s/repos/%s/%s/pulls", remote_info.api_base, remote_info.owner, remote_info.repo)
  local code, body = M._http_request("POST", url, token, payload)
  if code ~= 201 and code ~= 200 then
    return nil, string.format("failed to create PR, HTTP %d: %s", code, credentials.redact(body))
  end

  local dok, data = pcall(vim.json.decode, body)
  if not dok or type(data) ~= "table" then
    return nil, "failed to parse created PR response JSON"
  end

  return {
    number = data.number,
    title = data.title,
    body = data.body,
    state = data.state,
    draft = data.draft == true,
    html_url = data.html_url,
  }, nil
end

---post_feedback executes the four-step resilient review posting lifecycle (ADR-0083 §2.6 Action 4).
---@param repo table
---@param pr_number integer|string
---@param reviews table[] list of review document tables or findings
---@param opts table?
---@return table result
function M.post_feedback(repo, pr_number, reviews, opts)
  opts = opts or {}
  local remote_url = _get_repo_remote_url(repo)
  local remote_info = M.parse_remote(remote_url)
  local slug = repo.slug or remote_info.repo
  local forge = remote_info.forge

  -- Acquire exclusive lock with live-owner immunity
  local lock = M.acquire_lock(forge, slug, pr_number)

  local ok, err = pcall(function()
    local receipt = M.load_receipt(forge, slug, pr_number)
    local token, terr = credentials.resolve_token(slug)
    if not token then error("worktree.pr: failed to resolve auth token: " .. tostring(terr)) end

    -- Group findings by commit_sha
    local commit_batches = {}
    for _, rev in ipairs(reviews or {}) do
      local sha = rev.commit or rev.sha or "HEAD"
      local doc_name = rev.doc_name or rev.id or "review"
      commit_batches[sha] = commit_batches[sha] or {
        commit_sha = sha,
        comments = {},
      }
      for idx, c in ipairs(rev.comments or {}) do
        local finding_id = string.format("%s:%s:%s", sha, doc_name, tostring(c.id or idx))
        table.insert(commit_batches[sha].comments, {
          finding_id = finding_id,
          path = c.path or c.file,
          line = c.line,
          side = c.side or "RIGHT",
          body = c.body or c.text or "",
          severity = c.severity,
        })
      end
    end

    -- Process each commit batch
    for sha, batch in pairs(commit_batches) do
      lock:refresh()
      local receipt_batch = receipt.batches[sha]
      if not receipt_batch then
        receipt_batch = {
          batch_id = string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff)),
          state = "in_flight",
          commit_sha = sha,
          started_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
          comments = {},
        }
        for _, c in ipairs(batch.comments) do
          receipt_batch.comments[c.finding_id] = {
            path = c.path,
            line = c.line,
            side = c.side,
            state = "in_flight",
          }
        end
        receipt.batches[sha] = receipt_batch
        M.save_receipt(forge, slug, pr_number, receipt)
      end

      -- If already committed, skip
      if receipt_batch.state ~= "committed" then
        -- Step 4 pre-flight reconciliation if in_flight from previous crash
        local remote_comments = M.get_comments(repo, pr_number)
        local remote_markers = {}
        for _, rc in ipairs(remote_comments or {}) do
          local rc_body = rc.body or ""
          local marker = rc_body:match("<!%-%- worktree:finding_id=([^%s]+) %-%->")
          if marker then
            remote_markers[marker] = rc.id
          end
        end

        local all_landed = true
        local pending_comments = {}
        for _, c in ipairs(batch.comments) do
          if remote_markers[c.finding_id] then
            receipt_batch.comments[c.finding_id].remote_id = remote_markers[c.finding_id]
            receipt_batch.comments[c.finding_id].state = "posted"
          else
            all_landed = false
            -- Suffix invisible HTML identity marker
            local remote_body = string.format("%s\n\n<!-- worktree:finding_id=%s -->", c.body, c.finding_id)
            table.insert(pending_comments, {
              path = c.path,
              line = c.line,
              side = c.side,
              body = remote_body,
            })
          end
        end

        if all_landed then
          receipt_batch.state = "committed"
          receipt_batch.committed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
          M.save_receipt(forge, slug, pr_number, receipt)
        elseif #pending_comments > 0 then
          -- Step 2: Transmission via Header Config Transport
          local review_payload = vim.json.encode({
            commit_id = sha,
            body = string.format("Review findings for %s", sha:sub(1, 7)),
            event = "COMMENT",
            comments = pending_comments,
          })

          local post_url = string.format("%s/repos/%s/%s/pulls/%s/reviews", remote_info.api_base, remote_info.owner, remote_info.repo, tostring(pr_number))
          local pcode, pbody = M._http_request("POST", post_url, token, review_payload)
          if pcode == 200 or pcode == 201 then
            -- Step 3: Post-Response Confirmation
            local dok, pdata = pcall(vim.json.decode, pbody)
            -- Mark all batch comments as posted
            for _, c in ipairs(batch.comments) do
              receipt_batch.comments[c.finding_id].state = "posted"
            end
            receipt_batch.state = "committed"
            receipt_batch.committed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
            M.save_receipt(forge, slug, pr_number, receipt)
          else
            -- Reconcile to see if it landed despite error
            local rem_after = M.get_comments(repo, pr_number)
            local landed_count = 0
            for _, rc in ipairs(rem_after or {}) do
              local marker = (rc.body or ""):match("<!%-%- worktree:finding_id=([^%s]+) %-%->")
              if marker and receipt_batch.comments[marker] then
                receipt_batch.comments[marker].remote_id = rc.id
                receipt_batch.comments[marker].state = "posted"
                landed_count = landed_count + 1
              end
            end
            if landed_count == #batch.comments then
              receipt_batch.state = "committed"
            else
              receipt_batch.state = "indeterminate"
            end
            M.save_receipt(forge, slug, pr_number, receipt)
            error(string.format("post review failed with HTTP %d: %s", pcode, credentials.redact(pbody)))
          end
        end
      end
    end

    return receipt
  end)

  lock:release()

  if not ok then
    return { ok = false, error = tostring(err) }
  end
  return { ok = true, receipt = err }
end

---dissociate_review removes PR association metadata from a review document.
---@param review_data table
---@param pr_number integer|string
---@return boolean changed
function M.dissociate_review(review_data, pr_number)
  if not review_data or not review_data.pr then return false end
  if tostring(review_data.pr) == tostring(pr_number) then
    review_data.pr = nil
    return true
  end
  return false
end

---fetch_and_create_worktree fetches PR branch, creates worktree, and writes KB PR document (Action 1).
---@param repo table
---@param pr_number integer|string
---@param opts table?
---@return table result
function M.fetch_and_create_worktree(repo, pr_number, opts)
  opts = opts or {}
  local pr, err = M.get_pr(repo, pr_number)
  if not pr then return { ok = false, error = err } end

  local dir = repo.common_dir or repo.sample_worktree or repo.path
  local branch = string.format("pr-%s", tostring(pr_number))

  -- 1. git fetch origin pull/{pr_number}/head:pr-{pr_number}
  local fetch_ref = string.format("pull/%s/head:%s", tostring(pr_number), branch)
  local f_res = vim.system({ "git", "-C", dir, "fetch", "origin", fetch_ref }, { text = true }):wait()
  if f_res.code ~= 0 then
    -- Try forgejo / gitlab refspec fallback
    local alt_ref = string.format("refs/pull/%s/head:%s", tostring(pr_number), branch)
    f_res = vim.system({ "git", "-C", dir, "fetch", "origin", alt_ref }, { text = true }):wait()
  end

  -- 2. Add worktree
  local is_bare = repo.bare == true or (repo.common_dir and repo.common_dir:find("%.git$") and not repo.path)
  local wt_path
  if is_bare or repo.sample_worktree then
    local parent = vim.fs.dirname(dir)
    wt_path = parent .. "/" .. branch
    vim.system({ "git", "-C", dir, "worktree", "add", wt_path, branch }, { text = true }):wait()
  else
    wt_path = dir
    vim.system({ "git", "-C", dir, "checkout", branch }, { text = true }):wait()
  end

  -- 3. Create KB document shared/prs/<repo_slug>/pr-<number>.md
  local kb_root = vim.env.AUTO_AGENTS_KB_ROOT or (vim.fn.expand("~/.config/nvim/.auto-agents-config/kb"))
  local kb_doc_path = string.format("%s/shared/prs/%s/pr-%s.md", kb_root, repo.slug or "repo", tostring(pr_number))
  local doc_content = table.concat({
    "---",
    "type: pr",
    string.format("repo: %s", repo.slug or "repo"),
    string.format("number: %s", tostring(pr_number)),
    string.format("title: %q", pr.title),
    string.format("state: %s", pr.draft and "draft" or pr.state),
    string.format("branch: %s", branch),
    string.format("base: %s", pr.base_ref or "main"),
    string.format("author: %s", pr.author or ""),
    string.format("created: %s", pr.created_at or os.date("%Y-%m-%d")),
    string.format("updated: %s", pr.updated_at or os.date("%Y-%m-%d")),
    "---",
    "",
    string.format("# PR #%s — %s", tostring(pr_number), pr.title),
    "",
    "## Description",
    pr.body,
    "",
  }, "\n")

  local ok_atomic, fs_atomic = pcall(require, "auto-core.fs.atomic")
  if ok_atomic and type(fs_atomic.write) == "function" then
    fs_atomic.write(kb_doc_path, doc_content, { mkdir = true })
  else
    pcall(vim.fn.mkdir, vim.fs.dirname(kb_doc_path), "p")
    pcall(vim.fn.writefile, vim.split(doc_content, "\n"), kb_doc_path)
  end

  return {
    ok = true,
    pr = pr,
    worktree_path = wt_path,
    kb_doc = kb_doc_path,
    branch = branch,
  }
end

---pr_diff_commits collects commits and changed files for a multi-commit diffview (Action 2).
---@param repo table
---@param base_branch string
---@param pr_branch string
---@return table[] commits
function M.pr_diff_commits(repo, base_branch, pr_branch)
  local dir = repo.common_dir or repo.sample_worktree or repo.path
  if not dir then return {} end

  local range = string.format("%s..%s", base_branch, pr_branch)
  local log_out = vim.system({ "git", "-C", dir, "log", "--oneline", "--reverse", range }, { text = true }):wait()
  if log_out.code ~= 0 or not log_out.stdout or log_out.stdout == "" then return {} end

  local commits = {}
  local lines = vim.split(log_out.stdout, "\n", { trimempty = true })
  local core = pcall(require, "auto-core") and require("auto-core")
  for _, line in ipairs(lines) do
    local sha, subj = line:match("^(%x+)%s+(.*)$")
    if sha then
      local files = {}
      if core and core.git and core.git.log and core.git.log.commit_files then
        files = core.git.log.commit_files(repo.common_dir or dir, sha)
      else
        local diff_tree = vim.system({ "git", "-C", dir, "diff-tree", "--no-commit-id", "--name-status", "-r", sha }, { text = true }):wait()
        if diff_tree.code == 0 then
          for _, dt_line in ipairs(vim.split(diff_tree.stdout or "", "\n", { trimempty = true })) do
            local status, fpath = dt_line:match("^(%S+)%s+(.*)$")
            if status and fpath then
              table.insert(files, { path = fpath, status = status })
            end
          end
        end
      end
      table.insert(commits, {
        sha = sha,
        short = sha:sub(1, 7),
        subject = subj,
        files = files,
      })
    end
  end
  return commits
end

---find_for_worktree searches local KB PR documents and receipts for a PR matching a worktree branch.
---@param repo table
---@param wt table
---@return table? pr
function M.find_for_worktree(repo, wt)
  if not repo or not wt or not wt.branch then return nil end
  local slug = repo.slug
  if not slug then return nil end

  -- 1. Check if branch is named pr-<number>
  local pr_num_from_branch = wt.branch:match("^pr%-(%d+)$")

  -- 2. Scan shared/prs/<repo_slug>/
  local kb_root = vim.env.AUTO_AGENTS_KB_ROOT or vim.fn.expand("~/.config/nvim/.auto-agents-config/kb")
  local prs_dir = string.format("%s/shared/prs/%s", kb_root, slug)
  if vim.fn.isdirectory(prs_dir) == 1 then
    local files = vim.fn.globpath(prs_dir, "pr-*.md", false, true)
    for _, f in ipairs(files) do
      local lines = vim.fn.readfile(f, "", 30)
      local num, title, state, branch, draft
      local in_fm = false
      for _, l in ipairs(lines) do
        if l == "---" then
          if not in_fm then in_fm = true else break end
        elseif in_fm then
          local k, v = l:match("^([%w_]+):%s*(.*)$")
          if k == "number" then num = tonumber(v) or v
          elseif k == "title" then title = v:gsub('^"(.*)"$', "%1")
          elseif k == "state" then state = v
          elseif k == "branch" then branch = v
          elseif k == "draft" then draft = (v == "true")
          end
        end
      end
      if (branch and branch == wt.branch) or (pr_num_from_branch and tostring(num) == pr_num_from_branch) then
        return {
          number = num or pr_num_from_branch,
          title = title or ("PR #" .. tostring(num or pr_num_from_branch)),
          state = state or "open",
          draft = draft == true or state == "draft",
          branch = branch or wt.branch,
          kb_doc = f,
        }
      end
    end
  end

  -- If branch is pr-<num> but no KB doc yet, return a minimal stub
  if pr_num_from_branch then
    return {
      number = tonumber(pr_num_from_branch) or pr_num_from_branch,
      title = "PR #" .. pr_num_from_branch,
      state = "open",
      draft = false,
      branch = wt.branch,
    }
  end

  return nil
end

return M
