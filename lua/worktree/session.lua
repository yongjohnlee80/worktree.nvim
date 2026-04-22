-- Lightweight per-worktree buffer tracking. Replaces the v0.3.0
-- persistence.nvim integration, which used `:source session.vim` to
-- restore state and clobbered ad-hoc panels (neo-tree, terminals,
-- dap-view) on every worktree switch.
--
-- Instead of a full session, we persist just the list of normal file-
-- buffers that lived under each worktree. On return:
--   * every saved file is `:badd`ed so it shows up in the buffer list
--     (picker, :bnext/:bprev, etc.)
--   * if the current window is a blank no-name buffer -- which is what
--     cleanup_on_switch leaves you on when the new worktree has no
--     existing open files -- the saved "focused" file is `:edit`ed into
--     it so you land on your last-active file
--   * nothing else touches window layout, so your neo-tree + terminals +
--     dap-view stay exactly where they are

local git = require("worktree.git")

local M = {}

local uv = vim.uv or vim.loop

local function sessions_dir()
  return vim.fn.stdpath("state") .. "/worktree-sessions"
end

local function session_path(cwd)
  local hash = vim.fn.sha256(cwd):sub(1, 16)
  return sessions_dir() .. "/" .. hash .. ".json"
end

-- Is `buf` a normal on-disk file buffer worth remembering? Filters out
-- terminals, help, quickfix, neo-tree panels, dap-view, plain :enew, etc.
local function is_tracked(buf)
  if not vim.api.nvim_buf_is_loaded(buf) then return false end
  if vim.bo[buf].buftype ~= "" then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return false end
  -- On-disk file check avoids stale paths whose file was deleted.
  return vim.fn.filereadable(name) == 1
end

--- Snapshot file-buffer paths that live inside `cwd`, plus the currently
--- focused file if it's inside `cwd`. Writes JSON atomically. Returns
--- (ok, count).
---@param cwd string  absolute path to the worktree (current cwd at call time)
---@return boolean, integer
function M.save(cwd)
  cwd = git.norm(cwd)
  local prefix = cwd .. "/"
  local files = {}
  local seen = {}

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if is_tracked(buf) then
      local abs = git.norm(vim.api.nvim_buf_get_name(buf))
      if (abs == cwd or abs:sub(1, #prefix) == prefix) and not seen[abs] then
        seen[abs] = true
        table.insert(files, abs)
      end
    end
  end

  -- Focused file is only restored if it's inside this worktree.
  local focused_buf = vim.api.nvim_get_current_buf()
  local focused = nil
  if is_tracked(focused_buf) then
    local abs = git.norm(vim.api.nvim_buf_get_name(focused_buf))
    if abs == cwd or abs:sub(1, #prefix) == prefix then
      focused = abs
    end
  end

  vim.fn.mkdir(sessions_dir(), "p")
  local path = session_path(cwd)
  local f, err = io.open(path, "w")
  if not f then return false, 0 end
  f:write(vim.json.encode({ cwd = cwd, buffers = files, focused = focused }))
  f:close()
  return true, #files
end

--- Restore the saved buffer list for `cwd`. Does NOT replace window
--- layout -- neo-tree, terminals, etc. stay intact. Returns (ok, count).
--- `ok` is false when no session exists yet; count is how many buffers
--- were actually added (files that no longer exist are silently skipped).
---@param cwd string  absolute path to the worktree (new cwd after :cd)
---@return boolean, integer
function M.load(cwd)
  cwd = git.norm(cwd)
  local path = session_path(cwd)
  local f = io.open(path, "r")
  if not f then return false, 0 end
  local content = f:read("*a")
  f:close()

  local ok, data = pcall(vim.json.decode, content)
  if not ok or type(data) ~= "table" or type(data.buffers) ~= "table" then
    return false, 0
  end

  -- If the current window is a blank no-name buffer (what cleanup_on_switch
  -- lands us on when the new worktree has no buffers yet), upgrade it to
  -- the focused file so the user doesn't have to :bnext to see anything.
  local current_name = vim.api.nvim_buf_get_name(0)
  if current_name == "" and data.focused
    and vim.fn.filereadable(data.focused) == 1
  then
    pcall(vim.cmd, "silent! edit " .. vim.fn.fnameescape(data.focused))
  end

  -- :badd every saved buffer. :badd is a no-op when the buffer is already
  -- open, so the focused :edit above doesn't create duplicates.
  local count = 0
  for _, file in ipairs(data.buffers) do
    if vim.fn.filereadable(file) == 1 then
      pcall(vim.cmd, "silent! badd " .. vim.fn.fnameescape(file))
      count = count + 1
    end
  end
  return true, count
end

--- Delete the saved session for `cwd`. Used when a worktree is removed
--- via `:WorktreeRemove` so stale session files don't pile up.
---@param cwd string
function M.forget(cwd)
  local path = session_path(git.norm(cwd))
  if uv.fs_stat(path) then pcall(os.remove, path) end
end

return M
