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

    -- Dead owner (ESRCH): fail closed. Automatic reclaim by pathname unlink is a
    -- check-then-act race (concurrency-testing §3, MF1). Manual operator recovery required.
    error(string.format(
      "worktree.pr: PR #%s review posting locked by dead/stale process PID %d (owner %s) on %s; automatic reclaim disabled. Manual recovery required (ensure quiescence: no active posters running for PR #%s, then remove %s or run :WorktreeRecoverPRLock)",
      tostring(pr_number), lock_data.pid, tostring(lock_data.owner_token), tostring(lock_data.host or my_host), tostring(pr_number), lock_path
    ))
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

---recover_lock explicitly removes a stale lock file after verifying the owner is dead (or forced).
---@param forge string
---@param repo_slug string
---@param pr_number integer|string
---@param opts table? { force: boolean? }
---@return boolean ok, string? err
function M.recover_lock(forge, repo_slug, pr_number, opts)
  opts = opts or {}
  local lock_path = M._lock_path(forge, repo_slug, pr_number)
  if vim.fn.filereadable(lock_path) ~= 1 then
    return true, nil
  end
  local ok_read, lines = pcall(vim.fn.readfile, lock_path)
  if not ok_read or not lines or #lines == 0 then
    if opts.force then
      pcall(vim.uv.fs_unlink, lock_path)
      return true, nil
    end
    return false, "unreadable lock file; specify force=true to delete"
  end
  local dok, lock_data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not dok or type(lock_data) ~= "table" or not lock_data.pid then
    if opts.force then
      pcall(vim.uv.fs_unlink, lock_path)
      return true, nil
    end
    return false, "malformed lock file; specify force=true to delete"
  end
  if not opts.force then
    local alive_ret = vim.uv.kill(lock_data.pid, 0)
    if alive_ret == 0 or alive_ret == true then
      return false, string.format("refusing to recover lock: process PID %d is still active on %s (use force to override)", lock_data.pid, tostring(lock_data.host or "localhost"))
    end
  end
  local ok_un = pcall(vim.uv.fs_unlink, lock_path)
  if ok_un then
    return true, nil
  else
    return false, "failed to unlink lock file"
  end
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

---lock_key derives the `(forge, slug)` pair that NAMES a PR's lock and receipt.
---
---Exported because a lock is only recoverable under the key it was taken with.
---`:WorktreeRecoverPRLock` built its own — `owner .. "/" .. name` — while
---`post_feedback` takes the lock under `repo.slug` (`owner__name`), so the
---command addressed a lock file that never existed and "recovered" nothing.
---One derivation, so the taker and the recoverer cannot disagree
---([[shared-resolver-single-source-of-truth]]).
---@param repo table?
---@param remote_info table?  an already-parsed `parse_remote` result, to avoid a second `git config`
---@return string forge, string slug
function M.lock_key(repo, remote_info)
  remote_info = remote_info
    or M.parse_remote(repo and (repo.url or _get_repo_remote_url(repo)) or "")
  local slug = (repo and repo.slug) or remote_info.repo
  if not slug or slug == "" then slug = "repo" end
  return remote_info.forge, slug
end

---get_pr fetches pull request metadata from the forge.
---@param repo table
---@param pr_number integer|string
---@param opts table?  { token: string? }  a already-resolved token, to avoid resolving twice
---@return table pr, string? err
function M.get_pr(repo, pr_number, opts)
  local remote_url = _get_repo_remote_url(repo)
  local remote_info = M.parse_remote(remote_url)
  -- `opts.token` lets a caller that has ALREADY resolved (associate) hand the
  -- token down rather than making the provider run a second time — a second
  -- `pass show` is a second GPG prompt (lector r0 P1-1, "resolve once").
  local token, terr = opts and opts.token, nil
  if not token then token, terr = credentials.resolve_token(repo.slug, remote_info.host) end
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
    base_sha = (data.base and data.base.sha) or "",
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
  local token, terr = credentials.resolve_token(repo.slug, remote_info.host)
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

-- ── where an association lives ────────────────────────────────
--
-- Four call sites now need the same three answers — which slug names this
-- repo's PR documents, which directory holds them, and which file is PR #N.
-- They were open-coded in `write_kb_doc` and `find_for_worktree` with the
-- kb-root fallback spelled slightly differently in each, and `associate` /
-- `dissociate` would have made a third and fourth copy. One derivation, so a
-- writer and a reader cannot disagree about where an association is
-- ([[shared-resolver-single-source-of-truth]]).

---kb_root resolves the knowledge-base root the PR documents live under.
---@return string
function M.kb_root()
  local r = vim.env.AUTO_AGENTS_KB_ROOT
  if r and r ~= "" then return r end
  return vim.fn.expand("~/.config/nvim/.auto-agents-config/kb")
end

---kb_slug names a repo's PR-document namespace.
---@param repo table?
---@return string
function M.kb_slug(repo)
  local s = repo and repo.slug
  if type(s) == "string" and s ~= "" then return s end
  return "repo"
end

---prs_dir is the directory holding every PR document for `repo`.
---@param repo table?
---@return string
function M.prs_dir(repo)
  return string.format("%s/shared/prs/%s", M.kb_root(), M.kb_slug(repo))
end

---kb_doc_path is the document that records PR #`number` for `repo`.
---@param repo table?
---@param number integer|string
---@return string
function M.kb_doc_path(repo, number)
  return string.format("%s/pr-%s.md", M.prs_dir(repo), tostring(number))
end

