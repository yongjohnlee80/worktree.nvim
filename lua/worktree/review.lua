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

---_is_array reports whether `t` is a proper JSON array: contiguous integer keys
---from 1, and nothing else. A JSON OBJECT decodes to a table `ipairs` walks
---zero times, which is why an object of comments silently validated and then
---uploaded nothing (r2 #4c).
---@param t table
---@return boolean
local function _is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k % 1 ~= 0 or k < 1 then return false end
    n = n + 1
  end
  return n == #t
end

---validate checks a review's shape and returns the problems it found, so a
---malformed file is reported precisely rather than rendering as a blank pane.
---@param review any
---@param opts { for_write: boolean? }?
---  `for_write` REQUIRES `document`. Reads stay tolerant so artifacts written
---  before ADR-0067 still load; writes do not, because JSON-last removed the
---  transient unpaired state that made the field optional in the first place.
---@return boolean ok, string[] problems
function M.validate(review, opts)
  local problems = {}
  if type(review) ~= "table" then
    return false, { "not a table" }
  end
  if review.schema ~= M.SCHEMA then
    problems[#problems + 1] =
      "schema is " .. tostring(review.schema) .. ", expected " .. M.SCHEMA
  end
  -- The payload carries the FULL sha (`review-json` §3); the filename carries
  -- the short form. A 7-char value here means someone wrote the abbreviation
  -- into the wrong field, and the review would not be reproducible.
  if type(review.commit) ~= "string" or not review.commit:match("^%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x%x$") then
    problems[#problems + 1] = "commit must be a full 40-character hex sha"
  end
  if type(review.revision) ~= "number" or review.revision % 1 ~= 0
    or review.revision < 1 then
    -- Integer >= 1. Revision 0 would write a real `…r0.review.json`, which
    -- collides with latest_revision()'s "none exist" sentinel of 0.
    problems[#problems + 1] = "revision must be an integer >= 1"
  end
  if review.verdict and not M.VERDICTS[review.verdict] then
    problems[#problems + 1] = "unknown verdict " .. tostring(review.verdict)
  end
  -- The artifact must NAME its repository (r3 #3). A type check alone let
  -- `repo = nil` and `repo = {}` through, and an empty Lua table serialises as
  -- `"repo":[]` — a JSON ARRAY, not the identity object the schema declares.
  -- Either a url or an owner/name pair is enough; both is better.
  if type(review.repo) ~= "table" then
    problems[#problems + 1] = "repo must be an identity table (url, or owner+name)"
  else
    local url = review.repo.url
    local owner, name = review.repo.owner, review.repo.name
    for field, v in pairs({ url = url, owner = owner, name = name }) do
      if v ~= nil and type(v) ~= "string" then
        problems[#problems + 1] = "repo." .. field .. " must be a string"
      end
    end
    local has_url = type(url) == "string" and url ~= ""
    local has_pair = type(owner) == "string" and owner ~= ""
      and type(name) == "string" and name ~= ""
    if not (has_url or has_pair) then
      problems[#problems + 1] =
        "repo carries no identity — needs a non-empty url, or owner AND name"
    end
  end
  -- `document` — the cross-reference to the primary Markdown (review-json §6).
  -- Shape only here; existence and containment are `validate_pair`'s job,
  -- because this function must stay filesystem-free.
  if review.document ~= nil then
    if type(review.document) ~= "string" or review.document == "" then
      problems[#problems + 1] = "document must be a non-empty string"
    else
      local drev = tonumber(review.document:match("%-r(%d+)%-review%.md$"))
      if not drev then
        problems[#problems + 1] =
          "document must be named …-r<N>-review.md so the pair is legible"
      elseif type(review.revision) == "number" and drev ~= review.revision then
        problems[#problems + 1] = ("document is r%d but the review is r%s")
          :format(drev, tostring(review.revision))
      end
    end
  elseif opts and opts.for_write then
    problems[#problems + 1] =
      "document required for a new review — every JSON is a projection of a "
      .. "Markdown review (review-json §6); write through save_pair()"
  end
  if type(review.comments) ~= "table" then
    problems[#problems + 1] = "comments missing"
  elseif not _is_array(review.comments) then
    -- review-json §3 specifies an array and §7 forbids silent loss. `ipairs`
    -- walks a JSON object zero times, so EVERY per-comment check was skipped
    -- and `github_payload` uploaded ZERO comments (r2 #4c).
    problems[#problems + 1] =
      "comments must be a JSON array (an object or an indexed hole uploads nothing)"
  else
    for i, c in ipairs(review.comments) do
      local where = "comments[" .. i .. "]"
      if type(c) ~= "table" then
        -- Indexing a number or boolean THREW, breaking validate's declared
        -- `@return boolean ok, string[] problems` — and via `review.load` it
        -- turned one malformed file into a raw traceback in the panel (r2 #4d).
        problems[#problems + 1] = where .. " is not a table (got " .. type(c) .. ")"
        goto continue
      end
      if type(c.path) ~= "string" or c.path == "" then
        problems[#problems + 1] = where .. ".path missing"
      end
      if type(c.line) ~= "number" or c.line < 1 or c.line % 1 ~= 0 then
        -- The 1-based rule is enforced, not assumed: a 0 here means someone
        -- wrote 0-indexed rows into a GitHub-native field, and every comment
        -- in the file would land one line off.
        problems[#problems + 1] = where .. ".line must be a 1-based integer"
      end
      if type(c.body) ~= "string" or c.body == "" then
        problems[#problems + 1] = where .. ".body missing"
      end
      if c.side and c.side ~= "LEFT" and c.side ~= "RIGHT" then
        problems[#problems + 1] = where .. ".side must be LEFT or RIGHT"
      end
      -- The range endpoints get the SAME rules as `line`. §4 states the
      -- 1-based rule for both, but only `line` was enforced — so an
      -- unchecked start_line reached both the renderer and `github_payload`,
      -- which forwards it verbatim into a request GitHub rejects (r1 MF3).
      if c.start_line ~= nil then
        if type(c.start_line) ~= "number" or c.start_line < 1
          or c.start_line % 1 ~= 0 then
          problems[#problems + 1] = where .. ".start_line must be a 1-based integer"
        elseif type(c.line) == "number" and c.start_line > c.line then
          problems[#problems + 1] = where .. ".start_line must be <= .line "
            .. "(it is the START of the range; .line is the END)"
        end
      end
      if c.start_side and c.start_side ~= "LEFT" and c.start_side ~= "RIGHT" then
        problems[#problems + 1] = where .. ".start_side must be LEFT or RIGHT"
      end
      if c.resolved ~= nil and type(c.resolved) ~= "boolean" then
        problems[#problems + 1] = where .. ".resolved must be a boolean"
      end
      if c.severity and not vim.tbl_contains(M.SEVERITIES, c.severity) then
        problems[#problems + 1] = where .. ".severity is not in the ladder"
      end
      ::continue::
    end
  end
  return #problems == 0, problems
end

-- ── The paired store (ADR-0067) ──────────────────────────────────────────
--
-- Three record kinds share the reviews directory. Only the canonical JSON is
-- visible to readers: `list_for` scans `"%.review%.json$"` and `store.list_files`
-- filters on exactly that pattern, so the two below are never listed, never
-- loaded and never counted by `latest_revision`.
--
--   <slug>@<short>.r<N>.review.json   canonical  — the commit point
--   <slug>@<short>.r<N>.reserve       reservation — a live writer's claim
--   <slug>@<short>.r<N>.tombstone     tombstone   — this revision is retired
--
-- Reclamation is APPEND-ONLY. Nothing is ever unlinked to reclaim it, because
-- conditional deletion is not expressible here: `store.lua`'s own registry lock
-- records that any `fs_stat` then `fs_unlink` "leaves a window in which a
-- successor is installed and then deleted by a decision that is already stale",
-- and that `rm` cannot be conditional on an inode any more than `fs_unlink`
-- could. An expired reservation is TOMBSTONED, never removed.

M.RESERVE_SUFFIX = ".reserve"
M.TOMBSTONE_SUFFIX = ".tombstone"

---LEASE_SECONDS is how long a reservation is considered live without renewal.
---
---Liveness is the lease and deliberately NOT a pid probe. This family has
---already shipped two defects that way (ADR-0060 r4): a `/proc/<pid>/stat`
---first-parenthesis parser that made a live renamed process look like PID
---reuse, and a stat-to-unlink interleaving that deleted a live successor. A
---lease has no such failure mode — its worst case is a slow writer losing a
---revision number it had not committed.
M.LEASE_SECONDS = 120

local function _base(slug, sha, revision)
  local short = tostring(sha or ""):sub(1, 7)
  return string.format("%s@%s.r%d", slug, short, tonumber(revision) or 1)
end

---reserve_path / tombstone_path — the two non-canonical record names.
function M.reserve_path(slug, sha, revision)
  return store.reviews_dir(slug) .. "/" .. _base(slug, sha, revision) .. M.RESERVE_SUFFIX
end

function M.tombstone_path(slug, sha, revision)
  return store.reviews_dir(slug) .. "/" .. _base(slug, sha, revision) .. M.TOMBSTONE_SUFFIX
end

---_token mints an UNGUESSABLE reservation owner.
---
---Not a pid and not a name: a guessable token is a lock anyone can forge, and
---ownership is the only thing standing between a cleanup pass and a live
---writer's claim.
local function _token()
  local ok, bytes = pcall(function()
    return (vim.uv or vim.loop).random(16)
  end)
  if ok and type(bytes) == "string" and #bytes > 0 then
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
  end
  -- Fallback: still unguessable enough for a same-machine race, and the only
  -- path when libuv has no `random`.
  local t = {}
  for _ = 1, 16 do t[#t + 1] = string.format("%02x", math.random(0, 255)) end
  return table.concat(t)
end

---_now is seconds since the epoch.
local function _now() return os.time() end

---max_recorded_revision is the allocation maximum over ALL THREE record kinds.
---
---`latest_revision` scans canonical files alone and is unchanged — it answers
---"what is the newest review", which is a different question. Allocating from
---it re-offers a number that is reserved or tombstoned but never committed,
---which would hand a crashed writer's revision to the next one.
---@param slug string
---@param sha string
---@return integer  0 when nothing is recorded
function M.max_recorded_revision(slug, sha)
  local short = tostring(sha or ""):sub(1, 7)
  local dir = store.reviews_dir(slug)
  local highest = 0
  for _, name in ipairs(store.list_files(dir)) do
    local rev = name:match("^.+@" .. short .. "%.r(%d+)%.review%.json$")
      or name:match("^.+@" .. short .. "%.r(%d+)%" .. M.RESERVE_SUFFIX .. "$")
      or name:match("^.+@" .. short .. "%.r(%d+)%" .. M.TOMBSTONE_SUFFIX .. "$")
    rev = tonumber(rev)
    if rev and rev > highest then highest = rev end
  end
  return highest
end

---_read_reservation returns the decoded reservation at `rev`, or nil.
local function _read_reservation(slug, sha, rev)
  local data = store.read_json(M.reserve_path(slug, sha, rev))
  if type(data) ~= "table" then return nil end
  return data
end

---_owns reports whether `token` still holds the reservation AND the revision has
---not been tombstoned underneath it.
local function _owns(slug, sha, rev, token)
  if vim.uv and vim.uv.fs_stat(M.tombstone_path(slug, sha, rev)) then return false end
  local r = _read_reservation(slug, sha, rev)
  return r ~= nil and r.owner == token
end

---retire fences a revision so it can never be handed out again.
---
---Tombstoning can itself fail — a read-only reviews directory rejects the
---tombstone for the same reason it rejected the JSON — so this is an ATTEMPT,
---not a guarantee. The reservation is the fallback fence: it already
---participates in `max_recorded_revision`, so retaining it keeps the number out
---of circulation just as well. The only difference is whether the fence
---survives a cleanup pass.
---@return boolean tombstoned, string? err
function M.retire(slug, sha, rev, token)
  local ok, err = store.create_exclusive(
    M.tombstone_path(slug, sha, rev),
    vim.json.encode({ retired_at = _now(), by = token }))
  if ok then
    -- The tombstone fences the revision, so releasing our own reservation is
    -- now safe. It is the ONLY unconditional removal in the protocol besides
    -- the post-commit one.
    if token and _owns(slug, sha, rev, token) then
      pcall(function() (vim.uv or vim.loop).fs_unlink(M.reserve_path(slug, sha, rev)) end)
    end
    return true, nil
  end
  -- Taken by another writer's tombstone is success for our purposes: the
  -- revision is fenced either way.
  if not err and (vim.uv and vim.uv.fs_stat(M.tombstone_path(slug, sha, rev))) then
    return true, nil
  end
  return false, err or "tombstone could not be created"
end

---cleanup tombstones reservations whose lease has expired.
---
---An expired lease is the ONLY evidence of staleness this protocol accepts. "No
---canonical JSON yet" is not — that is also the state of every live writer
---between reserving and committing, and a cleanup built on it reaps running
---submitters.
---@return integer retired
function M.cleanup(slug, sha)
  local short = tostring(sha or ""):sub(1, 7)
  local dir = store.reviews_dir(slug)
  local n = 0
  for _, name in ipairs(store.list_files(dir)) do
    local rev = tonumber(name:match("^.+@" .. short .. "%.r(%d+)%" .. M.RESERVE_SUFFIX .. "$"))
    if rev then
      -- Never tombstone a revision that already committed: the pair is
      -- complete and the tombstone would be pure noise.
      local canonical = store.reviews_dir(slug) .. "/" .. M.filename(slug, sha, rev)
      local committed = vim.uv and vim.uv.fs_stat(canonical) ~= nil
      local r = _read_reservation(slug, sha, rev)
      local expired = r and type(r.lease_until) == "number" and r.lease_until < _now()
      if not committed and expired then
        if M.retire(slug, sha, rev, nil) then n = n + 1 end
      end
    end
  end
  return n
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
---
---A review already on disk is IMMUTABLE. `review-json` §3 says a re-review is
---a new revision, never an edit, but nothing enforced that: this wrote the
---canonical path unconditionally and `fs_rename` replaces, so saving r1 twice
---destroyed the first review and returned success to both writers (r1 MF2).
---Pass `{ overwrite = true }` for a deliberate amend of your own file.
---@param slug string
---@param review WorktreeReview
---@param opts { overwrite: boolean? }?
---@return string? path, string? err
function M.save(slug, review, opts)
  -- A PRIMITIVE, not the supported writer (ADR-0067 §2.5). `save_pair` is.
  --
  -- This refuses an unpaired canonical review because the "no reader ever sees
  -- a JSON without its document" invariant is only worth what the narrowest
  -- writer allows — and this one is public. The check is the full pair check,
  -- not merely "the field is present": a syntactically valid path naming a
  -- nonexistent file would otherwise satisfy it and publish the very artifact
  -- §6 forbids. It runs BEFORE the exclusive create, so a refusal leaves
  -- nothing behind.
  local ok, problems = M.validate(review, { for_write = true })
  if not ok then
    return nil, "invalid review: " .. table.concat(problems, "; ")
  end
  -- No escape hatch. A `skip_pair_check` option was considered and rejected:
  -- an invariant any caller can opt out of is not an invariant, and the whole
  -- point of closing this path is that the narrowest public writer decides what
  -- readers can observe.
  local okp, pproblems = M.validate_pair(review, opts)
  if not okp then
    return nil, "unpaired review refused (write through save_pair): "
      .. table.concat(pproblems, "; ")
  end
  local dir = store.reviews_dir(slug)
  local name = M.filename(slug, review.commit, review.revision)
  local path = dir .. "/" .. name
  local taken_msg = ("revision r%d already exists for this commit — a re-review "
    .. "is a new revision, never an edit; claim the next one with save_next() "
    .. "(or pass overwrite=true to amend deliberately): %s")
    :format(review.revision, name)

  if not (opts and opts.overwrite) then
    -- CLAIM, not check-then-write (r2 #2). r1 said a pre-write `fs_stat` was
    -- not enough; I acted on that only in `save_next` and left this path as
    -- stat-then-replacing-write, so two writers that both observed absence both
    -- returned success and the later rename destroyed the earlier review.
    -- Reproduced with a real second process. The exclusive create IS the gate.
    local ok_enc, encoded = pcall(vim.json.encode, review)
    if not ok_enc then return nil, "encode failed: " .. tostring(encoded) end
    local claimed, cerr = store.create_exclusive(path, encoded)
    if claimed then return path, nil end
    if cerr then return nil, cerr end
    return nil, taken_msg          -- claimed=false with no err means "taken"
  end

  -- An explicit amend IS a replace, so the replacing write belongs here.
  local wok, werr = store.write_json(path, review)
  if not wok then return nil, werr end
  return path, nil
end

---save_next claims the next free revision for this commit and writes it,
---atomically, so two reviewers running concurrently land on rN and rN+1 rather
---than both taking rN and one silently winning (r1 MF2).
---
---`latest_revision() + 1` alone is a check-then-write race. The claim is the
---exclusive CREATE of the target file itself, so losing the race is observable
---(the name is taken) rather than silent, and we simply try the next number.
---@param slug string
---@param review WorktreeReview
---@return string? path, integer|string? revision_or_err
function M.save_next(slug, review, opts)
  -- Also a PRIMITIVE. It re-selects the revision on collision, which is exactly
  -- what makes it unsafe for a pair: the JSON would end up at a revision the
  -- Markdown was never named for. Kept for callers that manage their own
  -- pairing, and refusing an unpaired write like `save` does.
  local start = M.latest_revision(slug, review.commit) + 1
  for rev = start, start + 24 do
    review.revision = rev
    local ok, problems = M.validate(review, { for_write = true })
    if not ok then return nil, "invalid review: " .. table.concat(problems, "; ") end
    local okp, pproblems = M.validate_pair(review, opts)
    if not okp then
      return nil, "unpaired review refused (write through save_pair): "
        .. table.concat(pproblems, "; ")
    end

    local path = store.reviews_dir(slug) .. "/" .. M.filename(slug, review.commit, rev)
    local ok_enc, encoded = pcall(vim.json.encode, review)
    if not ok_enc then return nil, "encode failed: " .. tostring(encoded) end

    local claimed, err = store.create_exclusive(path, encoded)
    if claimed then return path, rev end
    if err then return nil, err end
    -- Taken by another writer between our scan and our claim: take the next.
  end
  return nil, "save_next: could not claim a revision after 25 attempts"
end

---validate_pair checks that a review's `document` names a real primary
---artifact in the reviewer's own directory.
---
---Split from `validate` by WHAT IT NEEDS. `validate` stays pure — schema only,
---no filesystem — so it keeps its unit tests and can run anywhere. This one
---touches disk, and exists because `document` PRESENCE is not pair EXISTENCE: a
---syntactically valid path naming a nonexistent file satisfies a field check
---and still publishes an unpaired canonical JSON.
---@param review table
---@param opts { kb_root: string? }?
---@return boolean ok, string[] problems
function M.validate_pair(review, opts)
  local problems = {}
  if type(review) ~= "table" then return false, { "not a table" } end
  local doc = review.document
  if type(doc) ~= "string" or doc == "" then
    return false, { "document missing — a review must name its primary Markdown" }
  end

  local kb = (opts and opts.kb_root) or vim.env.AUTO_AGENTS_KB_ROOT
  if type(kb) ~= "string" or kb == "" then
    problems[#problems + 1] = "cannot resolve $KB_ROOT to contain the document"
  else
    local abs = doc
    if not abs:match("^/") then abs = kb .. "/" .. abs end
    local norm = vim.fs and vim.fs.normalize(abs) or abs
    local reviewer = tostring(review.reviewer_slug or "")
    local want = vim.fs and vim.fs.normalize(kb .. "/agents/") or (kb .. "/agents/")
    -- Containment is checked on the NORMALISED path, so `..` cannot walk out.
    if norm:sub(1, #want) ~= want then
      problems[#problems + 1] = "document is outside $KB_ROOT/agents/: " .. norm
    elseif reviewer ~= "" then
      local mine = vim.fs and vim.fs.normalize(kb .. "/agents/" .. reviewer .. "/reviews/")
        or (kb .. "/agents/" .. reviewer .. "/reviews/")
      if norm:sub(1, #mine) ~= mine then
        problems[#problems + 1] = "document is under another reviewer's directory: " .. norm
      end
    end
    if not (vim.uv or vim.loop).fs_stat(norm) then
      problems[#problems + 1] = "document does not exist: " .. norm
    end
  end

  local rev = tonumber(doc:match("%-r(%d+)%-review%.md$"))
  if not rev then
    problems[#problems + 1] = "document name does not carry a revision (…-rN-review.md)"
  elseif type(review.revision) == "number" and rev ~= review.revision then
    problems[#problems + 1] = ("document is r%d but the review is r%s")
      :format(rev, tostring(review.revision))
  end
  return #problems == 0, problems
end

---save_pair writes a review and its primary Markdown as ONE operation.
---
---Ordering is the entire safety argument, and two earlier designs failed on it:
---
---  * Markdown-first is unimplementable — the Markdown filename carries `r<N>`,
---    but `save_next` only assigns N at write time, so two submitters can both
---    write `…-r1-review.md`.
---  * Canonical-JSON-first fixes the naming race and MOVES the damage: readers
---    can observe a valid JSON-only review the instant it appears, and a kill
---    between phases makes that permanent.
---
---So: reserve on a NON-CANONICAL name, derive N from the won reservation,
---generate both final contents at that point, claim the Markdown, and publish
---the complete canonical JSON LAST as the commit point. Every crash window
---leaves at most an orphan Markdown — a primary document nobody has projected
---yet, which review-json §6 permits — and never a projection without its
---primary.
---@param slug string
---@param review table            revision is assigned here
---@param markdown fun(rev: integer): string, string   body, absolute path
---@param opts { kb_root: string?, attempts: integer? }?
---@return table? result  { json_path, md_path, revision }
---@return string? err
function M.save_pair(slug, review, markdown, opts)
  if type(review) ~= "table" then return nil, "review must be a table" end
  if type(markdown) ~= "function" then return nil, "markdown generator required" end
  local sha = review.commit
  if type(sha) ~= "string" then return nil, "review.commit required" end

  -- A stale reservation blocks its number forever unless something retires it,
  -- so the cheap same-directory scan runs first.
  pcall(M.cleanup, slug, sha)

  local attempts = (opts and opts.attempts) or 25
  local start = M.max_recorded_revision(slug, sha) + 1
  local token = _token()

  for rev = start, start + attempts - 1 do
    local tomb = (vim.uv or vim.loop).fs_stat(M.tombstone_path(slug, sha, rev))
    if not tomb then
      local claimed = store.create_exclusive(M.reserve_path(slug, sha, rev),
        vim.json.encode({ owner = token, created_at = _now(),
                          lease_until = _now() + M.LEASE_SECONDS }))
      if claimed then
        -- The revision is ours, so both final names are now determined.
        local body, md_path = markdown(rev)
        if type(body) ~= "string" or type(md_path) ~= "string" then
          M.retire(slug, sha, rev, token)
          return nil, "markdown generator returned no body/path"
        end

        review.revision = rev
        review.document = md_path

        if not _owns(slug, sha, rev, token) then
          -- Reclaimed underneath us before anything was written.
          goto continue
        end

        if not store.ensure_dir(vim.fn.fnamemodify(md_path, ":h")) then
          M.retire(slug, sha, rev, token)
          return nil, "could not create " .. vim.fn.fnamemodify(md_path, ":h")
        end
        local md_ok, md_err = store.create_exclusive(md_path, body)
        if md_err then
          M.retire(slug, sha, rev, token)
          return nil, md_err
        end
        if not md_ok then
          -- The final name is taken: retire this revision so BOTH names move.
          M.retire(slug, sha, rev, token)
          goto continue
        end

        if not _owns(slug, sha, rev, token) then
          -- Lost it after the Markdown landed: abandon, leaving the orphan.
          -- That is the tolerated remnant, never an unpaired JSON.
          goto continue
        end

        local ok_v, problems = M.validate(review, { for_write = true })
        if not ok_v then
          M.retire(slug, sha, rev, token)
          return nil, "invalid review: " .. table.concat(problems, "; ")
        end
        local ok_enc, encoded = pcall(vim.json.encode, review)
        if not ok_enc then
          M.retire(slug, sha, rev, token)
          return nil, "encode failed: " .. tostring(encoded)
        end

        -- ***THE COMMIT POINT***
        local json_path = store.reviews_dir(slug) .. "/" .. M.filename(slug, sha, rev)
        local j_ok, j_err = store.create_exclusive(json_path, encoded)
        if not j_ok then
          local _, terr = M.retire(slug, sha, rev, token)
          return nil, ("the review JSON could not be written (%s). Your Markdown review "
            .. "is kept at %s — it is not lost.%s"):format(
              tostring(j_err or "revision taken"), md_path,
              terr and (" (revision not tombstoned: " .. terr .. "; reservation retained "
                .. "as the fence)") or "")
        end

        -- Committed. The canonical JSON is the monotonic fence, so no live
        -- writer can still hold this revision — the one place removing the
        -- reservation unconditionally is safe.
        pcall(function() (vim.uv or vim.loop).fs_unlink(M.reserve_path(slug, sha, rev)) end)
        return { json_path = json_path, md_path = md_path, revision = rev }, nil
      end
    end
    ::continue::
  end
  return nil, ("could not claim a revision after %d attempts"):format(attempts)
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
      -- MATERIALISE the default (r3 #2). The artifact may omit `side` — the
      -- convention says omitted means RIGHT — but GitHub does NOT supply that
      -- default: its REST contract wants `side` on a line comment and
      -- `start_side` on a multiline one. Emitting only what the artifact
      -- happened to carry produced `{path, line, body}` for a perfectly valid
      -- review, which GitHub rejects. The default belongs here, at the
      -- boundary, not in the reader.
      entry.side = c.side or "RIGHT"
      if c.start_line then
        entry.start_line = c.start_line
        -- Cross-side ranges are preserved rather than normalised: GitHub models
        -- the two sides independently and the convention does not forbid it.
        entry.start_side = c.start_side or c.side or "RIGHT"
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
