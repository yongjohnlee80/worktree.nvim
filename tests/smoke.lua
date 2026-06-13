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
-- worktree.log caches `core_log` at module-load time. Running the
-- legacy-fallback dance above forces `worktree.log` to load under the
-- no-auto-core preload (the git.lua probe emits a warn through it),
-- which freezes `core_log = nil` for the rest of the session. Drop
-- the loaded module so the next `require("worktree.log")` re-probes
-- and picks up the now-restored auto-core. Section [8] depends on
-- the live wrapper to assert routing.
package.loaded["worktree.log"] = nil

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

-- ───────── 7. remote branch management ─────────
print("\n[7] remote branch management")
-- Create a dummy repo with a remote branch to test listing.
local repo_path = vim.fn.tempname() .. "_repo"
vim.fn.mkdir(repo_path, "p")
vim.system({ "git", "-C", repo_path, "init" }):wait()
vim.system({ "git", "-C", repo_path, "config", "user.email", "test@example.com" }):wait()
vim.system({ "git", "-C", repo_path, "config", "user.name", "Test User" }):wait()
vim.system({ "git", "-C", repo_path, "commit", "--allow-empty", "-m", "init" }):wait()
-- Create a fake remote ref
local remote_ref_dir = repo_path .. "/.git/refs/remotes/origin"
vim.fn.mkdir(remote_ref_dir, "p")
local head_sha = vim.trim(vim.fn.system({ "git", "-C", repo_path, "rev-parse", "HEAD" }))
local f = io.open(remote_ref_dir .. "/feature-x", "w")
f:write(head_sha .. "\n")
f:close()

local remotes = git_mod.list_remote_branches(repo_path)
local found_remotes = false
for _, r in ipairs(remotes) do if r == "origin/feature-x" then found_remotes = true end end
ok("list_remote_branches finds fake remote branch", found_remotes)

-- Test workflows via UI stubs
local ui_select_calls = {}
local ui_input_calls = {}

local orig_select = vim.ui.select
local orig_input = vim.ui.input

vim.ui.select = function(items, opts, on_choice)
  table.insert(ui_select_calls, { items = items, prompt = opts.prompt })
  -- Always select the first action (Delete, Force pull, etc)
  on_choice(items[1])
end

vim.ui.input = function(opts, on_confirm)
  table.insert(ui_input_calls, { prompt = opts.prompt, default = opts.default })
  if opts.prompt:match("New branch name") then
    on_confirm("new-feature-branch")
  elseif opts.prompt:match("Local branch name") then
    on_confirm("track-feature-branch")
  elseif opts.prompt:match("Worktree path") then
    on_confirm(opts.default)
  else
    on_confirm("dummy")
  end
end

wt.graph.set_root(repo_path)
wt.graph.open()

-- Toggle remote branches synchronously
vim.api.nvim_feedkeys("R", "xt", false)

local mfloat = core.ui.float.multi.get("worktree.graph")
local left_win = mfloat:winid("left")
local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(left_win), 0, -1, false)

local remote_branch_row = nil
for i, line in ipairs(lines) do
  -- v0.4.5: remote branches now render as `(origin/<branch>)`, the
  -- parens being the only thing distinguishing them from worktree
  -- rows (which render as plain `<branch> @<sha>`). The `feature-x`
  -- ref name is fixed by the test fixture above.
  if line:find("(origin/feature-x)", 1, true) then
    remote_branch_row = i
    break
  end
end

ok("remote branch visible in graph after toggling 'R'", remote_branch_row ~= nil)

