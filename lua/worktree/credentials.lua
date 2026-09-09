---worktree.credentials — secure credential store and provider resolution (ADR-0083 §2.5.1).
---
---Strict allowlisting for command providers, token-free disk persistence,
---mode-0600 permissions, in-memory isolation, and ephemeral curl header configs.
---@module 'worktree.credentials'

local config = require("worktree.config")

local M = {}

M.DEFAULT_ALLOWLIST = {
  "pass",
  "op",
  "gh",
  "secret-tool",
  "keyctl",
  "security",
}

-- In-memory profile storage (for kind == "in_memory")
M._in_memory = {}
M._custom_config_path = nil

---_config_path returns the path to worktree-auth.json
function M._config_path()
  if M._custom_config_path then return M._custom_config_path end
  local cfg = config.options and config.options.auth and config.options.auth.config_path
  if cfg then return cfg end
  return vim.fn.expand("~/.config/nvim/.auto-agents-config/worktree-auth.json")
end

---is_allowlisted checks if an executable name or path is permitted.
---@param exe string
---@return boolean
function M.is_allowlisted(exe)
  if type(exe) ~= "string" or exe == "" then return false end
  local has_sep = exe:find("/", 1, true) ~= nil or exe:find("\\", 1, true) ~= nil
  if has_sep then
    -- A relative path with separator is strictly rejected to prevent execution of
    -- repository-controlled files (e.g. ./pass or ../tmp/pass in a worktree)
    if not (exe:sub(1, 1) == "/" or exe:match("^%a:[/\\]")) then
      return false
    end
    -- For absolute paths, accept if explicitly configured in user_allowed,
    -- or if it resolves to the exact system executable of an allowed default tool
    local user_allowed = (config.options and config.options.auth and config.options.auth.allowed_command_providers) or {}
    for _, allowed in ipairs(user_allowed) do
      if allowed:find("/", 1, true) or allowed:find("\\", 1, true) then
        if vim.fs.normalize(exe) == vim.fs.normalize(allowed) then
          return true
        end
      end
    end
    for _, allowed in ipairs(M.DEFAULT_ALLOWLIST) do
      local sys_path = vim.fn.exepath(allowed)
      if sys_path ~= "" and vim.fs.normalize(exe) == vim.fs.normalize(sys_path) then
        return true
      end
    end
    return false
  end

  -- Bare command name (no path separator, e.g. "pass", "op", "gh")
  for _, allowed in ipairs(M.DEFAULT_ALLOWLIST) do
    if exe == allowed then return true end
  end
  local user_allowed = (config.options and config.options.auth and config.options.auth.allowed_command_providers) or {}
  for _, allowed in ipairs(user_allowed) do
    if exe == allowed then return true end
  end
  return false
end

---_read_disk_config reads and decodes the persisted auth config.
---@return table<string, table>
function M._read_disk_config()
  local path = M._config_path()
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or not lines or #lines == 0 then return {} end
  local dok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  if not dok or type(data) ~= "table" then return {} end
  return data
end

---_write_disk_config writes the auth config to disk with mode 0600.
---@param data table<string, table>
---@return boolean ok, string? err
function M._write_disk_config(data)
  local path = M._config_path()
  local dir = vim.fs.dirname(path)
  if vim.fn.isdirectory(dir) ~= 1 then
    pcall(vim.fn.mkdir, dir, "p")
  end

  local encoded = vim.json.encode(data)
  -- Use atomic write if auto-core available, else write directly
  local ok_atomic, fs_atomic = pcall(require, "auto-core.fs.atomic")
  local wok = false
  if ok_atomic and type(fs_atomic.write) == "function" then
    wok = fs_atomic.write(path, encoded, { mkdir = true })
  else
    local ok_w = pcall(vim.fn.writefile, { encoded }, path)
    wok = ok_w
  end

  if not wok then return false, "failed to write auth config" end
  -- Enforce mode 0600 (384 decimal)
  pcall(vim.uv.fs_chmod, path, 384)
  return true, nil
end

