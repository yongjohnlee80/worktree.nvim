-- worktree.nvim -- plugin entry. Registers user commands and lazily
-- captures the startup cwd as the default "root" so require-order doesn't
-- matter. User config / keymaps live in the user's setup(opts) call.

if vim.g.loaded_worktree == 1 then return end
vim.g.loaded_worktree = 1

local function user_cmd(name, fn, desc)
  vim.api.nvim_create_user_command(name, function()
    require("worktree")[fn]()
  end, { desc = desc })
end

user_cmd("WorktreePick", "pick", "Worktree: switch")
user_cmd("WorktreeHome", "home", "Worktree: back to root")
user_cmd("WorktreeAdd", "add", "Worktree: add")
user_cmd("WorktreeRemove", "remove", "Worktree: remove")
user_cmd("WorktreeClone", "clone", "Worktree: clone a remote into a bare+worktree layout")
user_cmd("WorktreeInit", "init", "Worktree: init a new project in a bare+worktree layout")

-- ADR 0007 Phase 3: multi-repo graph view absorbed from gitsgraph.
-- `:WorktreeGraph` toggles the panel; `:WorktreeGraphRefresh` drops
-- caches and re-fans-out under the workspace root.
vim.api.nvim_create_user_command("WorktreeGraph", function()
  require("worktree").graph.toggle()
end, { desc = "Worktree: toggle multi-repo graph view" })
vim.api.nvim_create_user_command("WorktreeGraphRefresh", function()
  require("worktree").graph.refresh()
end, { desc = "Worktree: refresh graph view (drops caches)" })

-- ADR-0083 §2.6: PR actions
vim.api.nvim_create_user_command("WorktreeGetPR", function(opts)
  local arg = opts.fargs[1]
  local pr_num = tonumber(arg)
  local function go(num)
    if not num then return end
    local repos_mod = require("worktree.repos")
    local root_repos = repos_mod.repos()
    local repo = root_repos[1]
    if not repo then
      vim.notify("WorktreeGetPR: no repository found in workspace", vim.log.levels.ERROR)
      return
    end
    local pr_mod = require("worktree.pr")
    local res = pr_mod.fetch_and_create_worktree(repo, num)
    if res and res.ok then
      vim.notify(string.format("WorktreeGetPR: fetched PR #%s into %s", tostring(num), tostring(res.branch)), vim.log.levels.INFO)
    else
      vim.notify(string.format("WorktreeGetPR: failed — %s", tostring(res and res.error or "unknown")), vim.log.levels.ERROR)
    end
  end
  if pr_num then
    go(pr_num)
  else
    vim.ui.input({ prompt = "Fetch PR #: " }, function(input)
      if input and input ~= "" then go(tonumber(input) or input) end
    end)
  end
end, { nargs = "?", desc = "Worktree: fetch PR branch and create worktree (ADR-0083)" })

vim.api.nvim_create_user_command("WorktreeCreatePR", function(opts)
  local repos_mod = require("worktree.repos")
  local root_repos = repos_mod.repos()
  local repo = root_repos[1]
  if not repo then
    vim.notify("WorktreeCreatePR: no repository found in workspace", vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = "PR Title: " }, function(title)
    if not title or title == "" then return end
    vim.ui.input({ prompt = "PR Description: " }, function(body)
      local pr_mod = require("worktree.pr")
      local wt_list = repos_mod.worktrees(repo)
      local wt = wt_list[1]
      local res = pr_mod.create_pr(repo, {
        title = title,
        body = body or "",
        head = wt and wt.branch or "HEAD",
        base = repo.default_branch or "main",
      })
      if res and res.ok then
        vim.notify(string.format("WorktreeCreatePR: created PR #%s", tostring(res.pr and res.pr.number or "")), vim.log.levels.INFO)
      else
        vim.notify(string.format("WorktreeCreatePR: failed — %s", tostring(res and res.error or "unknown")), vim.log.levels.ERROR)
      end
    end)
  end)
end, { desc = "Worktree: create PR for active branch (ADR-0083)" })

