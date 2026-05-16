---worktree.log — single-file logging surface for the plugin.
---
---Per ADR 0021 §6 (the "wrapper rule"), every auto-family plugin
---owns exactly one `lua/<plugin>/log.lua` that delegates to
---`auto-core.log`. Feature code in worktree.nvim calls THIS module;
---feature code MUST NOT `require("auto-core").log` directly.
---
---worktree.nvim's pre-ADR-0021 pattern routed everything through
---two local `notify()` helpers (one in init.lua, one in graph.lua).
---Both now delegate to this wrapper; their callers don't change.
---
---@module 'worktree.log'

local core_log
do
  local ok, core = pcall(require, "auto-core")
  if ok and type(core) == "table" and type(core.log) == "table" then
    core_log = core.log
  end
end

local NS = "worktree"

local M = {}

-- Re-export the level table for callers that need to compare
-- numeric levels (e.g. `level or M.levels.INFO`).
M.levels = core_log and core_log.levels or {
  ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4, TRACE = 5,
}

---Prefix `component` with `worktree.` so logs are namespaced
---under the family root. Idempotent — already-prefixed strings
---pass through unchanged.
---@param component any
---@return string
local function ns(component)
  if type(component) ~= "string" or component == "" then
    return NS
  end
  if component == NS or component:sub(1, #NS + 1) == (NS .. ".") then
    return component
  end
  return NS .. "." .. component
end

---When the first arg isn't a string, treat it as a message part
---with no explicit component and fall back to the bare worktree
---namespace.
---@param level_fn function?
---@param fallback_pcall function?  -- pre-auto-core fallback for vim.notify
---@param fallback_level integer
---@param component any
---@param ... any
local function level_call(level_fn, fallback_pcall, fallback_level, component, ...)
  if level_fn then
    if type(component) ~= "string" then
      level_fn(NS, component, ...)
    else
      level_fn(ns(component), ...)
    end
    return
  end
  -- Pre-auto-core fallback. vim.notify accepts (msg, level, opts).
  -- We collapse all parts into a single message string via tostring.
  local parts = type(component) == "string"
    and { ... } or { component, ... }
  local out = {}
  for i, p in ipairs(parts) do
    if type(p) == "table" or type(p) == "boolean" then
      out[i] = vim.inspect(p)
    else
      out[i] = tostring(p)
    end
  end
  fallback_pcall(table.concat(out, " "), fallback_level)
end

-- vim.notify fallback used when auto-core isn't loaded. Honors the
-- user's `notify_title` config when available (parity with the
-- legacy init.lua / graph.lua helpers).
local function _legacy_notify(msg, level)
  local title
  local ok, cfg = pcall(require, "worktree.config")
  if ok and cfg.options and cfg.options.notify_title then
    title = cfg.options.notify_title
  end
  vim.notify(msg, level or vim.log.levels.INFO, title and { title = title } or nil)
end

function M.error(component, ...)
  level_call(core_log and core_log.error, _legacy_notify, vim.log.levels.ERROR, component, ...)
end
function M.warn(component, ...)
  level_call(core_log and core_log.warn, _legacy_notify, vim.log.levels.WARN, component, ...)
end
function M.info(component, ...)
  level_call(core_log and core_log.info, _legacy_notify, vim.log.levels.INFO, component, ...)
end
function M.debug(component, ...)
  level_call(core_log and core_log.debug, _legacy_notify, vim.log.levels.DEBUG, component, ...)
end
function M.trace(component, ...)
  level_call(core_log and core_log.trace, _legacy_notify, vim.log.levels.TRACE, component, ...)
end

---Force-toast single emission. Ring + vim.notify regardless of
---severity default. Pre-auto-core fallback uses bare vim.notify.
---@param msg any
---@param opts table?
function M.notify(msg, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.component ~= nil then opts.component = ns(opts.component) end
  if core_log and type(core_log.notify) == "function" then
    return core_log.notify(msg, opts)
  end
  -- Legacy fallback: route via vim.notify directly.
  local level = opts.level or vim.log.levels.INFO
  if type(level) == "string" then
    local map = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 }
    level = map[level] or vim.log.levels.INFO
  end
  _legacy_notify(tostring(msg), level)
end

---Ring write + conditional toast. Toasts iff `event` is in the
---user's subscribed set. Auto-prefixes bare event names with the
---plugin namespace.
---@param event string
---@param msg any
---@param opts table?
function M.notifyIf(event, msg, opts)
  opts = vim.tbl_extend("force", {}, opts or {})
  if opts.component ~= nil then opts.component = ns(opts.component) end
  local fq_event = event
  if type(event) == "string"
      and event ~= NS
      and event:sub(1, #NS + 1) ~= (NS .. ".") then
    fq_event = NS .. "." .. event
  end
  if core_log and type(core_log.notifyIf) == "function" then
    return core_log.notifyIf(fq_event, msg, opts)
  end
  -- Soft-dep fallback: ring-only via M.info.
  return M.info(opts.component, msg)
end

---Declare the events this plugin emits. Auto-prefixes via
---`auto-core.log.events.register`. Idempotent.
---@param events string|string[]
function M.register_events(events)
  if not core_log or type(core_log.events) ~= "table"
      or type(core_log.events.register) ~= "function" then
    return
  end
  return core_log.events.register(NS, events)
end

return M