---set_profile configures a credential profile for a repository remote or slug.
---@param key string
---@param profile table
function M.set_profile(key, profile)
  if type(key) ~= "string" or key == "" then
    error("worktree.credentials: key must be a non-empty string")
  end
  if type(profile) ~= "table" or not profile.kind then
    error("worktree.credentials: profile must be a table with a 'kind' field")
  end

  if profile.kind == "in_memory" then
    if type(profile.token) ~= "string" or profile.token == "" then
      error("worktree.credentials: in_memory profile requires a non-empty 'token'")
    end
    M._in_memory[key] = { kind = "in_memory", token = profile.token }
    return true
  elseif profile.kind == "env" then
    if type(profile.var) ~= "string" or profile.var == "" then
      error("worktree.credentials: env profile requires a non-empty 'var'")
    end
    M._in_memory[key] = nil
    local data = M._read_disk_config()
    data[key] = { kind = "env", var = profile.var }
    return M._write_disk_config(data)
  elseif profile.kind == "command" then
    if type(profile.argv) ~= "table" or #profile.argv == 0 then
      error("worktree.credentials: command profile requires non-empty 'argv' array")
    end
    local exe = profile.argv[1]
    if not M.is_allowlisted(exe) then
      error(string.format(
        "worktree.credentials: rejected non-allowlisted provider executable '%s'. Add to setup({ auth = { allowed_command_providers = ... } }) to permit.",
        tostring(exe)
      ))
    end
    M._in_memory[key] = nil
    local data = M._read_disk_config()
    data[key] = { kind = "command", argv = profile.argv }
    return M._write_disk_config(data)
  else
    error(string.format("worktree.credentials: unknown profile kind '%s'", tostring(profile.kind)))
  end
end

---get_profile returns the configured profile for a repository remote or slug.
---@param key string
---@return table? profile
function M.get_profile(key)
  if M._in_memory[key] then return M._in_memory[key] end
  local data = M._read_disk_config()
  return data[key]
end

---clear_profile removes credentials for a repository remote or slug.
---@param key string
function M.clear_profile(key)
  M._in_memory[key] = nil
  local data = M._read_disk_config()
  if data[key] then
    data[key] = nil
    M._write_disk_config(data)
  end
end

---list_profiles returns every configured profile (disk + in-memory), keyed by
---its key, with the token VALUE never included — only the kind and the
---non-secret shape (env var name, command argv). For `:WorktreeAuth list`.
---@return table<string, table>
function M.list_profiles()
  local out = {}
  local data = M._read_disk_config()
  for k, v in pairs(data) do
    if type(v) == "table" then out[k] = { kind = v.kind, var = v.var, argv = v.argv, source = "disk" } end
  end
  for k, v in pairs(M._in_memory) do
    -- in_memory carries the raw token; never surface it.
    out[k] = { kind = v.kind, source = "memory" }
  end
  return out
end