vim.api.nvim_create_user_command("WorktreePostPRFeedback", function(opts)
  local arg = opts.fargs[1]
  local pr_num = tonumber(arg)
  local function go(num)
    if not num then return end
    local repos_mod = require("worktree.repos")
    local root_repos = repos_mod.repos()
    local repo = root_repos[1]
    if not repo then
      vim.notify("WorktreePostPRFeedback: no repository found in workspace", vim.log.levels.ERROR)
      return
    end
    local pr_mod = require("worktree.pr")
    local revs = repos_mod.reviews_for_pr(repo, num)
    local res = pr_mod.post_feedback(repo, num, revs)
    if res and res.ok then
      vim.notify(string.format("WorktreePostPRFeedback: feedback posted for PR #%s", tostring(num)), vim.log.levels.INFO)
    else
      vim.notify(string.format("WorktreePostPRFeedback: failed — %s", tostring(res and res.error or "unknown")), vim.log.levels.ERROR)
    end
  end
  if pr_num then
    go(pr_num)
  else
    vim.ui.input({ prompt = "Post feedback for PR #: " }, function(input)
      if input and input ~= "" then go(tonumber(input) or input) end
    end)
  end
end, { nargs = "?", desc = "Worktree: post review feedback to PR (ADR-0083)" })

vim.api.nvim_create_user_command("WorktreeRecoverPRLock", function(opts)
  local pr_mod = require("worktree.pr")
  local repo_mod = require("worktree.repos")
  local repos = repo_mod.repos()
  local r = repos and repos[1]
  local forge, owner, name = pr_mod.parse_remote_url(r and r.url or "")
  local repo_slug = (owner and name) and (owner .. "/" .. name) or (r and r.slug or "repo")
  local pr_num = tonumber(opts.args)
  local force = opts.bang
  local function go(num)
    local ok, err = pr_mod.recover_lock(forge or "github", repo_slug, num, { force = force })
    if ok then
      vim.notify(string.format("worktree: recovered lock for PR #%s", tostring(num)), vim.log.levels.INFO)
    else
      vim.notify(string.format("worktree: failed to recover lock for PR #%s: %s", tostring(num), tostring(err)), vim.log.levels.ERROR)
    end
  end
  if pr_num then
    go(pr_num)
  else
    vim.ui.input({ prompt = "Recover lock for PR #: " }, function(input)
      if input and input ~= "" then go(tonumber(input) or input) end
    end)
  end
end, { bang = true, nargs = "?", desc = "Worktree: recover stale PR review lock (ADR-0083)" })

-- Capture the startup cwd as the workspace root.
--
-- Two paths because lazy.nvim can source plugin/ either BEFORE
-- VimEnter (eager spec) or AFTER (lazy on event/cmd/keys). For the
-- eager case, register a VimEnter autocmd. For the lazy case, run
-- immediately — `vim.v.vim_did_enter` is set once VimEnter fired,
-- so we know our autocmd above will never trigger and capture now
-- instead. ensure-root is idempotent (no-op if already set).
local function _ensure_root_now()
  -- Route through M.ensure_root so the workspace root is the RESOLVED
  -- stable project identity (`.auto-agents/` → `.bare` → repo root →
  -- cwd), not the raw launch cwd. Pinning the raw cwd made per-project
  -- state (auto-finder panels, md-harpoon pins, both keyed on
  -- sha256(core.workspace_root)) key differently for every directory
  -- nvim was launched from. ensure_root() carries its own
  -- already-set guard, so this stays idempotent.
  require("worktree").ensure_root()
end

if vim.v.vim_did_enter == 1 then
  -- Lazy-loaded post-VimEnter: capture immediately. Without this,
  -- worktree.set_workspace_root never fires (the VimEnter autocmd
  -- below registers a handler for an event that already happened),
  -- which leaves auto-core's core.workspace_root nil and starves
  -- every consumer (auto-finder repos panel, md-harpoon's per-
  -- project pin keying, etc.) of the canonical workspace key.
  _ensure_root_now()
else
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = _ensure_root_now,
  })
end
