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
-- The registry mtime the mirror was built from. Another nvim writing the file
-- moves this, which is how we know the mirror went stale (ADR-0060 r1 MF1).
local _mtime_seen = nil

---_decode turns whatever is on disk into a set, tolerating absence and
---corruption: a broken watch file must not stop the panel from rendering, it
---just means nothing is watched yet.
local function _decode(data)
  local set = {}
  -- Shape: { paths = { "<abs>", ... } }. Accept a bare list too, so an
  -- older/hand-edited file still loads.
  local list = (type(data) == "table" and (data.paths or data)) or {}
  if type(list) == "table" then
    for _, p in ipairs(list) do
      if type(p) == "string" and p ~= "" then set[p] = true end
    end
  end
  return set
end

---_read_disk ALWAYS reads the file — no mirror, no latch. Every mutation must
---start here so it merges onto the current shared state rather than onto a
---snapshot that may be hours old.
---@return table set
local function _read_disk()
  local path = store.watches_path()
  local data, err = store.read_json(path)
  if err then
    local ok_log, log = pcall(require, "worktree.log")
    if ok_log then log.warn("watch", "watch registry unreadable, starting empty: " .. err) end
    return {}
  end
  return _decode(data)
end

---_load returns the render mirror, rebuilding it when the file has changed
---underneath us. Reads stay cheap in the common case (one `fs_stat`), but a
---watch another instance added still becomes visible without a restart.
local function _load()
  local mt = store.mtime(store.watches_path())
  if _watched and mt == _mtime_seen then return _watched end
  _watched = _read_disk()
  _mtime_seen = mt
  return _watched
end

---_commit writes a set and re-points the mirror at what we just persisted.
---@param set table
---@return boolean ok, string? err
local function _commit(set)
  local paths = {}
  for p in pairs(set or {}) do paths[#paths + 1] = p end
  table.sort(paths)
  local ok, err = store.write_json(store.watches_path(), { paths = paths })
  if ok then
    _watched = set
    _mtime_seen = store.mtime(store.watches_path())
  end
  return ok, err
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
---Applies ONE key to the state currently on disk, under a lock, so a
---concurrent nvim's watches survive (r1 MF1). Publishes only after the write
---succeeds — a listener repainting a watch that was never persisted would show
---the user a state that vanishes on restart.
function M.set(path, on)
  local key = _norm(path)
  if not key then return false, "watch: no path" end
  local want = on and true or false

  local ok, err = store.with_lock(store.watches_path(), function()
    local set = _read_disk()          -- fresh, NOT the mirror
    if want then set[key] = true else set[key] = nil end
    return _commit(set)
  end)

  if not ok then
    -- Do not publish, and leave the mirror alone: the caller repaints from
    -- whatever is still true rather than from a change that did not land.
    return M.is_watched(key), err or "watch: write failed"
  end
  M._publish(key, want)
  return want, nil
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
---Prunes against the state on DISK, under the lock. Reading the mirror here was
---the worst instance of r1 MF1: prune both removes entries and rewrites the
---whole file, so a stale mirror deleted every watch another instance had added,
---triggered by no user action at all.
function M.prune()
  local uv = vim.uv or vim.loop
  local removed = 0

  store.with_lock(store.watches_path(), function()
    local set = _read_disk()
    for p in pairs(set) do
      if not uv.fs_stat(p) then set[p] = nil; removed = removed + 1 end
    end
    if removed > 0 then return _commit(set) end
    -- Nothing to write, but the mirror may still be stale — adopt what we read.
    _watched = set
    _mtime_seen = store.mtime(store.watches_path())
    return true
  end)

  return removed
end

---_reset_for_tests drops the in-memory mirror so the next read re-reads disk.
function M._reset_for_tests()
  _watched = nil
  _mtime_seen = nil   -- else _load() would keep a mirror it thinks is current
  _registered = false
end

return M
