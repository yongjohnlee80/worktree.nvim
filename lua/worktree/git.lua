-- Git-adjacent helpers. Pure shell wrappers + a porcelain parser. These
-- touch the filesystem but not the editor state.

local M = {}

function M.norm(path)
  return (vim.fn.fnamemodify(path, ":p"):gsub("/$", ""))
end

function M.is_git(path)
  -- `.git` as directory (regular repo / bare) OR file (linked worktree).
  return vim.fn.isdirectory(path .. "/.git") == 1
    or vim.fn.filereadable(path .. "/.git") == 1
end

-- Parse `git worktree list --porcelain` into a list of
-- { path, branch?, head?, bare?, detached? } records.
function M.parse_porcelain(lines)
  local out, cur = {}, nil
  local function flush()
    if cur and cur.path then table.insert(out, cur) end
    cur = nil
  end
  for _, line in ipairs(lines) do
    if line:match("^worktree ") then
      flush()
      cur = { path = line:sub(10) }
    elseif cur then
      local branch = line:match("^branch (.+)$")
      if branch then
        cur.branch = branch:gsub("^refs/heads/", "")
      elseif line:match("^HEAD ") then
        cur.head = line:sub(6, 13)
      elseif line == "bare" then
        cur.bare = true
      elseif line == "detached" then
        cur.detached = true
      end
    end
  end
  flush()
  return out
end

-- Walk `dir`'s immediate children, collect worktrees from every git-managed
-- child. Bare repos themselves are omitted; their linked worktrees are kept.
function M.collect_worktrees(dir)
  local seen, out = {}, {}

  local handle = vim.uv.fs_scandir(dir)
  if not handle then return out end

  while true do
    local name, t = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if (t == "directory" or t == "link") and not name:match("^%.") then
      local full = dir .. "/" .. name
      if M.is_git(full) then
        local lines = vim.fn.systemlist({
          "git", "-C", full, "worktree", "list", "--porcelain",
        })
        if vim.v.shell_error == 0 then
          for _, wt in ipairs(M.parse_porcelain(lines)) do
            if not wt.bare then
              wt.path = M.norm(wt.path)
              if not seen[wt.path] then
                seen[wt.path] = true
                table.insert(out, wt)
              end
            end
          end
        else
          -- Not a valid repo but .git entry exists — include as-is.
          local p = M.norm(full)
          if not seen[p] then
            seen[p] = true
            table.insert(out, { path = p })
          end
        end
      end
    end
  end

  table.sort(out, function(a, b) return a.path < b.path end)
  return out
end

function M.git_common_dir(path)
  local out = vim.fn.systemlist({
    "git", "-C", path, "rev-parse", "--path-format=absolute", "--git-common-dir",
  })
  if vim.v.shell_error ~= 0 or not out[1] or out[1] == "" then return nil end
  return (out[1]:gsub("/$", ""))
end

-- New worktrees are created as siblings of the common git dir.
--   /foo/repo/.bare  → container /foo/repo   → new wt at /foo/repo/<name>
--   /foo/repo/.git   → container /foo/repo   → new wt at /foo/repo/<name>
--   /foo/repo.git    → container /foo        → new wt at /foo/<name>
function M.repo_container(common)
  return vim.fn.fnamemodify(common, ":h")
end

function M.list_child_repos(dir)
  local repos = {}
  local handle = vim.uv.fs_scandir(dir)
  if not handle then return repos end
  while true do
    local name, t = vim.uv.fs_scandir_next(handle)
    if not name then break end
    if (t == "directory" or t == "link") and not name:match("^%.") then
      local full = dir .. "/" .. name
      if M.is_git(full) then
        table.insert(repos, { name = name, path = M.norm(full) })
      end
    end
  end
  table.sort(repos, function(a, b) return a.name < b.name end)
  return repos
end

