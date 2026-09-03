-- ADR-0081 AC1 — THE I/O CONTRACT CHECK.
--
-- AC1 asks for "a contract check over an enumerated list of production modules
-- and calls, not a blanket grep", because the rule it enforces is narrow:
-- **document** I/O for review artifacts and the review-draft store belongs to
-- auto-core. Repository, config and session I/O is explicitly NOT prohibited, so
-- a grep for `fs_write` would fail on code the ADR permits and teach everyone to
-- ignore it.
--
-- So this pins an INVENTORY: every raw filesystem call in worktree's production
-- code, counted per file, each file classified as `delegate` (must reach zero by
-- P6) or `permitted` (out of AC1's scope, with the reason). It fails when a count
-- changes in either direction:
--
--   * an INCREASE is new raw I/O, which is the thing the rule forbids;
--   * a DECREASE means a phase landed, and the pin must be updated in the same
--     commit — otherwise this file slowly stops describing reality, which is how
--     a contract check becomes decoration.
--
-- Counts, not line numbers: line numbers drift on every unrelated edit, and a
-- check that cries wolf is a check people delete.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

-- ── THE PINNED INVENTORY (2026-09-03, before P4a) ──
--
-- `scope`:
--   "delegate"  — document I/O that ADR-0081 moves to auto-core. P4a/P4c/P6
--                 drive these to zero; the `phase` says which one owns it.
--   "permitted" — outside AC1's scope. `why` must say what kind of I/O it is,
--                 because "permitted" with no reason is how scope creeps.
local INVENTORY = {
  ["store.lua"] = {
    scope = "delegate", phase = "P4a",
    why = "the leaf persistence layer; becomes a thin delegation to auto-core.docstore",
    calls = {
      fs_stat = 5, fs_open = 2, fs_write = 2, fs_close = 3, fs_unlink = 4,
      fs_fstat = 1, fs_fsync = 1, fs_link = 1, fs_scandir = 1,
      fs_scandir_next = 1, ["io.open"] = 2, mkdir = 1,
    },
  },
  ["review.lua"] = {
    scope = "delegate", phase = "P4c",
    why = "review-document mechanics: the pair's stats, unlinks and the rename",
    calls = { fs_stat = 5, fs_unlink = 2 },
  },
  ["init.lua"] = {
    scope = "delegate", phase = "P6",
    why = "a LOCAL atomic-write fallback duplicating auto-core.fs.atomic (AC6: no local duplicate)",
    calls = { ["io.open"] = 1 },
  },
  ["watch.lua"] = {
    scope = "permitted", phase = nil,
    why = "REPOSITORY I/O: prune stats each watched WORKTREE PATH to drop entries whose"
      .. " directory is gone. Not a document. The watch registry's own reads and writes"
      .. " already go through store.with_lock, which P4a delegates.",
    calls = { fs_stat = 1 },
  },
  ["session.lua"] = {
    scope = "permitted", phase = nil,
    why = "SESSION STATE: the panel's cwd/buffers/focused snapshot, not a review artifact"
      .. " and not the review-draft store. Whether the family's session state should also"
      .. " move to auto-core is a separate decision, deliberately not folded into ADR-0081.",
    calls = { fs_stat = 1, ["io.open"] = 2, mkdir = 1 },
  },
}

-- ── SCAN ──
---_scan_file counts raw I/O calls in one file.
local function _scan_file(path)
  local counts = {}
  local fd = io.open(path, "r")
  if not fd then return nil end
  local src = fd:read("*a") or ""
  fd:close()
  local function bump(name) counts[name] = (counts[name] or 0) + 1 end
  -- libuv filesystem calls, through any of the three spellings. NO trailing
  -- `(` is required: `pcall(uv.fs_close, fd)` passes the function by reference
  -- and is every bit as much an I/O call site. Requiring the paren silently
  -- missed six of them here, and the pin built from a paren-requiring grep
  -- disagreed with the code -- which is how I found it.
  for name in src:gmatch("uv%.(fs_[%a_]+)") do bump(name) end
  for name in src:gmatch("vim%.loop%.(fs_[%a_]+)") do bump(name) end
  -- `vim.uv.fs_x(` also matches the `uv%.` pattern above (it ends in "uv."), so
  -- it is already counted; counting it again would double every such call.
  for _ in src:gmatch("io%.open%s*%(") do bump("io.open") end
  for _ in src:gmatch("vim%.fn%.mkdir%s*%(") do bump("mkdir") end
  for _ in src:gmatch("vim%.fn%.readfile%s*%(") do bump("readfile") end
  for _ in src:gmatch("vim%.fn%.writefile%s*%(") do bump("writefile") end
  return counts
end

print("[1] the scanner sees what a human sees")
-- A scanner nobody has checked is worse than no scanner: it reports "clean"
-- forever. These fixtures pin its behaviour, including the double-count trap.
do
  local tmp = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({
    "local uv = vim.uv or vim.loop",
    "uv.fs_stat(p)",
    "vim.uv.fs_stat(p)",      -- the same call spelled differently
    "vim.loop.fs_unlink(p)",
    "io.open(p, 'r')",
    "vim.fn.mkdir(d, 'p')",
    "-- uv.fs_write(fd) in a comment still counts; a scanner that parses Lua",
    "-- properly would be better, and is not worth it here.",
  }, tmp)
  local c = _scan_file(tmp)
  vim.fn.delete(tmp)
  ok("[1] counts uv.* and vim.uv.* as ONE call each, not two",
    c.fs_stat == 2, vim.inspect(c))
  ok("[1] counts vim.loop.*", c.fs_unlink == 1)
  ok("[1] counts io.open and vim.fn.mkdir", c["io.open"] == 1 and c.mkdir == 1)
  ok("[1] counts a commented-out call too (documented limitation)",
    c.fs_write == 1, vim.inspect(c))
  ok("[1] and reports nothing for a file with no I/O", (function()
    local t2 = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({ "local M = {}", "return M" }, t2)
    local c2 = _scan_file(t2)
    vim.fn.delete(t2)
    return next(c2) == nil
  end)())
end

print("\n[2] every production file is classified, and every count matches its pin")
local files = vim.fn.globpath(plugin_root .. "/lua/worktree", "*.lua", false, true)
ok("[2] the scan found the production modules", #files >= 5, tostring(#files))

local unpinned, mismatched = {}, {}
for _, path in ipairs(files) do
  local name = vim.fn.fnamemodify(path, ":t")
  local counts = _scan_file(path) or {}
  local pin = INVENTORY[name]
  if next(counts) ~= nil and not pin then
    -- A NEW file doing raw I/O is exactly what this check is for.
    unpinned[#unpinned + 1] = name .. " (" .. vim.inspect(counts):gsub("%s+", " ") .. ")"
  elseif pin then
    for call, n in pairs(counts) do
      if (pin.calls[call] or 0) ~= n then
        mismatched[#mismatched + 1] = ("%s: %s pinned %d, found %d")
          :format(name, call, pin.calls[call] or 0, n)
      end
    end
    for call, n in pairs(pin.calls) do
      if (counts[call] or 0) ~= n then
        mismatched[#mismatched + 1] = ("%s: %s pinned %d, found %d")
          :format(name, call, n, counts[call] or 0)
      end
    end
  end
end

ok("[2] *** no production file does raw I/O without being in the inventory ***",
  #unpinned == 0, table.concat(unpinned, "; "))
ok("[2] *** every pinned count still matches the code ***",
  #mismatched == 0,
  #mismatched > 0 and (table.concat(mismatched, "; ")
    .. "  <- a phase landed, or new raw I/O appeared. Update INVENTORY in this"
    .. " file IN THE SAME COMMIT, and say which phase moved it.")
  or nil)
ok("[2] every entry declares a scope and a reason", (function()
  for name, pin in pairs(INVENTORY) do
    if pin.scope ~= "delegate" and pin.scope ~= "permitted" then return false, name end
    if type(pin.why) ~= "string" or pin.why == "" then return false, name end
    if pin.scope == "delegate" and type(pin.phase) ~= "string" then return false, name end
  end
  return true
end)())

print("\n[3] what remains, stated as a number")
-- The point of the inventory: P6's completion is a COUNT, not an opinion.
local delegate_total, permitted_total = 0, 0
local by_phase = {}
for _, pin in pairs(INVENTORY) do
  local n = 0
  for _, c in pairs(pin.calls) do n = n + c end
  if pin.scope == "delegate" then
    delegate_total = delegate_total + n
    by_phase[pin.phase] = (by_phase[pin.phase] or 0) + n
  else
    permitted_total = permitted_total + n
  end
end
print(("      delegate (must reach 0 by P6): %d   permitted: %d")
  :format(delegate_total, permitted_total))
for phase, n in pairs(by_phase) do print(("        %s owns %d"):format(phase, n)) end
ok("[3] the remaining work is enumerated, not estimated",
  delegate_total == 32 and permitted_total == 5,
  ("delegate=%d permitted=%d — if a phase just landed, update this figure too")
    :format(delegate_total, permitted_total))
-- At P6 this assertion becomes `delegate_total == 0`, and AC1 is met by
-- arithmetic rather than by assertion.

io.stdout:write(string.format("\n%d passed, %d failed\n", pass, fail))
os.exit(fail > 0 and 1 or 0)
