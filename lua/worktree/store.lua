---worktree.store — the per-repo persistent store.
---
---ADR-0060 P3 §2.7. worktree.nvim had exactly one persistence mechanism:
---`session.lua`, a hashed JSON file per **cwd** holding a buffer list. Reviews
---and watches are neither cwd-scoped nor a single blob:
---
---  * a review belongs to a COMMIT, which belongs to a REPO — not to whichever
---    worktree happened to be current when it was written;
---  * there are many review files per repo, each independently named so it can
---    be applied systematically (§2.6), so `auto-core.state.namespace` is the
---    wrong shape: it stores one table per namespace.
---
---So this module owns a directory layout keyed by repo SLUG:
---
---    $XDG_STATE_HOME/nvim/worktree.nvim/
---      reviews/<owner>__<repo>/<owner>__<repo>@<short-sha>.r<N>.review.json
---      watches.json
---
---Every write goes through `auto-core.fs.atomic.write` (temp → fsync →
---rename), the same primitive `session.lua` and the `.git` gitfile writer use:
---a half-written review file that still parses as JSON is worse than none.
---@module 'worktree.store'

local M = {}

local uv = vim.uv or vim.loop

---root is the store's base directory. Overridable for tests only.
---@return string
function M.root()
  return M._root_override or (vim.fn.stdpath("state") .. "/worktree.nvim")
end

---_root_override lets the smoke suite point the store at a temp dir without
---touching the user's real state.
M._root_override = nil

---slug turns a repo identity into a filesystem-safe `<owner>__<repo>`.
---
---Accepts anything that names a repo: an SSH remote, an HTTPS remote, or a
---bare local path. A local repo with no remote still needs a stable key, so it
---falls back to the directory name — and the result is sanitised, because this
---string becomes a PATH SEGMENT and must never be able to escape the store.
---@param identity string   remote url, or a filesystem path
---@return string slug
function M.slug(identity)
  local s = tostring(identity or "")
  -- Order matters: strip trailing slashes FIRST. `…/r.git/` would otherwise
  -- keep its `.git` (it is not at the end), the dot would sanitise to `-`, and
  -- the same repo would key to `o__r-git` with a slash and `o__r` without —
  -- splitting one repo's reviews across two directories.
  s = s:gsub("/+$", ""):gsub("%.git$", ""):gsub("/+$", "")
  local owner, repo

  -- git@host:owner/repo  |  ssh://git@host/owner/repo  |  https://host/owner/repo
  owner, repo = s:match("[:/]([^:/]+)/([^:/]+)$")
  if not owner then
    -- A single-segment name with no separator at all. Use it as the repo and
    -- mark the owner `local` so it cannot collide with a hosted `x/<name>`.
    repo = s:match("([^/\\]+)$") or "repo"
    owner = "local"
  end
  -- NOTE for a local PATH the two trailing segments become owner/repo — e.g.
  -- `/home/j/Source/nvim-plugins/autodb` -> `nvim-plugins__autodb`. That is
  -- deliberate: it is stable, descriptive, and keeps two same-named repos in
  -- different parents distinct, which a flat `local__autodb` would not.

  local function clean(part)
    -- Anything that is not clearly safe becomes `-`. This is the guard that
    -- makes the slug usable as a path segment: no `.`, `/`, `\` or NUL can
    -- survive, so `..` traversal is impossible by construction.
    return (tostring(part):gsub("[^%w%-_]", "-"))
  end
  return clean(owner) .. "__" .. clean(repo)
end

---remote_slug resolves a repo's slug from its own git config, falling back to
---the common dir's name when the repo has no `origin`.
---@param common_dir string
---@return string slug, string? url
function M.remote_slug(common_dir)
  if not common_dir or common_dir == "" then return M.slug("repo"), nil end
  local res = vim.system(
    { "git", "--git-dir=" .. common_dir, "config", "--get", "remote.origin.url" },
    {}):wait()
  local url = vim.trim((res.stdout or ""))
  if res.code == 0 and url ~= "" then return M.slug(url), url end
  -- No remote: key off the repo container. A bare repo's common dir is the
  -- repo itself (`…/autodb`), a checkout's is `…/autodb/.git`.
  local dir = common_dir:gsub("/%.git/?$", "")
  return M.slug(dir), nil
end

---ensure_dir creates `path` with owner-only permissions and reports success.
---0700 because a review can quote source, and the watch list reveals what a
---user is working on — neither belongs to the group.
---@param path string
---@return boolean
function M.ensure_dir(path)
  if not path or path == "" then return false end
  if uv.fs_stat(path) then return true end
  return vim.fn.mkdir(path, "p", tonumber("700", 8)) == 1
end

---write_json atomically serialises `value` to `path`.
---@param path string
---@param value any
---@return boolean ok, string? err
function M.write_json(path, value)
  if not path or path == "" then return false, "no path" end
  local ok_enc, encoded = pcall(vim.json.encode, value)
  if not ok_enc then return false, "encode failed: " .. tostring(encoded) end
  if not M.ensure_dir(vim.fn.fnamemodify(path, ":h")) then
    return false, "could not create " .. vim.fn.fnamemodify(path, ":h")
  end
  local ok_atomic, atomic = pcall(require, "auto-core.fs.atomic")
  if ok_atomic and type(atomic.write) == "function" then
    local wok = atomic.write(path, encoded)
    if not wok then return false, "atomic write failed" end
    return true, nil
  end
  -- auto-core is a hard dependency, so this path is a defensive fallback for a
  -- version older than the atomic primitive (>= 0.1.58).
  local fd = io.open(path, "w")
  if not fd then return false, "could not open " .. path end
  fd:write(encoded); fd:close()
  return true, nil
end

---read_json reads and decodes, returning nil for "absent" and an error string
---only for "present but unreadable". A caller must be able to tell a fresh
---install from a corrupt file.
---@param path string
---@return any? value, string? err
function M.read_json(path)
  if not path or path == "" then return nil, "no path" end
  if not uv.fs_stat(path) then return nil, nil end
  local ok_read, lines = pcall(vim.fn.readfile, path)
  if not ok_read then return nil, "unreadable: " .. path end
  local ok_dec, value = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not ok_dec then return nil, "malformed json: " .. path end
  return value, nil
end

---reviews_dir is where a repo's review files live.
---@param slug string
---@return string
function M.reviews_dir(slug)
  return M.root() .. "/reviews/" .. tostring(slug)
end

---watches_path is the single persisted watch registry.
---@return string
function M.watches_path()
  return M.root() .. "/watches.json"
end

---list_files returns the names in `dir` matching an optional Lua pattern,
---sorted. A missing directory is empty, not an error.
---@param dir string
---@param pattern string?
---@return string[]
function M.list_files(dir, pattern)
  local out = {}
  local handle = uv.fs_scandir(dir or "")
  if not handle then return out end
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then break end
    if typ ~= "directory" and (not pattern or name:match(pattern)) then
      out[#out + 1] = name
    end
  end
  table.sort(out)
  return out
end

---_reset_for_tests clears the root override.
function M._reset_for_tests() M._root_override = nil end

return M
