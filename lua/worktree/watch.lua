---worktree.watch — the persisted watch registry.
---
---ADR-0060 §2.3. This is the load-bearing performance decision of the repos
---panel: commit children are computed **only for a watched worktree**. An
---unwatched worktree costs one `parse_porcelain` line — no `git log`, no
---`git status`, no watcher. Contrast the panel this replaces, which gave every
---repo an fs_event and ran a blocking `git status` per worktree on every
---navigate.
---
---Watches PERSIST across restarts (Johno, 2026-08-22) — a worktree you are
---working in stays watched — so the registry is a small JSON file rather than
---session state.
---
---Keyed by absolute worktree PATH, not by branch: a branch can be checked out
---somewhere else tomorrow, and the thing being watched is the working copy.
---@module 'worktree.watch'

local store = require("worktree.store")

local M = {}

-- In-memory mirror so a render pass never hits the disk. nil = not loaded yet.
local _watched = nil

---_load reads the registry once, tolerating absence and corruption: a broken
---watch file must not stop the panel from rendering, it just means nothing is
---watched yet.
local function _load()
  if _watched then return _watched end
  _watched = {}
  local data, err = store.read_json(store.watches_path())
  if err then
    local ok_log, log = pcall(require, "worktree.log")
    if ok_log then log.warn("watch", "watch registry unreadable, starting empty: " .. err) end
    return _watched
  end
  -- Shape: { paths = { "<abs>", ... } }. Accept a bare list too, so an
  -- older/hand-edited file still loads.
  local list = (type(data) == "table" and (data.paths or data)) or {}
  if type(list) == "table" then
    for _, p in ipairs(list) do
      if type(p) == "string" and p ~= "" then _watched[p] = true end
    end
  end
  return _watched
end

local function _flush()
  local paths = {}
  for p in pairs(_watched or {}) do paths[#paths + 1] = p end
  table.sort(paths)
  return store.write_json(store.watches_path(), { paths = paths })
end

---_norm normalises a worktree path so `/x` and `/x/` are one key.
local function _norm(path)
  if not path or path == "" then return nil end
  local ok, git = pcall(require, "worktree.git")
  if ok and type(git.norm) == "function" then return git.norm(path) end
  return (tostring(path):gsub("/+$", ""))
end

---is_watched reports whether a worktree's commits should be listed.
---@param path string
---@return boolean
function M.is_watched(path)
  local key = _norm(path)
  if not key then return false end
  return _load()[key] == true
end

---list returns every watched path, sorted.
---@return string[]
function M.list()
  local out = {}
  for p in pairs(_load()) do out[#out + 1] = p end
  table.sort(out)
  return out
end

---set turns a watch on or off and persists immediately.
---
---Persisting on every toggle rather than at exit is deliberate: a crash must
---not silently forget what the user asked to watch, and the file is tiny.
---@param path string
---@param on boolean
---@return boolean watched, string? err
function M.set(path, on)
  local key = _norm(path)
  if not key then return false, "watch: no path" end
  _load()
  if on then _watched[key] = true else _watched[key] = nil end
  local ok, err = _flush()
  M._publish(key, on and true or false)
  return on and true or false, (not ok) and err or nil
end

---toggle flips a worktree's watch and returns the new state.
---@param path string
---@return boolean watched, string? err
function M.toggle(path)
  return M.set(path, not M.is_watched(path))
end

---TOPIC is published whenever a watch changes, so an open panel re-renders the
---affected worktree without polling.
M.TOPIC = "worktree.watch:changed"

local _registered = false
function M._publish(path, watched)
  local ok, events = pcall(require, "auto-core.events")
  if not ok then return end
  if not _registered then
    _registered = true
    pcall(events.register_topics, "worktree", {
      [M.TOPIC] = {
        doc = "A worktree's watch was turned on or off (ADR-0060 §2.3).",
        payload = "{ path = string, watched = boolean }",
        publishers = { "worktree" },
      },
    })
  end
  pcall(events.publish, M.TOPIC, { path = path, watched = watched })
end

---prune drops watches whose worktree no longer exists on disk, so a removed
---worktree does not keep a dead entry forever. Returns how many went.
---@return integer removed
function M.prune()
  local uv = vim.uv or vim.loop
  local removed = 0
  _load()
  for p in pairs(_watched) do
    if not uv.fs_stat(p) then _watched[p] = nil; removed = removed + 1 end
  end
  if removed > 0 then _flush() end
  return removed
end

---_reset_for_tests drops the in-memory mirror so the next read re-reads disk.
function M._reset_for_tests()
  _watched = nil
  _registered = false
end

return M
