-- tests/adr0083-credentials.lua — test suite for worktree.credentials (ADR-0083 §2.5.1)
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
  if vim.fn.isdirectory(p) == 1 then
    vim.opt.runtimepath:prepend(p)
  end
end

vim.o.columns = 200
vim.o.lines = 60

local pass_count = 0
local fail_count = 0

local function ok(name, cond, details)
  if cond then
    pass_count = pass_count + 1
    print("  PASS  " .. name)
  else
    fail_count = fail_count + 1
    print("  FAIL  " .. name .. (details and (" — " .. tostring(details)) or ""))
  end
end

local creds = require("worktree.credentials")
local config = require("worktree.config")

-- Isolated scratch configuration
local tmp_dir = vim.fn.tempname() .. "-worktree-creds"
vim.fn.mkdir(tmp_dir, "p")
local test_auth_path = tmp_dir .. "/test-worktree-auth.json"
creds._custom_config_path = test_auth_path

-- 1. Default allowlist validation (MF2)
for _, cmd in ipairs({ "pass", "op", "gh", "secret-tool", "keyctl", "security" }) do
  ok("default allowlist contains " .. cmd, creds.is_allowlisted(cmd) == true)
  local sys = vim.fn.exepath(cmd)
  if sys ~= "" then
    ok("default allowlist matches real system path " .. sys, creds.is_allowlisted(sys) == true)
  end
end

-- Gold's exact execution matrix (MF2)
ok("MF2: cat is rejected", creds.is_allowlisted("cat") == false)
ok("MF2: echo is rejected", creds.is_allowlisted("echo") == false)
ok("MF2: gopass is rejected", creds.is_allowlisted("gopass") == false)
ok("MF2: bw is rejected", creds.is_allowlisted("bw") == false)
ok("MF2: /tmp/evil/pass is rejected", creds.is_allowlisted("/tmp/evil/pass") == false)
ok("MF2: /home/johno/evil/gh is rejected", creds.is_allowlisted("/home/johno/evil/gh") == false)
ok("MF2: ./pass is rejected", creds.is_allowlisted("./pass") == false)
ok("MF2: ../../../tmp/pass is rejected", creds.is_allowlisted("../../../tmp/pass") == false)

ok("unallowlisted executable is rejected by is_allowlisted", creds.is_allowlisted("curl") == false)
ok("shell is rejected by is_allowlisted", creds.is_allowlisted("sh") == false)
ok("bash is rejected by is_allowlisted", creds.is_allowlisted("bash") == false)

-- 2. Strict rejection of unallowlisted command provider
local rejected = false
local err_msg = nil
local sok, serr = pcall(function()
  creds.set_profile("bad-repo", { kind = "command", argv = { "sh", "-c", "echo bad" } })
end)
if not sok then
  rejected = true
  err_msg = tostring(serr)
end
ok("setting non-allowlisted command provider throws error", rejected == true)
ok("error message names rejected executable", err_msg and err_msg:find("rejected non-allowlisted provider executable 'sh'", 1, true) ~= nil, err_msg)

-- 3. Custom allowlist configuration via setup
config.setup({ auth = { allowed_command_providers = { "my-secret-vault" } } })
ok("configured custom provider is now allowlisted", creds.is_allowlisted("my-secret-vault") == true)

-- 4. In-memory profile handling
creds.set_profile("in-mem-slug", { kind = "in_memory", token = "token_mem_12345" })
ok("in_memory profile resolves correctly", creds.resolve_token("in-mem-slug") == "token_mem_12345")
ok("in_memory token is not saved in worktree-auth.json", vim.fn.filereadable(test_auth_path) == 0)

-- 5. Environment variable profile handling
vim.env.TEST_FORGE_PAT = "token_env_67890"
creds.set_profile("env-slug", { kind = "env", var = "TEST_FORGE_PAT" })
ok("env profile resolves correctly", creds.resolve_token("env-slug") == "token_env_67890")
ok("worktree-auth.json was written to disk", vim.fn.filereadable(test_auth_path) == 1)

