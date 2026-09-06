-- tests/adr0083-graph-repos-diff.lua — `o` on the graph commit tree opens the
-- repos diff view, plus the diff-float hardening that shipped with it.
--
-- Johno, 2026-09-06: "there are cases (and somewhat frequently) for me to go
-- back in the commit history to see the exact files changed under the commit".
-- `<CR>` gives one flat unified float; `o` gives auto-finder's file list, a/b
-- panes and the annotate + submit surface.
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local siblings = vim.fn.fnamemodify(plugin_root, ":h:h")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
for _, p in ipairs({
  LAZY .. "/plenary.nvim",
  LAZY .. "/auto-core.nvim",
  siblings .. "/auto-core.nvim/main",
  siblings .. "/auto-core.nvim/" .. branch_dir,
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
vim.o.columns, vim.o.lines = 200, 60

local pass_count, fail_count = 0, 0
local function ok(name, cond, details)
  if cond then
    pass_count = pass_count + 1
    print("  PASS  " .. name)
  else
    fail_count = fail_count + 1
    print("  FAIL  " .. name .. (details and ("  — " .. tostring(details)) or ""))
  end
end

print("ADR-0083 — graph `o` opens the repos diff view")

local graph = require("worktree.graph")

-- ── a real repo, so remote_identity resolves a real slug ────────────
local sb = vim.fn.tempname() .. "-graph-o"
vim.fn.mkdir(sb, "p")
local repo_dir = sb .. "/proj"
vim.fn.mkdir(repo_dir, "p")
local function git(...)
  local r = vim.system({ "git", "-C", repo_dir, ... }, { text = true }):wait()
  if r.code ~= 0 then error("git failed: " .. tostring(r.stderr)) end
  return vim.trim(r.stdout or "")
end
git("init", "-q", "-b", "main")
git("config", "user.email", "t@example.com")
git("config", "user.name", "t")
git("remote", "add", "origin", "git@github.com:lab/proj.git")
vim.fn.writefile({ "one", "two" }, repo_dir .. "/f.lua")
git("add", "f.lua")
git("commit", "-q", "-m", "the subject line")
local SHA = git("rev-parse", "HEAD")

local REPO = {
  common_dir = repo_dir .. "/.git",
  label = "proj",
  is_bare = false,
  sample_worktree = repo_dir,
}
local COMMIT = { hash = SHA, msg = "the subject line" }

-- ── §1 THE POINT OF THIS SUITE: no auto-finder anywhere ─────────────
-- worktree used to reach UP into auto-finder for this view, inverting the
-- family's order. It now assembles from worktree.repos + worktree.review +
-- auto-core. Poisoning the auto-finder module proves the path never touches it:
-- if anything still required it, this errors instead of opening.
package.loaded["auto-finder.views.repos.tree"] = nil
package.preload["auto-finder.views.repos.tree"] = function()
  error("auto-finder must NOT be required by this path", 0)
end

local ok2, err2 = graph._open_repos_diff(REPO, { hash = nil })
ok("no commit under the cursor is refused", ok2 == false, tostring(ok2))
ok("...with its own reason", (err2 or ""):find("commit", 1, true) ~= nil, tostring(err2))

-- ── §1b gitgraph hands an ABBREVIATED hash ──────────────────────────
-- The regression this suite failed to catch. gitgraph's commit objects carry a
-- SHORT hash (measured live: "bd3a4c495", 9 chars), and
-- auto-core.review.draft.scope requires 40 hex — deliberately, since two
-- commits can share a prefix and a colliding scope merges two reviewers'
-- drafts. scope() returns nil, draft() indexes the nil the store hands back,
-- and `o` dies with:
--   draft.lua:202: attempt to index local 'd' (a nil value)
--
-- The first version of this suite fabricated `{ hash = <full 40-hex> }` from
-- `git rev-parse HEAD`, so it pinned MY ASSUMPTION of gitgraph's contract
-- instead of gitgraph's. This drives the real shape.
local SHORT = SHA:sub(1, 9)
local captured_short
local dv_pre = require("auto-core.ui.diffview")
local real_open_pre = dv_pre.open
dv_pre.open = function(opts) captured_short = opts; return { stub = true }, nil end
local ok_short, err_short = graph._open_repos_diff(REPO, { hash = SHORT, msg = "the subject line" })
dv_pre.open = real_open_pre
ok("an abbreviated gitgraph hash opens rather than erroring", ok_short == true,
  tostring(err_short))
ok("...and the view is handed the FULL 40-hex sha",
  captured_short and captured_short.sha == SHA,
  captured_short and tostring(captured_short.sha))
ok("...so the annotate surface is enabled, not disabled",
  captured_short and type(captured_short.annotate) == "table"
    and captured_short.annotate.disabled_reason == nil,
  captured_short and captured_short.annotate and captured_short.annotate.disabled_reason)

-- ── §2 what it hands the shared diff view ───────────────────────────
local captured
local dv = require("auto-core.ui.diffview")
local real_open = dv.open
dv.open = function(opts) captured = opts; return { stub = true }, nil end
local ok3 = graph._open_repos_diff(REPO, COMMIT)
dv.open = real_open
ok("open_repos_diff reports success", ok3 == true)
ok("it called auto-core.ui.diffview.open", captured ~= nil)
ok("it did NOT require auto-finder", package.loaded["auto-finder.views.repos.tree"] == nil,
  "the whole point of step 3")

if captured then
  ok("files came from worktree.repos.diff", type(captured.files) == "table"
    and #captured.files > 0, "#files=" .. tostring(captured.files and #captured.files))
  -- Both are load-bearing: auto-core's _sides_full shells out to
  -- `git -C <dir> show <rev>:<path>` and, given neither, silently returns the
  -- HUNK render while the footer claims full context (auto-finder v0.4.22).
  ok("sha is passed through", captured.sha == SHA, tostring(captured.sha))
  ok("worktree is passed through", captured.worktree == repo_dir, tostring(captured.worktree))
  -- gitgraph calls the subject `msg`; the title reads it. A mismatch renders an
  -- empty title rather than erroring, so it is asserted rather than eyeballed.
  ok("title carries the short sha", (captured.title or ""):find(SHA:sub(1, 7), 1, true) ~= nil,
    captured.title)
  ok("title carries gitgraph's msg",
    (captured.title or ""):find("the subject line", 1, true) ~= nil, captured.title)
  -- Without a slug the draft has no stable key, so the annotate surface must be
  -- DISABLED with a reason rather than silently dropping the reviewer's work.
  ok("annotate surface is enabled for a repo with a remote",
    type(captured.annotate) == "table" and captured.annotate.disabled_reason == nil
      and type(captured.annotate.on_add) == "function",
    tostring(captured.annotate and captured.annotate.disabled_reason))
  ok("annotations table is present", type(captured.annotations) == "table")

  -- The draft must be the SHARED one, keyed <slug>@<40-hex> in auto-core, so an
  -- annotation made from the graph is the same draft auto-finder's panel sees.
  local drafts = require("auto-core.review.draft")
  local ident = require("worktree.store").remote_identity(REPO.common_dir)
  -- Do NOT discard first: `annotate.on_add` closes over the draft TABLE taken
  -- when the view opened, and discarding the scope out from under it leaves the
  -- closure appending to an orphan. That is a real property of the store, not a
  -- test artifact — measure the DELTA instead of assuming an empty start.
  local before_n = #((drafts.peek(ident.slug, SHA) or {}).items or {})
  captured.annotate.on_add({ path = "f.lua", line = 1, anchored = true,
                             severity = "nit", body = "from the graph" })
  local shared = drafts.peek(ident.slug, SHA)
  local after_n = #((shared or {}).items or {})
  ok("the finding lands in auto-core's SHARED draft store", after_n == before_n + 1,
    ("before=%d after=%d"):format(before_n, after_n))
  ok("...and it is the finding we added", (function()
    for _, c in ipairs((shared or {}).items or {}) do
      if c.body == "from the graph" then return true end
    end
    return false
  end)())
  ok("...under the slug@sha key the panel uses",
    drafts.scope(ident.slug, SHA) ~= nil, tostring(drafts.scope(ident.slug, SHA)))
  ok("on_remove takes it back out", (function()
    captured.annotate.on_remove({ path = "f.lua", line = 1, side = "RIGHT" })
    local d2 = drafts.peek(ident.slug, SHA)
    return d2 == nil or #(d2.items or {}) == 0
  end)())
  drafts.discard(ident.slug, SHA)
end

-- a refusing view is reported, not swallowed
dv.open = function() return nil, "window too narrow" end
local ok4, err4 = graph._open_repos_diff(REPO, COMMIT)
dv.open = real_open
ok("a refusing diff view is reported", ok4 == false, tostring(ok4))
ok("...carrying the view's own reason",
  (err4 or ""):find("window too narrow", 1, true) ~= nil, tostring(err4))

-- a repo whose diff is empty must say so rather than opening an empty view
local real_diff = require("worktree.repos").diff
require("worktree.repos").diff = function() return {} end
local ok5, err5 = graph._open_repos_diff(REPO, COMMIT)
require("worktree.repos").diff = real_diff
ok("an empty diff is refused", ok5 == false, tostring(ok5))
ok("...naming the commit", (err5 or ""):find(SHA:sub(1, 7), 1, true) ~= nil, tostring(err5))

-- ── §3 `o` is actually bound ────────────────────────────────────────
local scratch = vim.api.nvim_create_buf(false, true)
graph._bind_pane_action_keys(scratch)
local have = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(scratch, "n")) do have[m.lhs] = m.desc or "" end
ok("`o` is bound on the graph pane", have["o"] ~= nil)
ok("`o` says what it opens", (have["o"] or ""):find("diff view", 1, true) ~= nil, have["o"])
-- f/F keep their existing meaning in THIS surface (fetch), which differs from
-- the diff view's f/F (file nav). Different buffers, so no collision — but a
-- regression here would silently steal a fetch key.
ok("`f` still fetches in the graph pane", (have["f"] or ""):find("fetch", 1, true) ~= nil, have["f"])
ok("`F` still fetches all in the graph pane", (have["F"] or ""):find("fetch", 1, true) ~= nil, have["F"])

-- ── §4 the flat float no longer inherits folds or swallows errors ───
graph._open_diff_float(REPO, COMMIT, { "diff --git a/f.lua b/f.lua", "@@ -1 +1 @@", "-one", "+ONE" })
local fwin = vim.api.nvim_get_current_win()
ok("float sets foldmethod explicitly",
  vim.api.nvim_get_option_value("foldmethod", { win = fwin, scope = "local" }) == "syntax",
  vim.api.nvim_get_option_value("foldmethod", { win = fwin, scope = "local" }))
ok("float opens folds rather than inheriting a husk view",
  vim.api.nvim_get_option_value("foldlevel", { win = fwin, scope = "local" }) == 99,
  vim.api.nvim_get_option_value("foldlevel", { win = fwin, scope = "local" }))
local fbuf = vim.api.nvim_win_get_buf(fwin)
ok("float rendered the diff", vim.api.nvim_buf_line_count(fbuf) == 4,
  vim.api.nvim_buf_line_count(fbuf))
pcall(vim.api.nvim_win_close, fwin, true)

-- a line git could never produce, but nvim_buf_set_lines rejects: the old
-- bare pcall left a blank float and said nothing.
graph._open_diff_float(REPO, COMMIT, { "fine", "bad\nline" })
local ewin = vim.api.nvim_get_current_win()
local ebuf = vim.api.nvim_win_get_buf(ewin)
local etext = table.concat(vim.api.nvim_buf_get_lines(ebuf, 0, -1, false), " ")
ok("an unrenderable diff SAYS so instead of showing blank",
  etext:find("could not be rendered", 1, true) ~= nil, etext)
pcall(vim.api.nvim_win_close, ewin, true)

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then os.exit(1) end
os.exit(0)
