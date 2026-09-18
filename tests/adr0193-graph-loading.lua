-- tests/adr0193-graph-loading.lua — the graph panel paints before it knows.
--
-- `<leader>gt` used to run repo discovery and a full `git log --all` BEFORE the
-- float existed, so the terminal showed nothing for seconds. The panel now
-- opens first, says what it is doing, and fills in.
--
-- THE CELL THAT MATTERS is §2: the placeholder must be observable WHILE
-- discovery is still outstanding. Asserting only that the repo list eventually
-- appears would pass against the old synchronous code too — the list was
-- always there the instant `open()` returned. "It arrives eventually" is not
-- the claim; "the float is up before the answer is" is.
--
-- Discovery is stubbed rather than timed. A cell that waits for real git and
-- infers loading from elapsed time asserts the machine's speed, not the code.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
vim.opt.runtimepath:prepend(plugin_root)
-- `:h:h` — plugin_root is a WORKTREE, so one `:h` only reaches the repo dir.
-- Candidates are matched by SYMBOL, not by path: a path proves some copy is
-- there, not that it can serve. This suite needs `fan_out_async`, and an
-- auto-core predating it would take the soft-dep fallback everywhere and pass
-- §1-§5 while never exercising the async path at all.
local siblings = vim.fn.fnamemodify(plugin_root, ":h:h")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
local ac = nil
for _, c in ipairs({
  siblings .. "/auto-core.nvim",
  siblings .. "/auto-core.nvim/main",
  siblings .. "/auto-core.nvim/" .. branch_dir,
}) do
  local f = c .. "/lua/auto-core/git/graph.lua"
  if vim.fn.filereadable(f) == 1
      and table.concat(vim.fn.readfile(f), "\n")
        :find("function M.fan_out_async", 1, true) then
    ac = c
  end
end
if not ac then
  io.stdout:write("  FAIL  no auto-core providing fan_out_async under "
    .. siblings .. "\n")
  vim.cmd("cq!")
end
vim.opt.runtimepath:prepend(ac)
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({ LAZY .. "/nui.nvim", LAZY .. "/plenary.nvim", LAZY .. "/gitgraph.nvim" }) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.columns, vim.o.lines = 200, 50
vim.o.swapfile = false

local pass, fail = 0, 0
local function ok(name, cond, detail)
  local line = cond and ("  PASS  " .. name)
    or ("  FAIL  " .. name .. (detail and ("  — " .. tostring(detail)) or ""))
  io.stdout:write(line:gsub("[\r\n]+", " "), "\n"); io.stdout:flush()
  if cond then pass = pass + 1 else fail = fail + 1 end
end

io.stdout:write("ADR-0193 — the graph panel paints before it knows\n"); io.stdout:flush()

local core = require("auto-core")
local wt = require("worktree")

-- ── a real repo, so render_left has something to render ─────────────
local root = vim.fn.tempname() .. "-adr0193-graph"
vim.fn.mkdir(root .. "/solo", "p")
local function sh(c) return vim.fn.system(c) end
sh({ "git", "-C", root .. "/solo", "init", "-q" })
vim.fn.writefile({ "x" }, root .. "/solo/f.txt")
sh({ "git", "-C", root .. "/solo", "add", "-A" })
sh({ "git", "-C", root .. "/solo", "-c", "user.email=t@t", "-c", "user.name=t",
     "commit", "-qm", "init" })

local REPOS = {
  { common_dir = root .. "/solo/.git", label = "solo",
    sample_worktree = root .. "/solo", is_bare = false },
}

-- ── stub discovery so we control WHEN it resolves ───────────────────
local real_async = core.git.graph.fan_out_async
local pending = nil   -- the callback discovery is waiting to deliver into
core.git.graph.fan_out_async = function(_, _, cb) pending = cb end

local function left_lines()
  local mf = core.ui.float.multi.get("worktree.graph")
  if not mf then return {} end
  local b = mf:bufnr("left")
  if not (b and vim.api.nvim_buf_is_valid(b)) then return {} end
  return vim.api.nvim_buf_get_lines(b, 0, -1, false)
end
local function left_text() return table.concat(left_lines(), "\n") end

-- ── 1. the float exists before discovery has answered ───────────────
wt.graph.set_root(root)
wt.graph.open()

ok("the panel is open while discovery is still outstanding",
  wt.graph.is_open(), "is_open() false — the float waited for data")
ok("discovery was actually requested (control: the stub was reached)",
  pending ~= nil, "fan_out_async was never called")

-- ── 2. THE DISCRIMINATING CELL: the placeholder is on screen ────────
-- Against the old synchronous code this is unreachable: the float did not
-- exist until after discovery returned, so there was no moment at which a
-- placeholder could be seen.
ok("the left pane shows a loading state, not an empty or final list",
  left_text():find("scanning", 1, true) ~= nil,
  vim.inspect(left_lines()))
ok("and it does NOT yet claim a repo count",
  left_text():find("Repos (", 1, true) == nil, vim.inspect(left_lines()))

-- ── 3. the answer replaces the placeholder ──────────────────────────
pending(REPOS)
vim.wait(3000, function() return left_text():find("Repos (", 1, true) ~= nil end, 20)
ok("the repo list replaces the placeholder once discovery resolves",
  left_text():find("Repos (", 1, true) ~= nil, vim.inspect(left_lines()))
ok("the placeholder is gone", left_text():find("scanning", 1, true) == nil,
  vim.inspect(left_lines()))

-- ── 4. a superseded generation must not overwrite ───────────────────
-- Reopening bumps the generation. The FIRST open's callback, arriving late,
-- must be ignored rather than painting stale content over the new panel.
wt.graph.close()
pending = nil
wt.graph.set_root(root)
wt.graph.open()
local late_cb = pending
ok("a second open started its own discovery", late_cb ~= nil)

wt.graph.close()          -- close before the answer lands
local closed_ok = pcall(function() if late_cb then late_cb(REPOS) end end)
ok("a callback landing after close does not error", closed_ok)
ok("and it did not resurrect the panel", not wt.graph.is_open())

-- ── 5. the empty case closes the float rather than stranding it ─────
-- The float is already open by the time "no repositories" is known, so the
-- early return the old code used is no longer available to it.
pending = nil
wt.graph.set_root(root)
wt.graph.open()
ok("panel opened for the empty case", wt.graph.is_open())
if pending then pending({}) end
vim.wait(3000, function() return not wt.graph.is_open() end, 20)
ok("an empty discovery closes the panel instead of leaving it scanning forever",
  not wt.graph.is_open())

-- ── 6. soft dependency: an older auto-core still works ──────────────
-- The consumer must not hard-require fan_out_async; ADR-0041's preview does
-- the same for show_stat_async.
core.git.graph.fan_out_async = nil
pending = nil
wt.graph.set_root(root)
wt.graph.open()
ok("the panel still opens with no fan_out_async available", wt.graph.is_open())
vim.wait(8000, function() return left_text():find("Repos (", 1, true) ~= nil end, 25)
ok("and the sync fallback still fills it",
  left_text():find("Repos (", 1, true) ~= nil, vim.inspect(left_lines()))
wt.graph.close()

core.git.graph.fan_out_async = real_async
vim.fn.delete(root, "rf")
io.stdout:write(("\n%d passed, %d failed\n"):format(pass, fail)); io.stdout:flush()
vim.cmd(fail > 0 and "cq!" or "qa!")