local disk_content = vim.fn.readfile(test_auth_path)
local disk_json = vim.json.decode(table.concat(disk_content, "\n"))
ok("disk config contains env profile", disk_json["env-slug"] and disk_json["env-slug"].kind == "env")
ok("disk config does NOT contain raw token string", not string.find(table.concat(disk_content, "\n"), "token_env_67890"))

-- 6. File permissions (mode 0600 = 384 decimal)
local stat = vim.uv.fs_stat(test_auth_path)
local mode_perm = stat and bit.band(stat.mode, 511)
ok("worktree-auth.json has mode 0600 (384)", mode_perm == 384, tostring(mode_perm))

-- 7. Command profile with allowlisted helper script
local helper_script = tmp_dir .. "/gh"
vim.fn.writefile({ "#!/bin/sh", "echo 'token_cmd_999'" }, helper_script)
vim.fn.system({ "chmod", "+x", helper_script })

config.setup({ auth = { allowed_command_providers = { helper_script } } })
creds.set_profile("cmd-slug", { kind = "command", argv = { helper_script, "auth", "token" } })
local cmd_token, cmd_err = creds.resolve_token("cmd-slug")
ok("allowlisted command resolves token correctly", cmd_token == "token_cmd_999", cmd_err)
ok("trailing newline was stripped from command output", cmd_token == "token_cmd_999")

