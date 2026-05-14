-- worktree.graph — multi-repo git-graph view, absorbed from gitsgraph.nvim
-- per ADR 0007 Phase 3.
--
-- Shell:
--   - Multi-pane float via `auto-core.ui.float.multi`
--   - Repo list (left pane) + commit graph (middle pane) + diff stat
--     preview (right pane) + key hint footer
--   - Foundational queries via `auto-core.git.graph` (fan_out, show_stat,
--     show_diff)
--   - Graph rendering still delegated to `isakbm/gitgraph.nvim` —
--     auto-core doesn't ship a renderer; gitsgraph wrapped that
--     plugin and we keep the wrap.
--
-- gitsgraph.nvim's repo IS NOT MODIFIED; this module is a fresh
-- consumer of the auto-core primitives. gitsgraph stays installed
-- and functional until Phase 4 archives it.
--
-- Out of scope (for the v0.X.0 minor that lands Phase 3 — follow-ups):
-- fetch/fetch_all (f/F), pull (p), destroy_worktree (D). The shell
-- below is wired so re-introducing them is purely additive.
--
-- Public surface:
--   M.open()            -- open the multi-float (idempotent — focuses if open)
--   M.close()           -- close + tear down
--   M.toggle()          -- open/close based on current state
--   M.refresh()         -- close + reopen, drops graph caches
--   M.is_open()         -- boolean
--   M.set_root(path)    -- override the workspace root (defaults to
--                          worktree.get_root())

local M = {}

-- ── soft-deps ────────────────────────────────────────────────

local function _core()
  local ok, core = pcall(require, "auto-core")
  if ok and type(core) == "table" then return core end
  return nil
end

-- ── module-level state (one panel at a time) ─────────────────

---@class WorktreeGraphState
---@field mfloat any?              auto-core MultiFloat instance
---@field root string?             workspace root the panel was opened at
---@field repos AutoCoreGraphRepo[]? discovered list (cached on the instance too)
---@field selected integer?         1-based index into repos
---@field preview_timer any?
---@field fetching table<integer, boolean>  repo_idx -> in-flight fetch
---@field show_remote_branches boolean?    toggle for remote branches
---@field line_map table<integer, table>    row -> { kind, repo_idx, worktree?, remote_ref? }
local state = {
  mfloat    = nil,
  root      = nil,
  repos     = nil,
  selected  = nil,
  fetching  = {},
  line_map  = {},
  show_remote_branches = false,
}

local HEADER_LINES = 2
local PANEL_NAME   = "worktree.graph"
local PREVIEW_DEBOUNCE_MS = 100
local DEFAULT_MAX_COUNT = 1024
local DEFAULT_DATE_FORMAT = "%Y-%m-%d %H:%M"

-- Forward decl: defined further down.
local select_repo

-- ── helpers ──────────────────────────────────────────────────

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "worktree.graph" })
end

local function workspace_root()
  -- Read the canonical workspace root from auto-core directly. This
  -- is the same value worktree.get_root() returns (which itself is
  -- a read-through to core.git.worktree.get_workspace_root since
  -- Phase 1 Step 1.3 — see ADR 0007), but skips a hop and avoids
  -- the require("worktree") circular-ish path from inside this
  -- module. Falls back to cwd when auto-core hasn't been seeded
  -- yet (e.g. :WorktreeGraph fired synchronously at startup before
  -- the VimEnter ensure_root autocmd runs).
  local core = _core()
  if core and core.git and core.git.worktree
      and type(core.git.worktree.get_workspace_root) == "function" then
    local r = core.git.worktree.get_workspace_root()
    if type(r) == "string" and r ~= "" then return r end
  end
  return vim.fn.getcwd()
end

local function set_buf_modifiable(buf, mod)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_set_option_value("modifiable", mod, { buf = buf })
  end
end

local function set_buf_lines(buf, lines)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  set_buf_modifiable(buf, true)
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  set_buf_modifiable(buf, false)
end

-- ── left pane: repo list (+ worktree expansion under selected) ──

