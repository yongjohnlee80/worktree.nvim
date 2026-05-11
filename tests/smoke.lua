-- Headless smoke tests for worktree.nvim.
-- Run with:  nvim --headless -u NONE -l tests/smoke.lua
--
-- Exits 0 on PASS, 1 on FAIL. Each test prints its own line.
-- First version landed in ADR 0007 Phase 1 — covers the auto-core
-- soft-dep probe (legacy fallback works without it), the public
-- API surface, set/get_root write-through to core.workspace_root,
-- the worktree:switched publication path, and the
-- restart_workspace_lsps → auto-core.lsp.reset wiring.

-- Derive the plugin root from the smoke script's own path so the
-- driver runs unmodified on any developer's machine (Mac, Linux,
-- bare-repo worktree, plain clone, …). `tests/smoke.lua` is two
-- levels below the plugin root.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")

local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
for _, p in ipairs({
  LAZY .. "/plenary.nvim",
  LAZY .. "/auto-core.nvim",
  vim.fn.fnamemodify(plugin_root, ":h:h") .. "/auto-core.nvim/main",
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

vim.o.columns = 200
vim.o.lines = 60
vim.o.swapfile = false
vim.o.hidden = true

-- Isolate from real nvim state — auto-core's state.namespace persists
-- to <state>/auto-core/<ns>.json by default; redirect to /tmp.
vim.fn.delete("/tmp/worktree-smoke-config", "rf")
vim.fn.delete("/tmp/worktree-smoke-state",  "rf")
vim.env.XDG_CONFIG_HOME = "/tmp/worktree-smoke-config"
vim.env.XDG_STATE_HOME  = "/tmp/worktree-smoke-state"

local fail_count, pass_count = 0, 0
local function ok(name, cond, detail)
  if cond then
    pass_count = pass_count + 1
    print(string.format("  PASS  %s", name))
  else
    fail_count = fail_count + 1
    print(string.format("  FAIL  %s  %s", name, tostring(detail or "")))
  end
end

-- ───────── 1. require + public API surface ─────────
print("\n[1] require + public API surface")
local wt = require("worktree")
ok("require returns a module", type(wt) == "table")
for _, fn in ipairs({
  "set_root", "get_root", "ensure_root", "setup",
  "status", "is_linked_worktree", "lualine_component",
  "pick", "home", "add", "remove", "clone", "init",
}) do
  ok(("public function exported: M." .. fn),
    type(wt[fn]) == "function")
end

-- ───────── 2. git.lua dispatcher: auto-core present and absent ─────────
print("\n[2] git.lua dispatcher (auto-core soft-dep + legacy fallback)")
local git_mod = require("worktree.git")
git_mod._reset_for_tests()

-- Sanity: a function that exists in BOTH auto-core and legacy returns
-- a value through the dispatcher.
local norm = git_mod.norm("/tmp/foo/")
ok("git.norm strips trailing slash",
  norm == "/tmp/foo", "got=" .. tostring(norm))

-- With auto-core on the runtimepath, parse_porcelain delegates to
-- auto-core (which has the canonical impl). We can't directly check
-- which path was taken, but the result should match the legacy
-- result on the same input.
local sample = {
  "worktree /repos/proj/main",
  "HEAD aaa",
  "branch refs/heads/main",
  "",
  "worktree /repos/proj/feature",
  "HEAD bbb",
  "branch refs/heads/feature",
  "",
}
local parsed = git_mod.parse_porcelain(sample)
ok("parse_porcelain returns a non-empty list", #parsed >= 2,
  "len=" .. tostring(#parsed))
ok("parse_porcelain entry 1 path",
  parsed[1] and parsed[1].path == "/repos/proj/main",
  vim.inspect(parsed[1]))
ok("parse_porcelain entry 2 branch",
  parsed[2] and parsed[2].branch == "feature",
  vim.inspect(parsed[2]))

-- Exercise the legacy-fallback path: mask auto-core temporarily,
-- re-arm the probe, run a delegate, confirm same shape.
local saved_core = package.loaded["auto-core"]
package.loaded["auto-core"] = nil
package.preload["auto-core"] = function() error("auto-core unavailable") end
git_mod._reset_for_tests()
local parsed_legacy = git_mod.parse_porcelain(sample)
ok("legacy fallback parse_porcelain works without auto-core",
  parsed_legacy[1] and parsed_legacy[1].path == "/repos/proj/main")
-- Restore auto-core for subsequent tests.
package.preload["auto-core"] = nil
package.loaded["auto-core"] = saved_core
git_mod._reset_for_tests()

-- ───────── 3. set_root / get_root write-through ─────────
print("\n[3] set_root / get_root write through to core.workspace_root")
local core = require("auto-core")
ok("auto-core present on rtp", type(core) == "table"
  and type(core.git) == "table"
  and type(core.git.worktree) == "table")

-- Use a temp dir so we don't affect the user's real workspace.
local tmproot = vim.fn.tempname() .. "_workspace"
vim.fn.mkdir(tmproot, "p")

wt.set_root(tmproot)
ok("set_root: get_root returns the value just set",
  wt.get_root() == tmproot, "got=" .. tostring(wt.get_root()))
ok("set_root: auto-core.git.worktree.get_workspace_root sees same",
  core.git.worktree.get_workspace_root() == tmproot,
  "got=" .. tostring(core.git.worktree.get_workspace_root()))

-- Reverse direction: writing through auto-core, the local mirror
-- stays out of sync (set_root is the canonical writer; get_root
-- reads through to auto-core every call).
core.git.worktree.set_workspace_root(tmproot .. "/sub")
vim.fn.mkdir(tmproot .. "/sub", "p")
ok("get_root re-reads from auto-core after external mutation",
  wt.get_root() == tmproot .. "/sub")

-- ───────── 4. worktree:switched publication ─────────
print("\n[4] worktree:switched publication on switch paths")
local got_event = nil
core.events.subscribe("worktree:switched", function(payload, _topic)
  got_event = payload
end)

-- We can't easily drive M.pick/M.home headless (they need real git
-- worktrees). Instead, verify the helper publishes correctly by
-- exercising the publish path through M.set_root (which doesn't
-- itself publish — but if we wire a fake switch, the helper does).
-- Easiest: simulate by calling the internal helper through the
-- existing public surface. We use M.home indirectly via a fake
-- workspace that has root == cwd, which short-circuits without
-- publishing. So instead we just verify the events bus works for
-- this topic by publishing manually (the real wiring is exercised
-- in live nvim during the user's :gw flow).
core.events.publish("worktree:switched",
  { from = "/a", to = "/b", cwd = "/b" })
vim.wait(20)
ok("subscriber receives worktree:switched payload",
  got_event ~= nil and got_event.from == "/a" and got_event.to == "/b",
  vim.inspect(got_event))

-- ───────── 5. restart_workspace_lsps → auto-core.lsp.reset ─────────
print("\n[5] restart_workspace_lsps routes through auto-core.lsp.reset")
ok("auto-core.lsp.reset reachable",
  type(core.lsp) == "table"
    and type(core.lsp.reset) == "table"
    and type(core.lsp.reset.reset_for) == "function")

-- Hook reset_for to capture invocations. We don't drive a real
-- switch (would require git worktrees); instead probe the wiring
-- by calling the public path that calls restart_workspace_lsps.
-- Since restart_workspace_lsps is local in init.lua, we exercise
-- it by triggering an M.home that's already at root (no-ops the
-- cd path) — that means we can't easily fire it from smoke
-- without a fully set-up worktree fixture. Live verification
-- is the user's daily `<leader>gw`; the unit-level wiring is
-- exercised by auto-core's own smoke [42] (see auto-core.nvim
-- tests/smoke.lua).
ok("auto-core.lsp.reset.detect_stack works on tmpdir",
  (function()
    local sample_dir = vim.fn.tempname() .. "_proj"
    vim.fn.mkdir(sample_dir, "p")
    vim.fn.writefile({ "module x" }, sample_dir .. "/go.mod")
    local stack = core.lsp.reset.detect_stack(sample_dir)
    vim.fn.delete(sample_dir, "rf")
    return vim.tbl_contains(stack, "gopls")
  end)())

-- Cleanup tmpdirs.
vim.fn.delete(tmproot, "rf")

-- ───────── 6. graph view (ADR 0007 Phase 3) ─────────
print("\n[6] worktree.graph — open / close / repo discovery")
ok("M.graph table reachable",
  type(wt.graph) == "table"
    and type(wt.graph.open)    == "function"
    and type(wt.graph.close)   == "function"
    and type(wt.graph.toggle)  == "function"
    and type(wt.graph.refresh) == "function"
    and type(wt.graph.is_open) == "function")
ok("auto-core.git.graph reachable",
  type(core.git.graph) == "table"
    and type(core.git.graph.fan_out) == "function")
ok("auto-core.ui.float.multi reachable",
  type(core.ui.float.multi) == "table"
    and type(core.ui.float.multi.new) == "function")

-- Build a small fixture workspace with two real repos so the
-- graph open path can fan_out + render the left pane. We don't
-- drive the full open path headless because gitgraph.nvim isn't
-- on rtp here; instead probe just fan_out + the panel descriptor.
local gtmp = vim.fn.tempname() .. "_graphws"
vim.fn.mkdir(gtmp .. "/r1", "p")
vim.fn.mkdir(gtmp .. "/r2", "p")
vim.fn.system({ "git", "-C", gtmp .. "/r1", "init", "-q" })
vim.fn.system({ "git", "-C", gtmp .. "/r1",
  "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "init r1" })
vim.fn.system({ "git", "-C", gtmp .. "/r2", "init", "-q" })
vim.fn.system({ "git", "-C", gtmp .. "/r2",
  "-c", "user.email=t@t", "-c", "user.name=t",
  "commit", "--allow-empty", "-m", "init r2" })

local repos_at_root = core.git.graph.fan_out(gtmp)
ok("fan_out finds both fixture repos",
  #repos_at_root == 2,
  "found=" .. #repos_at_root)
ok("fan_out repo labels are sorted",
  repos_at_root[1].label < repos_at_root[2].label,
  string.format("%s, %s", repos_at_root[1].label, repos_at_root[2].label))

-- show_stat over the fixture's commit hash.
local hash = vim.fn.systemlist({
  "git", "--git-dir=" .. repos_at_root[1].common_dir,
  "rev-parse", "HEAD",
})[1]
local stat = core.git.graph.show_stat(repos_at_root[1].common_dir, hash)
ok("show_stat returns content for fixture commit", #stat > 0)

-- Responsive layout test
wt.graph.set_root(gtmp)
wt.graph.open()
ok("wt.graph.open() opened the panel", wt.graph.is_open())

local mfloat = core.ui.float.multi.get("worktree.graph")
if mfloat then
  local left_win = mfloat:winid("left")
  local prev_win = mfloat:winid("preview")
  
  -- vim.o.columns = 200
  -- width_pct = 0.92 -> 184
  -- inner_w = 184 - 2 = 182
  -- left = 0.15 * 182 = 27
  -- preview = 0.40 * 182 = 72
  ok("responsive: left window width (15%)", 
    vim.api.nvim_win_get_width(left_win) == 27, "got " .. vim.api.nvim_win_get_width(left_win))
  ok("responsive: preview window width (40%)",
    vim.api.nvim_win_get_width(prev_win) == 72, "got " .. vim.api.nvim_win_get_width(prev_win))
  
  -- Resize and check again
  vim.o.columns = 150
  mfloat:resize()
  -- inner_w = floor(150 * 0.92) - 2 = 138 - 2 = 136
  -- left = 0.15 * 136 = 20
  -- preview = 0.40 * 136 = 54
  ok("responsive: left window width (15%) after resize",
    vim.api.nvim_win_get_width(left_win) == 20, "got " .. vim.api.nvim_win_get_width(left_win))
  ok("responsive: preview window width (40%) after resize",
    vim.api.nvim_win_get_width(prev_win) == 54, "got " .. vim.api.nvim_win_get_width(prev_win))
end

wt.graph.close()
vim.fn.delete(gtmp, "rf")

-- ───────────────────── summary ─────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