-- 7b. resolve_token fallback chain: slug -> host -> env (items A2, A3)
--
-- The call sites read resolve_token(repo.slug or remote_info.host), so a slug
-- always won and a per-HOST profile was unreachable; and the env fallback keyed
-- on key:find("github"), which a slug like monstercat__lm never matches. Both
-- are fixed by resolve_token(key, host).
do
  -- A2: a per-HOST profile is reached when there is no per-repo profile.
  creds.set_profile("github.com", { kind = "in_memory", token = "host_token_abc" })
  ok("A2: unknown slug falls back to the host profile",
    creds.resolve_token("monstercat__lm", "github.com") == "host_token_abc",
    tostring(creds.resolve_token("monstercat__lm", "github.com")))
  -- A per-repo profile still WINS over the host.
  creds.set_profile("monstercat__lm", { kind = "in_memory", token = "repo_token_xyz" })
  ok("A2: a per-repo profile wins over the host",
    creds.resolve_token("monstercat__lm", "github.com") == "repo_token_xyz")
  creds.clear_profile("monstercat__lm")
  creds.clear_profile("github.com")

  -- A3: env fallback keyed on the HOST, not a substring of the slug.
  local saved = vim.env.GITHUB_TOKEN
  vim.env.GITHUB_TOKEN = "env_gh_token_123"
  ok("A3: a github HOST reaches GITHUB_TOKEN for a non-github slug",
    creds.resolve_token("monstercat__lm", "github.com") == "env_gh_token_123",
    tostring(creds.resolve_token("monstercat__lm", "github.com")))
  ok("A3: *** a non-github host does NOT silently use GITHUB_TOKEN ***",
    select(1, creds.resolve_token("acme__thing", "gitlab.example.com")) == nil)
  ok("A3: the old slug-substring behaviour is gone (slug alone, no host, no match)",
    select(1, creds.resolve_token("monstercat__lm")) == nil)
  -- SECURITY (lector PR #23): the github-host rule is EXACT, not a substring.
  -- A malicious remote whose host merely CONTAINS "github" must not borrow the
  -- ambient GitHub token.
  ok("A3: *** 'notgithub.example' does NOT borrow GITHUB_TOKEN ***",
    select(1, creds.resolve_token("x__y", "notgithub.example")) == nil)
  ok("A3: *** 'github.attacker.example' does NOT borrow GITHUB_TOKEN ***",
    select(1, creds.resolve_token("x__y", "github.attacker.example")) == nil)
  ok("A3: a real github SUBDOMAIN (api.github.com) still resolves",
    creds.resolve_token("x__y", "api.github.com") == "env_gh_token_123")
  ok("A3: *** key='default' with a concrete NON-github host does NOT borrow it ***",
    select(1, creds.resolve_token("default", "gitlab.example.com")) == nil)
  vim.env.GITHUB_TOKEN = saved
end

-- 7c. list_profiles reports shape without leaking the token (A1 support)
do
  creds.set_profile("list-env", { kind = "env", var = "SOME_VAR" })
  creds.set_profile("list-mem", { kind = "in_memory", token = "super_secret_tok" })
  local profs = creds.list_profiles()
  ok("A1: list includes the env profile with its var", profs["list-env"]
    and profs["list-env"].kind == "env" and profs["list-env"].var == "SOME_VAR")
  ok("A1: list includes the in-memory profile", profs["list-mem"]
    and profs["list-mem"].kind == "in_memory")
  ok("A1: *** list NEVER surfaces the in-memory token value ***", (function()
    for _, p in pairs(profs) do
      for _, v in pairs(p) do
        if type(v) == "string" and v:find("super_secret_tok", 1, true) then return false end
      end
    end
    return true
  end)())
  creds.clear_profile("list-env")
  creds.clear_profile("list-mem")
end

-- 7d. describe — the PREFLIGHT's report (ADR-0083 §2.6 Action 1 step 1).
--
-- Action 1 step 1 ("ensure credential profile is configured, prompt if
-- missing") was never implemented: G/N/S prompted for a PR number and only
-- discovered a missing token after the forge round trip. `describe` answers
-- the question BEFORE the prompt.
--
-- Two properties matter more than the happy path, and both are asserted
-- against the real chain rather than a reimplementation of it:
--   * it must AGREE with resolve_token about which credential applies;
--   * it must never EXECUTE a provider (a `command` profile would fire a GPG
--     passphrase prompt on a keypress that has asked for nothing).
do
  -- Agreement, driven over the same cases §7b drives resolve_token over. A
  -- second implementation of "which credential applies" that drifts would
  -- report "configured" for a key that then fails — the one outcome a
  -- preflight must never produce.
  local saved = vim.env.GITHUB_TOKEN
  vim.env.GITHUB_TOKEN = "env_gh_token_123"
  creds.set_profile("github.com", { kind = "in_memory", token = "host_token_abc" })
  creds.set_profile("monstercat__lm", { kind = "in_memory", token = "repo_token_xyz" })

  local cases = {
    { "monstercat__lm", "github.com" },        -- per-repo wins
    { "unknown__repo",  "github.com" },        -- host profile
    { "x__y",           "api.github.com" },    -- env, real subdomain
    { "x__y",           "notgithub.example" }, -- refused
    { "x__y",           "github.attacker.example" }, -- refused
    { "default",        "gitlab.example.com" },-- refused
    { "acme__thing",    "gitlab.example.com" },-- refused
  }
  local agree = true
  local disagreement
  for _, c in ipairs(cases) do
    local tok = select(1, creds.resolve_token(c[1], c[2]))
    local d = creds.describe(c[1], c[2])
    if (tok ~= nil) ~= (d.configured == true) then
      agree = false
      disagreement = string.format("%s/%s: token=%s describe.configured=%s",
        c[1], c[2], tostring(tok ~= nil), tostring(d.configured))
      break
    end
  end
  ok("preflight: *** describe agrees with resolve_token on every chain case ***",
    agree, tostring(disagreement))

  local d = creds.describe("monstercat__lm", "github.com")
  ok("preflight: it names WHICH key won", d.key == "monstercat__lm", vim.inspect(d))
  local dh = creds.describe("unknown__repo", "github.com")
  ok("preflight: a host profile is reported under the HOST key",
    dh.configured and dh.key == "github.com", vim.inspect(dh))
  creds.clear_profile("monstercat__lm")
  creds.clear_profile("github.com")

  local de = creds.describe("x__y", "api.github.com")
  ok("preflight: the env fallback is reported as env/GITHUB_TOKEN",
    de.configured and de.kind == "env" and de.var == "GITHUB_TOKEN", vim.inspect(de))

  -- A qualifying host with the variable UNSET is a different problem from
  -- "nothing configured", and conflating them sends the user to register a
  -- profile they do not need.
  vim.env.GITHUB_TOKEN = nil
  local du = creds.describe("x__y", "github.com")
  ok("preflight: *** a github host with $GITHUB_TOKEN unset says so ***",
    du.configured == false and tostring(du.why):find("GITHUB_TOKEN is unset", 1, true) ~= nil,
    vim.inspect(du))
  vim.env.GITHUB_TOKEN = saved

  -- The hint is the LINE TO RUN, with the host filled in. "Configure a
  -- credential" is not actionable; this is.
  local dn = creds.describe("acme__thing", "gitlab.example.com")
  ok("preflight: an unconfigured repo reports configured=false", dn.configured == false)
  ok("preflight: *** the hint names :WorktreeAuth set AND the real host ***",
    dn.hint:find(":WorktreeAuth set", 1, true) ~= nil
      and dn.hint:find("gitlab.example.com", 1, true) ~= nil, dn.hint)
  ok("preflight: the hint offers both provider forms",
    dn.hint:find("command", 1, true) ~= nil and dn.hint:find("env GITHUB_TOKEN", 1, true) ~= nil,
    dn.hint)

  -- NO EXECUTION. The provider is a script that leaves a marker file when it
  -- runs; describe must leave it absent while resolve_token creates it. A
  -- positive control, so "no marker" cannot mean "the script was broken".
  local marker = tmp_dir .. "/describe-ran-the-provider"
  local script = tmp_dir .. "/probe-provider"
  vim.fn.writefile({ "#!/bin/sh", "touch " .. marker, "echo tok_from_script" }, script)
  vim.fn.system({ "chmod", "+x", script })
  -- An absolute path is only accepted when explicitly allowlisted (the MF2
  -- traversal guard); keep §7's helper permitted alongside it.
  config.setup({ auth = { allowed_command_providers = { helper_script, script } } })
  creds.set_profile("exec__probe", { kind = "command", argv = { script } })

  vim.fn.delete(marker)
  local dc = creds.describe("exec__probe", "github.com")
  ok("preflight: a command profile is reported as configured, with its argv",
    dc.configured and dc.kind == "command" and dc.argv and dc.argv[1] == script, vim.inspect(dc))
  ok("preflight: *** describe did NOT execute the provider ***",
    vim.fn.filereadable(marker) == 0,
    "marker present -- describe ran the command, which would fire a GPG prompt")
  -- Positive control: the same profile, resolved, DOES run it. Without this,
  -- an absent marker could just mean the script never worked.
  local tok = creds.resolve_token("exec__probe", "github.com")
  ok("preflight: (control) resolve_token DOES execute it, so the probe observes",
    tok == "tok_from_script" and vim.fn.filereadable(marker) == 1,
    tostring(tok) .. " / marker=" .. tostring(vim.fn.filereadable(marker)))
  creds.clear_profile("exec__probe")

  -- And nothing in a report may carry a secret.
  creds.set_profile("leak__mem", { kind = "in_memory", token = "super_secret_desc_tok" })
  local dm = creds.describe("leak__mem", "github.com")
  ok("preflight: *** describe NEVER surfaces the token value ***", (function()
    for _, v in pairs(dm) do
      if type(v) == "string" and v:find("super_secret_desc_tok", 1, true) then return false end
      if type(v) == "table" then
        for _, vv in ipairs(v) do
          if type(vv) == "string" and vv:find("super_secret_desc_tok", 1, true) then return false end
        end
      end
    end
    return true
  end)(), vim.inspect(dm))
  creds.clear_profile("leak__mem")
end

-- 7e. SELECTION vs READINESS (lector r0 P1-1).
--
-- describe() reported `configured=true` for every selected profile, without
-- checking whether an explicit env profile's variable held anything. An
-- independent probe confirmed the two APIs disagreeing on exactly the state
-- the preflight exists to catch: describe said configured, resolve_token said
-- "environment variable ... is unset or empty", and the panel gate let G/N/S
-- through to fail at the forge.
--
-- The §7d agreement cell did not catch it because its seven cases contained
-- no explicit-env profile at all — an agreement test is only as good as its
-- case list, which is the lesson worth keeping here.
do
  local saved_env = vim.env.GITHUB_TOKEN
  vim.env.GITHUB_TOKEN = nil

  -- env, SET -> selected + ready
  vim.env.WT_READY_VAR = "tok_ready"
  creds.set_profile("env__ready", { kind = "env", var = "WT_READY_VAR" })
  local dr = creds.describe("env__ready", "gitlab.example.com")
  ok("7e: a set env profile is selected and READY",
    dr.selected == true and dr.readiness == "ready", vim.inspect(dr))
  ok("7e: and its coarse `configured` stays true for older consumers",
    dr.configured == true)

  -- env, UNSET -> selected but UNAVAILABLE (the reported defect)
  vim.env.WT_BROKEN_VAR = nil
  creds.set_profile("env__broken", { kind = "env", var = "WT_BROKEN_VAR" })
  local db = creds.describe("env__broken", "gitlab.example.com")
  ok("7e: *** an UNSET env profile is still SELECTED ***", db.selected == true, vim.inspect(db))
  ok("7e: *** but its readiness is UNAVAILABLE, not ready ***",
    db.readiness == "unavailable", vim.inspect(db))
  ok("7e: it names the variable in the reason",
    tostring(db.why):find("WT_BROKEN_VAR", 1, true) ~= nil, tostring(db.why))
  ok("7e: *** and the coarse `configured` is FALSE, so an older gate refuses ***",
    db.configured == false, vim.inspect(db))
  ok("7e: (agreement) resolve_token also refuses it",
    select(1, creds.resolve_token("env__broken", "gitlab.example.com")) == nil)

  -- command -> selected, readiness UNKNOWN, and NOT executed
  local marker = tmp_dir .. "/readiness-probe-ran"
  local script = tmp_dir .. "/readiness-provider"
  vim.fn.writefile({ "#!/bin/sh", "touch " .. marker, "echo tok" }, script)
  vim.fn.system({ "chmod", "+x", script })
  config.setup({ auth = { allowed_command_providers = { helper_script, script } } })
  creds.set_profile("cmd__unknown", { kind = "command", argv = { script } })
  vim.fn.delete(marker)
  local dc = creds.describe("cmd__unknown", "gitlab.example.com")
  ok("7e: *** a command provider is selected with readiness UNKNOWN ***",
    dc.selected == true and dc.readiness == "unknown", vim.inspect(dc))
  ok("7e: *** and describing it still does not RUN it ***",
    vim.fn.filereadable(marker) == 0)
  ok("7e: unknown is permissive in the coarse boolean (a working provider must not be blocked)",
    dc.configured == true, vim.inspect(dc))

  -- SELECTION IDENTITY: when both a slug and a host profile could answer, the
  -- report must say WHICH won — `configured` alone cannot.
  creds.set_profile("gitlab.example.com", { kind = "in_memory", token = "host_tok" })
  creds.set_profile("both__slug", { kind = "in_memory", token = "slug_tok" })
  local dboth = creds.describe("both__slug", "gitlab.example.com")
  ok("7e: *** with both candidates usable, the report names the SLUG as the winner ***",
    dboth.key == "both__slug" and dboth.readiness == "ready", vim.inspect(dboth))
  ok("7e: (agreement) and resolve_token returns that same source's token",
    creds.resolve_token("both__slug", "gitlab.example.com") == "slug_tok")
  creds.clear_profile("both__slug")
  local dhost = creds.describe("both__slug", "gitlab.example.com")
  ok("7e: removing the slug profile moves the winner to the host",
    dhost.key == "gitlab.example.com", vim.inspect(dhost))
  creds.clear_profile("gitlab.example.com")

  -- The ambient token is a SELECTED source too; its emptiness is readiness.
  vim.env.GITHUB_TOKEN = nil
  local damb = creds.describe("x__y", "github.com")
  ok("7e: an unset ambient GITHUB_TOKEN is selected-but-unavailable, not unselected",
    damb.selected == true and damb.readiness == "unavailable", vim.inspect(damb))
  vim.env.GITHUB_TOKEN = "amb_tok"
  local damb2 = creds.describe("x__y", "github.com")
  ok("7e: (control) setting it makes the same source ready",
    damb2.selected == true and damb2.readiness == "ready", vim.inspect(damb2))

  -- readiness == "unavailable" must IMPLY resolve_token fails, across every
  -- state above. This is the invariant the panel gate actually relies on.
  local implication_holds, offender = true, nil
  for _, c in ipairs({
    { "env__ready", "gitlab.example.com" }, { "env__broken", "gitlab.example.com" },
    { "cmd__unknown", "gitlab.example.com" }, { "x__y", "github.com" },
    { "nobody__nothing", "gitlab.example.com" },
  }) do
    local d = creds.describe(c[1], c[2])
    local tok = select(1, creds.resolve_token(c[1], c[2]))
    if d.readiness == "unavailable" and tok ~= nil then
      implication_holds, offender = false, c[1] .. "/" .. c[2]
    end
    if d.readiness == "ready" and tok == nil then
      implication_holds, offender = false, "ready-but-nil: " .. c[1] .. "/" .. c[2]
    end
  end
  ok("7e: *** unavailable implies resolve fails, and ready implies it succeeds ***",
    implication_holds, tostring(offender))

  creds.clear_profile("env__ready"); creds.clear_profile("env__broken")
  creds.clear_profile("cmd__unknown")
  vim.env.GITHUB_TOKEN = saved_env
end

-- 7f. :WorktreeAuth status reports readiness, and does not overstate it.
--
-- Testing describe() alone does not pin the command surface: the overstatement
-- lector found was in the STATUS WORDING as much as in the report.
do
  local repos_mod = require("worktree.repos")
  local saved_repos = repos_mod.repos
  local saved_target = repos_mod.getpr_target_repo
  -- The host is a variable: on github.com the ambient GITHUB_TOKEN is always a
  -- SELECTED source (ready or not), so "nothing is selected" can only be shown
  -- on a host that does not qualify for it.
  local status_url = "git@gitlab.example.com:acme/status.git"
  repos_mod.getpr_target_repo = function()
    return { slug = "acme__status", url = status_url }
  end
  vim.g.loaded_worktree = nil
  pcall(vim.cmd, "source " .. plugin_root .. "/plugin/worktree.lua")
  ok("7f: :WorktreeAuth is registered", vim.fn.exists(":WorktreeAuth") == 2)

  local said = {}
  local saved_notify = vim.notify
  vim.notify = function(m) said[#said + 1] = tostring(m) end
  local function run() said = {}; pcall(vim.cmd, "WorktreeAuth status"); return table.concat(said, "\n") end

  local saved_env = vim.env.GITHUB_TOKEN
  vim.env.GITHUB_TOKEN = nil
  local out_none = run()
  ok("7f: with nothing selected it says NO credential and gives the line to run",
    out_none:find("NO credential", 1, true) ~= nil
      and out_none:find(":WorktreeAuth set", 1, true) ~= nil, out_none)

  -- On a github host the ambient token is selected even when empty, so the
  -- honest report is "selected but UNAVAILABLE" — not "no credential".
  status_url = "git@github.com:acme/status.git"
  local out_amb = run()
  ok("7f: *** an empty ambient GITHUB_TOKEN reports selected-but-UNAVAILABLE ***",
    out_amb:find("UNAVAILABLE", 1, true) ~= nil
      and out_amb:find("GITHUB_TOKEN", 1, true) ~= nil, out_amb)
  status_url = "git@gitlab.example.com:acme/status.git"

  vim.env.WT_STATUS_BROKEN = nil
  creds.set_profile("acme__status", { kind = "env", var = "WT_STATUS_BROKEN" })
  local out_broken = run()
  ok("7f: *** a broken env profile is reported UNAVAILABLE, never 'resolves through' ***",
    out_broken:find("UNAVAILABLE", 1, true) ~= nil
      and out_broken:find("resolves through", 1, true) == nil, out_broken)

  vim.env.WT_STATUS_BROKEN = "now_set"
  local out_ready = run()
  ok("7f: (control) setting the variable flips it to 'resolves through'",
    out_ready:find("resolves through", 1, true) ~= nil, out_ready)

  creds.set_profile("acme__status", { kind = "command", argv = { helper_script } })
  local out_cmd = run()
  ok("7f: *** a command provider is reported as readiness UNKNOWN, not resolved ***",
    out_cmd:find("readiness unknown", 1, true) ~= nil
      and out_cmd:find("resolves through", 1, true) == nil, out_cmd)

  vim.notify = saved_notify
  vim.env.GITHUB_TOKEN = saved_env
  vim.env.WT_STATUS_BROKEN = nil
  creds.clear_profile("acme__status")
  repos_mod.repos = saved_repos
  repos_mod.getpr_target_repo = saved_target
end

-- 8. Clearing profiles
creds.clear_profile("in-mem-slug")
ok("cleared in-memory profile is gone", creds.get_profile("in-mem-slug") == nil)
creds.clear_profile("env-slug")
ok("cleared disk profile is gone from memory", creds.get_profile("env-slug") == nil)
local disk_after_clear = vim.json.decode(table.concat(vim.fn.readfile(test_auth_path), "\n"))
ok("cleared disk profile is gone from json file", disk_after_clear["env-slug"] == nil)

-- 9. open_exclusive_config creates mode 0600 curl config and cleans up
local cfg_path, cleanup_fn = creds.open_exclusive_config("ephemeral_secret_token")
ok("open_exclusive_config returned a valid file path", vim.fn.filereadable(cfg_path) == 1)
local cfg_stat = vim.uv.fs_stat(cfg_path)
local cfg_mode = cfg_stat and bit.band(cfg_stat.mode, 511)
ok("ephemeral curl config has mode 0600 (384)", cfg_mode == 384, tostring(cfg_mode))
local cfg_lines = vim.fn.readfile(cfg_path)
local cfg_text = table.concat(cfg_lines, "\n")
ok("ephemeral curl config includes Authorization header", cfg_text:find("Authorization: Bearer ephemeral_secret_token", 1, true) ~= nil)
ok("ephemeral curl config includes Accept header", cfg_text:find("application/vnd.github+json", 1, true) ~= nil)

cleanup_fn()
ok("cleanup function removed ephemeral curl config file", vim.fn.filereadable(cfg_path) == 0)

-- 10. Diagnostic redaction
local leaked = "Error 401: Authorization: Bearer secret_pat_12345 invalid"
local redacted = creds.redact(leaked)
ok("redact strips bearer token", redacted == "Error 401: Authorization: Bearer [REDACTED] invalid", redacted)

-- 11. Spawned argv non-disclosure inspection (ADR §2.5.2 MUST)
local spawned_calls = {}
local real_system = vim.system
vim.system = function(cmd, opts, on_exit)
  table.insert(spawned_calls, { cmd = cmd, opts = opts })
  return real_system(cmd, opts, on_exit)
end

creds.set_profile("canary-cmd", { kind = "command", argv = { helper_script, "get-pat" } })
local can_token = creds.resolve_token("canary-cmd")
ok("MF3: resolve_token executed spawned helper", #spawned_calls >= 1)
local last_call = spawned_calls[#spawned_calls]
ok("MF3: spawned command array matches configured argv", last_call.cmd[1] == helper_script)
for _, arg in ipairs(last_call.cmd) do
  ok("MF3: argument does not leak resolved secret token", arg:find("token_cmd_999", 1, true) == nil)
end
vim.system = real_system

-- MF-rng (lector PR #23 r1): concurrent credential-config creation must not
-- collide. open_exclusive_config drew its temp suffix from Lua's DEFAULT
-- math.random stream, which is identical in every freshly-launched Lua state —
-- so N independently-spawned nvims produced the SAME ten O_EXCL candidates and
-- exhausted them (lector measured 4/4 concurrent failures). The fix seeds from
-- an OS entropy source. Evidence, timing-independent: launch 8 headless nvims,
-- each with its OWN run_dir so candidate #1 always succeeds, and collect the
-- chosen filename. Under the deterministic bug every process reports the SAME
-- suffix; with OS entropy all eight are distinct.
do
  local probe = tmp_dir .. "/rng-probe.lua"
  vim.fn.writefile({
    "vim.opt.runtimepath:prepend(" .. string.format("%q", plugin_root) .. ")",
    "local creds = require('worktree.credentials')",
    "creds._custom_run_dir = arg[1]",
    "local path = creds.open_exclusive_config('tok-probe')",
    "io.write(vim.fn.fnamemodify(path, ':t'))",
    "os.exit(0)",
  }, probe)
  local N = 8
  local procs = {}
  for i = 1, N do
    local rd = tmp_dir .. "/rng-run-" .. i
    vim.fn.mkdir(rd, "p")
    procs[i] = vim.system(
      { "nvim", "--headless", "-u", "NONE", "-l", probe, rd }, { text = true })
  end
  local suffixes, seen, n_distinct, all_spawned = {}, {}, 0, true
  for i = 1, N do
    local r = procs[i]:wait()
    local out = vim.trim(r.stdout or "")
    if r.code ~= 0 or out == "" then all_spawned = false end
    suffixes[i] = out
    if out ~= "" and not seen[out] then seen[out] = true; n_distinct = n_distinct + 1 end
  end
  ok("MF-rng: all 8 probe processes created a config (no O_EXCL exhaustion)",
    all_spawned, vim.inspect(suffixes))
  ok("MF-rng: *** 8 concurrent processes chose 8 DISTINCT temp names (not one shared RNG stream) ***",
    n_distinct == N, string.format("%d distinct of %d: %s", n_distinct, N, vim.inspect(suffixes)))
end

-- MF-rng fallback (lector PR #23 r2 nonblocking note): when vim.uv.random is
-- unavailable, _temp_suffix must still produce distinct candidates AND must not
-- reseed Lua's GLOBAL math.random stream (a global side effect that would
-- perturb any other code relying on it).
do
  local real_random = vim.uv.random
  math.randomseed(12345)
  local before = { math.random(), math.random(), math.random() }
  math.randomseed(12345) -- rewind the stream to a known point
  vim.uv.random = function() error("forced unavailable") end
  local seen, n, err_free = {}, 0, true
  for attempt = 1, 10 do
    local ok_s, suf = pcall(creds._temp_suffix, attempt)
    if not ok_s or type(suf) ~= "string" or suf == "" then err_free = false end
    if suf and not seen[suf] then seen[suf] = true; n = n + 1 end
  end
  vim.uv.random = real_random
  ok("MF-rng fallback: produces a suffix without error on every attempt", err_free)
  ok("MF-rng fallback: 10 attempts yield 10 distinct suffixes", n == 10, tostring(n))
  local after = { math.random(), math.random(), math.random() }
  ok("MF-rng fallback: *** does NOT reseed the global math.random stream ***",
    after[1] == before[1] and after[2] == before[2] and after[3] == before[3],
    vim.inspect({ before = before, after = after }))
end

-- Cleanup scratch dir
vim.fn.delete(tmp_dir, "rf")

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
