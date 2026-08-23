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
print("\n[2] git.lua facade over auto-core (ADR-0041 Batch D — legacy fallback removed)")
local git_mod = require("worktree.git")
git_mod._reset_for_tests()

-- The 4 worktree-local helpers are now inlined (no auto-core
-- equivalent); they must work and need no auto-core delegation.
local norm = git_mod.norm("/tmp/foo/")
ok("git.norm strips trailing slash (inlined helper)",
  norm == "/tmp/foo", "got=" .. tostring(norm))
local code, out = git_mod.run({ "git", "--version" })
ok("git.run returns (code, output) — inlined helper",
  code == 0 and type(out) == "string" and out:find("git version", 1, true) ~= nil,
  "code=" .. tostring(code))

-- parse_porcelain now delegates UNCONDITIONALLY to auto-core's
-- canonical impl. Same shape as before the migration.
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
ok("parse_porcelain delegates to auto-core (non-empty list)", #parsed >= 2,
  "len=" .. tostring(#parsed))
ok("parse_porcelain entry 1 path",
  parsed[1] and parsed[1].path == "/repos/proj/main",
  vim.inspect(parsed[1]))
ok("parse_porcelain entry 2 branch",
  parsed[2] and parsed[2].branch == "feature",
  vim.inspect(parsed[2]))

-- Batch D: the legacy module is gone — require must fail.
local has_legacy = pcall(require, "worktree.git_legacy")
ok("worktree.git_legacy is removed (require fails)", has_legacy == false)

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

-- REIMPLEMENTED (test-health): this section used to publish the event ITSELF
-- and then assert its own subscriber received it — which tests auto-core's
-- event bus, not worktree's wiring, and would stay green if worktree stopped
-- publishing altogether. Driving the real switch headlessly needs a full
-- worktree fixture, so the invariant that IS worktree's own is asserted at
-- source: this plugin must publish `worktree:switched`, with the payload
-- shape its consumers destructure.
local init_src = table.concat(
  vim.fn.readfile(plugin_root .. "/lua/worktree/init.lua"), "\n")
ok("[4] worktree PUBLISHES worktree:switched (its own responsibility)",
  init_src:match('publish,%s*"worktree:switched"') ~= nil
    or init_src:match('publish%("worktree:switched"') ~= nil,
  "no publish of worktree:switched found in lua/worktree/init.lua")
ok("[4] and the publish is pcall-guarded (auto-core is a soft edge here)",
  init_src:match('pcall%(core%.events%.publish,%s*"worktree:switched"') ~= nil)
ok("[4] the payload carries from/to/cwd, which consumers destructure",
  init_src:match('worktree:switched".-from%s*=') ~= nil
    and init_src:match('worktree:switched".-to%s*=') ~= nil,
  "payload keys not found next to the publish call")

-- The bus round-trip itself, honestly labelled as a CONTRACT check on the
-- payload shape rather than as evidence that worktree publishes.
core.events.publish("worktree:switched",
  { from = "/a", to = "/b", cwd = "/b" })
vim.wait(20)
ok("[4] CONTRACT: a worktree:switched payload round-trips to a subscriber",
  got_event ~= nil and got_event.from == "/a" and got_event.to == "/b",
  vim.inspect(got_event))

-- ───────── 5. restart_workspace_lsps → auto-core.lsp.reset ─────────
-- RETITLED (test-health): the old title claimed this verified routing
-- through auto-core.lsp.reset, but both assertions only probe auto-core's
-- reachability and detect_stack — restart_workspace_lsps is local to
-- init.lua and is never called here. The routing itself is covered by
-- auto-core's own smoke [42]; this checks the dependency worktree needs.
print("\n[5] auto-core.lsp.reset is present and detects a stack (dependency probe)")
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
  -- Was a hardcoded `true`, which asserted nothing while DISCARDING the
  -- `checked_out` value it had just computed. Assert on that value: git must
  -- answer with a real ref name, not an error or an empty string.
  ok("C (checkout) leaves the repo on a resolvable branch",
    checked_out ~= "" and checked_out:match("^%S+$") ~= nil
      and checked_out:lower():find("error") == nil,
    "rev-parse --abbrev-ref HEAD -> " .. vim.inspect(checked_out))

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

---_captured_toast searches the WHOLE capture for a message, rather than
---indexing [1].
---
---Indexing the first entry made these assertions order-dependent: any unrelated
---toast landing in the window — a scheduled auto-core warning, a deferred
---notification from an earlier section — failed the assertion even though the
---expected toast WAS captured, just not first. Lector observed 7 failures in 8
---runs where I saw 8 clean ones, which is exactly the shape of a race whose
---outcome depends on machine timing. A test that passes on the author's box and
---fails on the reviewer's is worse than one that fails everywhere.
---@param pattern string
---@return boolean
local function _captured_toast(pattern)
  for _, t in ipairs(notify_captured) do
    if type(t.msg) == "string" and t.msg:match(pattern) then return true end
  end
  return false
end

---_captured_count counts only toasts matching `pattern`, so an absence
---assertion cannot be broken by an unrelated toast arriving.
---@param pattern string
---@return integer
local function _captured_count(pattern)
  local n = 0
  for _, t in ipairs(notify_captured) do
    if type(t.msg) == "string" and t.msg:match(pattern) then n = n + 1 end
  end
  return n
end

-- 8a. Wrapper contract — worktree.log.notify always toasts (force-toast
-- surface). This is the foundation feedback() depends on. If
-- auto-core.log.notify's routing ever flips to silent, this catches it.
notify_captured = {}
require("worktree.log").notify("smoke: forced INFO toast",
  { level = "info", component = "smoke" })
vim.wait(20)
ok("worktree.log.notify surfaces a toast at INFO",
  _captured_toast("smoke: forced INFO toast"),
  "captured=" .. vim.inspect(notify_captured))

-- 8b. Inverse contract — worktree.log.info stays silent at default
-- routing. Pins down "use log.notify, not log.info, for user-facing
-- feedback." If this flips, the level-semantics table in the
-- convention doc needs updating before any code does.
notify_captured = {}
require("worktree.log").info("smoke", "smoke: silent INFO log")
vim.wait(20)
ok("worktree.log.info stays silent at default routing",
  _captured_count("smoke: silent INFO log") == 0,
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
-- Matched against the two messages `feedback()` can actually emit, not against
-- "any toast at all": a bare `#notify_captured > 0` would pass on an unrelated
-- toast arriving in the window — the mirror of the ordering bug in 8a, failing
-- open instead of closed.
ok("init.feedback() surfaces a toast on M.home()",
  _captured_toast("already at root") or _captured_toast("worktree ."),
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
    -- Was `true` (a skip masquerading as a pass). auto-core is a HARD
    -- dependency — worktree/git.lua asserts it at load — so reaching this
    -- branch means the harness is broken, not that a soft dep is missing.
    -- Fail loudly and say which precondition was absent.
    ok("9d: FAIL-LOUD — auto-core and a commit sha are both required here",
      false, ("auto-core=%s sha=%q — harness precondition missing")
        :format(tostring(ok_core), tostring(sha)))
  end

  -- ── 9e: the two test-shaped seams with ZERO references (test-health) ──
  -- `_show_range_diff` and `_bind_middle_action_keys` are underscore-prefixed
  -- (i.e. exposed FOR tests) and were referenced by no suite at all. A seam
  -- built for a test that was never written is the same signal md-harpoon's
  -- unused `_reset_for_tests` gave: intent that ran out.
  ok("9e: _show_range_diff is exported as a seam",
    type(graph._show_range_diff) == "function")
  ok("9e: _bind_middle_action_keys is exported as a seam",
    type(graph._bind_middle_action_keys) == "function")

  -- _show_range_diff must not throw on a real range, and must open the float
  -- with the diff it ALREADY fetched rather than re-running git (ADR-0041 P3
  -- fixed a double invocation here; nothing pinned it).
  if ok_core and sha ~= "" then
    -- The [9] fixture is deliberately single-commit for the assertions above,
    -- so a RANGE needs more history. Add TWO commits rather than reshaping a
    -- fixture other assertions depend on.
    --
    -- Three commits are required, not two: production builds the range as
    -- `from.hash .. "~1.." .. to.hash`, so `from` must itself HAVE a parent.
    -- Passing the fixture's initial commit as `from` makes git fail on
    -- `<root>~1`, the function logs and returns, and no float opens — which is
    -- exactly how an earlier version of this test mis-blamed the production
    -- code for its own bad fixture.
    for _, msg in ipairs({ "p9 second", "p9 third" }) do
      local fh = assert(io.open(arepo .. "/f.txt", "a")); fh:write(msg .. "\n"); fh:close()
      vim.system({ "git", "-C", arepo, "add", "." }):wait()
      vim.system({ "git", "-C", arepo, "commit", "-q", "-m", msg }):wait()
    end
    local c3 = vim.trim(vim.fn.system({ "git", "-C", arepo, "rev-parse", "HEAD" }))
    local c2 = vim.trim(vim.fn.system({ "git", "-C", arepo, "rev-parse", "HEAD~1" }))
    if c2 ~= "" and c3 ~= "" and c2 ~= c3 and c2 ~= sha then
      local win_before = vim.api.nvim_get_current_win()
      -- from = c2 (its parent is the initial commit), to = c3.
      local okr = pcall(graph._show_range_diff,
        { common_dir = common, label = "p9" },
        { hash = c2 }, { hash = c3 })
      ok("9e: _show_range_diff runs on a real two-commit range", okr)
      local opened_r = vim.wait(4000, function()
        return vim.api.nvim_get_current_win() ~= win_before
      end, 10)
      if opened_r then
        local hdr = vim.api.nvim_buf_get_lines(0, 0, 3, false)
        local joined = table.concat(hdr, "\n")
        ok("9e: the float is titled with the RANGE, not a single commit",
          joined:find("%.%.") ~= nil or joined:find("diff", 1, true) ~= nil, joined)
        pcall(vim.api.nvim_win_close, vim.api.nvim_get_current_win(), true)
      else
        ok("9e: _show_range_diff opened a float", false, "no new window appeared")
      end
    else
      ok("9e: FAIL-LOUD — the fixture needs three commits for a range diff",
        false, ("c2=%s c3=%s (from.hash~1 needs from to HAVE a parent)")
          :format(vim.inspect(c2), vim.inspect(c3)))
    end
  end

  -- _bind_middle_action_keys must be a safe no-op with no float open, which is
  -- the state every caller can hit. It guards on state.mfloat internally.
  graph.close()
  ok("9e: _bind_middle_action_keys is a safe no-op with no float open",
    (pcall(graph._bind_middle_action_keys)))
end

-- ───────────── [10] ADR-0060 P3 — store / watch / review / repos ─────────────
print("\n[10] ADR-0060 P3 — store, watch registry, review store, repos surface")
do
  local store  = require("worktree.store")
  local watch  = require("worktree.watch")
  local review = require("worktree.review")
  local repos  = require("worktree.repos")

  -- Point the store at a temp root so the user's real state is untouched.
  local sroot = vim.fn.tempname() .. "-p3store"
  store._root_override = sroot
  watch._reset_for_tests()
  repos._reset_for_tests()

  -- ── store: slugs are PATH SEGMENTS, so traversal must be impossible ──
  ok("10a: ssh remote slug", store.slug("git@github.com:yongjohnlee80/autodb.git")
    == "yongjohnlee80__autodb", store.slug("git@github.com:yongjohnlee80/autodb.git"))
  ok("10a: https remote slug", store.slug("https://github.com/yongjohnlee80/autodb")
    == "yongjohnlee80__autodb")
  ok("10a: trailing slash + .git both stripped",
    store.slug("https://github.com/o/r.git/") == "o__r", store.slug("https://github.com/o/r.git/"))
  ok("10a: the SAME repo keys identically with or without a trailing slash",
    store.slug("https://github.com/o/r.git/") == store.slug("https://github.com/o/r.git")
    and store.slug("https://github.com/o/r.git") == store.slug("https://github.com/o/r"),
    store.slug("https://github.com/o/r.git/") .. " vs " .. store.slug("https://github.com/o/r"))
  ok("10a: a single-segment name is owner=local",
    store.slug("autodb") == "local__autodb", store.slug("autodb"))
  local evil = store.slug("git@h:../../etc/passwd")
  ok("10a: a traversal attempt cannot produce dots or slashes",
    evil:find("%.") == nil and evil:find("/") == nil, evil)
  local evil2 = store.slug("../../../root")
  ok("10a: a relative path likewise",
    evil2:find("%.%.") == nil and evil2:find("/") == nil, evil2)

  -- ── store: json round-trip, absent vs corrupt ──
  local jp = sroot .. "/probe/x.json"
  ok("10b: write_json creates its directory", select(1, store.write_json(jp, { a = 1 })) == true)
  ok("10b: read_json round-trips", (store.read_json(jp) or {}).a == 1)
  local absent, aerr = store.read_json(sroot .. "/nope.json")
  ok("10b: an ABSENT file is nil with NO error", absent == nil and aerr == nil)
  vim.fn.writefile({ "{not json" }, sroot .. "/broken.json")
  local bad, berr = store.read_json(sroot .. "/broken.json")
  ok("10b: a CORRUPT file is nil WITH an error (a fresh install must be distinguishable)",
    bad == nil and berr ~= nil, tostring(berr))
  ok("10b: write_json refuses an empty path", select(1, store.write_json("", {})) == false)

  -- ── watch registry: persistence is the point ──
  ok("10c: nothing is watched initially", #watch.list() == 0)
  ok("10c: is_watched is false, not nil", watch.is_watched("/tmp/x") == false)
  watch.set("/tmp/wt-a", true)
  watch.set("/tmp/wt-b", true)
  ok("10c: set() records both", #watch.list() == 2, vim.inspect(watch.list()))
  ok("10c: is_watched sees them", watch.is_watched("/tmp/wt-a") == true)
  ok("10c: a trailing slash is the same key", watch.is_watched("/tmp/wt-a/") == true)
  watch.set("/tmp/wt-a", false)
  ok("10c: set(false) removes it", watch.is_watched("/tmp/wt-a") == false and #watch.list() == 1)
  ok("10c: toggle() flips and returns the new state", watch.toggle("/tmp/wt-a") == true)
  ok("10c: toggle() again flips back", watch.toggle("/tmp/wt-a") == false)

  -- The whole reason this is a file: a restart must remember.
  watch.set("/tmp/wt-persist", true)
  watch._reset_for_tests()                     -- simulate a fresh nvim
  ok("10c: a watch SURVIVES a reload (persisted, ADR-0060 §2.3)",
    watch.is_watched("/tmp/wt-persist") == true, vim.inspect(watch.list()))
  ok("10c: the registry file exists on disk",
    vim.fn.filereadable(store.watches_path()) == 1, store.watches_path())

  -- A corrupt registry must not stop the panel rendering.
  vim.fn.writefile({ "garbage" }, store.watches_path())
  watch._reset_for_tests()
  ok("10c: a CORRUPT registry degrades to empty rather than throwing",
    (function() local okc, r = pcall(watch.list); return okc and #r == 0 end)())
  watch._reset_for_tests()
  watch.set("/tmp/wt-keep", true)

  -- prune drops entries whose worktree is gone.
  local live = vim.fn.tempname() .. "-live"; vim.fn.mkdir(live, "p")
  watch.set(live, true)
  local pruned = watch.prune()
  ok("10c: prune() drops dead paths and keeps live ones",
    pruned >= 1 and watch.is_watched(live) == true, tostring(pruned))
  vim.fn.delete(live, "rf")

  -- ── [10c-r1] MULTI-INSTANCE LOST UPDATE (ADR-0060 r1 MF1) ──
  -- The registry is shared by every nvim on this machine, so a mutation must
  -- not rewrite the whole file from a mirror loaded minutes ago. Atomic rename
  -- keeps the file WHOLE; it does nothing about a lost update. Reproduced
  -- against two real processes during r1 verification — the loss is silent, and
  -- the write that causes it returns err=nil.
  --
  -- "Instance A" here is a direct disk write, which is exactly what another
  -- nvim's _flush() looks like from this process's point of view.
  watch._reset_for_tests()
  store.write_json(store.watches_path(), { paths = { "/tmp/wt-base" } })
  ok("10c-r1: instance B loads the shared registry",
    watch.is_watched("/tmp/wt-base") == true)

  store.write_json(store.watches_path(),                    -- instance A adds one
    { paths = { "/tmp/wt-base", "/tmp/wt-from-a" } })
  local _, serr = watch.set("/tmp/wt-from-b", true)         -- B mutates while stale
  ok("10c-r1: B's write reports no error", serr == nil, tostring(serr))

  local disk = store.read_json(store.watches_path()) or {}
  local on_disk = {}
  for _, p in ipairs(disk.paths or {}) do on_disk[p] = true end
  ok("10c-r1: *** B's toggle does NOT erase instance A's watch ***",
    on_disk["/tmp/wt-from-a"] == true, vim.inspect(disk.paths))
  ok("10c-r1: and B's own watch landed", on_disk["/tmp/wt-from-b"] == true)
  ok("10c-r1: and the pre-existing one survived", on_disk["/tmp/wt-base"] == true)
  ok("10c-r1: the stale mirror is refreshed, so is_watched sees A's write too",
    watch.is_watched("/tmp/wt-from-a") == true, vim.inspect(watch.list()))

  -- prune() had the same defect and worse: it iterates the mirror and flushes
  -- the lot, so a prune from a stale instance deletes watches it never saw —
  -- with no user action beyond whatever triggers prune.
  local plive = vim.fn.tempname() .. "-prune-live"; vim.fn.mkdir(plive, "p")
  watch._reset_for_tests()
  watch.set(plive, true)                                    -- B loads + caches
  store.write_json(store.watches_path(),                    -- A adds a live path
    { paths = { plive, "/tmp/wt-dead-x", plive .. "-other" } })
  vim.fn.mkdir(plive .. "-other", "p")
  local npruned = watch.prune()
  local pdisk = store.read_json(store.watches_path()) or {}
  local pset = {}
  for _, p in ipairs(pdisk.paths or {}) do pset[p] = true end
  ok("10c-r1: *** prune() keeps a live path added by ANOTHER instance ***",
    pset[plive .. "-other"] == true, vim.inspect(pdisk.paths))
  ok("10c-r1: prune() still drops the genuinely dead one",
    pset["/tmp/wt-dead-x"] ~= true and npruned >= 1, tostring(npruned))
  vim.fn.delete(plive, "rf"); vim.fn.delete(plive .. "-other", "rf")
  watch._reset_for_tests()

  -- ── review store: filename grammar + validation ──
  ok("10d: filename grammar", review.filename("o__r", "ff24bc5fcc759de", 3)
    == "o__r@ff24bc5.r3.review.json", review.filename("o__r", "ff24bc5fcc759de", 3))
  local fs_, fsh, frev = review.parse_filename("o__r@ff24bc5.r3.review.json")
  ok("10d: parse_filename round-trips", fs_ == "o__r" and fsh == "ff24bc5" and frev == 3)
  ok("10d: parse_filename rejects a foreign name",
    select(1, review.parse_filename("notes.md")) == nil)

  local r = review.new({ commit = "ff24bc5fcc759dec047bec7794e4704582696caa",
    base = "2377bdb", revision = 1, reviewer = "lector",
    owner = "yongjohnlee80", name = "autodb", verdict = "change_requested",
    summary = "one must-fix" })
  ok("10d: new() is valid and stamped", select(1, review.validate(r)) == true
    and r.schema == review.SCHEMA and r.created ~= nil)
  r.comments = {
    { path = "core/auth/sessions.go", line = 134, start_line = 128,
      side = "RIGHT", start_side = "RIGHT", severity = "must-fix",
      body = "unix-socket login bypasses the allowlist" },
    { path = "core/auth/sessions.go", line = 90, side = "RIGHT",
      severity = "nit", body = "typo", resolved = true },
    { path = "rpc/server.go", line = 250, side = "RIGHT",
      severity = "question", body = "why here?" },
  }
  ok("10d: validate() accepts a full review", select(1, review.validate(r)) == true,
    vim.inspect(select(2, review.validate(r))))

  -- The 1-based rule is ENFORCED: a 0 means someone wrote extmark rows into a
  -- GitHub-native field and every comment would land one line off.
  local zero = vim.deepcopy(r); zero.comments[1].line = 0
  local zok, zprob = review.validate(zero)
  ok("10d: a 0-based line is REJECTED (the ClaudeCodeMention trap)",
    zok == false and table.concat(zprob, ";"):find("1%-based") ~= nil, vim.inspect(zprob))
  local badside = vim.deepcopy(r); badside.comments[1].side = "MIDDLE"
  ok("10d: an unknown side is rejected", select(1, review.validate(badside)) == false)
  local badsev = vim.deepcopy(r); badsev.comments[1].severity = "meh"
  ok("10d: a severity outside the ladder is rejected", select(1, review.validate(badsev)) == false)
  local badschema = vim.deepcopy(r); badschema.schema = "other/9"
  ok("10d: a foreign schema is rejected", select(1, review.validate(badschema)) == false)

  -- save/load/list
  local path, serr = review.save("yongjohnlee80__autodb", r)
  ok("10d: save() writes the file", path ~= nil and vim.fn.filereadable(path) == 1, tostring(serr))
  ok("10d: save() REFUSES an invalid review (a broken file is worse than none)",
    select(1, review.save("x__y", { schema = "nope" })) == nil)
  local back = review.load("yongjohnlee80__autodb", r.commit, 1)
  ok("10d: load() returns it", back ~= nil and #back.comments == 3)
  ok("10d: load() of an absent review is nil with no error",
    (function() local v, e = review.load("yongjohnlee80__autodb", "0000000", 9); return v == nil and e == nil end)())

  local r2 = vim.deepcopy(r); r2.revision = 2
  review.save("yongjohnlee80__autodb", r2)
  local listed = review.list_for("yongjohnlee80__autodb", r.commit)
  ok("10d: list_for() finds both revisions, newest first",
    #listed == 2 and listed[1].revision == 2, vim.inspect(vim.tbl_map(function(x) return x.revision end, listed)))
  ok("10d: latest_revision()", review.latest_revision("yongjohnlee80__autodb", r.commit) == 2)
  ok("10d: latest_revision() is 0 when none exist",
    review.latest_revision("yongjohnlee80__autodb", "abc1234") == 0)

  -- ── [10d-r1] REVIEW HISTORY IS IMMUTABLE (ADR-0060 r1 MF2) ──
  -- The convention says a re-review is a NEW revision, never an edit, but
  -- nothing enforced it: save() wrote the canonical path unconditionally and
  -- fs_rename replaces, so saving r1 twice destroyed the first review with no
  -- error to either writer. Reproduced across two real processes in r1.
  local imm = vim.deepcopy(r); imm.revision = 1
  imm.summary = "FIRST summary"
  local ip1 = review.save("immut__repo", imm)
  local imm2 = vim.deepcopy(imm); imm2.summary = "SECOND summary"
  local ip2, ierr = review.save("immut__repo", imm2)
  ok("10d-r1: *** re-saving an existing revision is REFUSED ***",
    ip2 == nil and ierr ~= nil, tostring(ip2) .. " / " .. tostring(ierr))
  local kept = review.load("immut__repo", imm.commit, 1)
  ok("10d-r1: and the ORIGINAL review is still on disk, unmodified",
    kept ~= nil and kept.summary == "FIRST summary", kept and kept.summary)
  ok("10d-r1: the refusal names the revision so the caller can bump",
    tostring(ierr):match("r1") ~= nil or tostring(ierr):match("revision") ~= nil, tostring(ierr))
  ok("10d-r1: an explicit overwrite is still possible for a deliberate amend",
    review.save("immut__repo", imm2, { overwrite = true }) ~= nil)

  -- save_next claims atomically, so two agents cannot both take rN.
  local nx = vim.deepcopy(r); nx.commit = "beefbeefbeefbeefbeefbeefbeefbeefbeefbeef"
  local np1, nr1 = review.save_next("claim__repo", nx)
  local np2, nr2 = review.save_next("claim__repo", vim.deepcopy(nx))
  ok("10d-r1: save_next() claims r1 then r2, never colliding",
    nr1 == 1 and nr2 == 2, tostring(nr1) .. "/" .. tostring(nr2))
  ok("10d-r1: both claims produced distinct files",
    np1 ~= nil and np2 ~= nil and np1 ~= np2)
  ok("10d-r1: and the first claim is intact after the second",
    (review.load("claim__repo", nx.commit, 1)) ~= nil)

  -- ── [10d-r1] validate() enforces the WHOLE wire schema (r1 MF3) ──
  -- Previously `comments[].line` was the only field with range/base
  -- enforcement and `side` the only enumeration; commit/revision/start_line
  -- were unchecked, so save() could emit a file the renderer misplaces and
  -- GitHub rejects with a 422.
  local function bad(mut)
    local c = vim.deepcopy(r); mut(c); return select(1, review.validate(c)) == false
  end
  ok("10d-r1: a SHORT commit sha is rejected (payload carries the full 40)",
    bad(function(c) c.commit = "abc1234" end))
  ok("10d-r1: a non-hex commit is rejected",
    bad(function(c) c.commit = string.rep("z", 40) end))
  ok("10d-r1: revision 0 is rejected (integer >= 1)",
    bad(function(c) c.revision = 0 end))
  ok("10d-r1: a negative revision is rejected",
    bad(function(c) c.revision = -3 end))
  ok("10d-r1: a non-integer revision is rejected",
    bad(function(c) c.revision = 1.5 end))
  ok("10d-r1: a non-integer line is rejected",
    bad(function(c) c.comments[1].line = 10.5 end))
  ok("10d-r1: start_line = 0 is rejected, like line",
    bad(function(c) c.comments[1].start_line = 0 end))
  ok("10d-r1: a non-number start_line is rejected",
    bad(function(c) c.comments[1].start_line = "seven" end))
  ok("10d-r1: an INVERTED range (start_line > line) is rejected",
    bad(function(c) c.comments[1].start_line = 99; c.comments[1].line = 10 end))
  ok("10d-r1: an unknown start_side is rejected (MIDDLE is not a side)",
    bad(function(c) c.comments[1].start_side = "MIDDLE" end))
  ok("10d-r1: a non-boolean resolved is rejected",
    bad(function(c) c.comments[1].resolved = "yes" end))
  -- The instrument is not simply rejecting everything: the untouched review,
  -- and a LEGITIMATE range, must both still pass.
  ok("10d-r1: CONTROL — the conformant review still validates",
    select(1, review.validate(r)) == true, vim.inspect(select(2, review.validate(r))))
  local okrange = vim.deepcopy(r)
  okrange.comments[1].start_line = 88; okrange.comments[1].line = 90
  okrange.comments[1].start_side = "RIGHT"
  ok("10d-r1: CONTROL — a valid 88..90 range still validates",
    select(1, review.validate(okrange)) == true,
    vim.inspect(select(2, review.validate(okrange))))

  local grouped = review.by_path(r)
  ok("10d: by_path() groups and line-sorts",
    #grouped["core/auth/sessions.go"] == 2
    and grouped["core/auth/sessions.go"][1].line == 90,
    vim.inspect(vim.tbl_keys(grouped)))

  -- github projection
  local gp = review.github_payload(r)
  ok("10e: verdict maps to a GitHub event", gp.review_event == "REQUEST_CHANGES", gp.review_event)
  ok("10e: the summary becomes the body", gp.body == "one must-fix")
  ok("10e: RESOLVED comments are excluded from the upload", #gp.comments == 2,
    tostring(#gp.comments))
  ok("10e: path/line/body are the established /review-pr fields",
    gp.comments[1].path ~= nil and gp.comments[1].line ~= nil and gp.comments[1].body ~= nil)
  ok("10e: severity is folded into the body (GitHub has no field for it)",
    gp.comments[1].body:find("must%-fix") ~= nil, gp.comments[1].body)
  ok("10e: a range passes through with start_line + start_side",
    gp.comments[1].start_line == 128 and gp.comments[1].start_side == "RIGHT")
  ok("10e: an approved verdict maps to APPROVE",
    review.github_payload({ verdict = "approved" }).review_event == "APPROVE")
  ok("10e: an unknown verdict degrades to COMMENT",
    review.github_payload({ verdict = "???" }).review_event == "COMMENT")

  -- ── repos surface over a REAL bare + worktree layout ──
  ok("10f: available() is true with auto-core >= 0.1.70 present", repos.available() == true)

  local lab = vim.fn.tempname() .. "-p3repo"
  vim.fn.mkdir(lab, "p")
  local function G(dir, ...)
    local argv = { "git", "-C", dir, "-c", "user.email=t@t", "-c", "user.name=t" }
    for _, a in ipairs({ ... }) do argv[#argv + 1] = a end
    local res = vim.system(argv, {}):wait()
    return res.code
  end
  -- a plain repo with a base branch and a diverged feature worktree
  local proj = lab .. "/proj"
  vim.fn.mkdir(proj, "p")
  G(proj, "init", "-q", "-b", "main")
  vim.fn.writefile({ "base" }, proj .. "/a.txt")
  G(proj, "add", "."); G(proj, "commit", "-q", "-m", "base one")
  G(proj, "worktree", "add", "-q", "-b", "feature", lab .. "/feature")
  vim.fn.writefile({ "f" }, lab .. "/feature/f.txt")
  G(lab .. "/feature", "add", "."); G(lab .. "/feature", "commit", "-q", "-m", "feature work")
  vim.fn.writefile({ "dirty" }, lab .. "/feature/dirty.txt")

  local found = repos.repos(lab)
  ok("10f: repos() discovers the repository", #found >= 1, vim.inspect(vim.tbl_map(function(x) return x.label end, found)))
  local repo = found[1]
  ok("10f: a repo carries common_dir + slug", repo and repo.common_dir ~= nil and repo.slug ~= nil,
    vim.inspect(repo and { repo.label, repo.slug }))

  local wts = repos.worktrees(repo)
  ok("10f: worktrees() lists both", #wts == 2, vim.inspect(vim.tbl_map(function(w) return w.branch end, wts)))
  ok("10f: the base branch sorts first", wts[1] and wts[1].is_base == true,
    vim.inspect(vim.tbl_map(function(w) return { w.branch, w.is_base } end, wts)))
  ok("10f: base_branch() resolves main", repos.base_branch(repo) == "main", tostring(repos.base_branch(repo)))

  local feat
  for _, w in ipairs(wts) do if w.branch == "feature" then feat = w end end
  ok("10f: the feature worktree is found and UNWATCHED", feat ~= nil and feat.watched == false)

  -- ── [10f-r1] available() probes EVERY surface repos uses (r1 SF2) ──
  -- It checked git.log.range and git.graph.fan_out only, so against an
  -- auto-core with the P1 surface but not P2's diff module it advertised
  -- availability and then `o` errored in the user's face instead of falling
  -- back. A version floor cannot fix this: auto-core's own M.version was stale
  -- at 0.1.62 across three releases, so capability probing is the only option.
  local core_live = require("auto-core")
  ok("10f-r1: REQUIRED names every auto-core symbol repos calls",
    type(repos.REQUIRED) == "table" and #repos.REQUIRED >= 8, vim.inspect(repos.REQUIRED))
  for _, dotted in ipairs({ "git.diff.parse", "git.worktree.parse_porcelain",
                            "git.log.working_changes", "git.log.commit_files",
                            "git.log.rev_exists", "git.graph.show_diff" }) do
    ok("10f-r1: REQUIRED includes " .. dotted,
      vim.tbl_contains(repos.REQUIRED, dotted), vim.inspect(repos.REQUIRED))
  end
  -- Behavioural: remove ONE required symbol and availability must go false.
  local saved_diff = core_live.git.diff
  core_live.git.diff = nil
  ok("10f-r1: *** available() is FALSE when git.diff is missing (was true) ***",
    repos.available() == false)
  core_live.git.diff = saved_diff
  ok("10f-r1: CONTROL — and TRUE again once restored (probe is not stuck)",
    repos.available() == true)

  -- THE performance contract: an unwatched worktree costs nothing.
  local nodes, meta = repos.children(repo, feat)
  ok("10g: an UNWATCHED worktree yields no children at all (§2.3)",
    #nodes == 0 and meta.mode == "unwatched", vim.inspect(meta))

  repos.toggle_watch(feat.path)
  ok("10g: toggle_watch() marks it watched", repos.is_watched(feat.path) == true)
  nodes, meta = repos.children(repo, feat)
  ok("10g: a WATCHED worktree yields UNCOMMITTED first, then its commits",
    #nodes >= 2 and nodes[1].kind == "uncommitted" and nodes[2].kind == "commit",
    vim.inspect(vim.tbl_map(function(n) return n.kind end, nodes)))
  ok("10g: UNCOMMITTED is labelled with a file count",
    nodes[1].label:find("UNCOMMITTED") ~= nil and nodes[1].count >= 1, nodes[1].label)
  ok("10g: the range resolves as since_divergence against main",
    meta.mode == "since_divergence" and meta.base == "main", vim.inspect(meta))
  ok("10g: and lists ONLY the feature commit, not the base's",
    #nodes == 2 and nodes[2].commit.subject == "feature work",
    vim.inspect(vim.tbl_map(function(n) return n.label end, nodes)))

  local ch = repos.uncommitted(feat)
  ok("10h: uncommitted() lists the dirty file with a kind",
    #ch >= 1 and ch[1].kind ~= nil, vim.inspect(ch))
  local cf = repos.commit_files(repo, nodes[2].sha)
  ok("10h: commit_files() lists what the commit touched",
    #cf == 1 and cf[1].path == "f.txt", vim.inspect(cf))
  local dfiles = repos.diff(repo, nodes[2].sha)
  ok("10h: diff() returns PARSED files (not raw text)",
    #dfiles == 1 and dfiles[1].hunks ~= nil, vim.inspect(#dfiles))

  -- ── [10h-r1] A FAILED GIT READ IS NOT A CLEAN TREE (r1 SF3) ──
  -- children() discarded the errors from working_changes and range, so a failed
  -- status/log became `(no commits, clean tree)` in the panel — the panel
  -- asserting, by omission, that the user has no uncommitted work. The
  -- reachable case is not a corrupt repo: it is a worktree whose directory
  -- disappeared (deleted outside nvim, unmounted path, permissions), which
  -- worktrees() STILL lists.
  local gone = vim.fn.tempname() .. "-vanished"
  vim.fn.mkdir(gone, "p")
  watch.set(gone, true)
  local ghost = { path = gone, branch = "ghost", head = "deadbee", detached = false,
                  watched = true, is_base = false }
  vim.fn.delete(gone, "rf")                       -- the tree vanishes underneath us
  local gnodes, gmeta = repos.children(repo, ghost)
  ok("10h-r1: *** a failed status read is REPORTED, not rendered as clean ***",
    (gmeta.status_err ~= nil or gmeta.log_err ~= nil), vim.inspect(gmeta))
  ok("10h-r1: and meta carries enough for the frontend to show an error row",
    type(gmeta.status_err or gmeta.log_err) == "string",
    vim.inspect({ status_err = gmeta.status_err, log_err = gmeta.log_err }))
  ok("10h-r1: no UNCOMMITTED node is fabricated from a failed read",
    (function() for _, n in ipairs(gnodes) do
       if n.kind == "uncommitted" then return false end end return true end)())
  -- CONTROL: the healthy worktree must NOT report an error, or the assertion
  -- above would pass for the wrong reason.
  local hnodes, hmeta = repos.children(repo, feat)
  ok("10h-r1: CONTROL — a healthy worktree reports NO error",
    hmeta.status_err == nil and hmeta.log_err == nil, vim.inspect(hmeta))
  ok("10h-r1: CONTROL — and still yields its nodes", #hnodes >= 1, tostring(#hnodes))
  watch.set(gone, false)

  -- ── [10h-r1] the backend delegates git to auto-core (r1 SF4) ──
  -- repos.lua's own docstring says it owns POLICY and "never a git invocation
  -- of its own", while worktrees() shelled out to `git worktree list` directly,
  -- duplicating auto-core.git.worktree.list byte-for-byte.
  local src = table.concat(
    vim.fn.readfile(plugin_root .. "/lua/worktree/repos.lua"), "\n")
  -- Matches the ARGV form only. A prose mention of the command in a comment is
  -- not a shell-out, and an earlier version of this assertion failed on its own
  -- explanatory comment.
  ok("10h-r1: repos.lua no longer shells out to `git worktree list` itself",
    src:match('"worktree",%s*"list"') == nil,
    "a direct { \"worktree\", \"list\" } argv is still present")
  ok("10h-r1: and it routes through core.git.worktree.list",
    src:match("git%.worktree%.list") ~= nil)
  ok("10h-r1: CONTROL — worktrees() still returns both entries, unchanged",
    #repos.worktrees(repo) == 2, vim.inspect(#repos.worktrees(repo)))

  -- reviews attach to a commit by repo slug
  -- Identity is required (r3 #3): a review must name its repository, and an
  -- empty `repo` serialises as `[]` rather than the declared object. The fix
  -- belongs in callers like this one, not in a weaker schema.
  local rr = review.new({ commit = nodes[2].sha, revision = 1, reviewer = "lector",
                          owner = "smoke", name = "fixture" })
  rr.comments = { { path = "f.txt", line = 1, side = "RIGHT", severity = "nit", body = "ok" } }
  review.save(repo.slug, rr)
  ok("10h: reviews() finds a review recorded for that commit",
    #repos.reviews(repo, nodes[2].sha) == 1, vim.inspect(repos.reviews(repo, nodes[2].sha)))

  -- the base worktree itself falls back to a window
  local basewt
  for _, w in ipairs(wts) do if w.branch == "main" then basewt = w end end
  repos.toggle_watch(basewt.path)
  local bnodes, bmeta = repos.children(repo, basewt)
  ok("10i: the base worktree resolves as a window of 15 (§2.4/§6.1)",
    bmeta.mode == "window" and bmeta.limit == 15, vim.inspect(bmeta))
  ok("10i: and still lists its own commits", #bnodes >= 1)

  vim.fn.delete(lab, "rf")
  vim.fn.delete(sroot, "rf")
  store._root_override = nil
  watch._reset_for_tests()
end

-- ───── [11] buffers — the unsaved-work guard for a DESTRUCTIVE command ─────
-- 116 lines at ZERO assertions before this, while being wired at five sites in
-- init.lua including the only thing that warns before `:WorktreeRemove`
-- destroys unsaved edits (init.lua:739 modified_under) and a force-delete
-- (init.lua:764 wipe_under). Coverage was inverted: the newest 875 lines of
-- ADR-0060 had ~81 assertions and this had none.
print("\n[11] worktree.buffers — unsaved-work guard + switch cleanup")
;(function()
  local buffers = require("worktree.buffers")
  local root = vim.fn.tempname() .. "-bufs"
  local wt_a = root .. "/feat"
  local wt_b = root .. "/other"
  -- A SIBLING sharing a prefix with wt_a. `/feat` must never match `/feature`.
  local sibling = root .. "/feature"
  for _, d in ipairs({ wt_a, wt_b, sibling, wt_a .. "/sub" }) do vim.fn.mkdir(d, "p") end

  local function mkbuf(path, opts)
    opts = opts or {}
    vim.fn.writefile({ "x" }, path)
    local b = vim.fn.bufadd(path)
    vim.fn.bufload(b)
    if opts.modified then
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { "dirty" })
    end
    return b
  end
  local function alive(b) return vim.api.nvim_buf_is_valid(b) end

  -- ── each_under: the path-matching contract everything else rests on ──
  local b_exact  = mkbuf(wt_a .. "/top.txt")
  local b_nested = mkbuf(wt_a .. "/sub/deep.txt")
  local b_sib    = mkbuf(sibling .. "/other.txt")
  local b_out    = mkbuf(wt_b .. "/elsewhere.txt")

  local seen = {}
  buffers.each_under(wt_a, function(_, abs) seen[abs] = true end)
  ok("11a: each_under sees a file directly inside the worktree",
    seen[wt_a .. "/top.txt"] == true, vim.inspect(vim.tbl_keys(seen)))
  ok("11a: and one nested deeper", seen[wt_a .. "/sub/deep.txt"] == true)
  ok("11a: *** a SIBLING sharing a prefix is NOT matched (/feat vs /feature) ***",
    seen[sibling .. "/other.txt"] ~= true, vim.inspect(vim.tbl_keys(seen)))
  ok("11a: an unrelated worktree is not matched", seen[wt_b .. "/elsewhere.txt"] ~= true)

  -- ── modified_under: THE data-loss guard ──
  ok("11b: modified_under is empty when nothing is dirty",
    #buffers.modified_under(wt_a) == 0, vim.inspect(buffers.modified_under(wt_a)))
  vim.api.nvim_buf_set_lines(b_nested, 0, -1, false, { "unsaved edit" })
  local dirty = buffers.modified_under(wt_a)
  ok("11b: *** an unsaved edit under the worktree IS reported (WorktreeRemove's only warning) ***",
    #dirty == 1 and dirty[1] == wt_a .. "/sub/deep.txt", vim.inspect(dirty))
  ok("11b: a dirty buffer OUTSIDE the worktree is not reported",
    (function()
      vim.api.nvim_buf_set_lines(b_out, 0, -1, false, { "dirty elsewhere" })
      local d = buffers.modified_under(wt_a)
      return #d == 1
    end)(), vim.inspect(buffers.modified_under(wt_a)))
  -- CONTROL: the guard must see a dirty buffer in the OTHER worktree too, or
  -- the assertion above would pass simply because it never sees anything.
  ok("11b: CONTROL — the same guard DOES report the other worktree's dirty buffer",
    #buffers.modified_under(wt_b) == 1, vim.inspect(buffers.modified_under(wt_b)))
  vim.bo[b_nested].modified = false
  vim.bo[b_out].modified = false

  -- ── wipe_under: force-close, and what it counts ──
  local n_wiped = buffers.wipe_under(wt_a)
  ok("11c: wipe_under closes the buffers under the worktree",
    n_wiped >= 2 and not alive(b_exact) and not alive(b_nested), tostring(n_wiped))
  ok("11c: and leaves the sibling + unrelated worktree alone",
    alive(b_sib) and alive(b_out))

  -- ── first_under: the landing spot when the current buffer is closed ──
  local b_land = mkbuf(wt_b .. "/land.txt")
  ok("11d: first_under finds a loaded file buffer inside the path",
    buffers.first_under(wt_b) ~= nil)
  ok("11d: first_under is nil when nothing lives there",
    buffers.first_under(wt_a) == nil)
  -- A non-file buffer (terminal, panel, scratch) must never be a landing spot.
  local scratch = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, scratch, wt_a .. "/scratch-panel")
  ok("11d: *** a non-file buffer is NOT offered as a landing spot ***",
    buffers.first_under(wt_a) == nil, tostring(buffers.first_under(wt_a)))

  -- ── close_between: the switch cleanup, and the dirty-skip contract ──
  local old_wt, new_wt = wt_b, wt_a
  local b_keep  = mkbuf(new_wt .. "/keep.txt")          -- under NEW: must survive
  local b_stale = mkbuf(old_wt .. "/stale.txt")         -- under OLD only: closes
  local b_dirty = mkbuf(old_wt .. "/dirty.txt", { modified = true })
  local closed, skipped = buffers.close_between(old_wt, new_wt)
  ok("11e: close_between closes an unmodified buffer left behind",
    not alive(b_stale), tostring(closed))
  ok("11e: *** it REFUSES to close a modified buffer and reports it ***",
    alive(b_dirty) and #skipped == 1 and skipped[1] == old_wt .. "/dirty.txt",
    vim.inspect(skipped))
  ok("11e: a buffer under the NEW worktree is untouched", alive(b_keep))
  ok("11e: old == new is a no-op (0 closed, nothing reported)",
    (function() local c, d = buffers.close_between(new_wt, new_wt)
       return c == 0 and #d == 0 end)())
  -- The nested case the comment calls out: new_path INSIDE old_path must not
  -- nuke buffers that still belong to the new one.
  local nested_new = old_wt .. "/nested"
  vim.fn.mkdir(nested_new, "p")
  local b_nested_keep = mkbuf(nested_new .. "/still-mine.txt")
  buffers.close_between(old_wt, nested_new)
  ok("11e: *** a nested switch keeps buffers under the NEW (inner) path ***",
    alive(b_nested_keep))

  -- ── win_is_stale: redirect focus BEFORE deletion ──
  local win = vim.api.nvim_get_current_win()
  local b_win = mkbuf(old_wt .. "/in-window.txt")
  vim.api.nvim_win_set_buf(win, b_win)
  ok("11f: win_is_stale is TRUE for a window showing an about-to-close buffer",
    buffers.win_is_stale(win, old_wt, new_wt) == true)
  vim.api.nvim_win_set_buf(win, b_keep)
  ok("11f: and FALSE when the window's buffer belongs to the new worktree",
    buffers.win_is_stale(win, old_wt, new_wt) == false)
  ok("11f: an invalid window is not stale (no throw)",
    buffers.win_is_stale(99999, old_wt, new_wt) == false)
  local sbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, sbuf)
  ok("11f: a non-file buffer in the window is never stale",
    buffers.win_is_stale(win, old_wt, new_wt) == false)

  -- cleanup
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local nm = vim.api.nvim_buf_get_name(b)
    if nm ~= "" and nm:sub(1, #root) == root then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  vim.fn.delete(root, "rf")
end)()

-- ───── [12] config — 68 lines feeding 13 branch points, ZERO assertions ─────
print("\n[12] worktree.config — defaults and the nested deep-merge")
;(function()
  local config = require("worktree.config")
  local saved = vim.deepcopy(config.options)

  ok("12a: defaults exist and are a table", type(config.defaults) == "table")
  ok("12a: options starts as a COPY of defaults, not the same table",
    config.options ~= config.defaults)

  -- The load-bearing property: `integrations` is nested, so a caller setting one
  -- integration must not wipe the others. `tbl_deep_extend` is what makes that
  -- true and nothing pinned it.
  local before = vim.deepcopy(config.defaults.integrations or {})
  local keys = vim.tbl_keys(before)
  ok("12b: defaults carry a nested integrations table", #keys > 0, vim.inspect(keys))
  config.setup({ integrations = { neotree = false } })
  ok("12b: *** setting ONE integration preserves the others (deep merge) ***",
    (function()
      for k in pairs(before) do
        if k ~= "neotree" and config.options.integrations[k] == nil then return false end
      end
      return config.options.integrations.neotree == false
    end)(), vim.inspect(config.options.integrations))

  config.options = vim.deepcopy(config.defaults)
  config.setup(nil)
  ok("12c: setup(nil) leaves the defaults intact",
    vim.deep_equal(config.options, config.defaults), vim.inspect(config.options))

  config.setup({ notify_title = "T1" })
  config.setup({ bare_dir = ".bare2" })
  ok("12d: a second setup() re-merges from DEFAULTS (does not accumulate)",
    config.options.bare_dir == ".bare2" and config.options.notify_title ~= "T1",
    vim.inspect({ config.options.bare_dir, config.options.notify_title }))
  ok("12d: and an unspecified key falls back to its default",
    config.options.notify_title == config.defaults.notify_title)

  config.options = saved
end)()

-- ───── [14] r2 #2/#4/#5 — atomic save, whole-schema validate, loud prune ─────
print("\n[14] ADR-0060 r2 — save atomicity, validation gaps, prune honesty")
;(function()
  local store = require("worktree.store")
  local review = require("worktree.review")
  local watch = require("worktree.watch")
  local uv = vim.uv or vim.loop
  local root = vim.fn.tempname() .. "-r2"
  vim.fn.mkdir(root, "p")
  store._root_override = root

  local function mkreview(rev)
    local r = review.new({ owner = "o", name = "r", commit = string.rep("a", 40),
                           revision = rev or 1, reviewer = "probe",
                           summary = "S" .. tostring(rev or 1) })
    r.comments = { { path = "f.go", line = 3, side = "RIGHT",
                     severity = "nit", body = "b" } }
    return r
  end

  -- ── #2: save() must CLAIM, not check-then-write ──
  -- r1 said a pre-write fs_stat is not enough; I put create_exclusive only in
  -- save_next and left save() as stat-then-replacing-write. A real second
  -- process committing r1 inside that gap destroyed the first review with both
  -- writers getting err=nil.
  local p1 = review.save("toctou__repo", mkreview(1))
  ok("14a: save() writes a new revision", p1 ~= nil)
  -- Blind ONLY the pre-check, exactly as the TOCTOU does, and confirm the
  -- write is still refused — proving the claim (not the stat) is the gate.
  local real_stat = uv.fs_stat
  local blinded = false
  uv.fs_stat = function(p)
    if not blinded and p == p1 then blinded = true; return nil end
    return real_stat(p)
  end
  local p2, e2 = review.save("toctou__repo", mkreview(1))
  uv.fs_stat = real_stat
  ok("14a: *** with the pre-check blinded, save() STILL refuses (atomic claim) ***",
    p2 == nil and e2 ~= nil, tostring(p2) .. " / " .. tostring(e2))
  local kept = review.load("toctou__repo", string.rep("a", 40), 1)
  ok("14a: and the original review is intact",
    kept ~= nil and kept.summary == "S1", kept and kept.summary)
  ok("14a: CONTROL — an explicit overwrite still replaces deliberately",
    review.save("toctou__repo", (function()
      local r = mkreview(1); r.summary = "AMENDED"; return r
    end)(), { overwrite = true }) ~= nil)
  ok("14a: CONTROL — and the amend is what is now on disk",
    (review.load("toctou__repo", string.rep("a", 40), 1) or {}).summary == "AMENDED")

  -- ── #4: the validation gaps r1 asked for and I did not deliver ──
  local function bad(mut)
    local c = mkreview(1); mut(c); return select(1, review.validate(c)) == false
  end
  ok("14b: *** a NON-ARRAY comments table is rejected (uploaded 0 comments) ***",
    bad(function(c) c.comments = { first = { path = "f.go", line = 1, body = "x" } } end))
  ok("14b: a comments table with an index hole is rejected",
    bad(function(c) c.comments = { [2] = { path = "f.go", line = 1, body = "x" } } end))
  ok("14b: *** a scalar comment element is REPORTED, not thrown ***",
    (function()
      local c = mkreview(1); c.comments = { 42 }
      local okc, res = pcall(review.validate, c)
      return okc and res == false
    end)())
  ok("14b: a boolean element is reported too",
    (function()
      local c = mkreview(1); c.comments = { true }
      local okc, res = pcall(review.validate, c)
      return okc and res == false
    end)())
  ok("14b: a malformed repo field is rejected",
    bad(function(c) c.repo = "not a table" end))
  -- CONTROLS: the permissive cases the CONVENTION mandates must stay valid.
  ok("14b: CONTROL — an EMPTY comments array is still valid",
    (function() local c = mkreview(1); c.comments = {}
      return select(1, review.validate(c)) == true end)())
  ok("14b: CONTROL — a range with NEITHER side nor start_side is still valid "
    .. "(review-json §3: omitted means RIGHT, as GitHub does)",
    (function()
      local c = mkreview(1)
      c.comments = { { path = "f.go", line = 9, start_line = 7, body = "b" } }
      return select(1, review.validate(c)) == true
    end)(), vim.inspect(select(2, review.validate((function()
      local c = mkreview(1)
      c.comments = { { path = "f.go", line = 9, start_line = 7, body = "b" } }
      return c end)()))))
  ok("14b: CONTROL — the conformant review still validates",
    select(1, review.validate(mkreview(1))) == true)

  -- ── #5: prune() must not claim removals it never committed ──
  watch._reset_for_tests()
  local live = vim.fn.tempname() .. "-alive"; vim.fn.mkdir(live, "p")
  watch.set(live, true)
  watch.set("/tmp/wt-r2-dead-a", true)
  watch.set("/tmp/wt-r2-dead-b", true)
  local before = table.concat(vim.fn.readfile(store.watches_path()), "")
  -- Make the COMMIT fail while the lock and the read both succeed — the exact
  -- window where prune used to report phantom removals.
  local real_write = store.write_json
  store.write_json = function(p) if p == store.watches_path() then
    return false, "injected ENOSPC" end return real_write(p) end
  local removed, perr = watch.prune()
  store.write_json = real_write
  local after = table.concat(vim.fn.readfile(store.watches_path()), "")
  ok("14c: *** prune() reports 0 removals when the write FAILED ***",
    removed == 0, "removed=" .. tostring(removed))
  ok("14c: and returns the error rather than swallowing it",
    perr ~= nil and tostring(perr):find("ENOSPC") ~= nil, tostring(perr))
  ok("14c: the registry really is unchanged", after == before,
    "before=" .. before .. " after=" .. after)
  -- CONTROL: with a working store, prune removes AND persists.
  local removed2, perr2 = watch.prune()
  ok("14c: CONTROL — prune() removes the dead paths when the write succeeds",
    removed2 >= 2 and perr2 == nil, tostring(removed2) .. " / " .. tostring(perr2))
  ok("14c: CONTROL — and the live path survives", watch.is_watched(live) == true)
  vim.fn.delete(live, "rf")
  watch._reset_for_tests()

  store._root_override = nil
  vim.fn.delete(root, "rf")
end)()

-- ───── [15] r3 — takeover race, GitHub side projection, repo identity ─────
print("\n[15] ADR-0060 r3 — conditional takeover, side projection, repo identity")
;(function()
  local store = require("worktree.store")
  local review = require("worktree.review")
  local uv = vim.uv or vim.loop
  local root = vim.fn.tempname() .. "-r3"
  vim.fn.mkdir(root, "p")
  store._root_override = root

  -- ── #1a: a lock we do not own is NEVER removed ──
  -- Two previous attempts tried to make takeover safe and both only MOVED the
  -- race: any `fs_stat` then `fs_unlink` leaves a window in which a successor
  -- is installed and then deleted by a stale decision. libuv offers no atomic
  -- conditional unlink, so automatic takeover is gone entirely (r4 #1). A dead
  -- owner's lock is now REPORTED with the identity needed to clear it — loud
  -- and diagnosable instead of a silent, unbounded lost update.
  local target = root .. "/takeover.json"
  local lock = target .. ".lock"
  local dead = uv.fs_open(lock, "wx", tonumber("600", 8))
  uv.fs_write(dead, vim.json.encode({ pid = 2147480000,
    host = uv.os_gethostname(), start = 1 }), 0)
  uv.fs_close(dead)
  local dead_ino = (uv.fs_stat(lock) or {}).ino

  local entered = false
  local v, err = store.with_lock(target, function() entered = true; return true end)
  ok("15a: *** a DEAD owner's lock is not taken over automatically ***",
    entered == false and v == nil, "entered=" .. tostring(entered))
  ok("15a: *** and the lock file is left exactly as it was ***",
    (uv.fs_stat(lock) or {}).ino == dead_ino,
    "inode changed or file removed")
  ok("15a: the refusal names the holding pid",
    tostring(err):find("2147480000", 1, true) ~= nil, tostring(err))
  ok("15a: and says the process is gone, so the lock is clearable",
    tostring(err):find("NO LONGER RUNNING", 1, true) ~= nil, tostring(err))
  ok("15a: an unreadable owner record is reported as such, not broken",
    (function()
      vim.fn.delete(lock)
      local torn = uv.fs_open(lock, "wx", tonumber("600", 8))
      uv.fs_write(torn, '{"pid":123,"ho', 0); uv.fs_close(torn)
      local _, e = store.with_lock(target, function() return true end)
      local still = uv.fs_stat(lock) ~= nil
      return still and tostring(e):find("unreadable owner record", 1, true) ~= nil
    end)(), "a torn record must be reported, never force-removed")
  vim.fn.delete(lock)
  -- CONTROL: with no lock present, acquisition works and releases cleanly.
  local ok_run = store.with_lock(target, function() return true end)
  ok("15a: CONTROL — an uncontested lock is acquired and released",
    ok_run == true and uv.fs_stat(lock) == nil)

  -- ── #1b: EPERM is not death ──
  -- pid 1 exists and cannot be signalled by a normal user: kill(1,0) yields
  -- EPERM. My code returned true for every non-success, while its own comment
  -- said only ESRCH counts — the same comment/code contradiction as before.
  -- Stubbed rather than relying on pid 1's real permissions, so the errno
  -- BRANCH is exercised deterministically on any machine (r4 should-fix 1).
  local real_kill = uv.kill
  local rec_live = { pid = 4242, host = uv.os_gethostname(), start = 1 }
  uv.kill = function() return nil, "permission denied", "EPERM" end
  ok("15b: *** EPERM (process exists, cannot signal) is NOT death ***",
    store._owner_dead_for_tests(rec_live) == false)
  uv.kill = function() return nil, "no such process", "ESRCH" end
  ok("15b: ESRCH IS death", store._owner_dead_for_tests(rec_live) == true)
  uv.kill = function() return nil, "something new libuv invented", "EWEIRD" end
  ok("15b: an UNKNOWN errno fails safe — treated as alive, never broken",
    store._owner_dead_for_tests(rec_live) == false)
  uv.kill = real_kill
  ok("15b: CONTROL — unstubbed, a live pid (ourselves' parent-safe probe) is alive",
    store._owner_dead_for_tests({ pid = uv.os_getpid(),
      host = uv.os_gethostname() }) == false)

  -- ── #2: /proc/<pid>/stat must be parsed from the LAST ")" ──
  -- The pattern took the leftmost `") "`, so a comm containing `) ` returned the
  -- wrong field — a start time of 0, which _owner_dead reads as pid reuse and a
  -- LIVE holder becomes "dead" (r4 #2).
  ok("15b: _proc_start reads a real start time for this process",
    type(store._proc_start(uv.os_getpid())) == "number"
      and store._proc_start(uv.os_getpid()) > 0,
    tostring(store._proc_start(uv.os_getpid())))
  ok("15b: *** a comm containing ') ' does not shift the field ***",
    (function()
      -- field 22 is the 20th token after the comm; build a line whose comm
      -- itself contains ") " to defeat a leftmost match.
      local fields = {}
      for i = 1, 30 do fields[i] = tostring(1000 + i) end
      local line = '4242 (nvim) shifted) S ' .. table.concat(fields, " ", 1, 30)
      return store._parse_proc_stat_for_tests(line) == tonumber(fields[19])
    end)(), "parsed=" .. tostring(store._parse_proc_stat_for_tests(
      '4242 (nvim) shifted) S ' .. (function()
        local f = {}; for i = 1, 30 do f[i] = tostring(1000 + i) end
        return table.concat(f, " ") end)())))

  -- ── #2: github_payload must MATERIALISE the side default ──
  -- The internal artifact may omit side (review-json §3), but GitHub's REST
  -- contract requires `side` for a line comment and `start_side` for a
  -- multiline one. The projection assigned neither when both were omitted, so
  -- a perfectly valid artifact uploaded as {path,line,body} and was rejected.
  local r = review.new({ owner = "o", name = "rp", url = "git@h:o/rp.git",
                         commit = string.rep("b", 40), revision = 1,
                         reviewer = "probe", verdict = "comment", summary = "s" })
  r.comments = {
    { path = "f.go", line = 9, body = "single, no side" },
    { path = "f.go", line = 9, start_line = 7, body = "range, no sides" },
  }
  ok("15c: the omitted-side artifact still VALIDATES (internal default stands)",
    select(1, review.validate(r)) == true,
    vim.inspect(select(2, review.validate(r))))
  local gp = review.github_payload(r)
  ok("15c: *** the projection materialises side=RIGHT for a line comment ***",
    gp.comments[1] and gp.comments[1].side == "RIGHT",
    vim.inspect(gp.comments[1]))
  ok("15c: *** and start_side for a multiline comment ***",
    gp.comments[2] and gp.comments[2].side == "RIGHT"
      and gp.comments[2].start_side == "RIGHT", vim.inspect(gp.comments[2]))
  ok("15c: CONTROL — an EXPLICIT side is passed through unchanged",
    (function()
      local e = review.new({ owner = "o", name = "rp", url = "u",
        commit = string.rep("c", 40), revision = 1 })
      e.comments = { { path = "f.go", line = 4, side = "LEFT", body = "b" } }
      return (review.github_payload(e).comments[1] or {}).side == "LEFT"
    end)())
  ok("15c: CONTROL — an explicit cross-side range is preserved, not normalised",
    (function()
      local e = review.new({ owner = "o", name = "rp", url = "u",
        commit = string.rep("d", 40), revision = 1 })
      e.comments = { { path = "f.go", line = 9, start_line = 7,
                       side = "RIGHT", start_side = "LEFT", body = "b" } }
      local c = review.github_payload(e).comments[1] or {}
      return c.side == "RIGHT" and c.start_side == "LEFT"
    end)())

  -- ── #3: repo IDENTITY, not merely a table ──
  local function bad_repo(mut)
    local c = review.new({ owner = "o", name = "rp", url = "u",
                           commit = string.rep("e", 40), revision = 1 })
    c.comments = {}
    mut(c)
    return select(1, review.validate(c)) == false
  end
  ok("15d: *** an ABSENT repo is rejected ***", bad_repo(function(c) c.repo = nil end))
  ok("15d: *** an EMPTY repo is rejected (it serialises as [] , not an object) ***",
    bad_repo(function(c) c.repo = {} end))
  ok("15d: a repo with no usable identity is rejected",
    bad_repo(function(c) c.repo = { owner = "", name = "" } end))
  ok("15d: a wrong-typed identity field is rejected",
    bad_repo(function(c) c.repo = { owner = 42, name = false } end))
  ok("15d: CONTROL — owner+name alone is sufficient identity",
    (function()
      local c = review.new({ owner = "o", name = "rp",
        commit = string.rep("f", 40), revision = 1 })
      c.comments = {}
      return select(1, review.validate(c)) == true
    end)())
  ok("15d: CONTROL — a url alone is sufficient identity",
    (function()
      local c = review.new({ url = "git@h:o/rp.git",
        commit = string.rep("1", 40), revision = 1 })
      c.comments = {}
      return select(1, review.validate(c)) == true
    end)(), vim.inspect(select(2, review.validate((function()
      local c = review.new({ url = "git@h:o/rp.git",
        commit = string.rep("1", 40), revision = 1 })
      c.comments = {}; return c end)()))))

  store._root_override = nil
  vim.fn.delete(root, "rf")
end)()

-- ───── [13] store.with_lock — mutual exclusion (ADR-0060 r2 #1) ─────
-- Had ZERO test coverage while being the mechanism r1 MF1 added to prevent
-- lost updates. It decided a lock was orphaned from AGE ALONE and unlinked it,
-- so a live holder stalled past the window (slow fsync, scheduler suspension, a
-- debugger) got its lock broken and BOTH writers entered — reintroducing the
-- very condition it exists to prevent. Reproduced across two real nvim
-- processes with an actual lost update on watches.json.
print("\n[13] store.with_lock — liveness, not age; ownership-checked release")
;(function()
  local store = require("worktree.store")
  local uv = vim.uv or vim.loop
  local root = vim.fn.tempname() .. "-lock"
  vim.fn.mkdir(root, "p")
  store._root_override = root
  local target = root .. "/guarded.json"
  local lock = target .. ".lock"

  -- ── the lock must carry an owner record, not be an empty file ──
  local seen_payload
  local okrun = store.with_lock(target, function()
    local fd = uv.fs_open(lock, "r", tonumber("600", 8))
    if fd then
      local st = uv.fs_fstat(fd)
      seen_payload = st and st.size and st.size > 0
        and uv.fs_read(fd, st.size, 0) or nil
      uv.fs_close(fd)
    end
    return true
  end)
  ok("13a: with_lock runs its critical section", okrun == true)
  ok("13a: *** the lock file carries an owner record (was zero bytes) ***",
    type(seen_payload) == "string" and seen_payload ~= "", tostring(seen_payload))
  local owner = seen_payload and (pcall(vim.json.decode, seen_payload)
    and vim.json.decode(seen_payload)) or nil
  ok("13a: the record names the owning pid", owner and type(owner.pid) == "number",
    vim.inspect(owner))
  ok("13a: and the host, so a foreign-host lock is never judged by us",
    owner and type(owner.host) == "string", vim.inspect(owner))
  ok("13a: the lock is released when the section completes",
    uv.fs_stat(lock) == nil)

  -- ── a LIVE holder is never broken, however old its mtime ──
  -- This is the r2 finding: age is not liveness.
  local held = uv.fs_open(lock, "wx", tonumber("600", 8))
  ok("13b: acquired a lock by hand", held ~= nil)
  local rec = vim.json.encode({ pid = uv.os_getpid(), host = uv.os_gethostname(),
                                start = store._proc_start(uv.os_getpid()) })
  uv.fs_write(held, rec, 0)
  -- Age it far past any threshold. THIS process is alive and owns it.
  local ancient = os.time() - (store.LOCK_STALE_MS / 1000) * 100
  uv.fs_utime(lock, ancient, ancient)
  local entered = false
  local v2, e2 = store.with_lock(target, function() entered = true; return true end)
  ok("13b: *** a LIVE owner's lock is NOT broken, even aged past the window ***",
    entered == false, "critical section entered=" .. tostring(entered))
  ok("13b: and the caller is told it could not acquire",
    v2 == nil and tostring(e2):find("acquire") ~= nil, tostring(e2))
  ok("13b: the live holder's lock is still on disk", uv.fs_stat(lock) ~= nil)

  -- ── a DEAD owner's lock IS broken (else a crash wedges the registry) ──
  -- Nothing on the system garbage-collects this file, so refusing forever would
  -- turn one SIGKILL into a permanent, user-unrecoverable failure.
  uv.fs_close(held)
  -- Recreate rather than overwrite in place: writing a SHORTER record at offset
  -- 0 leaves trailing bytes from the longer one, which is a torn write, not a
  -- crashed owner. (That mistake is why an earlier run of this test failed —
  -- and it exercised the "cannot judge" backstop instead of the dead-owner
  -- path, which is worth knowing the difference between.)
  vim.fn.delete(lock)
  local dead = uv.fs_open(lock, "wx", tonumber("600", 8))
  uv.fs_write(dead, vim.json.encode({
    pid = 2147480000,                        -- a pid that cannot be running
    host = uv.os_gethostname(), start = 1,
  }), 0)
  uv.fs_close(dead)
  local entered2 = false
  local v3 = store.with_lock(target, function() entered2 = true; return true end)
  -- INVERTED, not deleted (the P6 pattern). This block used to assert that a
  -- dead owner's lock IS broken, and that an unjudgeable one is broken past a
  -- 15-minute horizon. Both behaviours were REMOVED in r4: every attempt to
  -- make that unlink safe only moved the race, because libuv has no atomic
  -- conditional unlink. So the assertions now guard that automatic takeover
  -- STAYS gone — dead coverage turned into a live invariant rather than thrown
  -- away.
  ok("13c: *** a DEAD owner's lock is NOT broken automatically ***",
    entered2 == false and v3 == nil, "entered=" .. tostring(entered2))
  ok("13c: the dead lock is still on disk, to be cleared deliberately",
    uv.fs_stat(lock) ~= nil)

  vim.fn.delete(lock)
  local torn = uv.fs_open(lock, "wx", tonumber("600", 8))
  uv.fs_write(torn, '{"pid":123,"ho', 0)   -- truncated write
  uv.fs_close(torn)
  local entered_torn = false
  store.with_lock(target, function() entered_torn = true; return true end)
  ok("13c: an UNJUDGEABLE lock is not broken on sight",
    entered_torn == false, "entered=" .. tostring(entered_torn))
  ok("13c: and no age threshold breaks it later either (the lease is gone)",
    (function()
      local long_ago = os.time() - 365 * 24 * 3600
      uv.fs_utime(lock, long_ago, long_ago)
      local e = false
      store.with_lock(target, function() e = true; return true end)
      return e == false and uv.fs_stat(lock) ~= nil
    end)(), "a year-old unreadable lock must still not be force-broken")
  ok("13c: LOCK_ABANDONED_MS is gone, so nothing can reintroduce the lease",
    store.LOCK_ABANDONED_MS == nil, tostring(store.LOCK_ABANDONED_MS))
  vim.fn.delete(lock)

  -- ── a foreign HOST's lock is not ours to judge ──
  local held2 = uv.fs_open(lock, "wx", tonumber("600", 8))
  uv.fs_write(held2, vim.json.encode({
    pid = 2147480000, host = "some-other-machine", start = 1,
  }), 0)
  uv.fs_close(held2)
  local entered3 = false
  store.with_lock(target, function() entered3 = true; return true end)
  ok("13d: a lock from ANOTHER host is not broken on pid evidence alone",
    entered3 == false, "entered=" .. tostring(entered3))
  vim.fn.delete(lock)

  -- ── release is ownership-checked, not by pathname ──
  -- After any break — including a legitimate one — a straggler in the old
  -- process reaching its release path would unlink the SUCCESSOR's lock by
  -- pathname, admitting a third writer.
  local inner_lock_ino
  store.with_lock(target, function()
    -- Simulate the successor: replace the lock file with a different inode
    -- while we are inside, then let our release run.
    vim.fn.delete(lock)
    local other = uv.fs_open(lock, "wx", tonumber("600", 8))
    uv.fs_write(other, vim.json.encode({ pid = uv.os_getpid(),
      host = uv.os_gethostname(), start = 1 }), 0)
    uv.fs_close(other)
    local st = uv.fs_stat(lock)
    inner_lock_ino = st and st.ino
    return true
  end)
  local after = uv.fs_stat(lock)
  ok("13e: *** release does NOT unlink a lock it no longer owns ***",
    after ~= nil and after.ino == inner_lock_ino,
    "successor lock survived=" .. tostring(after ~= nil))
  vim.fn.delete(lock)

  -- CONTROL: a lock we DO own is released, or every run would leak one.
  store.with_lock(target, function() return true end)
  ok("13e: CONTROL — a lock we own IS released", uv.fs_stat(lock) == nil)

  store._root_override = nil
  vim.fn.delete(root, "rf")
end)()

-- ───────────── assertion-count floor (silent-drop guard) ─────────────
-- Three blocks in this file are conditional on a runtime precondition:
--   * `if mfloat then`            (responsive-geometry assertions)
--   * `if remote_branch_row then` (remote-branch action assertions)
--   * `if ok_core and sha ~= ""`  (async commit-diff assertions)
-- If a precondition silently stops holding, their assertions simply do not
-- run: the totals drop and NOTHING fails. That is the same class of defect as
-- an aborting suite — coverage disappearing without a signal — reachable here
-- without any crash at all.
--
-- A floor catches it while still allowing new tests to be added freely: raise
-- MIN_ASSERTIONS when you add coverage, and a drop below it is a hard failure.
local MIN_ASSERTIONS = 272
local total_asserts = pass_count + fail_count
if total_asserts < MIN_ASSERTIONS then
  fail_count = fail_count + 1
  print(string.format(
    "  FAIL  assertion-count floor: ran %d, expected >= %d — a conditional "
    .. "block was silently skipped (coverage vanished with no failure)",
    total_asserts, MIN_ASSERTIONS))
else
  print(string.format("  PASS  assertion-count floor (%d >= %d)",
    total_asserts, MIN_ASSERTIONS))
  pass_count = pass_count + 1
end

-- ───────────────────── summary ─────────────────────
print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
