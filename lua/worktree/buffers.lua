-- Buffer-state helpers used by the remove flow: detect unsaved edits in
-- files that live under the worktree being removed, and wipe dangling
-- buffers after a successful remove.

local git = require("worktree.git")

local M = {}

-- Call `fn(buf, abs_path)` for every buffer whose file lives inside `path`.
-- Matching is on fully-resolved absolute paths so relative buffer names line
-- up correctly.
function M.each_under(path, fn)
  local prefix = path .. "/"
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local abs = git.norm(name)
        if abs == path or abs:sub(1, #prefix) == prefix then
          fn(buf, abs)
        end
      end
    end
  end
end

-- `git status` only sees the disk. Nvim's modified flag catches unsaved
-- edits that would be silently lost on removal.
function M.modified_under(path)
  local dirty = {}
  M.each_under(path, function(buf, abs)
    if vim.bo[buf].modified then table.insert(dirty, abs) end
  end)
  return dirty
end

-- Force-close buffers inside `path`. Without this, buffers linger after the
-- on-disk files are gone and explode on focus/save.
function M.wipe_under(path)
  local count = 0
  M.each_under(path, function(buf)
    if pcall(vim.api.nvim_buf_delete, buf, { force = true }) then
      count = count + 1
    end
  end)
  return count
end

-- True when the buffer is backed by a real file on disk (excludes help,
-- terminal, neo-tree panels, dap-view panels, etc.).
local function is_file_buffer(buf)
  return vim.bo[buf].buftype == ""
end

local function under(abs, path)
  if abs == path then return true end
  return abs:sub(1, #path + 1) == path .. "/"
end

-- Return the first loaded file-buffer whose path is inside `new_path`.
-- Used as the landing spot for the current window when its buffer is about
-- to be closed.
function M.first_under(new_path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and is_file_buffer(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local abs = git.norm(name)
        if under(abs, new_path) then return buf end
      end
    end
  end
  return nil
end

-- Close every unmodified file-buffer whose path is under `old_path` but
-- NOT under `new_path` (so nested-switch edge cases where the new path is
-- a subdir of the old one don't nuke buffers that still belong).
-- Returns (closed_count, dirty_paths) -- dirty_paths is the list of
-- modified buffers we skipped so the caller can surface them to the user.
function M.close_between(old_path, new_path)
  if old_path == new_path then return 0, {} end
  local closed, dirty = 0, {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and is_file_buffer(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local abs = git.norm(name)
        if under(abs, old_path) and not under(abs, new_path) then
          if vim.bo[buf].modified then
            table.insert(dirty, abs)
          elseif pcall(vim.api.nvim_buf_delete, buf, { force = false }) then
            closed = closed + 1
          end
        end
      end
    end
  end
  return closed, dirty
end

-- True if the buffer currently displayed in `win` has a file path that's
-- under `old_path` but not under `new_path` (i.e. would be closed by
-- close_between). Lets the caller redirect focus BEFORE deletion so nvim
-- doesn't pick an arbitrary alternate buffer.
function M.win_is_stale(win, old_path, new_path)
  if not vim.api.nvim_win_is_valid(win) then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  if not is_file_buffer(buf) then return false end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then return false end
  local abs = git.norm(name)
  return under(abs, old_path) and not under(abs, new_path)
end

return M
