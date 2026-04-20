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

return M
