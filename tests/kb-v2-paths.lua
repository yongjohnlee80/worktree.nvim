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

-- the record follows the KB's `pr` type (ADR 1791209946 §4.4): what _schema/frontmatter.yaml requires
local function fm_of(p)
  local out, n = {}, 0
  for _, l in ipairs(vim.fn.readfile(p)) do
    if l == "---" then n = n + 1; if n == 2 then break end
    elseif n == 1 then local k, v = l:match("^([%w_]+):%s*(.*)$"); if k then out[k] = v end end
  end
  return out
end
local p7 = pr.write_kb_doc(repo, { number = 7, title = 'say "hi"', state = "open", base_ref = "main",
  created_at = "2026-10-06T01:02:03Z", updated_at = "2026-10-06T01:02:03Z", author = "johno" }, "feat/x")
local f7 = fm_of(p7)
ok("the record carries the schema's required fields: type, status, created, tags, abstract",
  f7.type == "pr" and f7.status == "active" and f7.created == "2026-10-06T01:02:03Z" and f7.tags == '[pr, "autodoc"]'
  and (f7.abstract or ""):find("autodoc PR #7", 1, true) ~= nil, vim.inspect(f7))
ok("the number is `pr:`, an integer, and no `number:` is written", f7.pr == "7" and f7.number == nil, vim.inspect(f7))
ok("the title is quoted so YAML reads it back exactly", f7.title == '"say \\"hi\\""', tostring(f7.title))
local r7 = pr.read_kb_doc(p7)
ok("read back: the number from `pr:`, the title unescaped", r7.number == 7 and r7.title == 'say "hi"' and r7.branch == "feat/x", vim.inspect(r7))
local p8 = pr.write_kb_doc(repo, { number = 8, title = "d", state = "open", draft = true }, "feat/y")
local f8 = fm_of(p8)
ok("a draft is state open with draft: true (state is open|merged|closed)", f8.state == "open" and f8.draft == "true" and f8.status == "active", vim.inspect(f8))
ok("and reads back as a draft", pr.read_kb_doc(p8).draft == true)
local p10 = pr.write_kb_doc(repo, { number = 10, title = "o", state = "draft" }, "feat/w")
ok("an older record's state: draft is rewritten as state open, draft: true", fm_of(p10).state == "open" and fm_of(p10).draft == "true", vim.inspect(fm_of(p10)))
local p9 = pr.write_kb_doc(repo, { number = 9, title = "c", state = "closed" }, "feat/z")
ok("a closed PR's record is status closed", fm_of(p9).status == "closed" and fm_of(p9).state == "closed")
vim.fn.writefile({ "---", "type: pr", "repo: autodoc", "number: 11", "branch: old", "---", "" }, kb .. "/prs/autodoc/pr-11.md")
ok("a record written before `pr:` still reads its `number:`", pr.read_kb_doc(kb .. "/prs/autodoc/pr-11.md").number == 11)

print(string.format("%d passed, %d failed", pass, fail))
vim.fn.delete(sb, "rf")
os.exit(fail == 0 and 0 or 1)