---List worktrees attached to a bare repo's common_dir, filtering
---out the bare entry itself. Mirrors gitsgraph's behavior using
---auto-core's parse_porcelain: shape is `{ path, branch?, head?,
---bare?, detached? }[]`.
---@param common_dir string
---@return table[]
local function list_worktrees(common_dir)
  if not common_dir or common_dir == "" then return {} end
  local result = vim.system(
    { "git", "--git-dir=" .. common_dir, "worktree", "list", "--porcelain" },
    { text = true }
  ):wait()
  if result.code ~= 0 then return {} end
  local lines = {}
  for line in (result.stdout or ""):gmatch("[^\r\n]+") do
    lines[#lines + 1] = line
  end
  local core = _core()
  local parsed
  if core and core.git and core.git.worktree
      and type(core.git.worktree.parse_porcelain) == "function" then
    parsed = core.git.worktree.parse_porcelain(lines)
  else
    parsed = {}
  end
  -- Filter out the bare entry itself; keep only working trees.
  local out = {}
  for _, e in ipairs(parsed) do
    if not e.bare then out[#out + 1] = e end
  end
  return out
end

local function render_left()
  if not state.mfloat then return end
  local left_buf = state.mfloat:bufnr("left")
  if not left_buf then return end

  local lines = {
    string.format(" Repos (%d) — %s",
      #(state.repos or {}),
      vim.fn.fnamemodify(state.root or "", ":~")),
    "",
  }
  -- line_map mirrors the rendered lines so <CR> / cursor logic can
  -- resolve a row back to its meaning without arithmetic. Header
  -- rows are unmapped (nil) so <CR> on them is a clean no-op.
  state.line_map = {}

  for i, entry in ipairs(state.repos or {}) do
    local marker  = (state.selected == i) and "▶" or " "
    local key     = (i <= 9) and tostring(i) or "·"
    local tag     = entry.is_bare and " (bare)" or ""
    local fetchin = state.fetching[i] and " ⟳" or ""
    lines[#lines + 1] = string.format("%s [%s] %s%s%s",
      marker, key, entry.label, tag, fetchin)
    state.line_map[#lines] = { kind = "repo", repo_idx = i }

    -- Fan out worktrees of the selected repo only. Re-shelled every
    -- render (cheap; `git worktree list` is local-IO only) so freshly-
    -- added worktrees show up without an explicit rescan.
    if state.selected == i and entry.common_dir then
      local wts = list_worktrees(entry.common_dir)
      local show_remotes = state.show_remote_branches
      local remotes = show_remotes
        and require("worktree.git").list_remote_branches(entry.common_dir)
        or {}

      for j, wt in ipairs(wts) do
        local connector = (j == #wts and #remotes == 0) and "└─" or "├─"
        local label = wt.branch or (wt.detached and "(detached)" or "?")
        local head7  = (wt.head or ""):sub(1, 7)
        local suffix = (head7 ~= "") and (" @" .. head7) or ""
        lines[#lines + 1] = string.format("   %s %s%s",
          connector, label, suffix)
        state.line_map[#lines] = {
          kind = "worktree", repo_idx = i, worktree = wt,
        }
      end

      if show_remotes then
        for j, ref in ipairs(remotes) do
          local connector = (j == #remotes) and "└─" or "├─"
          lines[#lines + 1] = string.format("   %s (%s)",
            connector, ref)
          state.line_map[#lines] = {
            kind = "remote_branch", repo_idx = i, remote_ref = ref,
          }
        end
      end
    end
  end

  set_buf_lines(left_buf, lines)
  if vim.api.nvim_buf_is_valid(left_buf) then
    vim.bo[left_buf].filetype = "worktree-graph-repos"
  end
end

local function row_to_hit(row)
  return state.line_map[row]
end

-- ── middle pane: gitgraph delegation ─────────────────────────

local function configure_gitgraph(repo)
  -- gitgraph.setup re-creates its config; we configure on each
  -- repo switch so the on_select hooks see the right repo.
  local ok, gitgraph = pcall(require, "gitgraph")
  if not ok then return false, "gitgraph.nvim not installed" end
  gitgraph.setup({
    format = {
      timestamp = DEFAULT_DATE_FORMAT,
      fields    = { "hash", "timestamp", "author", "branch_name", "tag", "message" },
    },
    hooks = {
      on_select_commit = function(commit)
        M._show_commit_diff(repo, commit)
      end,
      on_select_range_commit = function(from, to)
        M._show_range_diff(repo, from, to)
      end,
    },
  })
  return true
end

-- chdir to the repo's working tree, draw, restore. Mirrors gitsgraph
-- because gitgraph's git module captures `git_cmd` at module load
-- and ignores per-call overrides.
local function draw_graph_for(repo)
  if not state.mfloat then return end
  local middle_win = state.mfloat:winid("middle")
  if not middle_win or not vim.api.nvim_win_is_valid(middle_win) then return end

  local ok, err = configure_gitgraph(repo)
  if not ok then
    set_buf_lines(state.mfloat:bufnr("middle"),
      { "(worktree.graph: " .. err .. ")", "",
        "Install isakbm/gitgraph.nvim or open the diff via",
        "auto-core.git.graph.show_diff() directly." })
    return
  end

  vim.api.nvim_set_current_win(middle_win)
  local target = repo.sample_worktree
    or vim.fn.fnamemodify(repo.common_dir, ":h")
  local prev_cwd
  local ok_cd = pcall(function() prev_cwd = vim.fn.chdir(target) end)
  if not ok_cd or not prev_cwd then
    notify("failed to chdir to " .. target, vim.log.levels.ERROR)
    return
  end
  local draw_ok, draw_err = pcall(function()
    require("gitgraph").draw({}, {
      all       = true,
      max_count = DEFAULT_MAX_COUNT,
    })
  end)
  if prev_cwd and prev_cwd ~= "" then pcall(vim.fn.chdir, prev_cwd) end
  if not draw_ok then
    notify("gitgraph draw failed: " .. tostring(draw_err), vim.log.levels.ERROR)
    return
  end

  -- Update middle pane title.
  pcall(vim.api.nvim_win_set_config, middle_win, {
    title     = " Graph: " .. repo.label .. " ",
    title_pos = "left",
  })

  -- gitgraph creates a fresh buffer per draw — re-bind our action
  -- keys so f/F/p still work from inside the graph pane.
  M._bind_middle_action_keys()
end

-- ── right pane: cursor-driven stat preview ───────────────────

local function current_commit_hash()
  if not state.mfloat then return nil end
  local mid = state.mfloat:winid("middle")
  if not mid or not vim.api.nvim_win_is_valid(mid) then return nil end
  local ok_d, draw_mod = pcall(require, "gitgraph.draw")
  if not ok_d or not draw_mod.graph or #draw_mod.graph == 0 then return nil end
  local ok_u, utils = pcall(require, "gitgraph.utils")
  if not ok_u then return nil end
  local row = vim.api.nvim_win_get_cursor(mid)[1]
  local ok_c, commit = pcall(utils.get_commit_from_row, draw_mod.graph, row)
  if not ok_c or not commit then return nil end
  return commit.hash
end

local function update_preview_now(repo)
  if not state.mfloat then return end
  local pv_buf = state.mfloat:bufnr("preview")
  if not pv_buf then return end
  local hash = current_commit_hash()
  if not hash then
    set_buf_lines(pv_buf, {})
    return
  end
  local core = _core()
  if not core or not core.git or not core.git.graph then
    set_buf_lines(pv_buf, { "(auto-core.git.graph not available)" })
    return
  end
  local lines = core.git.graph.show_stat(repo.common_dir, hash)
  set_buf_lines(pv_buf, lines)
  -- git filetype highlighting on the stat output.
  if vim.api.nvim_buf_is_valid(pv_buf) then
    vim.bo[pv_buf].filetype = "git"
  end
end

local function schedule_preview(repo)
  if state.preview_timer then
    pcall(function()
      state.preview_timer:stop(); state.preview_timer:close()
    end)
    state.preview_timer = nil
  end
  state.preview_timer = vim.defer_fn(function()
    state.preview_timer = nil
    update_preview_now(repo)
  end, PREVIEW_DEBOUNCE_MS)
end

-- ── diff float (CR handler) ──────────────────────────────────

function M._show_commit_diff(repo, commit)
  local core = _core()
  if not (core and core.git and core.git.graph) then return end
  local lines = core.git.graph.show_diff(repo.common_dir, commit.hash)
  if not lines or #lines == 0 then
    notify("git show -p produced no output", vim.log.levels.WARN)
    return
  end
  -- Use vim.api.nvim_open_win directly for the diff float; our
  -- single-float helper would also work but the title + zindex
  -- shape is bespoke enough that inline is clearer here.
  local cols = vim.o.columns
  local rows = vim.o.lines - vim.o.cmdheight - 1
  local w = math.floor(cols * 0.85)
  local h = math.floor(rows * 0.85)
  local row = math.floor((rows - h) / 2)
  local col = math.floor((cols - w) / 2)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype   = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype  = "git"
  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  local title = string.format(" Diff: %s — %s ",
    commit.hash:sub(1, 12), repo.label)
  local win = vim.api.nvim_open_win(buf, true, {
    relative  = "editor",
    row       = row,
    col       = col,
    width     = w - 2,
    height    = h - 2,
    style     = "minimal",
    border    = "rounded",
    title     = title,
    title_pos = "center",
    zindex    = 50,
  })
  vim.wo[win].wrap = false
  vim.wo[win].winhighlight = "Normal:NormalFloat,FloatBorder:FloatBorder"
  pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
  local function close()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
  vim.keymap.set("n", "q",     close, { buffer = buf, silent = true })
  vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
end

function M._show_range_diff(repo, from, to)
  local core = _core()
  if not (core and core.git and core.git.graph) then return end
  -- Range diff: assemble manually via show_diff isn't ideal; fall
  -- back to a fresh git diff against a range. Cache key per (range)
  -- is a separate concern — Phase 3 keeps it simple by re-running.
  local cmd = {
    "git", "--git-dir=" .. repo.common_dir,
    "diff", "--no-color", from.hash .. "~1.." .. to.hash,
  }
  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    notify("git diff range failed", vim.log.levels.ERROR)
    return
  end
  M._show_commit_diff(repo, {
    hash = from.hash:sub(1, 8) .. ".." .. to.hash:sub(1, 8),
  })
  -- ... actually inline the full path so we don't double-fetch:
  local _ = lines  -- TODO: reuse to avoid the double git invocation;
                    -- left as-is for Phase 3 brevity.
end

-- ── select_repo ──────────────────────────────────────────────

select_repo = function(idx)
  local entry = (state.repos or {})[idx]
  if not entry then return end
  state.selected = idx
  -- Clear prior preview so cursor scroll on a fresh repo doesn't
  -- show stale stats while the gitgraph redraws.
  local pv_buf = state.mfloat and state.mfloat:bufnr("preview")
  if pv_buf then set_buf_lines(pv_buf, {}) end

  draw_graph_for(entry)
  render_left()

  -- Bind cursor-move preview on the middle pane.
  if state.mfloat and state.mfloat._augroup then
    pcall(vim.api.nvim_clear_autocmds, {
      group = state.mfloat._augroup, event = { "CursorMoved" },
    })
    vim.api.nvim_create_autocmd("CursorMoved", {
      group = state.mfloat._augroup,
      callback = function()
        local mid = state.mfloat and state.mfloat:winid("middle")
        if mid and vim.api.nvim_get_current_win() == mid then
          schedule_preview(entry)
        end
      end,
    })
  end
  -- Prime once so the preview pane isn't blank on entry.
  update_preview_now(entry)

  -- Move focus back to left pane and park cursor on the selected row.
  local left_win = state.mfloat and state.mfloat:winid("left")
  if left_win and vim.api.nvim_win_is_valid(left_win) then
    vim.api.nvim_set_current_win(left_win)
    pcall(vim.api.nvim_win_set_cursor, left_win,
      { HEADER_LINES + idx, 0 })
  end
end

-- ── fetch / pull / destroy handlers ──────────────────────────
--
-- Mirrors gitsgraph's exact prompt UX (vim.ui.select with the same
-- option labels and prompt strings) so users carry over their
-- muscle memory verbatim. The auto-core APIs are consultative:
-- consumer probes status, prompts, then calls the action with a
-- force/mode argument on confirmation.

local function fetch_one(repo_idx)
  local repo = (state.repos or {})[repo_idx]
  if not repo then return end
  if state.fetching[repo_idx] then return end  -- already in flight
  local core = _core()
  if not (core and core.git and core.git.fetch) then return end
  state.fetching[repo_idx] = true
  render_left()
  notify("fetching " .. repo.label .. "…")
  core.git.fetch.fetch_one(repo, nil, function(ok, stderr)
    state.fetching[repo_idx] = nil
    render_left()
    if ok then
      notify("fetched " .. repo.label)
      if state.selected == repo_idx then select_repo(repo_idx) end
    else
      notify(string.format("fetch failed (%s): %s",
        repo.label, (stderr or ""):gsub("\n+$", "")),
        vim.log.levels.ERROR)
    end
  end)
end

local function fetch_selected()
  if not state.selected then
    notify("no repo selected", vim.log.levels.WARN)
    return
  end
  fetch_one(state.selected)
end

local function fetch_all_repos()
  local core = _core()
  if not (core and core.git and core.git.fetch) then return end
  local repos = state.repos or {}
  if #repos == 0 then return end
  for i, _ in ipairs(repos) do state.fetching[i] = true end
  render_left()
  notify("fetching all (" .. #repos .. ")…")
  core.git.fetch.fetch_all(repos, nil,
    function(idx, ok, repo)
      state.fetching[idx] = nil
      render_left()
      if not ok then
        notify("fetch failed (" .. (repo.label or "?") .. ")",
          vim.log.levels.ERROR)
      end
    end,
    function()
      notify("fetch all done (" .. #repos .. " repos)")
      if state.selected then select_repo(state.selected) end
    end)
end

---Pull one worktree, with the gitsgraph round-trip prompt UX:
--- - clean ff: silent (just notify success)
--- - up-to-date / ahead-clean / detached / no_remote: notify, no action
--- - dirty / diverged / ahead+dirty: prompt "Force pull" / "Cancel"
---@param wt { path: string, branch: string? }
---@param on_done fun()?
local function pull_one_post_fetch(wt, on_done)
  local function done() if on_done then on_done() end end
  local core = _core()
  if not (core and core.git and core.git.pull) then return done() end
  if not wt.branch then
    notify(wt.path .. " is detached — skipping pull", vim.log.levels.WARN)
    return done()
  end
  local s = core.git.pull.pull_status(wt)
  if s.state == "no_remote" then
    notify("no remote ref " .. (s.remote_ref or "?") .. " for " .. wt.path,
      vim.log.levels.WARN)
    return done()
  end
  if s.state == "uptodate" then
    notify(s.branch .. " already at " .. s.remote_ref)
    return done()
  end
  if s.state == "ahead" and not s.dirty then
    notify(s.branch .. " is ahead of " .. s.remote_ref ..
      " — nothing to pull")
    return done()
  end
  -- Clean fast-forward: silent.
  if s.state == "ff" and not s.dirty then
    core.git.pull.pull_apply(wt, "ff", nil, function(ok, err)
      if ok then
        notify("fast-forwarded " .. s.branch .. " → " .. s.remote_ref)
        if state.selected then select_repo(state.selected) end
      else
        notify("ff failed for " .. s.branch .. ": " .. (err or ""),
          vim.log.levels.ERROR)
      end
      done()
    end)
    return
  end
  -- Anything destructive (dirty, diverged, ahead+dirty): prompt.
  local parts = {}
  if s.state == "diverged" then
    parts[#parts + 1] = string.format("%d commit(s) will be discarded",
      s.ahead_count or 0)
  end
  if s.dirty then
    parts[#parts + 1] = string.format("%d file(s) have uncommitted changes",
      s.dirty_count or 0)
  end
  if s.state == "ff" and s.dirty then
    parts[#parts + 1] = "fast-forward possible but working tree dirty"
  end
  local prompt = string.format("%s vs %s — %s", s.branch, s.remote_ref,
    table.concat(parts, "; "))
  vim.ui.select({ "Force pull", "Cancel" }, { prompt = prompt },
    function(choice)
      if choice == "Force pull" then
        core.git.pull.pull_apply(wt, "reset", nil, function(ok, err)
          if ok then
            notify("reset " .. s.branch .. " --hard " .. s.remote_ref)
            if state.selected then select_repo(state.selected) end
          else
            notify("force pull failed for " .. s.branch .. ": " ..
              (err or ""), vim.log.levels.ERROR)
          end
          done()
        end)
      else
        done()
      end
    end)
end

local function pull_one_with_fetch(repo, wt)
  local core = _core()
  if not (core and core.git and core.git.fetch) then return end
  core.git.fetch.fetch_one(repo, nil, function(ok)
    if ok then pull_one_post_fetch(wt) end
  end)
end

local function pull_repo_at(repo_idx)
  local repo = (state.repos or {})[repo_idx]
  if not repo then return end
  local wts = list_worktrees(repo.common_dir)
  if #wts == 0 then
    notify("no worktrees to pull for " .. repo.label, vim.log.levels.WARN)
    return
  end
  local core = _core()
  if not (core and core.git and core.git.fetch) then return end
  core.git.fetch.fetch_one(repo, nil, function(fetched)
    if not fetched then return end
    local i = 0
    local function next_one()
      i = i + 1
      if i > #wts then return end
      pull_one_post_fetch(wts[i], next_one)
    end
    next_one()
  end)
end

local function pull_at_cursor()
  if not state.mfloat then return end
  local cur = vim.api.nvim_get_current_win()
  local left_win = state.mfloat:winid("left")
  if cur == left_win then
    local row = vim.api.nvim_win_get_cursor(left_win)[1]
    local hit = row_to_hit(row)
    if not hit then return end
    if hit.kind == "repo" then
      pull_repo_at(hit.repo_idx)
    elseif hit.kind == "worktree" then
      local repo = (state.repos or {})[hit.repo_idx]
      if repo then pull_one_with_fetch(repo, hit.worktree) end
    end
  else
    if state.selected then pull_repo_at(state.selected) end
  end
end

local function destroy_worktree_at(repo_idx, wt)
  local repo = (state.repos or {})[repo_idx]
  if not repo then return end
  local core = _core()
  if not (core and core.git and core.git.worktree
      and core.git.pull) then return end
  local label = wt.branch or (wt.detached and "(detached)" or wt.path)

  local function apply(force)
    core.git.worktree.destroy(repo, wt, { force = force },
      function(ok, err, branch_err)
        if not ok then
          notify("destroy failed for " .. label .. ": " .. (err or ""),
            vim.log.levels.ERROR)
          return
        end
        if branch_err then
          notify("worktree removed; branch delete failed: " .. branch_err,
            vim.log.levels.WARN)
        else
          local what = wt.branch
            and (wt.path .. " + branch " .. wt.branch)
            or  wt.path
          notify("destroyed " .. what)
        end
        -- If the destroyed path was the sample_worktree, rebind it
        -- so a subsequent select_repo() doesn't chdir into a dead path.
        if repo.sample_worktree == wt.path then
          local live = list_worktrees(repo.common_dir)
          repo.sample_worktree = live[1] and live[1].path or nil
        end
        render_left()
      end)
  end

  local d = core.git.pull.worktree_dirty(wt)
  if d.dirty then
    local prompt = string.format(
      "%s has %d uncommitted change(s) — force destroy worktree + branch?",
      label, d.dirty_count)
    vim.ui.select({ "Force destroy", "Cancel" }, { prompt = prompt },
      function(choice)
        if choice == "Force destroy" then apply(true) end
      end)
    return
  end

  local prompt = wt.branch
    and ("Destroy worktree " .. wt.path
         .. " and local branch " .. wt.branch .. "?")
    or  ("Destroy worktree " .. wt.path .. "?")
  vim.ui.select({ "Destroy", "Cancel" }, { prompt = prompt },
    function(choice)
      if choice == "Destroy" then apply(false) end
    end)
end

local function destroy_at_cursor()
  if not state.mfloat then return end
  local left_win = state.mfloat:winid("left")
  if not left_win or vim.api.nvim_get_current_win() ~= left_win then
    notify("move to a row in the repo pane to destroy",
      vim.log.levels.WARN)
    return
  end
  local row = vim.api.nvim_win_get_cursor(left_win)[1]
  local hit = row_to_hit(row)
  if not hit then return end

  if hit.kind == "worktree" then
    destroy_worktree_at(hit.repo_idx, hit.worktree)
  elseif hit.kind == "remote_branch" then
    local repo = (state.repos or {})[hit.repo_idx]
    if not repo then return end
    local remote_ref = hit.remote_ref
    local remote, branch = remote_ref:match("^([^/]+)/(.+)$")
    if not remote or not branch then return end

    vim.ui.select({ "Delete remote branch", "Cancel" }, {
      prompt = string.format("Delete %s? (push --delete to remote)", remote_ref),
    }, function(choice)
      if choice == "Delete remote branch" then
        local git = require("worktree.git")
        local path = repo.sample_worktree
          or vim.fn.fnamemodify(repo.common_dir, ":h")
        git.delete_remote(path, remote, branch, function(res)
          if res.ok then
            notify("deleted remote branch " .. remote_ref)
            -- Prune local tracking ref so it disappears from UI
            vim.system({ "git", "-C", path, "fetch", "--prune", remote }):wait()
            render_left()
          else
            notify("delete remote failed: " .. (res.stderr or ""),
              vim.log.levels.ERROR)
          end
        end)
      end
    end)
  else
    notify("D destroys a worktree or remote branch — select a valid row",
      vim.log.levels.WARN)
  end
end

local function checkout_at_cursor()
  if not state.mfloat then return end
  local left_win = state.mfloat:winid("left")
  if not left_win or vim.api.nvim_get_current_win() ~= left_win then
    notify("move to a remote branch row in the repo pane to checkout",
      vim.log.levels.WARN)
    return
  end
  local row = vim.api.nvim_win_get_cursor(left_win)[1]
  local hit = row_to_hit(row)
  if not hit or hit.kind ~= "remote_branch" then
    notify("C is for checking out remote branches — select a remote branch row",
      vim.log.levels.WARN)
    return
  end

  local repo = (state.repos or {})[hit.repo_idx]
  if not repo then return end
  local git = require("worktree.git")
  local remote_ref = hit.remote_ref
  local branch_name = remote_ref:match("^[^/]+/(.+)$")

  if repo.is_bare then
    -- Track into a new worktree.
    vim.ui.input({
      prompt = "Local branch name: ",
      default = branch_name,
    }, function(local_name)
      if not local_name or vim.trim(local_name) == "" then return end
      local_name = vim.trim(local_name)
      local container = git.repo_container(repo.common_dir)
      vim.ui.input({
        prompt = "Worktree path: ",
        default = container .. "/" .. local_name,
      }, function(target_path)
        if not target_path or vim.trim(target_path) == "" then return end
        target_path = vim.trim(target_path)
        git.track(repo, remote_ref, local_name, target_path, function(res)
          if res.ok then
            notify("tracking " .. remote_ref .. " → " .. target_path)
            render_left()
          else
            notify("track failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
          end
        end)
      end)
    end)
  else
    -- Regular checkout.
    local root = git.norm(vim.fn.fnamemodify(repo.common_dir, ":h"))
    -- Must-fix 2: use checkout_status probe
    local status = git.checkout_status(root, branch_name)
    if not status.ok then
      notify("refusing to checkout: " .. (status.reason or "?"),
        vim.log.levels.ERROR)
      return
    end

    git.checkout(root, branch_name, function(res)
      if res.ok then
        notify("checked out " .. branch_name)
        render_left()
        if state.selected == hit.repo_idx then draw_graph_for(repo) end
      else
        notify("checkout failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
      end
    end)
  end
end

local function new_at_cursor()
  if not state.mfloat then return end
  local left_win = state.mfloat:winid("left")
  if not left_win or vim.api.nvim_get_current_win() ~= left_win then
    notify("move to a row in the repo pane to create from",
      vim.log.levels.WARN)
    return
  end
  local row = vim.api.nvim_win_get_cursor(left_win)[1]
  local hit = row_to_hit(row)
  if not hit then return end

  local base_ref
  if hit.kind == "worktree" then
    base_ref = hit.worktree.branch or hit.worktree.head
  elseif hit.kind == "remote_branch" then
    base_ref = hit.remote_ref
  else
    notify("W creates from a worktree or remote branch — select a valid row",
      vim.log.levels.WARN)
    return
  end

  if not base_ref then return end

  local repo = (state.repos or {})[hit.repo_idx]
  if not repo then return end
  local git = require("worktree.git")

  vim.ui.input({ prompt = "New branch name: " }, function(name)
    if not name or vim.trim(name) == "" then return end
    name = vim.trim(name)

    if repo.is_bare then
      local container = git.repo_container(repo.common_dir)
      vim.ui.input({
        prompt = "Worktree path: ",
        default = container .. "/" .. name,
      }, function(target_path)
        if not target_path or vim.trim(target_path) == "" then return end
        target_path = vim.trim(target_path)
        git.create(repo, name, target_path, base_ref, function(res)
          if res.ok then
            notify("+ " .. name .. " → " .. target_path)
            render_left()
          else
            notify("create failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
          end
        end)
      end)
    else
      local root = git.norm(vim.fn.fnamemodify(repo.common_dir, ":h"))
      if git.has_uncommitted(root) then
        notify("refusing to create — uncommitted changes in " .. root,
          vim.log.levels.ERROR)
        return
      end
      git.create_branch(root, name, base_ref, function(res)
        if res.ok then
          notify("+ branch " .. name .. " (from " .. base_ref .. ")")
          render_left()
          if state.selected == hit.repo_idx then draw_graph_for(repo) end
        else
          notify("create branch failed: " .. (res.stderr or ""), vim.log.levels.ERROR)
        end
      end)
    end
  end)
end

-- ── key bindings ─────────────────────────────────────────────

local function bind_left_keys()
  if not state.mfloat then return end
  local buf = state.mfloat:bufnr("left")
  if not buf then return end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn,
      { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map("r",       function() M.refresh() end,  "worktree.graph: refresh repos")
  map("R", function()
    state.show_remote_branches = not state.show_remote_branches
    render_left()
  end, "worktree.graph: toggle remote branches")
  map("<Tab>",   function() state.mfloat:cycle("forward")  end, "worktree.graph: cycle pane")
  map("<S-Tab>", function() state.mfloat:cycle("backward") end, "worktree.graph: cycle pane back")
  -- Directional pane navigation. Maps to the same forward/backward
  -- cycle as Tab/S-Tab so wrap-around works at the edges (left ↔
  -- preview). Mirrors vim's stock <C-h>/<C-l> window-navigation
  -- pattern within the panel.
  map("<C-h>",   function() state.mfloat:cycle("backward") end, "worktree.graph: pane left")
  map("<C-l>",   function() state.mfloat:cycle("forward")  end, "worktree.graph: pane right")
  map("<CR>", function()
    local row = vim.api.nvim_win_get_cursor(state.mfloat:winid("left"))[1]
    local hit = row_to_hit(row)
    -- Only repo rows are actionable from <CR>; worktree rows are
    -- read-only listings under the selected repo (use p/D against
    -- them). Header rows are unmapped → no-op.
    if hit and hit.kind == "repo" then select_repo(hit.repo_idx) end
  end, "worktree.graph: select repo at cursor")
  for i = 1, math.min(9, #(state.repos or {})) do
    map(tostring(i), function() select_repo(i) end,
      "worktree.graph: select repo " .. i)
  end
  map("f", fetch_selected,    "worktree.graph: fetch selected repo")
  map("F", fetch_all_repos,   "worktree.graph: fetch all repos")
  map("p", pull_at_cursor,    "worktree.graph: pull worktree(s)")
  map("C", checkout_at_cursor, "worktree.graph: checkout/track branch")
  map("W", new_at_cursor,      "worktree.graph: create new branch/worktree")
  map("D", destroy_at_cursor, "worktree.graph: destroy worktree + local branch")
end

-- Bind a thinner subset to the middle (gitgraph) and preview panes
-- so the user can trigger fetch / pull from anywhere in the panel.
local function bind_pane_action_keys(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn,
      { buffer = buf, silent = true, nowait = true, desc = desc })
  end
  map("<Tab>",   function() state.mfloat:cycle("forward")  end, "worktree.graph: cycle pane")
  map("<S-Tab>", function() state.mfloat:cycle("backward") end, "worktree.graph: cycle pane back")
  map("<C-h>",   function() state.mfloat:cycle("backward") end, "worktree.graph: pane left")
  map("<C-l>",   function() state.mfloat:cycle("forward")  end, "worktree.graph: pane right")
  map("f", fetch_selected,  "worktree.graph: fetch selected repo")
  map("F", fetch_all_repos, "worktree.graph: fetch all repos")
  map("p", pull_at_cursor,  "worktree.graph: pull selected repo's worktrees")
  -- q / <Esc> close the panel. auto-core.ui.float.multi already
  -- stamps these on every pane's bufnr at open time, but those
  -- stamps live on the SCRATCH buffer and don't carry over when a
  -- consumer swaps a different buffer in (notably gitgraph.nvim
  -- creates its own buffer per draw and the auto-core stamps are
  -- on the original scratch). Re-stamping here keeps q/<Esc>
  -- working from inside the middle pane after every gitgraph draw.
  map("q",     function() M.close() end, "worktree.graph: close")
  map("<Esc>", function() M.close() end, "worktree.graph: close (Esc)")
end

-- ── public surface ───────────────────────────────────────────

function M.is_open()
  return state.mfloat ~= nil and state.mfloat:is_open()
end

function M.set_root(path)
  state.root = vim.fn.fnamemodify(path or vim.fn.getcwd(), ":p"):gsub("/+$", "")
  if M.is_open() then M.refresh() end
end

function M.open()
  if M.is_open() then
    state.mfloat:focus("left")
    return
  end
  local core = _core()
  if not (core and core.git and core.git.graph and core.ui and core.ui.float
      and core.ui.float.multi) then
    notify("auto-core not installed (need git.graph + ui.float.multi)",
      vim.log.levels.ERROR)
    return
  end

  state.root = state.root or workspace_root()
  -- Defensive: drop the fan_out cache for this root on every UI
  -- entry. Subscriber-driven invalidation (worktree:added/removed/
  -- switched) catches in-process mutations, but a user who ran
  -- `git clone` / `git worktree add` from another terminal would
  -- still see a stale list. Re-scanning per open keeps the panel
  -- honest at the cost of one directory walk (sub-100ms for a
  -- typical workspace).
  if type(core.git.graph.invalidate_fan_out) == "function" then
    pcall(core.git.graph.invalidate_fan_out, state.root)
  end
  state.repos = core.git.graph.fan_out(state.root, { max_depth = 3 })
  if #state.repos == 0 then
    notify("no git repositories found under " .. state.root,
      vim.log.levels.WARN)
    return
  end
  state.selected = nil

  state.mfloat = core.ui.float.multi.new({
    name  = PANEL_NAME,
    outer = {
      -- Slightly larger panel so the middle (graph) pane has more
      -- horizontal room for commit messages. width_pct 0.92 vs the
      -- prior 0.85; height grows a touch too
      -- so the graph shows more rows without scrolling.
      width_pct  = 0.92,
      height_pct = 0.90,
      border     = "rounded",
      title      = " worktree.graph ",
      title_pos  = "center",
    },
    panes = {
      left = {
        width = 0.15,
        cursorline = true,
      },
      middle = {
        title     = " Graph ",
        title_pos = "left",
      },
      preview = {
        -- Responsive default (40% of inner width) so the middle pane
        -- claims the rest. min_width still 40 — drops
        -- the preview entirely on narrow terminals so middle can
        -- use the full inner width.
        width        = 0.40,
        min_width    = 40,
        min_middle   = 40,
        filetype     = "git",
      },
      footer = {
        height  = 1,
        content = " <Tab> cycle • <CR> diff • 1-9 repo • f fetch • F fetch all • p pull • C checkout • W new • D destroy wt/remote • r rescan • R remotes • q close",
      },
    },
    initial_focus = "left",
  })
  state.mfloat:open()

  render_left()
  bind_left_keys()
  -- Bind action keys (Tab/S-Tab/<C-h>/<C-l>/f/F/p) to the preview
  -- pane buffer so the user can navigate AWAY from preview without
  -- closing the panel. Without this, pressing Tab from preview was
  -- a no-op (auto-core.ui.float.multi only stamps q/<Esc> per pane;
  -- consumer binds the rest). Preview's bufnr is stable across
  -- cursor moves (we only update its content via nvim_buf_set_lines),
  -- so binding once at open is enough.
  do
    local pv_buf = state.mfloat:bufnr("preview")
    if pv_buf then bind_pane_action_keys(pv_buf) end
  end
  -- First repo selection so the middle/preview panes have content.
  select_repo(1)
end

---Bind action keys to the middle pane buffer. Called after each
---gitgraph draw because gitgraph creates a new buffer per draw, so
---our buffer-local maps need to be re-stamped.
function M._bind_middle_action_keys()
  if not state.mfloat then return end
  local mid = state.mfloat:winid("middle")
  if not mid or not vim.api.nvim_win_is_valid(mid) then return end
  bind_pane_action_keys(vim.api.nvim_win_get_buf(mid))
end

function M.close()
  if state.preview_timer then
    pcall(function()
      state.preview_timer:stop(); state.preview_timer:close()
    end)
    state.preview_timer = nil
  end
  if state.mfloat then
    state.mfloat:dispose()
    state.mfloat = nil
  end
  state.repos = nil
  state.selected = nil
end

function M.refresh()
  -- Drop graph caches so a manual `r` after a fetch sees fresh
  -- commit data.
  local core = _core()
  if core and core.git and core.git.graph then
    core.git.graph.clear_cache()
  end
  M.close()
  M.open()
end

function M.toggle()
  if M.is_open() then M.close() else M.open() end
end

return M
