---worktree.review — the review-JSON store.
---
---ADR-0060 §2.6/§2.7. One file per `(repo, commit, revision)`, named so it can
---be applied systematically and stays self-describing when copied out:
---
---    <owner>__<repo>@<short-sha>.r<N>.review.json
---
---**Line numbers are 1-based and GitHub-native.** That is a deliberate choice
---with a trap behind it: the family already has a divergent base — auto-agents'
---MCP `ClaudeCodeMention` uses 0-indexed lines "for Claude compatibility". The
---artifact's purpose is to upload to GitHub, so the file on disk stays
---uploadable with no transformation, and the RENDERER converts to 0-based
---extmark rows at paint time (`auto-core.git.diff.row_for` + `ui.marks`).
---
---The payload is a superset of `/review-pr`'s established
---`{review_event, body, comments:[{path,line,body}]}`, so `github_payload()` is
---a projection rather than a rewrite.
---@module 'worktree.review'

local store = require("worktree.store")

local M = {}

---SCHEMA is the payload version. Bump it only for a breaking shape change; a
---reader must be able to refuse a file it does not understand rather than
---silently mis-rendering it.
M.SCHEMA = "worktree.review/1"

---SEVERITIES is the KB's established review ladder.
M.SEVERITIES = { "must-fix", "should-fix", "nit", "question" }

---VERDICTS map onto GitHub review events.
M.VERDICTS = {
  approved = "APPROVE",
  change_requested = "REQUEST_CHANGES",
  comment = "COMMENT",
}

---@class WorktreeReviewComment
---@field id string?
---@field path string          repo-relative
---@field line integer         1-BASED, GitHub-native; the END line of a range
---@field start_line integer?  1-based range start
---@field side string?         "RIGHT" (after) | "LEFT" (before)
---@field start_side string?
---@field severity string?     must-fix | should-fix | nit | question
---@field body string
---@field resolved boolean?

---@class WorktreeReview
---@field schema string
---@field repo { url: string?, owner: string?, name: string? }
---@field commit string
---@field base string?
---@field revision integer
---@field reviewer string?
---@field created string?
---@field verdict string?      approved | change_requested | comment
---@field summary string?
---@field comments WorktreeReviewComment[]

---filename builds the canonical name. `short` is the abbreviated sha as git
---renders it; a full sha is accepted and shortened so callers need not care.
---@param slug string
---@param sha string
---@param revision integer
---@return string
function M.filename(slug, sha, revision)
  local short = tostring(sha or ""):sub(1, 7)
  return string.format("%s@%s.r%d.review.json", slug, short, tonumber(revision) or 1)
end

---parse_filename recovers `(slug, short_sha, revision)` from a name, so a
---directory listing can be grouped without opening every file.
---@param name string
---@return string? slug, string? short, integer? revision
function M.parse_filename(name)
  local slug, short, rev = tostring(name or "")
    :match("^(.+)@(%x+)%.r(%d+)%.review%.json$")
  if not slug then return nil, nil, nil end
  return slug, short, tonumber(rev)
end