---resolve_token retrieves the secret token for a key, with a fallback chain.
---
---The chain is repo SLUG → forge HOST → env (item A2). Callers pass both,
---because a token is registered EITHER per-repo (`monstercat__lm`) OR
---per-host (`github.com`) and there was no way to reach a host profile: the
---call sites read `resolve_token(repo.slug or remote_info.host)`, so a slug
---always won and `host` was dead code.
---
---The env fallback is keyed on the HOST, not the key (item A3). The old check
---was `key:find("github")` — a slug like `monstercat__lm` never contains
---"github", so `GITHUB_TOKEN` was unreachable for every real repo. A github
---HOST is what actually decides whether `GITHUB_TOKEN` applies.
---@param key string           repo slug (or any primary key)
---@param host string?         forge host, for the profile + env fallback
---@return string? token, string? err
function M.resolve_token(key, host)
  local prof = M.get_profile(key)
  -- SLUG → HOST profile fallback: a per-host profile keyed `github.com` is now
  -- reachable when no per-repo profile exists.
  if not prof and type(host) == "string" and host ~= "" and host ~= key then
    prof = M.get_profile(host)
  end
  if not prof then
    -- Env fallback via GITHUB_TOKEN — but ONLY for a host that is genuinely
    -- github.com (lector PR #23 must-fix). `host:find("github")` matched
    -- `notgithub.example` and `github.attacker.example`, handing a malicious
    -- remote the ambient GitHub token; and `key == "default"` handed it out
    -- even with a concrete non-GitHub host. The rule is now EXACT: `github.com`
    -- itself, or a `*.github.com` subdomain (api.github.com, an enterprise
    -- subdomain). "default" is honoured only when NO concrete host was given.
    local env_pat = os.getenv("GITHUB_TOKEN") or vim.env.GITHUB_TOKEN
    local function is_github_host(h)
      return type(h) == "string" and (h == "github.com" or h:match("%.github%.com$") ~= nil)
    end
    local no_host = host == nil or host == "" or host == "default"
    if env_pat and env_pat ~= "" and (is_github_host(host) or (no_host and key == "default")) then
      return env_pat, nil
    end
    return nil, string.format(
      "no credential profile configured for '%s'%s — register one with :WorktreeAuth set",
      tostring(key), host and (" or host '" .. host .. "'") or "")
  end

  if prof.kind == "in_memory" then
    return prof.token, nil
  elseif prof.kind == "env" then
    local tok = os.getenv(prof.var) or vim.env[prof.var]
    if not tok or tok == "" then
      return nil, string.format("environment variable '%s' is unset or empty", prof.var)
    end
    return tok, nil
  elseif prof.kind == "command" then
    local exe = prof.argv[1]
    if not M.is_allowlisted(exe) then
      error(string.format(
        "worktree.credentials: rejected non-allowlisted provider executable '%s'. Add to setup({ auth = { allowed_command_providers = ... } }) to permit.",
        tostring(exe)
      ))
    end
    local res = vim.system(prof.argv, { text = true }):wait()
    if res.code ~= 0 then
      return nil, string.format("command '%s' exited with code %d: %s", exe, res.code, vim.trim(res.stderr or ""))
    end
    local tok = vim.trim(res.stdout or "")
    if tok == "" then
      return nil, string.format("command '%s' returned empty token", exe)
    end
    return tok, nil
  end

  return nil, string.format("unsupported profile kind '%s'", tostring(prof.kind))
end

---open_exclusive_config creates a mode 0600 ephemeral curl config for bearer auth (ADR-0083 §2.5.2).
---@param token string
---@return string config_path, function cleanup_fn
function M.open_exclusive_config(token)
  if type(token) ~= "string" or token == "" then
    error("worktree.credentials: token must be a non-empty string")
  end
  local run_dir = vim.fn.stdpath("run")
  if not run_dir or run_dir == "" or vim.fn.isdirectory(run_dir) ~= 1 then
    run_dir = "/tmp"
  end

  for _ = 1, 10 do
    local rand_suffix = string.format("%08x%08x", math.random(0, 0x7fffffff), math.random(0, 0x7fffffff))
    local path = string.format("%s/worktree-auth-%s.curlrc", run_dir, rand_suffix)
    -- "wx" maps strictly to O_WRONLY | O_CREAT | O_EXCL
    local fd, err = vim.uv.fs_open(path, "wx", 384) -- mode 0600
    if fd then
      local stat = vim.uv.fs_fstat(fd)
      if stat and bit.band(stat.mode, 511) == 384 then
        local header_data = string.format(
          'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "Content-Type: application/json"\n',
          token
        )
        vim.uv.fs_write(fd, header_data)
        vim.uv.fs_close(fd)

        local cleaned = false
        local function cleanup()
          if not cleaned then
            cleaned = true
            pcall(vim.uv.fs_unlink, path)
          end
        end

        return path, cleanup
      end
      vim.uv.fs_close(fd)
      pcall(vim.uv.fs_unlink, path)
    end
  end
  error("worktree.credentials: failed to create exclusive temporary credential file")
end

---redact strips Authorization headers and tokens from diagnostic strings.
---@param text string
---@return string
function M.redact(text)
  if type(text) ~= "string" then return text end
  return text:gsub("Authorization:%s*Bearer%s+[%w%-_.]+", "Authorization: Bearer [REDACTED]")
             :gsub("Bearer%s+[%w%-_.]+", "Bearer [REDACTED]")
end

return M