function M.list_branches(repo_path)
  local lines = vim.fn.systemlist({
    "git", "-C", repo_path, "for-each-ref", "--format=%(refname:short)", "refs/heads",
  })
  if vim.v.shell_error ~= 0 then return {} end
  -- Float main/master to the top so the first choice is usually right.
  table.sort(lines, function(a, b)
    local function rank(s)
      if s == "main" then return 0 end
      if s == "master" then return 1 end
      return 2
    end
    local ra, rb = rank(a), rank(b)
    if ra ~= rb then return ra < rb end
    return a < b
  end)
  return lines
end

function M.has_uncommitted(worktree_path)
  local lines =
    vim.fn.systemlist({ "git", "-C", worktree_path, "status", "--porcelain" })
  return vim.v.shell_error == 0 and #lines > 0
end

-- `true` if a local branch with this exact name exists in the repo.
function M.local_branch_exists(repo_path, name)
  vim.fn.systemlist({
    "git", "-C", repo_path, "rev-parse", "--verify", "--quiet",
    "refs/heads/" .. name,
  })
  return vim.v.shell_error == 0
end

-- Path of the worktree currently checking out `branch`, if any. Git refuses
-- to check out the same branch in two worktrees, so this tells the caller
-- when a "use existing local branch" option is actually available.
function M.worktree_for_branch(repo_path, branch)
  local lines = vim.fn.systemlist({
    "git", "-C", repo_path, "worktree", "list", "--porcelain",
  })
  if vim.v.shell_error ~= 0 then return nil end
  for _, wt in ipairs(M.parse_porcelain(lines)) do
    if wt.branch == branch then return wt.path end
  end
  return nil
end

-- Remote-tracking branches whose short branch name exactly equals `name`,
-- across all remotes. Returns { { remote, ref } } where `ref` is the short
-- form like "origin/feature-x". Empty when no remote has the branch.
function M.find_remote_branches(repo_path, name)
  local lines = vim.fn.systemlist({
    "git", "-C", repo_path, "for-each-ref",
    "--format=%(refname:short)",
    "refs/remotes/",
  })
  if vim.v.shell_error ~= 0 then return {} end
  local matches = {}
  for _, line in ipairs(lines) do
    -- Remote names contain no slashes; branch names can. Anchor the remote
    -- at `[^/]+` and let the branch consume everything after the first `/`.
    local remote, branch = line:match("^([^/]+)/(.+)$")
    if remote and branch == name and not line:match("/HEAD$") then
      table.insert(matches, { remote = remote, ref = line })
    end
  end
  return matches
end

-- Run a git subcommand and return (exit_code, combined_output). Uses
-- vim.system so stderr is captured; systemlist swallows it.
function M.run(args)
  local res = vim.system(args, { text = true }):wait()
  return res.code, (res.stdout or "") .. (res.stderr or "")
end

-- Same as run() but pipes `stdin` into the subprocess. Used for plumbing
-- like `hash-object --stdin < /dev/null`.
function M.run_with_stdin(args, stdin)
  local res = vim.system(args, { text = true, stdin = stdin }):wait()
  return res.code, (res.stdout or "") .. (res.stderr or "")
end

-- Derive a repo name from a git URL or local path.
--   git@github.com:foo/bar.git     → bar
--   https://github.com/foo/bar.git → bar
--   https://github.com/foo/bar     → bar
--   /path/to/myrepo                → myrepo
-- The last run of chars that are neither `/` nor `:` is the segment.
function M.repo_name_from_url(url)
  local s = url:gsub("/+$", "")
  local name = s:match("[^/:]+$") or s
  return (name:gsub("%.git$", ""))
end

-- Symbolic HEAD (short form). Falls back to "main" if HEAD isn't resolvable,
-- e.g. a freshly-initialized repo with no commits.
function M.default_branch(repo_path)
  local head = vim.fn.systemlist({
    "git", "-C", repo_path, "symbolic-ref", "--short", "HEAD",
  })[1]
  if vim.v.shell_error == 0 and head and head ~= "" then return head end
  return "main"
end

return M