---validate checks a review's shape and returns the problems it found, so a
---malformed file is reported precisely rather than rendering as a blank pane.
---@param review any
---@return boolean ok, string[] problems
function M.validate(review)
  local problems = {}
  if type(review) ~= "table" then
    return false, { "not a table" }
  end
  if review.schema ~= M.SCHEMA then
    problems[#problems + 1] =
      "schema is " .. tostring(review.schema) .. ", expected " .. M.SCHEMA
  end
  if type(review.commit) ~= "string" or review.commit == "" then
    problems[#problems + 1] = "commit missing"
  end
  if type(review.revision) ~= "number" then
    problems[#problems + 1] = "revision missing or not a number"
  end
  if review.verdict and not M.VERDICTS[review.verdict] then
    problems[#problems + 1] = "unknown verdict " .. tostring(review.verdict)
  end
  if type(review.comments) ~= "table" then
    problems[#problems + 1] = "comments missing"
  else
    for i, c in ipairs(review.comments) do
      local where = "comments[" .. i .. "]"
      if type(c.path) ~= "string" or c.path == "" then
        problems[#problems + 1] = where .. ".path missing"
      end
      if type(c.line) ~= "number" or c.line < 1 then
        -- The 1-based rule is enforced, not assumed: a 0 here means someone
        -- wrote 0-indexed rows into a GitHub-native field, and every comment
        -- in the file would land one line off.
        problems[#problems + 1] = where .. ".line must be a 1-based number"
      end
      if type(c.body) ~= "string" or c.body == "" then
        problems[#problems + 1] = where .. ".body missing"
      end
      if c.side and c.side ~= "LEFT" and c.side ~= "RIGHT" then
        problems[#problems + 1] = where .. ".side must be LEFT or RIGHT"
      end
      if c.severity and not vim.tbl_contains(M.SEVERITIES, c.severity) then
        problems[#problems + 1] = where .. ".severity is not in the ladder"
      end
    end
  end
  return #problems == 0, problems
end

---new builds a valid, empty review for a commit.
---@param opts { slug: string?, url: string?, owner: string?, name: string?, commit: string, base: string?, revision: integer?, reviewer: string?, verdict: string?, summary: string? }
---@return WorktreeReview
function M.new(opts)
  opts = opts or {}
  return {
    schema = M.SCHEMA,
    repo = { url = opts.url, owner = opts.owner, name = opts.name },
    commit = opts.commit,
    base = opts.base,
    revision = opts.revision or 1,
    reviewer = opts.reviewer,
    -- ISO-8601 UTC so the field sorts lexicographically.
    created = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    verdict = opts.verdict or "comment",
    summary = opts.summary,
    comments = {},
  }
end

---save writes a review, refusing an invalid one. Writing a malformed review
---would leave a file the panel cannot render and the uploader cannot use.
---@param slug string
---@param review WorktreeReview
---@return string? path, string? err
function M.save(slug, review)
  local ok, problems = M.validate(review)
  if not ok then
    return nil, "invalid review: " .. table.concat(problems, "; ")
  end
  local dir = store.reviews_dir(slug)
  local path = dir .. "/" .. M.filename(slug, review.commit, review.revision)
  local wok, werr = store.write_json(path, review)
  if not wok then return nil, werr end
  return path, nil
end

---load reads one review by `(slug, sha, revision)`.
---@param slug string
---@param sha string
---@param revision integer
---@return WorktreeReview? review, string? err
function M.load(slug, sha, revision)
  local path = store.reviews_dir(slug) .. "/" .. M.filename(slug, sha, revision)
  local data, err = store.read_json(path)
  if err then return nil, err end
  if not data then return nil, nil end
  local ok, problems = M.validate(data)
  if not ok then return nil, "invalid review at " .. path .. ": " .. table.concat(problems, "; ") end
  return data, nil
end

---list_for returns every revision recorded for a commit, newest revision
---first — what the tree lists under a commit (§2.2 rule 4).
---@param slug string
---@param sha string
---@return { revision: integer, path: string, name: string }[]
function M.list_for(slug, sha)
  local short = tostring(sha or ""):sub(1, 7)
  local dir = store.reviews_dir(slug)
  local out = {}
  for _, name in ipairs(store.list_files(dir, "%.review%.json$")) do
    local fslug, fshort, rev = M.parse_filename(name)
    if fslug and fshort == short and rev then
      out[#out + 1] = { revision = rev, path = dir .. "/" .. name, name = name }
    end
  end
  table.sort(out, function(a, b) return a.revision > b.revision end)
  return out
end

---latest_revision reports the highest revision on disk for a commit, so a new
---review can claim `n + 1` without the caller scanning.
---@param slug string
---@param sha string
---@return integer  0 when none exist
function M.latest_revision(slug, sha)
  local all = M.list_for(slug, sha)
  return all[1] and all[1].revision or 0
end

---by_path groups a review's comments by file, then by line, which is the shape
---the diff view needs when it paints one file's annotations.
---@param review WorktreeReview
---@return table<string, WorktreeReviewComment[]>
function M.by_path(review)
  local out = {}
  for _, c in ipairs((review or {}).comments or {}) do
    if type(c.path) == "string" then
      out[c.path] = out[c.path] or {}
      table.insert(out[c.path], c)
    end
  end
  for _, list in pairs(out) do
    table.sort(list, function(a, b) return (a.line or 0) < (b.line or 0) end)
  end
  return out
end

---github_payload projects a review onto GitHub's review API shape.
---
---A projection, not a rewrite: `path`/`line`/`body` are exactly the fields
---`/review-pr` already emits, and `side`/`start_line` pass through because
---GitHub accepts them natively. `severity` and `resolved` are OURS and are
---deliberately folded into the body text — GitHub has no field for them, and
---dropping them silently would lose the reviewer's emphasis.
---@param review WorktreeReview
---@return { review_event: string, body: string, comments: table[] }
function M.github_payload(review)
  review = review or {}
  local comments = {}
  for _, c in ipairs(review.comments or {}) do
    if not c.resolved then
      local body = c.body or ""
      if c.severity then body = "**" .. c.severity .. "** — " .. body end
      local entry = { path = c.path, line = c.line, body = body }
      if c.side then entry.side = c.side end
      if c.start_line then
        entry.start_line = c.start_line
        entry.start_side = c.start_side or c.side
      end
      comments[#comments + 1] = entry
    end
  end
  return {
    review_event = M.VERDICTS[review.verdict or "comment"] or "COMMENT",
    body = review.summary or "",
    comments = comments,
  }
end

return M
