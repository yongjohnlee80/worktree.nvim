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

-- Cleanup scratch dir
vim.fn.delete(tmp_dir, "rf")

print(string.format("\n%d passed, %d failed", pass_count, fail_count))
if fail_count > 0 then
  os.exit(1)
end
os.exit(0)
