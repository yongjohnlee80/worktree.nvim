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
-- :WorktreeAuth — register / inspect / clear credential profiles (item A1).
--
-- There was previously NO way to register a forge token short of calling
-- require("worktree.credentials").set_profile by hand, so GetPR was unusable
-- out of the box. Usage:
--   :WorktreeAuth list
--   :WorktreeAuth set <key> env <VAR>
--   :WorktreeAuth set <key> command <exe> [args...]   (exe must be allowlisted)
--   :WorktreeAuth clear <key>
-- <key> is a repo slug (e.g. monstercat__lm) or a forge host (e.g. github.com);
-- resolve_token tries slug then host then env.
vim.api.nvim_create_user_command("WorktreeAuth", function(opts)
  local creds = require("worktree.credentials")
  local a = opts.fargs
  local sub = a[1]
  if sub == "list" then
    local profs = creds.list_profiles()
    if vim.tbl_isempty(profs) then
      vim.notify("WorktreeAuth: no credential profiles configured", vim.log.levels.INFO)
      return
    end
    local lines = { "WorktreeAuth profiles:" }
    for key, p in pairs(profs) do
      local shape = p.kind == "env" and ("env " .. tostring(p.var))
        or p.kind == "command" and ("command " .. table.concat(p.argv or {}, " "))
        or p.kind
      lines[#lines + 1] = string.format("  %-28s %s  (%s)", key, shape, p.source or "?")
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  elseif sub == "clear" then
    local key = a[2]
    if not key then vim.notify("WorktreeAuth clear <key>", vim.log.levels.ERROR); return end
    creds.clear_profile(key)
    vim.notify("WorktreeAuth: cleared profile for " .. key, vim.log.levels.INFO)
  elseif sub == "set" then
    local key, kind = a[2], a[3]
    if not key or not kind then
      vim.notify("WorktreeAuth set <key> env <VAR> | command <exe> [args...]", vim.log.levels.ERROR); return
    end
    local ok, err = pcall(function()
      if kind == "env" then
        creds.set_profile(key, { kind = "env", var = a[4] })
      elseif kind == "command" then
        local argv = {}
        for i = 4, #a do argv[#argv + 1] = a[i] end
        creds.set_profile(key, { kind = "command", argv = argv })
      else
        error("kind must be 'env' or 'command', got '" .. tostring(kind) .. "'")
      end
    end)
    if ok then
      vim.notify(string.format("WorktreeAuth: set %s profile for %s", kind, key), vim.log.levels.INFO)
    else
      vim.notify("WorktreeAuth: " .. tostring(err), vim.log.levels.ERROR)
    end
  else
    vim.notify("WorktreeAuth <list|set|clear>", vim.log.levels.ERROR)
  end
end, {
  nargs = "*",
  desc = "Worktree: manage forge credential profiles (list/set/clear)",
  complete = function(_, line)
    local n = select(2, line:gsub("%s+", " "))
    if n <= 1 then return { "list", "set", "clear" } end
    return {}
  end,
})

vim.api.nvim_create_user_command("WorktreeGetPR", function(opts)
  local arg = opts.fargs[1]
  local pr_num = tonumber(arg)
  local function go(num)
    if not num then return end
    -- B8: act on the repo the cursor/cwd is IN, not blindly repos()[1], and
    -- REFUSE when cwd is a repo outside the inventory (lector PR #23). The
    -- resolution + refusal live in worktree.repos.getpr_target_repo so they are
    -- unit-tested.
    local repos_mod = require("worktree.repos")
    local repo, rerr = repos_mod.getpr_target_repo(vim.fn.getcwd())
    if not repo then
      vim.notify("WorktreeGetPR: " .. tostring(rerr), vim.log.levels.ERROR)
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
  -- `pr.lock_key`, not a local derivation. Two defects, one line:
  --   1. `pr_mod.parse_remote_url` has never existed (the module exports
  --      `parse_remote`, returning a TABLE, not a `forge, owner, name`
  --      triple), so this command died on its first line with "attempt to
  --      call field 'parse_remote_url' (a nil value)" — the documented
  --      recovery for a stuck PR lock could not be run at all.
  --   2. even repaired in place, `owner .. "/" .. name` is not the key
  --      `post_feedback` locks under (`repo.slug`, i.e. `owner__name`), so it
  --      would address a lock file that never existed.
  local forge, repo_slug = pr_mod.lock_key(r)
  local pr_num = tonumber(opts.args)
  local force = opts.bang
  local function go(num)
    local function do_recover()
      local ok, err = pr_mod.recover_lock(forge or "github", repo_slug, num, { force = force })
      if ok then
        vim.notify(string.format("worktree: recovered lock for PR #%s", tostring(num)), vim.log.levels.INFO)
      else
        vim.notify(string.format("worktree: failed to recover lock for PR #%s: %s", tostring(num), tostring(err)), vim.log.levels.ERROR)
      end
    end

    if force then
      do_recover()
    else
      local prompt = string.format("Recover lock for PR #%s? (Quiescence requirement: ensure no active posting worker is running for this PR)", tostring(num))
      vim.ui.select({ "yes", "no" }, { prompt = prompt }, function(choice)
        if choice == "yes" then
          do_recover()
        else
          vim.notify("worktree: recovery cancelled", vim.log.levels.INFO)
        end
      end)
    end
  end
  if pr_num then
    go(pr_num)
  else
    vim.ui.input({ prompt = "Recover lock for PR #: " }, function(input)
      if input and input ~= "" then go(tonumber(input) or input) end
    end)
  end
end, { bang = true, nargs = "?", desc = "Worktree: recover stale PR lock (requires quiescence: no active posters for PR)" })

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