---read_kb_doc parses a PR document's frontmatter into a flat field table.
---
---Returns the RAW fields — no defaults applied. `find_for_worktree` owns the
---defaulting, because "no `state:` recorded" and "state is open" are different
---facts and only the consumer knows which it wants.
---@param path string
---@return table? fields   { number, title, state, branch, draft, base, base_sha }
function M.read_kb_doc(path)
  if vim.fn.filereadable(path) ~= 1 then return nil end
  local ok, lines = pcall(vim.fn.readfile, path, "", 30)
  if not ok or type(lines) ~= "table" then return nil end
  local f, in_fm = {}, false
  for _, l in ipairs(lines) do
    if l == "---" then
      if not in_fm then in_fm = true else break end
    elseif in_fm then
      local k, v = l:match("^([%w_]+):%s*(.*)$")
      local function unquote(s) return (s:gsub('^"(.*)"$', "%1")) end
      if k == "number" then f.number = tonumber(v) or v
      elseif k == "title" then f.title = unquote(v)
      elseif k == "state" then f.state = v
      elseif k == "branch" then f.branch = v
      elseif k == "draft" then f.draft = (v == "true")
      -- Accept both `base:` and the `base_ref:` some writers emit (B7).
      elseif k == "base" or k == "base_ref" then f.base = unquote(v)
      elseif k == "base_sha" then f.base_sha = unquote(v)
      end
    end
  end
  return f
end

