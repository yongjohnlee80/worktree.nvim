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

-- ── §1 auto-finder absent: a REASON, never silence ──────────────────
package.loaded["auto-finder.views.repos.tree"] = nil
local real_searchers = package.preload["auto-finder.views.repos.tree"]
package.preload["auto-finder.views.repos.tree"] = function()
  error("auto-finder is not installed")
end
local ok1, err1 = graph._open_repos_diff(REPO, COMMIT)
ok("without auto-finder it refuses rather than crashing", ok1 == false, tostring(ok1))
ok("...and names why", type(err1) == "string" and err1:find("auto%-finder") ~= nil, tostring(err1))
package.preload["auto-finder.views.repos.tree"] = real_searchers

local ok2, err2 = graph._open_repos_diff(REPO, { hash = nil })
ok("no commit under the cursor is refused", ok2 == false, tostring(ok2))
ok("...with its own reason", (err2 or ""):find("commit", 1, true) ~= nil, tostring(err2))

-- ── §2 the row handed to open_diff ──────────────────────────────────
local captured
package.loaded["auto-finder.views.repos.tree"] = {
  open_diff = function(row) captured = row; return true end,
}
local ok3 = graph._open_repos_diff(REPO, COMMIT)
ok("open_repos_diff reports success", ok3 == true)
ok("it called auto-finder's open_diff", captured ~= nil)

if captured then
  ok("row.kind is commit", captured.kind == "commit", captured.kind)
  ok("node.sha is the full hash", captured.node and captured.node.sha == SHA,
    captured.node and captured.node.sha)
  ok("node.short is the 7-char form", captured.node and captured.node.short == SHA:sub(1, 7),
    captured.node and captured.node.short)
  -- The float titles itself with this; gitgraph calls it `msg`, the view
  -- reads `commit.subject`. A mismatch renders an empty title, not an error.
  ok("node.commit.subject carries gitgraph's msg",
    captured.node and captured.node.commit and captured.node.commit.subject == "the subject line",
    captured.node and captured.node.commit and captured.node.commit.subject)
  -- Without a slug the review store and the authoring draft have no key, so
  -- annotate and submit would be dead on arrival — the whole point of routing
  -- here rather than to the flat float.
  ok("repo.slug was resolved from the remote", type(captured.repo.slug) == "string"
    and captured.repo.slug ~= "", tostring(captured.repo and captured.repo.slug))
  ok("repo.slug names this repo", (captured.repo.slug or ""):find("proj", 1, true) ~= nil,
    captured.repo.slug)
  ok("repo.common_dir is carried", captured.repo.common_dir == REPO.common_dir,
    captured.repo.common_dir)
  -- open_diff hands `worktree` to the diff view so whole-file context can be
  -- read; nil here would silently degrade `T`/`X` to the hunk render.
  ok("worktree.path is the checkout", captured.worktree and captured.worktree.path == repo_dir,
    captured.worktree and captured.worktree.path)
  ok("repo.sample_worktree is carried", captured.repo.sample_worktree == repo_dir,
    captured.repo.sample_worktree)
end

-- a declining view is reported, not swallowed
package.loaded["auto-finder.views.repos.tree"] = {
  open_diff = function() return false, "no diff for this commit" end,
}
local ok4, err4 = graph._open_repos_diff(REPO, COMMIT)
ok("a declining diff view is reported", ok4 == false, tostring(ok4))
ok("...carrying the view's own reason",
  (err4 or ""):find("no diff for this commit", 1, true) ~= nil, tostring(err4))

-- a THROWING view must not take the keypress down with it
package.loaded["auto-finder.views.repos.tree"] = {
  open_diff = function() error("boom inside the view") end,
}
local ok5, err5 = graph._open_repos_diff(REPO, COMMIT)
ok("a throwing diff view is caught", ok5 == false, tostring(ok5))
ok("...and its error is surfaced", (err5 or ""):find("boom", 1, true) ~= nil, tostring(err5))
package.loaded["auto-finder.views.repos.tree"] = nil

-- ── §3 `o` is actually bound ────────────────────────────────────────
local scratch = vim.api.nvim_create_buf(false, true)
graph._bind_pane_action_keys(scratch)
local have = {}
for _, m in ipairs(vim.api.nvim_buf_get_keymap(scratch, "n")) do have[m.lhs] = m.desc or "" end
ok("`o` is bound on the graph pane", have["o"] ~= nil)
ok("`o` says what it opens", (have["o"] or ""):find("repos diff", 1, true) ~= nil, have["o"])
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