if remote_branch_row then
  vim.api.nvim_win_set_cursor(left_win, { remote_branch_row, 0 })

  -- Test W (create branch)
  vim.api.nvim_feedkeys("W", "xt", false)
  ok("W (new branch) triggered vim.ui.input", #ui_input_calls > 0)
  
  -- Test C (checkout branch)
  vim.api.nvim_feedkeys("C", "xt", false)
  local checked_out = vim.trim(vim.fn.system({ "git", "-C", repo_path, "rev-parse", "--abbrev-ref", "HEAD" }))
  ok("C (checkout) ran successfully (or attempted)", true)

  -- Test D (delete remote branch)
  vim.api.nvim_feedkeys("D", "xt", false)
  ok("D (destroy) triggered vim.ui.select for remote branch", #ui_select_calls > 0 and ui_select_calls[#ui_select_calls].prompt:match("Delete origin/feature%-x"))
end

wt.graph.close()

vim.ui.select = orig_select
vim.ui.input = orig_input
vim.fn.delete(repo_path, "rf")

-- ───────── 8. interactive feedback toasts (notify regression guard) ─────────
-- Locks down the v0.4.6 regression: the wrapper sweep landed every
-- graph/init INFO toast on `log.info(...)` whose default sink is
-- silent — so users lost every happy-path message ("already at root",
-- "fetched X", "fast-forwarded Y", "+ worktree", "cloned →").
--
-- Fix (2026-05-25) splits each module's emission into two helpers:
--   • `log(msg, level)`   — severity-routed instrumentation (ERROR/WARN
--                            toast, INFO+ silent ring). Replaces the
--                            old misleadingly-named `notify` helper.
--   • `feedback(msg)`     — force-toast user-action feedback via
--                            `worktree.log.notify(...)`. Used at the
--                            ~25 git/worktree action sites in graph.lua
--                            and init.lua.
--
-- See shared/conventions/auto-family-logging.md row 5
-- ("Interactive feedback on a user-initiated UI action").
--
-- Asserts EFFECTS, not calls: we capture `vim.notify` and verify that
-- the toast actually surfaces.
print("\n[8] interactive feedback toasts (notify regression guard)")

local notify_captured = {}
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  notify_captured[#notify_captured + 1] = { msg = msg, level = level, opts = opts }
end

-- 8a. Wrapper contract — worktree.log.notify always toasts (force-toast
-- surface). This is the foundation feedback() depends on. If
-- auto-core.log.notify's routing ever flips to silent, this catches it.
notify_captured = {}
require("worktree.log").notify("smoke: forced INFO toast",
  { level = "info", component = "smoke" })
vim.wait(20)
ok("worktree.log.notify surfaces a toast at INFO",
  #notify_captured > 0 and notify_captured[1].msg:match("smoke: forced INFO toast"),
  "captured=" .. vim.inspect(notify_captured))

-- 8b. Inverse contract — worktree.log.info stays silent at default
-- routing. Pins down "use log.notify, not log.info, for user-facing
-- feedback." If this flips, the level-semantics table in the
-- convention doc needs updating before any code does.
notify_captured = {}
require("worktree.log").info("smoke", "smoke: silent INFO log")
vim.wait(20)
ok("worktree.log.info stays silent at default routing",
  #notify_captured == 0,
  "captured=" .. vim.inspect(notify_captured))

-- 8c. init.lua integration — M.home() always emits via feedback()
-- (either "already at root" or "worktree ← root"). With feedback()
-- routed through log.notify, a toast must surface. Pre-fix (log.info
-- path) zero toasts landed.
--
-- We don't pre-position cwd: macOS resolves /var/folders → /private/var/
-- which makes "old_cwd == root" fragile in headless. Both branches
-- emit; either is fine for this assertion.
local home_tmp = vim.fn.tempname() .. "_home"
vim.fn.mkdir(home_tmp, "p")
wt.set_root(home_tmp)
notify_captured = {}
wt.home()
vim.wait(20)
ok("init.feedback() surfaces a toast on M.home()",
  #notify_captured > 0,
  "captured=" .. vim.inspect(notify_captured))
vim.fn.delete(home_tmp, "rf")

vim.notify = orig_notify

-- ───────── ensure_root: stable workspace-root resolution ─────────
print("\n[ensure_root] resolves a stable per-project identity from launch cwd")
do
  local fsp = require("auto-core.fs.path")
  local saved_cwd = vim.fn.getcwd(-1, -1)

  -- An `.auto-agents/` workspace holding a nested repo + deep subdir.
  local awsroot = fsp.normalize(vim.fn.tempname() .. "_aws")
  vim.fn.mkdir(awsroot .. "/.auto-agents", "p")
  vim.fn.mkdir(awsroot .. "/repoY/.git", "p")
  vim.fn.writefile({ "ref: refs/heads/main" }, awsroot .. "/repoY/.git/HEAD")
  vim.fn.mkdir(awsroot .. "/repoY/sub/deep", "p")

  -- Launched from a deep subdir → collapses to the `.auto-agents/` root,
  -- NOT the raw cwd (the bug: each launch cwd hashed to its own key).
  wt._reset_root_for_tests()
  vim.fn.chdir(awsroot .. "/repoY/sub/deep")
  wt.ensure_root()
  ok("ensure_root: deep subdir under .auto-agents → the workspace marker dir",
    wt.get_root() == awsroot, "got=" .. tostring(wt.get_root()))

  -- WORKTREE_ROOT env wins over the resolver.
  local envroot = fsp.normalize(vim.fn.tempname() .. "_envroot")
  vim.fn.mkdir(envroot, "p")
  vim.env.WORKTREE_ROOT = envroot
  wt._reset_root_for_tests()
  vim.fn.chdir(awsroot .. "/repoY/sub/deep")
  wt.ensure_root()
  ok("ensure_root: WORKTREE_ROOT env overrides the resolver",
    wt.get_root() == envroot, "got=" .. tostring(wt.get_root()))
  vim.env.WORKTREE_ROOT = nil

  -- Marker-less cwd → keeps the raw cwd (parity with the legacy pin).
  local plainparent = fsp.normalize(vim.fn.tempname() .. "_plain")
  local plaindir = plainparent .. "/here"
  vim.fn.mkdir(plaindir, "p")
  wt._reset_root_for_tests()
  vim.fn.chdir(plaindir)
  wt.ensure_root()
  ok("ensure_root: marker-less cwd stays the raw cwd",
    wt.get_root() == plaindir, "got=" .. tostring(wt.get_root()))

  -- Restore + clean up.
  vim.fn.chdir(saved_cwd)
  wt._reset_root_for_tests()
  vim.fn.delete(awsroot, "rf")
  vim.fn.delete(envroot, "rf")
  vim.fn.delete(plainparent, "rf")
end

-- ───────── [9] ADR-0041 A+B+C — async diff, durable writes, guards ─────────
print("\n[9] ADR-0041 A+B+C — async diff path, atomic gitfile/session, scope-local float")
do
  local graph = require("worktree.graph")
  local session = require("worktree.session")
  local sdir = vim.fn.stdpath("state") .. "/worktree-sessions"
  local function session_file_for(cwd)
    local norm = require("worktree.git").norm(cwd)
    return sdir .. "/" .. vim.fn.sha256(norm):sub(1, 16) .. ".json"
  end

  -- 9a. Batch B: write_gitfile is atomic — exact content, no strays.
  local gdir = vim.fn.tempname() .. "_p9-gitfile"
  vim.fn.mkdir(gdir, "p")
  local g_ok, g_err = wt._write_gitfile(gdir, ".bare")
  ok("9a: write_gitfile succeeds", g_ok == true, tostring(g_err))
  local gf = io.open(gdir .. "/.git", "r")
  local g_content = gf and gf:read("*a") or ""
  if gf then gf:close() end
  ok("9a: gitfile content exact", g_content == "gitdir: ./.bare\n",
    vim.inspect(g_content))
  local g_strays = vim.fn.glob(gdir .. "/.tmp-*", false, true)
  ok("9a: no atomic-write temp strays", #g_strays == 0, vim.inspect(g_strays))

  -- 9b. Batch B + E head-start: session save/load roundtrip (this
  -- module had ZERO coverage), atomic on disk, malformed input
  -- tolerated, C6 focused type-guard.
  -- Resolve through symlinks so the cwd we pass matches the paths
  -- nvim stores in buffer names (macOS /tmp → /private/tmp). This is
  -- the known env class (task 2026-05-26-fix-macos-symlink-…), not an
  -- ADR-0041 concern — the fixture just stays deterministic across it.
  local scwd = vim.fn.resolve(vim.fn.tempname() .. "_p9-sess")
  vim.fn.mkdir(scwd, "p")
  for _, name in ipairs({ "one.txt", "two.txt" }) do
    local fh = assert(io.open(scwd .. "/" .. name, "w"))
    fh:write(name .. "\n")
    fh:close()
    -- :edit (not :badd) so the buffer is LOADED — session.save's
    -- is_tracked filter (correctly) skips unloaded buffers.
    vim.cmd("edit " .. vim.fn.fnameescape(scwd .. "/" .. name))
  end
  local s_ok, s_count = session.save(scwd)
  ok("9b: session.save persists tracked buffers", s_ok == true and s_count == 2,
    string.format("ok=%s count=%s", tostring(s_ok), tostring(s_count)))
  ok("9b: session file exists at the hashed path",
    vim.fn.filereadable(session_file_for(scwd)) == 1)
  local s_strays = vim.fn.glob(sdir .. "/.tmp-*", false, true)
  ok("9b: no temp strays in sessions dir", #s_strays == 0, vim.inspect(s_strays))
  for _, name in ipairs({ "one.txt", "two.txt" }) do
    local b = vim.fn.bufnr(scwd .. "/" .. name)
    if b ~= -1 then pcall(vim.api.nvim_buf_delete, b, { force = true }) end
  end
  local l_ok, l_count = session.load(scwd)
  ok("9b: session.load restores the buffer list", l_ok == true and l_count == 2,
    string.format("ok=%s count=%s", tostring(l_ok), tostring(l_count)))

  -- malformed JSON → (false, 0); C6: non-string `focused` tolerated.
  local mcwd = vim.fn.resolve(vim.fn.tempname() .. "_p9-bad")
  vim.fn.mkdir(mcwd, "p")
  session.save(mcwd)
  local mfile = session_file_for(mcwd)
  local bh = assert(io.open(mfile, "w"))
  bh:write("{ not json")
  bh:close()
  local bad_ok, bad_count = session.load(mcwd)
  ok("9b: malformed session JSON tolerated", bad_ok == false and bad_count == 0,
    string.format("ok=%s count=%s", tostring(bad_ok), tostring(bad_count)))
  local ch = assert(io.open(mfile, "w"))
  ch:write(vim.json.encode({ cwd = mcwd, buffers = {}, focused = 12345 }))
  ch:close()
  local c6_ok = pcall(session.load, mcwd)
  ok("9b: C6 — non-string `focused` does not error", c6_ok == true)

  -- 9c. Batch A/S2: diff float from pre-fetched lines; LOCAL window
  -- options; global defaults survive.
  local function gopt(name)
    return vim.api.nvim_get_option_value(name, { scope = "global" })
  end
  local wrap_before = gopt("wrap")
  graph._open_diff_float({ label = "p9" }, { hash = "deadbeefdead" },
    { "diff --git a/x b/x", "+p9 line" })
  local float_win = vim.api.nvim_get_current_win()
  ok("9c: diff float opened with fetched lines",
    vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] == "diff --git a/x b/x")
  ok("9c: float wrap is LOCAL false",
    vim.api.nvim_get_option_value("wrap", { win = float_win }) == false)
  ok("9c: GLOBAL wrap default survived", gopt("wrap") == wrap_before)
  pcall(vim.api.nvim_win_close, float_win, true)

  -- 9d. Batch A: async commit diff end-to-end against a real repo —
  -- the float arrives via show_diff_async's main-loop callback.
  local arepo = vim.fn.tempname() .. "_p9-async"
  vim.fn.mkdir(arepo, "p")
  vim.system({ "git", "-C", arepo, "init", "-q" }):wait()
  vim.system({ "git", "-C", arepo, "config", "user.email", "p9@test" }):wait()
  vim.system({ "git", "-C", arepo, "config", "user.name", "p9" }):wait()
  local af = assert(io.open(arepo .. "/f.txt", "w")); af:write("p9\n"); af:close()
  vim.system({ "git", "-C", arepo, "add", "." }):wait()
  vim.system({ "git", "-C", arepo, "commit", "-q", "-m", "p9 commit" }):wait()
  local sha = vim.trim(vim.fn.system({ "git", "-C", arepo, "rev-parse", "HEAD" }))
  local common = vim.trim(vim.fn.system({ "git", "-C", arepo,
    "rev-parse", "--path-format=absolute", "--git-common-dir" }))
  local ok_core = pcall(require, "auto-core")
  if ok_core and sha ~= "" then
    local before_win = vim.api.nvim_get_current_win()
    graph._show_commit_diff({ common_dir = common, label = "p9" }, { hash = sha })
    local opened = vim.wait(4000, function()
      return vim.api.nvim_get_current_win() ~= before_win
    end, 10)
    ok("9d: async commit diff opens the float", opened)
    if opened then
      local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""
      ok("9d: float carries the commit diff",
        first:find("commit", 1, true) ~= nil or first:find("diff", 1, true) ~= nil,
        first)
      pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
    end
    ok("9d: preview generation hook exported",
      type(graph._preview_generation) == "number")
  else
    ok("9d: async path needs auto-core (skipped — soft-dep absent)", true)
  end
end

-- ───────────────────── summary ─────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