---kb_docs lists every PR document for `repo`, parsed, as { path = …, fields = … }.
---@param repo table?
---@return table[]
function M.kb_docs(repo)
  local dir = M.prs_dir(repo)
  if vim.fn.isdirectory(dir) ~= 1 then return {} end
  local out = {}
  for _, p in ipairs(vim.fn.globpath(dir, "pr-*.md", false, true)) do
    local fields = M.read_kb_doc(p)
    if fields then out[#out + 1] = { path = p, fields = fields } end
  end
  return out
end

---write_kb_doc writes the KB PR document — the record that ASSOCIATES a PR
---with a branch (ADR-0083 §2.5, Action 1 step 3 and Action 6).
---
---This is the association itself, not a by-product of it. `find_for_worktree`
---knows a worktree is PR #N by exactly two facts: the branch is literally
---named `pr-<N>`, or a doc under `shared/prs/<slug>/` carries
---`branch: <that branch>`. A PR whose head is an ordinary branch name — every
---PR opened by `create_pr` — has only the second, so writing this doc is what
---makes the `[#N]` badge, `O`'s range diff, and a review's `pr` tag exist at
---all.
---
---ONE writer, because two would be two definitions of what an association is
---([[shared-resolver-single-source-of-truth]]). `fetch_and_create_worktree`
---and `create_pr` differ only in which branch heads the PR.
---@param repo table
---@param pr table      the forge PR record (see `get_pr`)
---@param branch string the LOCAL branch this PR is associated with
---@return string? path, string? err
function M.write_kb_doc(repo, pr, branch)
  if type(pr) ~= "table" or pr.number == nil then
    return nil, "write_kb_doc: a PR record with a number is required"
  end
  local path = M.kb_doc_path(repo, pr.number)
  local slug = M.kb_slug(repo)
  local content = table.concat({
    "---",
    "type: pr",
    string.format("repo: %s", slug),
    string.format("number: %s", tostring(pr.number)),
    string.format("title: %q", pr.title or ""),
    string.format("state: %s", pr.draft and "draft" or (pr.state or "open")),
    string.format("branch: %s", tostring(branch or "")),
    string.format("base: %s", pr.base_ref or "main"),
    string.format("base_sha: %s", pr.base_sha or ""),
    string.format("author: %s", pr.author or ""),
    string.format("created: %s", (pr.created_at ~= "" and pr.created_at) or os.date("%Y-%m-%d")),
    string.format("updated: %s", (pr.updated_at ~= "" and pr.updated_at) or os.date("%Y-%m-%d")),
    "---",
    "",
    string.format("# PR #%s — %s", tostring(pr.number), pr.title or ""),
    "",
    "## Description",
    pr.body or "",
    "",
  }, "\n")

  local ok_atomic, fs_atomic = pcall(require, "auto-core.fs.atomic")
  if ok_atomic and type(fs_atomic.write) == "function" then
    local wok, werr = fs_atomic.write(path, content, { mkdir = true })
    if not wok then return nil, tostring(werr or "atomic write failed") end
    return path, nil
  end
  local mkok = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")
  if not mkok then return nil, "could not create " .. vim.fs.dirname(path) end
  local wok = pcall(vim.fn.writefile, vim.split(content, "\n"), path)
  if not wok then return nil, "could not write " .. path end
  return path, nil
end

---create_pr creates a new pull request on the forge (Action 6).
---
---Returns a RESULT ENVELOPE (`{ ok, pr, kb_doc, branch, error }`), like its
---sibling actions `fetch_and_create_worktree` and `post_feedback` — not the
---`(value, err)` pair of the internal fetchers `get_pr` / `get_comments`.
---
---It always meant to: both call sites (`:WorktreeCreatePR` and auto-finder's
---`N`) read `res.ok` and `res.pr.number`, and auto-finder's own test mocked
---`{ ok = true, pr = { number = 99 } }`. The function returned `(pr, err)`
---instead, so `res.ok` was nil for a PR that had just been created — every
---successful create reported "could not create PR — unknown", and the mock
---meant no suite ever observed it ([[validate-the-verifier]]).
---@param repo table
---@param opts table { title: string, body: string, head: string, base: string, draft: boolean? }
---@return table result
function M.create_pr(repo, opts)
  opts = opts or {}
  local remote_url = _get_repo_remote_url(repo)
  local remote_info = M.parse_remote(remote_url)
  local token, terr = credentials.resolve_token(repo.slug, remote_info.host)
  if not token then return { ok = false, error = terr } end

  local head = opts.head
  local payload = vim.json.encode({
    title = opts.title or "PR",
    body = opts.body or "",
    head = head,
    base = opts.base or "main",
    draft = opts.draft == true,
  })

  local url = string.format("%s/repos/%s/%s/pulls", remote_info.api_base, remote_info.owner, remote_info.repo)
  local code, body = M._http_request("POST", url, token, payload)
  if code ~= 201 and code ~= 200 then
    return { ok = false, error = string.format(
      "failed to create PR, HTTP %d: %s", code, credentials.redact(body)) }
  end

  local dok, data = pcall(vim.json.decode, body)
  if not dok or type(data) ~= "table" then
    return { ok = false, error = "failed to parse created PR response JSON" }
  end

  -- The SAME projection `get_pr` returns, so the KB doc a created PR writes is
  -- indistinguishable from the one a fetched PR writes — base/base_sha/author
  -- were dropped here before, leaving `open_pr_diff` to fall back to "main".
  local pr = {
    number = data.number,
    title = data.title or "",
    body = data.body or "",
    state = data.state or "open",
    draft = data.draft == true,
    base_ref = (data.base and data.base.ref) or opts.base or "main",
    base_sha = (data.base and data.base.sha) or "",
    head_ref = (data.head and data.head.ref) or head or "",
    head_sha = (data.head and data.head.sha) or "",
    author = (data.user and data.user.login) or "",
    html_url = data.html_url or "",
    created_at = data.created_at or "",
    updated_at = data.updated_at or "",
    forge = remote_info.forge,
  }

  -- Associate the PR with the branch that heads it (Action 6: "on creation,
  -- instantiate the KB PR document"). Without this the PR exists on the forge
  -- and nowhere locally: no `[#N]` badge, no `S`, and every review drafted
  -- afterwards carries no `pr`, so it can never be submitted.
  --
  -- A failed write does NOT fail the action — the PR is already open, and
  -- reporting failure would invite a second create. It is returned instead, so
  -- the caller can say the association is missing and the user can re-run GetPR.
  local kb_doc, kberr = M.write_kb_doc(repo, pr, pr.head_ref ~= "" and pr.head_ref or head)

  return {
    ok = true,
    pr = pr,
    branch = pr.head_ref ~= "" and pr.head_ref or head,
    kb_doc = kb_doc,
    kb_doc_error = kberr,
  }
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
  local forge, slug = M.lock_key(repo, remote_info)

  -- Acquire exclusive lock with live-owner immunity
  local lock = M.acquire_lock(forge, slug, pr_number)

  local ok, err = pcall(function()
    local receipt = M.load_receipt(forge, slug, pr_number)
    -- Thread the HOST too (lector PR #23): review posting must honour the same
    -- slug -> host -> env chain as get/create/comments, or a shared github.com
    -- host profile works everywhere EXCEPT posting.
    local token, terr = credentials.resolve_token(slug, remote_info.host)
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

    -- Recompute a batch's aggregate state from its comments: committed only when
    -- EVERY finding it owns is posted. A committed batch that gains a new
    -- review's findings reopens to in_flight.
    local function reconcile_batch_state(rb)
      local all_posted = true
      for _, rc in pairs(rb.comments) do
        if rc.state ~= "posted" then all_posted = false; break end
      end
      if all_posted then
        rb.state = "committed"
        rb.committed_at = rb.committed_at or os.date("!%Y-%m-%dT%H:%M:%SZ")
      elseif rb.state == "committed" then
        rb.state = "in_flight"
      end
    end

    -- Process each commit batch. Batches are keyed by commit SHA, but a per-review
    -- submit (ADR-0083 r9) posts ONE review at a time and two distinct reviews can
    -- share a commit. So the batch is the UNION of every review's findings for
    -- that sha: this call's finding_ids are MERGED in, and "done" is judged
    -- against THIS call's finding_ids — never an aggregate "committed" a prior
    -- review set. (lector PR #45 MF1: keying by sha and skipping a committed batch
    -- silently dropped the second review while still returning ok=true. A
    -- finding_id is unique per (sha, review_doc, comment), so a new review's
    -- findings never collide with an already-posted one.)
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
        receipt.batches[sha] = receipt_batch
      end
      -- Merge THIS call's findings (new ones as in_flight).
      for _, c in ipairs(batch.comments) do
        if not receipt_batch.comments[c.finding_id] then
          receipt_batch.comments[c.finding_id] = {
            path = c.path, line = c.line, side = c.side, state = "in_flight",
          }
        end
      end
      M.save_receipt(forge, slug, pr_number, receipt)

      -- Is every finding in THIS call already posted? (Not: is the batch, in
      -- aggregate, committed.)
      local this_all_posted = true
      for _, c in ipairs(batch.comments) do
        if receipt_batch.comments[c.finding_id].state ~= "posted" then
          this_all_posted = false
          break
        end
      end

      if not this_all_posted then
        -- Step 4 pre-flight reconciliation against the remote.
        local remote_comments = M.get_comments(repo, pr_number)
        local remote_markers = {}
        for _, rc in ipairs(remote_comments or {}) do
          local marker = (rc.body or ""):match("<!%-%- worktree:finding_id=([^%s]+) %-%->")
          if marker then remote_markers[marker] = rc.id end
        end

        -- Only THIS call's not-yet-landed findings go on the wire.
        local pending_comments = {}
        for _, c in ipairs(batch.comments) do
          local rc = receipt_batch.comments[c.finding_id]
          if rc.state == "posted" then
            -- landed on a prior call; nothing to send
          elseif remote_markers[c.finding_id] then
            rc.remote_id = remote_markers[c.finding_id]
            rc.state = "posted"
          else
            local remote_body = string.format("%s\n\n<!-- worktree:finding_id=%s -->", c.body, c.finding_id)
            table.insert(pending_comments, {
              path = c.path, line = c.line, side = c.side,
              body = remote_body, finding_id = c.finding_id,
            })
          end
        end

        if #pending_comments > 0 then
          -- Step 2: Transmission via Header Config Transport.
          local review_payload = vim.json.encode({
            commit_id = sha,
            body = string.format("Review findings for %s", sha:sub(1, 7)),
            event = "COMMENT",
            comments = vim.tbl_map(function(pc)
              return { path = pc.path, line = pc.line, side = pc.side, body = pc.body }
            end, pending_comments),
          })

          local post_url = string.format("%s/repos/%s/%s/pulls/%s/reviews", remote_info.api_base, remote_info.owner, remote_info.repo, tostring(pr_number))
          local pcode, pbody = M._http_request("POST", post_url, token, review_payload)
          if pcode == 200 or pcode == 201 then
            -- Step 3: Post-Response Confirmation — mark the SENT findings posted.
            for _, pc in ipairs(pending_comments) do
              receipt_batch.comments[pc.finding_id].state = "posted"
            end
          else
            -- Reconcile to see what landed despite the error.
            local rem_after = M.get_comments(repo, pr_number)
            for _, rc in ipairs(rem_after or {}) do
              local marker = (rc.body or ""):match("<!%-%- worktree:finding_id=([^%s]+) %-%->")
              if marker and receipt_batch.comments[marker] then
                receipt_batch.comments[marker].remote_id = rc.id
                receipt_batch.comments[marker].state = "posted"
              end
            end
            reconcile_batch_state(receipt_batch)
            if receipt_batch.state ~= "committed" then receipt_batch.state = "indeterminate" end
            M.save_receipt(forge, slug, pr_number, receipt)
            error(string.format("post review failed with HTTP %d: %s", pcode, credentials.redact(pbody)))
          end
        end
      end

      reconcile_batch_state(receipt_batch)
      M.save_receipt(forge, slug, pr_number, receipt)
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

---review_posted answers whether a review's findings are all on the forge, read
---from the two-phase posting RECEIPT (ADR-0083 §2.6 Action 4, r9.3). The
---review's own JSON is an ADR-0067 immutable artifact and is NEITHER consulted
---nor written — the receipt is the mutable side-store that records posted state.
---
---A review is matched to its receipt entries by the `doc_name` segment of the
---finding_id (`<commit_sha>:<doc_name>:<comment_id>` — see post_feedback), which
---is the review's file name, exactly what the panel passes as `doc_name` when it
---posts. `doc_name` and `commit_sha` never contain a colon, so `:<doc_name>:` is
---an unambiguous marker of this review's findings inside a finding_id.
---
---Returns true only when the review HAS receipt entries AND every one is posted:
---a review nobody has submitted, or one only partially landed, is not "posted".
---@param repo table
---@param review table  a describe record (needs `.pr` and `.name`/`.path`)
---@return boolean posted
function M.review_posted(repo, review)
  if not (repo and review and review.pr) then return false end
  local remote_info = M.parse_remote(_get_repo_remote_url(repo))
  local slug = repo.slug or remote_info.repo
  local receipt = M.load_receipt(remote_info.forge, slug, review.pr)
  if type(receipt) ~= "table" or type(receipt.batches) ~= "table" then return false end
  local doc_name = review.name
    or (type(review.path) == "string" and review.path:match("[^/]+$")) or nil
  if not doc_name or doc_name == "" then return false end
  local needle = ":" .. doc_name .. ":"
  local found, all_posted = false, true
  for _, batch in pairs(receipt.batches) do
    if type(batch) == "table" and type(batch.comments) == "table" then
      for fid, c in pairs(batch.comments) do
        if type(fid) == "string" and fid:find(needle, 1, true) then
          found = true
          if not (type(c) == "table" and c.state == "posted") then all_posted = false end
        end
      end
    end
  end
  return found and all_posted
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
  --
  -- B5: check the RESULT. The original returned `{ ok = true }` unconditionally
  -- — it never re-checked `f_res.code` after the fallback refspec, and never
  -- checked `worktree add` / `checkout` at all — so the UI toasted "fetched PR
  -- #N" even when every git call failed.
  local fetch_ref = string.format("pull/%s/head:%s", tostring(pr_number), branch)
  local f_res = vim.system({ "git", "-C", dir, "fetch", "origin", fetch_ref }, { text = true }):wait()
  if f_res.code ~= 0 then
    -- Try forgejo / gitlab refspec fallback
    local alt_ref = string.format("refs/pull/%s/head:%s", tostring(pr_number), branch)
    f_res = vim.system({ "git", "-C", dir, "fetch", "origin", alt_ref }, { text = true }):wait()
  end
  if f_res.code ~= 0 then
    return { ok = false, error = string.format(
      "git fetch of PR #%s failed: %s", tostring(pr_number),
      vim.trim(f_res.stderr or f_res.stdout or "")) }
  end

  -- Refresh the base's remote-tracking ref while we are already on the network,
  -- so a later diff has a fresh `origin/<base>` (best-effort; the authoritative
  -- base_sha in the KB doc below is the real fix — B6/lector PR #22). A failure
  -- here is non-fatal: the fetch that matters (the PR head) already succeeded.
  if pr.base_ref and pr.base_ref ~= "" then
    pcall(function()
      vim.system({ "git", "-C", dir, "fetch", "origin",
        string.format("%s:refs/remotes/origin/%s", pr.base_ref, pr.base_ref) },
        { text = true }):wait()
    end)
  end

  -- 2. Add worktree — and CHECK it.
  local is_bare = repo.bare == true or (repo.common_dir and repo.common_dir:find("%.git$") and not repo.path)
  local wt_path
  local add_res
  if is_bare or repo.sample_worktree then
    local parent = vim.fs.dirname(dir)
    wt_path = parent .. "/" .. branch
    add_res = vim.system({ "git", "-C", dir, "worktree", "add", wt_path, branch }, { text = true }):wait()
  else
    wt_path = dir
    add_res = vim.system({ "git", "-C", dir, "checkout", branch }, { text = true }):wait()
  end
  if add_res.code ~= 0 then
    return { ok = false, error = string.format(
      "fetched PR #%s but could not check it out into a worktree: %s",
      tostring(pr_number), vim.trim(add_res.stderr or add_res.stdout or "")) }
  end

  -- 3. Associate: write shared/prs/<repo_slug>/pr-<number>.md. `pr.number` may
  -- be absent from a sparse forge response, so pin the number the caller asked
  -- for — the doc's filename and `number:` field must agree with it.
  local kb_doc, kberr = M.write_kb_doc(repo,
    vim.tbl_extend("force", pr, { number = pr.number or pr_number }), branch)

  return {
    ok = true,
    pr = pr,
    worktree_path = wt_path,
    kb_doc = kb_doc,
    kb_doc_error = kberr,
    branch = branch,
  }
end

---Resolve the base for a PR range, and range from the merge-base.
---
---Ground truth is the FORGE's base sha (`base_rev`), passed by a caller that
---queried the PR. It is authoritative, and it is USABLE locally in the common
---case: for a PR whose base has not advanced since the branch diverged, the
---base sha is an ancestor of the fetched head, so it is already present and
---`merge-base(base_rev, pr_branch)` needs no network.
---
---It is NOT universally local (lector PR #22 r1): if the base branch advanced
---AFTER the divergence, its tip sha is not in the PR head's history and may be
---absent until fetched. `_pr_range` handles that by checking `rev(base_rev)`
---first and, when the object is absent, degrading to the flagged best-effort
---(`stale = true`) rather than ranging against a sha git cannot resolve. The
---GetPR fetch refreshes `origin/<base>` for exactly this reason, so the tip is
---present after a fetch.
---
---Without it, the best LOCAL answer is a BEST EFFORT and is surfaced as such
---(second return `stale`). The old two-dot `local_base..pr_branch` inflated the
---range whenever the local base lagged the remote — the normal state in this
---shared bare-repo layout (peers push; nobody pulled) — listing the base's own
---catch-up commits as the PR's. `origin/<base>` + merge-base narrows that, but
---lector's counterexample (PR #22) is exact: local C1, origin/base C2, true
---base C3, PR=C3+F1 → `merge-base(origin/base, PR)=C2` still misreports C3. A
---remote-tracking ref nobody fetched is not ground truth, so this path returns
---`stale = true` and the caller should say so rather than trust the count.
---@param dir string  a directory git can resolve refs in
---@param base_branch string
---@param pr_branch string
---@param base_rev string?  the forge's authoritative base sha, when known
---@return string range      a `<rev>..<pr_branch>` range
---@return boolean stale     true when the range is a local best-effort (no base_rev)
local function _pr_range(dir, base_branch, pr_branch, base_rev)
  local function rev(ref)
    local o = vim.system({ "git", "-C", dir, "rev-parse", "--verify", "--quiet", ref },
      { text = true }):wait()
    return o.code == 0 and vim.trim(o.stdout or "") ~= "" and vim.trim(o.stdout) or nil
  end
  local function mbase(a, b)
    local o = vim.system({ "git", "-C", dir, "merge-base", a, b }, { text = true }):wait()
    return o.code == 0 and vim.trim(o.stdout or "") ~= "" and vim.trim(o.stdout) or nil
  end

  -- Authoritative path: the forge base sha, if we can resolve it locally.
  if type(base_rev) == "string" and base_rev ~= "" and rev(base_rev) then
    local mb = mbase(base_rev, pr_branch)
    return string.format("%s..%s", mb or base_rev, pr_branch), false
  end

  -- Best-effort local path: freshest available base ref, merge-base floor.
  local base_ref = rev("origin/" .. base_branch) and ("origin/" .. base_branch) or base_branch
  local mb = mbase(base_ref, pr_branch)
  return string.format("%s..%s", mb or base_ref, pr_branch), true
end

---pr_diff_commits collects commits and changed files for a multi-commit diffview (Action 2).
---@param repo table
---@param base_branch string
---@param pr_branch string
---@param opts table?  { base_rev: string? }  the forge's authoritative base sha
---@return table[] commits
---@return boolean stale  true when the range is a local best-effort (no base_rev)
function M.pr_diff_commits(repo, base_branch, pr_branch, opts)
  local dir = repo.common_dir or repo.sample_worktree or repo.path
  if not dir then return {}, false end

  local base_rev = type(opts) == "table" and opts.base_rev or nil
  local range, stale = _pr_range(dir, base_branch, pr_branch, base_rev)
  -- `--format=%H %s`, NOT `--oneline`.
  --
  -- `--oneline` implies `--abbrev-commit`, so `sha` came back abbreviated —
  -- while the very next line here computes `short = sha:sub(1, 7)`, which only
  -- makes sense if `sha` is full. Consumers took the field at its name:
  -- auto-core's `review.draft.scope` requires 40 hex and refuses anything
  -- shorter (two commits can share a prefix, and a colliding scope would
  -- silently merge two reviewers' drafts), so opening a range diff over a real
  -- repository died in `draft()` on the first commit.
  --
  -- This is the SAME defect v0.5.12 fixed in `graph.lua`, where gitgraph
  -- handed out a nine-character hash; that fix resolved the abbreviation at
  -- the consumer because gitgraph's output was not ours to change. Here the
  -- abbreviation is ours, and produced one line above where it is consumed, so
  -- it is fixed at the source instead — `short` is now a real abbreviation of
  -- a real sha rather than a truncation of a truncation (Johno, 2026-09-08).
  local log_out = vim.system({ "git", "-C", dir, "log", "--format=%H %s", "--reverse", range }, { text = true }):wait()
  if log_out.code ~= 0 or not log_out.stdout or log_out.stdout == "" then return {}, stale end

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
  return commits, stale
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

  -- 2. Scan shared/prs/<repo_slug>/. An EXPLICIT branch match wins over a
  -- match on the pr-<N> naming convention: when a branch called `pr-7` has
  -- been deliberately associated with #12, the document is the newer, more
  -- specific statement, and letting glob order decide between them made the
  -- badge depend on filesystem iteration.
  local by_name
  for _, doc in ipairs(M.kb_docs(repo)) do
    local d, f = doc.fields, doc.path
    local function hit()
      return {
        number = d.number or pr_num_from_branch,
        title = d.title or ("PR #" .. tostring(d.number or pr_num_from_branch)),
        state = d.state or "open",
        draft = d.draft == true or d.state == "draft",
        branch = d.branch or wt.branch,
        base = d.base,
        base_sha = (d.base_sha and d.base_sha ~= "") and d.base_sha or nil,
        kb_doc = f,
      }
    end
    if d.branch and d.branch == wt.branch then
      return hit()
    elseif pr_num_from_branch and tostring(d.number) == pr_num_from_branch then
      by_name = by_name or hit()
    end
  end
  if by_name then return by_name end

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

-- ── associate / dissociate (ADR-0083 r10.7) ───────────────────
--
-- Until now an association could only be MADE as a side effect of opening or
-- fetching a PR. A branch that already exists and already has a PR — the
-- common case after `gh pr create` outside nvim, after a rename, or after
-- someone else opened the PR — could be bound only by hand-editing the KB
-- document. These two verbs are that missing edge, and they go through
-- `write_kb_doc` so an association made here is the same artifact as one made
-- by GetPR.

---_branch_exists reports whether `branch` resolves in the repo.
---
---Checked because an association to a branch git cannot resolve is dead on
---arrival: the badge needs a worktree row to hang on, and there is none. A
---typo'd branch would otherwise write a document that silently matches
---nothing ([[prove-the-instrument-observes]] — a write that observes nothing
---is not a write worth reporting as success).
local function _branch_exists(repo, branch)
  local dir = repo and (repo.common_dir or repo.sample_worktree or repo.path)
  if not dir or not branch or branch == "" then return false end
  local o = vim.system({ "git", "-C", dir, "rev-parse", "--verify", "--quiet",
    "refs/heads/" .. branch }, { text = true }):wait()
  return o.code == 0 and vim.trim(o.stdout or "") ~= ""
end

---association_lock is the path serializing every association transition for
---one repo (lector r0 P1-3).
---
---`worktree.store.with_lock` is the project's supported locking boundary; this
---only names the resource. Scoped per REPO, not per document: a transition
---touches two documents (the incumbent it releases and the winner it writes),
---so a per-document lock would not make the pair atomic.
---@param repo table?
---@return string
function M.association_lock(repo)
  return M.prs_dir(repo) .. "/.association"
end

---_credential_state answers, structurally, what we may do about verification.
---
---"nil token" was treated as one state and is four: no profile at all, a
---configured env var that is unset, a configured command that failed, an empty
---provider result. ONLY the first justifies a stub — the rest mean
---verification was configured and did not work, and papering over that with a
---fictional record is worse than refusing (lector r0 P1-1).
---
---`credentials.describe` is the structured boundary: no message parsing, and
---it does not execute a provider, so asking costs nothing. The token is then
---resolved ONCE and handed to `get_pr`, rather than resolving twice.
---@param repo table
---@param host string?
---@return string state  "unconfigured" | "ready" | "unusable" | "error"
---@return string? token
---@return string? detail
local function _credential_state(repo, host)
  local d = credentials.describe(repo.slug, host)
  if not d.configured then
    return "unconfigured", nil, d.why
  end
  -- A configured provider may THROW (a non-allowlisted executable). That must
  -- become an envelope, not an escaping error: `associate` documents a result.
  local ok, token, terr = pcall(credentials.resolve_token, repo.slug, host)
  if not ok then
    return "error", nil, tostring(token)
  end
  if not token or token == "" then
    return "unusable", nil, tostring(terr or "the configured provider returned no token")
  end
  return "ready", token, nil
end

---associate binds `branch` to PR #`pr_number` by writing the KB PR document.
---
---Outcomes, and the difference between them is whether verification was
---CONFIGURED and whether it SUCCEEDED — never a guess, never message parsing:
---
---  * **no credential configured** — nothing could ask, so a minimal stub is
---    written and flagged `stub = true`. Refusing here would make the verb
---    useless exactly when the token guidance in `?` has not been followed.
---  * **configured and the forge confirms** — the full record, identical to
---    what GetPR would have written.
---  * **configured but unusable** (unset env var, failing or non-allowlisted
---    provider, network error, malformed response) — REFUSED, document
---    untouched. Verification was attempted and failed; a stub would paper
---    over it (lector r0 P1-1).
---  * **the forge denies** (404 included) — REFUSED, for the same reason.
---
---The whole scan → release → write transition runs under one per-repo
---association lock, because the one-branch-one-PR invariant is otherwise a
---check-then-write that two actors can both pass (lector r0 P1-3).
---
---Failures carry a `code` so a caller can branch on identity rather than on
---message text ([[error-identity-not-error-text]]).
---@param repo table
---@param branch string
---@param pr_number integer|string
---@param opts table?  { reassign: boolean?, allow_stub: boolean?, expect_incumbent: integer|string? }
---@return table result  { ok, pr?, kb_doc?, stub?, reason?, code?, error?, conflict? }
function M.associate(repo, branch, pr_number, opts)
  opts = opts or {}
  if not repo then return { ok = false, code = "no_repo", error = "associate: a repo is required" } end
  if type(branch) ~= "string" or branch == "" then
    return { ok = false, code = "no_branch", error = "associate: a branch name is required" }
  end
  local n = tonumber(pr_number)
  if not n or n ~= math.floor(n) or n <= 0 then
    return { ok = false, code = "bad_number",
      error = string.format("associate: '%s' is not a PR number", tostring(pr_number)) }
  end

  if not _branch_exists(repo, branch) then
    return { ok = false, code = "no_such_branch",
      error = string.format("associate: this repository has no branch '%s'", branch) }
  end

  local remote_info = M.parse_remote(_get_repo_remote_url(repo))
  local state, token, detail = _credential_state(repo, remote_info.host)
  if state == "unusable" then
    return { ok = false, code = "credential_unusable",
      error = string.format(
        "a credential is configured for this repository but could not be used: %s", tostring(detail)) }
  elseif state == "error" then
    return { ok = false, code = "credential_error",
      error = string.format("the configured credential provider failed: %s", tostring(detail)) }
  elseif state == "unconfigured" and opts.allow_stub == false then
    return { ok = false, code = "no_credential",
      error = "no credential profile resolved — register one with :WorktreeAuth set" }
  end

  -- Verify BEFORE taking the lock: the forge round trip is the slow part, and
  -- holding a lock across it would serialize every actor behind the network.
  local pr, reason, stub
  if state == "ready" then
    local ok_call, got, gerr = pcall(M.get_pr, repo, n, { token = token })
    if not ok_call then
      return { ok = false, code = "forge_error",
        error = string.format("the forge request for PR #%d failed: %s", n, tostring(got)) }
    end
    if not got then
      return { ok = false, code = "forge_refused",
        error = string.format("attempted verification of PR #%d failed: %s", n, tostring(gerr)) }
    end
    pr = got
    pr.number = pr.number or n
  else
    stub = true
    reason = "no credential profile resolved; wrote an unverified stub. "
      .. "Register a token with :WorktreeAuth set, then re-run to fill in "
      .. "title, state, base and base_sha."
    pr = { number = n, title = string.format("PR #%d", n), body = "",
           state = "open", draft = false, base_ref = "", base_sha = "", author = "" }
  end

  local store = require("worktree.store")
  local result = store.with_lock(M.association_lock(repo), function()
    -- BOTH endpoints, inside the lock. An association is a relation with two
    -- occupied ends: the branch may already name another PR, and the target
    -- document may already name another branch. Only the first was checked,
    -- so associating an already-owned PR silently stole it and overwrote its
    -- cached title/base/body with a stub (lector r0 P1-2).
    local source_conflict, target_conflict
    local target_doc
    for _, doc in ipairs(M.kb_docs(repo)) do
      local f = doc.fields
      if f.branch == branch and tostring(f.number) ~= tostring(n) then
        source_conflict = source_conflict or { number = f.number, kb_doc = doc.path }
      end
      if tostring(f.number) == tostring(n) then
        target_doc = doc
        if f.branch and f.branch ~= "" and f.branch ~= branch then
          target_conflict = { number = f.number, branch = f.branch, kb_doc = doc.path }
        end
      end
    end

    local conflict = source_conflict or target_conflict
    if conflict and not opts.reassign then
      return { ok = false, code = "conflict",
        conflict = {
          number = conflict.number,
          branch = target_conflict and target_conflict.branch or branch,
          kb_doc = conflict.kb_doc,
          kind = target_conflict and "target" or "source",
        },
        error = target_conflict
          and string.format("PR #%s is already associated with '%s' (%s)",
            tostring(target_conflict.number), tostring(target_conflict.branch), target_conflict.kb_doc)
          or string.format("'%s' is already associated with PR #%s (%s)",
            branch, tostring(source_conflict.number), source_conflict.kb_doc) }
    end

    -- Expected-state binding. A panel confirmation is authority over the
    -- incumbent the USER SAW; if another actor moved it while the prompt was
    -- open, the confirmation does not cover the new one (lector r0 P1-3).
    if opts.expect_incumbent ~= nil then
      local actual = conflict and conflict.number or nil
      if tostring(actual) ~= tostring(opts.expect_incumbent) then
        return { ok = false, code = "incumbent_drift",
          conflict = conflict,
          error = string.format(
            "the association changed while you were deciding: expected PR #%s, found %s",
            tostring(opts.expect_incumbent), actual and ("#" .. tostring(actual)) or "none") }
      end
    end

    if source_conflict then
      local cleared, cerr = M.set_kb_doc_branch(source_conflict.kb_doc, "")
      if not cleared then
        return { ok = false, code = "reassign_failed",
          error = string.format("could not release '%s' from PR #%s: %s",
            branch, tostring(source_conflict.number), tostring(cerr)) }
      end
    end

    -- An EXISTING target document holds real metadata — title, body, base_sha,
    -- and any prose a human added. Re-rendering it from a stub destroys all of
    -- that. When we could not verify, move only the `branch:` line.
    local kb_doc, werr
    if stub and target_doc then
      local moved, merr = M.set_kb_doc_branch(target_doc.path, branch)
      kb_doc, werr = moved and target_doc.path or nil, merr
      reason = "no credential profile resolved; re-pointed the existing PR #"
        .. tostring(n) .. " document without changing its recorded metadata."
    else
      kb_doc, werr = M.write_kb_doc(repo, pr, branch)
    end
    if not kb_doc then
      return { ok = false, code = "write_failed",
        error = string.format("could not write the association: %s", tostring(werr)) }
    end

    return { ok = true, pr = pr, kb_doc = kb_doc, branch = branch,
             stub = stub, reason = reason,
             reassigned_from = source_conflict and source_conflict.number or nil,
             took_from_branch = target_conflict and target_conflict.branch or nil }
  end)

  if type(result) ~= "table" then
    return { ok = false, code = "lock_failed",
      error = "could not take the association lock for this repository" }
  end
  return result
end

---set_kb_doc_branch rewrites one document's `branch:` line in place.
---
---In place, rather than re-rendering through `write_kb_doc`: the document also
---carries the PR's description and any prose a human added under it, and
---re-rendering from a parsed frontmatter would silently drop the body.
---@param path string
---@param branch string   "" to clear the association
---@return boolean ok, string? err
function M.set_kb_doc_branch(path, branch)
  if vim.fn.filereadable(path) ~= 1 then return false, "no such document: " .. tostring(path) end
  local ok_r, lines = pcall(vim.fn.readfile, path)
  if not ok_r or type(lines) ~= "table" then return false, "could not read " .. path end
  local in_fm, done = false, false
  for i, l in ipairs(lines) do
    if l == "---" then
      if not in_fm then in_fm = true else break end
    elseif in_fm and l:match("^branch:") then
      lines[i] = "branch: " .. tostring(branch or "")
      done = true
      break
    end
  end
  if not done then return false, "no `branch:` line in " .. path end

  local text = table.concat(lines, "\n") .. "\n"
  local ok_atomic, fs_atomic = pcall(require, "auto-core.fs.atomic")
  if ok_atomic and type(fs_atomic.write) == "function" then
    local wok, werr = fs_atomic.write(path, text, { mkdir = true })
    if not wok then return false, tostring(werr or "atomic write failed") end
    return true, nil
  end
  local ok_w = pcall(vim.fn.writefile, lines, path)
  if not ok_w then return false, "could not write " .. path end
  return true, nil
end

---dissociate releases `branch` from whatever PR currently claims it.
---
---It clears the document's `branch:` rather than deleting the document: the
---PR's title, base and description are still true, and a later re-associate
---should not have to re-fetch them. Deleting is the user's call, not ours.
---
---A branch LITERALLY named `pr-<N>` cannot be dissociated, because the name is
---itself the association (`find_for_worktree` rule 1). Saying so is the whole
---point — the alternative is a verb that reports success and changes nothing.
---@param repo table
---@param branch string
---@param opts table?  { expect_pr: integer|string? }  refuse if the incumbent drifted
---@return table result  { ok, kb_doc?, number?, code?, error? }
function M.dissociate(repo, branch, opts)
  opts = opts or {}
  if not repo then return { ok = false, code = "no_repo", error = "dissociate: a repo is required" } end
  if type(branch) ~= "string" or branch == "" then
    return { ok = false, code = "no_branch", error = "dissociate: a branch name is required" }
  end

  -- Same lock as `associate`: releasing is half of a re-point, and a release
  -- racing an association is the same check-then-write hole (lector r0 P1-3).
  local store = require("worktree.store")
  local result = store.with_lock(M.association_lock(repo), function()
    local claimed
    for _, doc in ipairs(M.kb_docs(repo)) do
      if doc.fields.branch == branch then
        claimed = { number = doc.fields.number, kb_doc = doc.path }
        break
      end
    end

    local by_name = branch:match("^pr%-(%d+)$")
    if by_name and not claimed then
      return { ok = false, code = "branch_name_association", number = tonumber(by_name),
        error = string.format(
          "'%s' is associated with PR #%s by its NAME, not by a document — "
          .. "rename the branch to release it", branch, by_name) }
    end

    if not claimed then
      return { ok = false, code = "not_associated",
        error = string.format("'%s' is not associated with a PR", branch) }
    end

    -- The confirmation the user answered named a SPECIFIC PR. If another actor
    -- installed a replacement association while the prompt was open, that
    -- answer does not authorize releasing the new one.
    if opts.expect_pr ~= nil and tostring(claimed.number) ~= tostring(opts.expect_pr) then
      return { ok = false, code = "incumbent_drift", number = claimed.number,
        error = string.format(
          "the association changed while you were deciding: you confirmed #%s, '%s' now holds #%s",
          tostring(opts.expect_pr), branch, tostring(claimed.number)) }
    end

    local ok_c, cerr = M.set_kb_doc_branch(claimed.kb_doc, "")
    if not ok_c then
      return { ok = false, code = "write_failed",
        error = string.format("could not release '%s': %s", branch, tostring(cerr)) }
    end

    -- Clearing the document does NOT win against rule 1. Say so rather than
    -- letting the badge reappear on the next repaint with no explanation.
    local residual = by_name and tonumber(by_name) or nil
    return { ok = true, kb_doc = claimed.kb_doc, number = claimed.number,
             still_named_pr = residual }
  end)

  if type(result) ~= "table" then
    return { ok = false, code = "lock_failed",
      error = "could not take the association lock for this repository" }
  end
  return result
end

return M
