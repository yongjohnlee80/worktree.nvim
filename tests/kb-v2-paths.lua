-- KB v2 paths (ADR 1791209946 §6): paired reviews live under `reviews/<reviewer>/`, PR records
-- under `prs/<slug>/`, and the KB root comes from auto-core's one resolver. With no KB, nothing
-- falls back to one person's KB: the PR record has nowhere to go and says so, the listing is empty,
-- and the association lock is still one name per repo.
--
-- Run headless:  nvim --headless -u NONE -l tests/kb-v2-paths.lua
local plugin_root = vim.fn.fnamemodify(
  vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p"), ":h:h")
local LAZY = vim.fn.expand("~/.local/share/nvim/lazy")
local siblings = vim.fn.fnamemodify(plugin_root, ":h:h")
local branch_dir = vim.fn.fnamemodify(plugin_root, ":t")
for _, p in ipairs({
  LAZY .. "/auto-core.nvim",
  siblings .. "/auto-core.nvim/main",
  siblings .. "/auto-core.nvim/" .. branch_dir,
  plugin_root,
}) do
  if vim.fn.isdirectory(p) == 1 then vim.opt.runtimepath:prepend(p) end
end
local sb = vim.fn.tempname() .. "-kbv2"
vim.fn.mkdir(sb, "p")
for _, x in ipairs({ "STATE", "DATA", "CONFIG", "CACHE" }) do
  vim.env["XDG_" .. x .. "_HOME"] = sb .. "/" .. x:lower()
end

local pass, fail = 0, 0
local function ok(n, c, d)
  if c then pass = pass + 1; print("  PASS  " .. n)
  else fail = fail + 1; print("  FAIL  " .. n .. (d and ("  — " .. tostring(d)) or "")) end
end

local pr = require("worktree.pr")
local review = require("worktree.review")
local repo = { slug = "autodoc" }

-- no KB at all
vim.env.AUTO_AGENTS_KB_ROOT = nil
package.loaded["auto-core.todo.vars"] = { get = function() return nil end }
ok("no KB resolves: kb_root is nil, never a fixed fallback", pr.kb_root() == nil, tostring(pr.kb_root()))
ok("no KB: prs_dir is nil", pr.prs_dir(repo) == nil)
ok("no KB: the PR listing is empty", #pr.kb_docs(repo) == 0)
local path, err = pr.write_kb_doc(repo, { number = 7, title = "t" }, "feat/x")
ok("no KB: writing the PR record is refused, and says why", path == nil and tostring(err):find("no KB root", 1, true) ~= nil, err)
local lock = pr.association_lock(repo)
ok("no KB: the association lock is still one name per repo, under the state dir",
  lock:find(vim.fn.stdpath("state"), 1, true) == 1 and lock:find("/autodoc/.association", 1, true) ~= nil, lock)

-- a KB, through auto-core's resolver
local kb = sb .. "/kb"
vim.fn.mkdir(kb, "p")
package.loaded["auto-core.todo.vars"] = { get = function(name) return name == "KB_ROOT" and kb or nil end }
ok("kb_root is auto-core's KB_ROOT", pr.kb_root() == kb, tostring(pr.kb_root()))
ok("PR records live under prs/<slug>/", pr.prs_dir(repo) == kb .. "/prs/autodoc", tostring(pr.prs_dir(repo)))
ok("the record is pr-<N>.md there", pr.kb_doc_path(repo, 7) == kb .. "/prs/autodoc/pr-7.md")
local doc = review.canonical_document({ kb_root = kb, reviewer_slug = "lector", revision = 2, date = "2026-10-06",
  slug = "autodoc", topic = "kb-v2" })
ok("a paired review lives under reviews/<reviewer>/",
  type(doc) == "string" and doc:find(kb .. "/reviews/lector/2026-10-06-", 1, true) == 1, tostring(doc))
ok("nothing names the old agents/<reviewer>/reviews/ tree", type(doc) == "string" and not doc:find("/agents/", 1, true))

print(string.format("%d passed, %d failed", pass, fail))
vim.fn.delete(sb, "rf")
os.exit(fail == 0 and 0 or 1)
