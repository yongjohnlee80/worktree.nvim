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
---Sourced from auto-core, so the documented figure and the one the allocator
---enforces cannot drift apart. Still published here because callers and the
---migration gate read `review.LEASE_SECONDS`.
M.LEASE_SECONDS = (function()
  local ok, ds = pcall(require, "auto-core.docstore")
  if ok and type(ds) == "table" and ds.revisions then return ds.revisions.LEASE_SECONDS end
  return 120
end)()

---### P4b — revisioned identity DELEGATES (ADR-0081 §2.2a)
---
---worktree keeps what it owns: the mapping from `(repo, commit)` to a logical
---KEY, and the canonical filename grammar. auto-core owns the mechanics —
---exclusive claim, lease, retirement, monotonic non-reuse, record persistence —
---behind a validated handle.
---
---The composed paths are byte-identical to the ones this module used to build
---itself, which is not an assumption: `tests/adr0081-migration-gate.lua` asserts
---it against records produced by the SHIPPED v0.5.7 writer.
local function _key(slug, sha)
  return string.format("%s@%s", tostring(slug or ""), tostring(sha or ""):sub(1, 7))
end

---_handle opens the allocator for one (slug, commit).
---
---Raises when the identity cannot be expressed in the record grammar. That is
---deliberate and it is a bug fix, not a regression: the only identities auto-core
---refuses are ones that would compose an AMBIGUOUS filename — a slug carrying a
---`.r<digits>` segment, say — and such a name was already ambiguous when this
---module built it by hand. A silent wrong answer is the worse outcome.
local function _handle(slug, sha)
  local ok_rv, rv = pcall(function() return require("auto-core.docstore").revisions end)
  if not ok_rv or type(rv) ~= "table" or type(rv.open) ~= "function" then
    error("worktree.review: auto-core.docstore.revisions is required"
      .. " (auto-core >= v0.2.12)", 0)
  end
  local h, err = rv.open({
    dir = store.reviews_dir(slug),
    key = _key(slug, sha),
    suffix = ".review.json",
  })
  if not h then
    error(("worktree.review: this repo/commit cannot be expressed as a review"
      .. " record identity: %s"):format(tostring(err)), 0)
  end
  return h
end

---reserve_path / tombstone_path — the two non-canonical record names.
function M.reserve_path(slug, sha, revision)
  return _handle(slug, sha):reserve_path(revision)
end

function M.tombstone_path(slug, sha, revision)
  return _handle(slug, sha):tombstone_path(revision)
end

---_now is seconds since the epoch.
local function _now() return os.time() end

---_token mints an UNGUESSABLE reservation owner, from auto-core.
---
---Not a pid and not a name: a guessable token is a lock anyone can forge, and
---ownership is the only thing standing between a cleanup pass and a live
---writer's claim. The `uv.random` call and its collision-avoidance fallback live
---in auto-core now — one implementation, and the one place its fallback is
---documented as NOT a CSPRNG.
local function _token()
  return require("auto-core.docstore").revisions.token()
end

---max_recorded_revision is the highest number this commit has ever used.
---
---Committed, reserved and tombstoned alike — auto-core scans every accepted
---tail for the key, so a deleted record's number is still spent and a crashed
---writer's reservation is not handed to the next writer.
---@return integer
function M.max_recorded_revision(slug, sha)
  return _handle(slug, sha):max_recorded()
end

---_owns reports whether `token` still holds the reservation AND the revision has
---not been tombstoned underneath it.
local function _owns(slug, sha, rev, token)
  return _handle(slug, sha):owns(rev, token)
end

---retire fences a revision so it can never be handed out again.
---
---Tombstoning can itself fail — a read-only reviews directory rejects the
---tombstone for the same reason it rejected the JSON — so this is an ATTEMPT,
---not a guarantee. auto-core reports the two facts separately: whether a
---tombstone was written, and whether the number is fenced at all (the surviving
---reservation counts, and its presence is CONFIRMED rather than assumed).
---
---The third return is additive; existing callers binding two are unaffected.
---@return boolean tombstoned, string? err, boolean? fenced
function M.retire(slug, sha, rev, token)
  return _handle(slug, sha):retire(rev, token)
end

---cleanup tombstones reservations whose lease has expired.
---
---An expired lease is the ONLY evidence of staleness this protocol accepts. "No
---canonical JSON yet" is not — that is also the state of every live writer
---between reserving and committing, and a cleanup built on it reaps running
---submitters.
---
---Committedness is decided across EVERY tail for the key, not just
---`.review.json`: one classifier answers "spent?" and "committed?" or a store
---holding two formats tombstones a revision the other one committed.
---
---The second return is additive: a report carrying `indeterminate` (a
---reservation present but unreadable — kept as a fence, never reaped) plus
---`errors` and `fenced`.
---@return integer retired, table? report
function M.cleanup(slug, sha)
  return _handle(slug, sha):cleanup()
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
  local okp, pproblems = M.validate_pair(review,
      vim.tbl_extend("keep", { slug = slug }, opts or {}))
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
    local ok_enc, encoded = pcall(store.encode_pretty, review)
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
    local okp, pproblems = M.validate_pair(review,
      vim.tbl_extend("keep", { slug = slug }, opts or {}))
    if not okp then
      return nil, "unpaired review refused (write through save_pair): "
        .. table.concat(pproblems, "; ")
    end

    local path = store.reviews_dir(slug) .. "/" .. M.filename(slug, review.commit, rev)
    local ok_enc, encoded = pcall(store.encode_pretty, review)
    if not ok_enc then return nil, "encode failed: " .. tostring(encoded) end

    local claimed, err = store.create_exclusive(path, encoded)
    if claimed then return path, rev end
    if err then return nil, err end
    -- Taken by another writer between our scan and our claim: take the next.
  end
  return nil, "save_next: could not claim a revision after 25 attempts"
end

---_sanitize_segment reduces a name to a safe single path component.
---
---Same rule as the repo slug in review-json §2, for the same reason: the value
---becomes a path segment and must not be able to escape the store.
---@param v any
---@return string?  nil when nothing safe survives
local function _sanitize_segment(v)
  if type(v) ~= "string" then return nil end
  local out = v:lower():gsub("[^a-z0-9_-]+", "-"):gsub("%-+", "-")
    :gsub("^%-", ""):gsub("%-$", "")
  if out == "" then return nil end
  return out
end

M.sanitize_segment = _sanitize_segment

---_kb_root resolves the knowledge-base root for a caller that did not supply
---one, through auto-core's canonical variable resolver.
---
---It used to read `vim.env.AUTO_AGENTS_KB_ROOT` directly, and that is why the
---repos panel could never write a review. That variable is injected into AGENT
---spawn environments only, so the raw read succeeded for every agent and every
---test and failed for the editor — the one caller a user drives. A caller that
---forgot `kb_root` therefore lost the whole feature rather than a degraded path,
---silently, in the one environment nothing exercises (2026-09-03).
---
---`auto-core.todo.vars` resolves `KB_ROOT` as `$AUTO_AGENTS_KB_ROOT` →
---`$AUTO_AGENTS_KB_READ[0]` → `$AUTO_AGENTS_KB_WRITE` →
---`auto-agents.kb.root()`, and that last hop exists precisely for "when the
---panel runs in the parent nvim (not an agent)". Its FIRST hop is the env var
---this replaced, so nothing an agent relied on changes — the chain only adds
---the cases the raw read could not see.
---
---auto-core is already a hard dependency of this plugin, so this adds nothing
---to the dependency graph. It deliberately does NOT reach for `auto-agents`:
---auto-core owns that hop, and every auto-family plugin depends on auto-core
---alone (Johno, 2026-09-03).
---@return string?
local function _kb_root()
  local ok, vars = pcall(require, "auto-core.todo.vars")
  if ok and type(vars) == "table" and type(vars.get) == "function" then
    local okv, v = pcall(vars.get, "KB_ROOT")
    if okv and type(v) == "string" and v ~= "" then return v end
  end
  -- An auto-core without the resolver: the raw variable is still better than
  -- nothing, and is what an agent process has.
  local env = vim.env.AUTO_AGENTS_KB_ROOT
  if type(env) == "string" and env ~= "" then return env end
  return nil
end

---_repo_component is the `<repo>` half of the canonical document name.
local function _repo_component(slug)
  local tail = tostring(slug or ""):match("__(.+)$") or tostring(slug or "")
  return _sanitize_segment(tail) or "repo"
end

---canonical_document builds the ONE document path a review may carry.
---
---The STORE owns this, not the caller. ADR-0067 §2.2 rejects a caller-supplied
---namer validated after the fact, and the first implementation did exactly that:
---it took an absolute path from a generator and created it, so a generator
---returning somewhere outside `$KB_ROOT` committed a pair that violated the
---containment invariant. Verified — `outside_save_ok=true`.
---@param opts { kb_root: string, reviewer_slug: string, slug: string, topic: string?, date: string?, revision: integer }
---@return string? path, string? err
function M.canonical_document(opts)
  local kb = opts and opts.kb_root
  if type(kb) ~= "string" or kb == "" then
    return nil, "cannot resolve $KB_ROOT for the review document"
  end
  local rslug = _sanitize_segment(opts and opts.reviewer_slug)
  if not rslug then
    return nil, "reviewer_slug produced no safe path segment"
  end
  local rev = tonumber(opts and opts.revision)
  if not rev or rev < 1 or rev % 1 ~= 0 then
    return nil, "revision must be an integer >= 1"
  end
  local date = opts.date or os.date("!%Y-%m-%d")
  if not tostring(date):match("^%d%d%d%d%-%d%d%-%d%d$") then
    return nil, "date must be YYYY-MM-DD"
  end
  local topic = _sanitize_segment(opts.topic) or "review"
  return ("%s/agents/%s/reviews/%s-%s-%s-r%d-review.md")
    :format(kb, rslug, date, _repo_component(opts.slug), topic, rev), nil
end

---DOC_NAME is the canonical filename shape: date, repo, topic, revision.
M.DOC_NAME = "^(%d%d%d%d%-%d%d%-%d%d)%-(.+)%-r(%d+)%-review%.md$"

---_under reports whether `path` sits inside `dir` at a COMPONENT boundary.
---
---A raw prefix comparison is not containment. `vim.fs.normalize` strips the
---trailing slash, so `…/agents/lector/reviews-evil/x` shares the prefix of
---`…/agents/lector/reviews` and was accepted — verified,
---`prefix_sibling_accepted=true`. Comparing with the separator restored is what
---makes a sibling a sibling.
local function _under(path, dir)
  if type(path) ~= "string" or type(dir) ~= "string" then return false end
  local norm = vim.fs and vim.fs.normalize(path) or path
  local base = vim.fs and vim.fs.normalize(dir) or dir
  if base:sub(-1) ~= "/" then base = base .. "/" end
  return norm:sub(1, #base) == base
end

---check_document_path validates a document's SHAPE and CONTAINMENT without
---touching the filesystem, so a writer can preflight before creating anything.
---@param doc any
---@param opts { kb_root: string?, reviewer_slug: string?, slug: string?, revision: integer? }?
---@return boolean ok, string[] problems
function M.check_document_path(doc, opts)
  local problems = {}
  opts = opts or {}
  if type(doc) ~= "string" or doc == "" then
    return false, { "document missing — a review must name its primary Markdown" }
  end
  local kb = opts.kb_root or _kb_root()
  if type(kb) ~= "string" or kb == "" then
    problems[#problems + 1] = "cannot resolve $KB_ROOT to contain the document"
  end
  -- The reviewer slug is REQUIRED, not optional. Skipping the check when it was
  -- absent meant a document under any other reviewer's directory passed —
  -- verified, `missing_reviewer_slug_accepted=true`.
  local rslug = _sanitize_segment(opts.reviewer_slug)
  if not rslug then
    problems[#problems + 1] =
      "reviewer_slug missing or unsafe — ownership of the document cannot be checked"
  end
  if kb and kb ~= "" and rslug then
    if not _under(doc, ("%s/agents/%s/reviews"):format(kb, rslug)) then
      problems[#problems + 1] =
        "document is not under $KB_ROOT/agents/" .. rslug .. "/reviews/: " .. doc
    end
  end
  local name = doc:match("([^/]+)$") or ""
  local date, mid, drev = name:match(M.DOC_NAME)
  if not date then
    problems[#problems + 1] =
      "document name must be YYYY-MM-DD-<repo>-<topic>-r<N>-review.md, got " .. name
  else
    if opts.revision and tonumber(drev) ~= tonumber(opts.revision) then
      problems[#problems + 1] = ("document is r%s but the review is r%s")
        :format(drev, tostring(opts.revision))
    end
    -- The middle must be `<repo>-<topic>` with a NON-EMPTY topic. A substring
    -- match on the repo alone accepted a single-component middle, so
    -- `2026-08-25-x-r1-review.md` passed for `owner__realrepo` — carrying
    -- neither the required repo component nor a separate topic.
    if opts.slug then
      local repo = _repo_component(opts.slug)
      local topic = mid:match("^" .. vim.pesc(repo) .. "%-(.+)$")
      if not topic or topic == "" then
        problems[#problems + 1] =
          ("document name must be <date>-%s-<topic>-r<N>-review.md, got %s"):format(repo, name)
      end
    else
      problems[#problems + 1] =
        "cannot verify the repo component: no slug supplied and the review carries no owner/name"
    end
  end
  return #problems == 0, problems
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
---@param opts { kb_root: string?, slug: string? }?
---@return boolean ok, string[] problems
function M.validate_pair(review, opts)
  if type(review) ~= "table" then return false, { "not a table" } end
  opts = opts or {}
  -- The slug is REQUIRED for the repo-component check, and this used to reduce
  -- to nil unconditionally — `opts.slug or X and nil or nil` is always nil — so
  -- the component was never verified and a non-canonical name passed. Public
  -- writers now supply theirs; failing that, derive it from the repo identity
  -- the review already carries.
  local slug = opts.slug
  if not slug then
    local r = review.repo or {}
    if r.owner and r.name then slug = r.owner .. "__" .. r.name end
  end
  local ok, problems = M.check_document_path(review.document, {
    kb_root = opts.kb_root, reviewer_slug = review.reviewer_slug,
    slug = slug,
    revision = review.revision,
  })
  problems = problems or {}
  local _ds = require("auto-core.docstore")
  -- `kind` rather than a raw stat: auto-core answers what is at a path, so the
  -- two distinct problems below stay distinguishable without this module
  -- handling stat tables. `exists` was not enough -- it cannot tell a directory
  -- sitting where the document belongs from the document itself.
  local kind = review.document and _ds.kind(
    vim.fs and vim.fs.normalize(review.document) or review.document) or nil
  if not kind then
    problems[#problems + 1] = "document does not exist: " .. tostring(review.document)
  elseif kind ~= "file" then
    -- A directory at the document's path is not a primary review.
    problems[#problems + 1] = "document is not a regular file: " .. tostring(review.document)
  end
  return #problems == 0, problems
end

---from_draft builds the review envelope from a draft.
---
---ADR-0067 §2.4 and acceptance criterion 11: the panel and the mailbox must
---produce equivalent artifacts for the same input, which they cannot do while
---each constructs its own envelope. This is the one constructor.
---
---**Repo identity is DERIVED when not supplied.** The schema requires a url or
---an owner+name pair, and the mailbox's advertised minimal call carries
---neither — so a minimal create failed validation only after a revision had
---been reserved and a Markdown written. The slug already encodes
---`<owner>__<repo>`; splitting it here is what makes the documented minimal
---call actually work.
---@param identity { slug: string, url: string?, owner: string?, name: string? }
---@param commit string
---@param reviewer string
---@param draft { verdict: string?, summary: string?, comments: table[]?, base: string? }
---@return table
function M.from_draft(identity, commit, reviewer, draft)
  identity = identity or {}
  draft = draft or {}
  local owner, name = identity.owner, identity.name
  if not (owner and name) then
    local o, n = tostring(identity.slug or ""):match("^(.-)__(.+)$")
    owner = owner or o
    name = name or n
  end
  local doc = M.new({
    slug = identity.slug, url = identity.url, owner = owner, name = name,
    commit = commit, base = draft.base, reviewer = reviewer,
    verdict = draft.verdict, summary = draft.summary,
  })
  doc.reviewer_slug = _sanitize_segment(identity.reviewer_slug or reviewer)
  doc.comments = vim.deepcopy(draft.comments or {})
  return doc
end

---save_pair writes a review and its primary Markdown as ONE operation.
---
---Ordering is the safety argument, and two earlier designs failed on it:
---Markdown-first is unimplementable (the filename carries r<N>, which
---`save_next` only assigns at write time), and canonical-JSON-first moves the
---damage (a reader can observe a valid JSON-only review the instant it
---appears). So: reserve on a NON-CANONICAL name, derive N, generate both final
---contents, claim the Markdown, publish the complete canonical JSON LAST.
---
---**The STORE owns the path.** `content` supplies only the document's body —
---a string, or a `fun(rev): string` when it must stay lazy until the revision
---is won. The first implementation took an absolute path from the caller and
---created it, which let a generator commit a pair outside `$KB_ROOT`; §2.2
---rejects exactly that, and a probe confirmed `outside_save_ok=true`.
---
---**Everything checkable is checked BEFORE the reservation**: the schema, the
---reviewer slug, `$KB_ROOT`, and the canonical path shape. Preflighting after
---the Markdown had landed is how an invalid sha left an orphan and consumed r1.
---@param slug string
---@param review table            revision + document are assigned here
---@param content string|fun(rev: integer): string
---@param opts { kb_root: string?, topic: string?, date: string?, attempts: integer? }?
---@return table? result  { json_path, md_path, revision }
---@return string? err
function M.save_pair(slug, review, content, opts)
  opts = opts or {}
  if type(review) ~= "table" then return nil, "review must be a table" end
  if not (type(content) == "string" or type(content) == "function") then
    return nil, "content must be the document body, or a function returning it"
  end
  local sha = review.commit
  if type(sha) ~= "string" then return nil, "review.commit required" end

  local kb = opts.kb_root or _kb_root()

  -- ── PREFLIGHT: everything knowable before a revision is won ──
  -- `document` is not set yet, so the schema is checked without the for_write
  -- requirement here; the full check runs once the path is computed below.
  do
    local ok, problems = M.validate(review)
    if not ok then return nil, "invalid review: " .. table.concat(problems, "; ") end
  end
  do
    -- Probe the canonical shape at a placeholder revision: an unsafe reviewer
    -- slug or a missing $KB_ROOT fails for EVERY revision, so discovering it
    -- must not cost a reservation.
    local _, perr = M.canonical_document({
      kb_root = kb, reviewer_slug = review.reviewer_slug, slug = slug,
      topic = opts.topic, date = opts.date, revision = 1,
    })
    if perr then return nil, perr end
  end

  pcall(M.cleanup, slug, sha)

  local attempts = opts.attempts or 25
  local start = M.max_recorded_revision(slug, sha) + 1
  local token = _token()

  -- ONE handle for the whole loop: the choreography below is worktree's, the
  -- claim is auto-core's. `claim` refuses a tombstoned revision itself, so the
  -- separate stat-then-create this used to do is gone — that pair was two
  -- decisions where one atomic step will do.
  local handle = _handle(slug, sha)
  for rev = start, start + attempts - 1 do
    do
      local claimed = handle:claim(rev, token)
      if claimed then
        local md_path, mderr = M.canonical_document({
          kb_root = kb, reviewer_slug = review.reviewer_slug, slug = slug,
          topic = opts.topic, date = opts.date, revision = rev,
        })
        if not md_path then
          M.retire(slug, sha, rev, token); return nil, mderr
        end

        -- A generator is caller code and may raise; unprotected, that
        -- propagated out of the writer and stranded a live lease.
        local body = content
        if type(content) == "function" then
          local okc, produced = pcall(content, rev)
          if not okc then
            M.retire(slug, sha, rev, token)
            return nil, "the document generator failed: " .. tostring(produced)
          end
          body = produced
        end
        if type(body) ~= "string" or body == "" then
          M.retire(slug, sha, rev, token)
          return nil, "the document generator produced no body"
        end

        review.revision = rev
        review.document = md_path

        local okp, pproblems = M.check_document_path(md_path, {
          kb_root = kb, reviewer_slug = review.reviewer_slug,
          slug = slug, revision = rev,
        })
        if not okp then
          M.retire(slug, sha, rev, token)
          return nil, "document path refused: " .. table.concat(pproblems, "; ")
        end
        local okv, vproblems = M.validate(review, { for_write = true })
        if not okv then
          M.retire(slug, sha, rev, token)
          return nil, "invalid review: " .. table.concat(vproblems, "; ")
        end
        -- Pretty, stable-ordered JSON: the reviewer opens this file, and a
        -- store diffs cleanly across rewrites (Johno, 2026-09-03).
        local ok_enc, encoded = pcall(store.encode_pretty, review)
        if not ok_enc then
          M.retire(slug, sha, rev, token)
          return nil, "encode failed: " .. tostring(encoded)
        end

        if not _owns(slug, sha, rev, token) then goto continue end

        if not store.ensure_dir(vim.fn.fnamemodify(md_path, ":h")) then
          M.retire(slug, sha, rev, token)
          return nil, "could not create " .. vim.fn.fnamemodify(md_path, ":h")
        end
        local md_ok, md_err = store.create_exclusive(md_path, body)
        if md_err then
          M.retire(slug, sha, rev, token); return nil, md_err
        end
        if not md_ok then
          M.retire(slug, sha, rev, token); goto continue
        end

        if not _owns(slug, sha, rev, token) then goto continue end

        -- ***THE COMMIT POINT***
        local json_path = store.reviews_dir(slug) .. "/" .. M.filename(slug, sha, rev)
        local j_ok, j_err = store.create_exclusive(json_path, encoded)
        if not j_ok then
          local _, terr = M.retire(slug, sha, rev, token)
          return nil, ("the review JSON could not be written (%s). Your Markdown review "
            .. "is kept at %s — it is not lost.%s"):format(
              tostring(j_err or "revision taken"), md_path,
              terr and (" (revision not tombstoned: " .. terr
                .. "; reservation retained as the fence)") or "")
        end

        -- Our own reservation, released now that the pair is committed. Through
        -- auto-core, which reports a failure instead of swallowing it -- though
        -- a leftover reservation here is benign: it only keeps a spent number
        -- spent, which is already true.
        handle:release(rev, token)
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

---SEVERITY_RANK orders `M.SEVERITIES` so a review can be summarised by its
---WORST finding — the one thing a reader triages a list of reviews on.
M.SEVERITY_RANK = { ["must-fix"] = 4, ["should-fix"] = 3, ["nit"] = 2, ["question"] = 1 }

---worst_severity returns the highest-ranked severity in a tally, or nil for a
---review that carries no comments at all (a summary-only approval).
---@param severities table<string, integer>
---@return string?
function M.worst_severity(severities)
  local worst, rank = nil, 0
  for sev, n in pairs(severities or {}) do
    local r = M.SEVERITY_RANK[tostring(sev)] or 0
    if (n or 0) > 0 and r > rank then worst, rank = tostring(sev), r end
  end
  return worst
end

---list_all returns every review recorded for a repo, whatever commit it names.
---
---`list_for` answers "what reviews does THIS commit have", which is the wrong
---question after a rebase: the sha the file is named for no longer exists, so
---the review disappears from every listing at exactly the moment someone needs
---to find it and re-point it. This one is keyed on the REPO alone, so nothing
---in the store can hide.
---
---Most recently written first. The order comes from the filesystem, not from
---the documents: `created` lives inside each file and reading all of them to
---sort would defeat a listing meant to be cheap. `describe` is where the
---document is opened.
---@param slug string
---@return { slug: string, short: string, revision: integer, path: string, name: string, mtime: integer }[]
function M.list_all(slug)
  local dir = store.reviews_dir(slug)
  local out = {}
  for _, name in ipairs(store.list_files(dir, "%.review%.json$")) do
    local fslug, short, rev = M.parse_filename(name)
    if fslug and short and rev then
      local path = dir .. "/" .. name
      out[#out + 1] = { slug = fslug, short = short, revision = rev,
                        path = path, name = name, mtime = store.mtime(path) or 0 }
    end
  end
  table.sort(out, function(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    -- A tie is two files written in the same nanosecond, or two with no stat at
    -- all; commit then revision keeps the order STABLE rather than arbitrary.
    if a.short ~= b.short then return a.short < b.short end
    return a.revision > b.revision
  end)
  return out
end

---describe projects one review FILE into the metadata a panel lists and an
---info view prints: which commit it belongs to, when it was written, how bad
---its worst finding is, and which files it touches.
---
---TOLERANT, unlike `load`. A file that will not parse, or that fails
---validation, still yields a record with `err` set and whatever fields could be
---read. A malformed review the reader can SEE is one they can be told about and
---can delete; one that vanishes from the listing is one they cannot fix at all.
---`load` stays strict, because a caller that is about to RENDER comments must
---not be handed a half-parsed document.
---
---`revision` and `short` come from the FILENAME — the store's identity for the
---file — while `commit`, `created` and the rest come from the document. They
---can disagree (a hand-copied file, a rename); `revision_mismatch` says so
---rather than quietly preferring one.
---@param path string
---@return table? meta, string? err
function M.describe(path)
  if type(path) ~= "string" or path == "" then return nil, "describe: path required" end
  local name = path:match("[^/]+$") or path
  local slug, short, rev = M.parse_filename(name)
  local meta = {
    path = path, name = name, slug = slug, short = short, revision = rev,
    comments = 0, resolved = 0, severities = {}, files = {}, file_list = {},
  }

  local data, rerr = store.read_json(path)
  if rerr or not data then
    meta.err = rerr or "unreadable"
    return meta, meta.err
  end

  meta.commit   = type(data.commit) == "string" and data.commit or nil
  meta.base     = type(data.base) == "string" and data.base or nil
  meta.reviewer = type(data.reviewer) == "string" and data.reviewer or nil
  meta.created  = type(data.created) == "string" and data.created or nil
  meta.verdict  = type(data.verdict) == "string" and data.verdict or nil
  meta.summary  = type(data.summary) == "string" and data.summary or nil
  meta.document = type(data.document) == "string" and data.document or nil
  -- `reviewer_slug` and `repo` are part of the record, and a projection that
  -- drops them cannot be used to VALIDATE anything: `validate_pair` rejects a
  -- described record for exactly this reason (lector, worktree#6 r0), and the
  -- pair-deletion check of ADR-0081 §2.3a needs the reviewer slug to rebuild the
  -- canonical document path. Projecting them keeps the described record usable
  -- for validation instead of only for display.
  meta.reviewer_slug = type(data.reviewer_slug) == "string" and data.reviewer_slug or nil
  meta.repo = type(data.repo) == "table" and data.repo or nil
  if type(data.revision) == "number" and rev and data.revision ~= rev then
    meta.revision_mismatch = data.revision
  end

  local comments = type(data.comments) == "table" and data.comments or {}
  for _, c in ipairs(comments) do
    if type(c) == "table" then
      meta.comments = meta.comments + 1
      if c.resolved then meta.resolved = meta.resolved + 1 end
      local sev = tostring(c.severity or "comment")
      meta.severities[sev] = (meta.severities[sev] or 0) + 1
      local p = type(c.path) == "string" and c.path or nil
      if p then
        local f = meta.files[p]
        if not f then
          f = { count = 0, severities = {} }
          meta.files[p] = f
          meta.file_list[#meta.file_list + 1] = p
        end
        f.count = f.count + 1
        f.severities[sev] = (f.severities[sev] or 0) + 1
        f.worst = M.worst_severity(f.severities)
      end
    end
  end
  table.sort(meta.file_list)
  meta.worst = M.worst_severity(meta.severities)

  -- Validation runs LAST and only annotates: everything above is already read,
  -- and a listing that drops malformed files is the failure this guards against.
  local vok, problems = M.validate(data)
  if not vok then meta.err = "invalid: " .. table.concat(problems, "; ") end
  return meta, nil
end

---_abs resolves a path for COMPARISON — absolute, symlinks followed. A path
---that does not exist resolves to itself, which is what lets a CLAIMED file be
---compared before anything has been created or deleted.
local function _abs(p)
  return vim.fn.resolve(vim.fn.fnamemodify(tostring(p or ""), ":p"))
end

---remove deletes a review's canonical JSON and FENCES its revision number.
---
---The delete ALONE would be wrong. `max_recorded_revision` — the allocator
---`save_next` claims from — counts canonical, reserved and tombstoned records
---alike, precisely so a number is never handed out twice. A plain unlink of the
---highest revision puts that number back in circulation, and the next review
---written for the commit becomes a SECOND r<N>: every reference to "r2" then
---names two different documents, and the pair invariant of ADR-0067 has no way
---to tell them apart. So the revision is tombstoned as well as deleted.
---
---The tombstone is written FIRST. If it fails — a read-only reviews directory
---rejects it for the same reason it would reject a write — nothing has been
---deleted yet and the caller can be told; unlink-first would lose the file and
---free the number in the same step, which is the one outcome with no recovery.
---A tombstone that lands while the unlink then fails is benign: the file is
---still listed and still removable, and the number was already spoken for.
---
---The paired canonical Markdown (ADR-0067) is deliberately NOT touched. It is
---the PRIMARY and this JSON is its projection; it lives in the knowledge base
---rather than in this store, and a projection can be written again from it
---while durable prose cannot. Its path is returned so a caller can say what
---remains.
---@param slug string
---@param sha string       full or short — only the first 7 characters are used
---@param revision integer
---@return boolean ok, string? err, table? detail
function M.remove(slug, sha, revision)
  if type(slug) ~= "string" or slug == "" then return false, "remove: slug required" end
  if type(sha) ~= "string" or sha == "" then return false, "remove: sha required" end
  local rev = tonumber(revision)
  if not rev then return false, "remove: revision required" end

  local ds = require("auto-core.docstore")
  local path = store.reviews_dir(slug) .. "/" .. M.filename(slug, sha, rev)
  if not ds.exists(path) then return false, "no such review: " .. path end

  -- Read the pair reference BEFORE the delete; afterwards there is nothing
  -- left to read it from.
  local meta = M.describe(path)
  local detail = {
    path = path,
    document = meta and meta.document or nil,
    tombstone = M.tombstone_path(slug, sha, rev),
  }

  local tombstoned, terr = M.retire(slug, sha, rev, nil)
  if not tombstoned then
    return false, "the revision could not be fenced, so nothing was deleted: "
      .. tostring(terr or "unknown"), detail
  end
  detail.tombstoned = true

  -- auto-core's delete distinguishes ENOENT from every other failure, so a
  -- file that is merely unreadable is no longer reported as already gone --
  -- which matters most here, where the answer becomes "the pair is deleted".
  local ok, uerr = ds.delete(path)
  if not ok then
    return false, "the revision is fenced but the file could not be deleted: "
      .. tostring(uerr or "unknown"), detail
  end

  -- The PAIR is deleted, not just the projection (Johno, 2026-09-03: the two
  -- files ARE one review). ADR-0081 §2.3a governs the ordering and the honesty
  -- of a partial result.
  --
  -- The document path is VALIDATED before it is touched. `describe()` is
  -- deliberately tolerant, so it will surface the `document` field of a
  -- malformed or TAMPERED JSON — and the first cut of this code handed that
  -- value straight to `fs_unlink`, which made a review file whose `document`
  -- pointed anywhere on disk into an arbitrary file deletion (lector, ADR-0081
  -- MF1). A tolerantly-parsed field must never reach an unlink. So the claimed
  -- document must be exactly the canonical paired document for THIS review:
  -- same reviewer slug, same repo component, same revision, contained under the
  -- resolved KB root. Anything else is refused and reported as an orphan — the
  -- projection is still removed and the revision still fenced, because those
  -- are already done and correct.
  local doc = meta and meta.document
  if type(doc) ~= "string" or doc == "" then
    detail.document_absent = true
    detail.document_removed = false
  else
    -- Validate with the DOMAIN validator that already exists, rather than
    -- rebuilding the filename grammar here. `check_document_path` is written for
    -- exactly this: normalised containment under `$KB_ROOT/agents/<reviewer>/
    -- reviews/`, the `<date>-<repo>-<topic>-r<N>-review.md` shape, agreement of
    -- the repo component, and agreement of the revision — which is MF1's
    -- requirement verbatim.
    --
    -- My first cut re-derived the date and topic from the filename and compared
    -- against `canonical_document`. It rejected every VALID pair, because the
    -- greedy topic capture swallowed the repo component too. Re-implementing a
    -- grammar that already has a validator is how that happens.
    local dok, dproblems = M.check_document_path(doc, {
      kb_root = _kb_root(), reviewer_slug = meta.reviewer_slug,
      slug = slug, revision = rev,
    })
    local cerr = (not dok) and table.concat(dproblems or {}, "; ") or nil
    if dok then
      if ds.exists(doc) then
        local dok, derr = ds.delete(doc)
        detail.document_removed = dok and true or false
        if not dok then
          -- HALF a pair is not success. The JSON is gone and the revision is
          -- fenced, but the promised artifacts are not all removed, so the
          -- caller is told so explicitly (§2.3a step 4).
          detail.json_removed, detail.fenced = true, true
          detail.document_error = tostring(derr or "unknown")
          return false, ("the review JSON was removed and the revision fenced, but "
            .. "its Markdown could not be deleted (%s). It remains at %s")
            :format(tostring(derr or "unknown"), doc), detail
        end
      else
        detail.document_removed = false
        detail.document_absent = true
      end
    else
      -- Not this review's canonical document: refuse to touch it, and say so.
      detail.document_removed = false
      detail.document_refused = doc
      detail.document_refusal = cerr
        or "the recorded document is not this review's canonical paired path"
      detail.json_removed, detail.fenced = true, true
      return false, ("the review JSON was removed and the revision fenced, but the "
        .. "recorded document was NOT deleted: %s (%s)")
        :format(doc, detail.document_refusal), detail
    end
  end
  detail.json_removed, detail.fenced = true, true
  return true, nil, detail
end

---remove_path is `remove` addressed by FILE, which is how a panel row knows a
---review: it holds a path, and for a malformed document the commit sha inside
---is exactly what cannot be trusted. The filename is the store's identity, so
---it is what the delete is keyed on — and a file that will not parse is one of
---the main things a user wants this for.
---@param path string
---@return boolean ok, string? err, table? detail
function M.remove_path(path)
  if type(path) ~= "string" or path == "" then return false, "remove_path: path required" end
  local name = path:match("[^/]+$") or path
  local slug, short, rev = M.parse_filename(name)
  if not (slug and short and rev) then
    return false, "not a review filename: " .. name
  end
  -- The reconstructed target must BE the file that was handed in.
  --
  -- `M.remove` rebuilds its target from the slug, and the slug comes from the
  -- BASENAME — so a file sitting in one repo's directory while NAMED for
  -- another resolves to the other repo's review, and the path a caller
  -- authorized is not the path that gets deleted. `repos.remove_review` proved
  -- a path contained in repo A and then tombstoned and unlinked repo B's real
  -- r1, with the claimed repo-A file absent (lector, worktree#4 must-fix,
  -- 2026-09-02). Authorization and effect have to be computed from the SAME
  -- source; this check makes the function's own contract true for EVERY
  -- caller, not only the one that happened to be audited.
  local canonical = store.reviews_dir(slug) .. "/" .. M.filename(slug, short, rev)
  if _abs(canonical) ~= _abs(path) then
    return false, ("refusing: %s is not the canonical location of %s (that is %s)")
      :format(path, name, canonical)
  end
  return M.remove(slug, short, rev)
end

---described_for is `list_for` with every file described — the shape a tree needs
---to render a commit's review rows AND to badge its changed files, from ONE
---read pass over the documents.
---@param slug string
---@param sha string
---@return table[] reviews   `describe` records, newest revision first
function M.described_for(slug, sha)
  local out = {}
  for _, rec in ipairs(M.list_for(slug, sha)) do
    out[#out + 1] = M.describe(rec.path) or rec
  end
  return out
end

---tally_paths merges described reviews into a per-file tally. PURE — it opens
---nothing, so a caller that already holds the descriptions pays no second read.
---
---Merged across every revision, because a file commented on in r1 still carries
---feedback when r3 is the latest. A file whose review will not parse still
---counts what could be read: the badge says "there is feedback here", and that
---is true of a malformed file too.
---@param described table[]
---@return table<string, { count: integer, worst: string? }>
function M.tally_paths(described)
  local out = {}
  for _, meta in ipairs(described or {}) do
    for path, f in pairs((meta or {}).files or {}) do
      local acc = out[path]
      if not acc then
        acc = { count = 0, severities = {} }
        out[path] = acc
      end
      acc.count = acc.count + (f.count or 0)
      for sev, n in pairs(f.severities or {}) do
        acc.severities[sev] = (acc.severities[sev] or 0) + n
      end
      acc.worst = M.worst_severity(acc.severities)
    end
  end
  return out
end

---reviewed_paths tallies which of a COMMIT's files carry review comments —
---what a tree badges its changed files with. The composition of the two above,
---for a caller that wants only the tally.
---@param slug string
---@param sha string
---@return table<string, { count: integer, worst: string? }>
function M.reviewed_paths(slug, sha)
  return M.tally_paths(M.described_for(slug, sha))
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

-- ─────────────────────────────────────────────────────────────────────────
-- PROVIDER PROJECTIONS — the transport-agnostic half of "post a review"
-- (diffview follow-up item 4).
--
-- These are PURE SHAPE TRANSFORMS. They take a validated review document and
-- return the exact JSON body a forge's review API expects. They do NOT touch
-- the network, read a token, or POST anything — and NOTHING in the UI is wired
-- to them yet (no command, no keymap). That is deliberate: the actual transport
-- (POST to GitHub via `gh`; POST to Forgejo via `tea` or curl+token+cert) is
-- SPLIT OUT and deferred until the auth/cert story is decided. See the KB todo
-- `2026-08-26-post-review-json-to-github-forgejo-transport` before wiring any
-- caller that sends over the wire. Keeping the projections here now means the
-- transport, when it lands, is a thin shell over already-tested shape code.
-- ─────────────────────────────────────────────────────────────────────────

---FORGEJO_EVENTS maps a review verdict onto a Forgejo/Gitea review event.
---
---Note the vocabulary is NOT GitHub's: Forgejo says `APPROVED`, GitHub says
---`APPROVE`. Emitting GitHub's word here is silently rejected by Forgejo, which
---is exactly why this is a separate map rather than a reuse of `VERDICTS`.
M.FORGEJO_EVENTS = {
  approved = "APPROVED",
  change_requested = "REQUEST_CHANGES",
  comment = "COMMENT",
}

---forgejo_payload projects a review onto Forgejo/Gitea's review API shape:
---`POST /api/v1/repos/{owner}/{repo}/pulls/{index}/reviews`, whose body is
---`{ event, body, commit_id, comments:[{path, new_position|old_position, body}] }`.
---
---Three things differ from `github_payload`, and each is a place a naive reuse
---would break:
---  * the event vocabulary (see FORGEJO_EVENTS);
---  * anchoring is by POSITION per side — `new_position` for the RIGHT/after
---    side, `old_position` for the LEFT/before side — NOT GitHub's `line`+`side`;
---  * there is NO native multi-line range field, so a ranged finding's scope is
---    folded into the body text rather than silently dropped.
---`severity` and `resolved` are ours, handled as in `github_payload`: severity
---folded into the body, resolved comments excluded from the upload.
---@param review WorktreeReview
---@return { event: string, body: string, commit_id: string?, comments: table[] }
function M.forgejo_payload(review)
  review = review or {}
  local comments = {}
  for _, c in ipairs(review.comments or {}) do
    if not c.resolved then
      local body = c.body or ""
      if c.severity then body = "**" .. c.severity .. "** — " .. body end
      -- No native range field: preserve the reviewer's scope in the text so it
      -- is not lost, the same defensive choice the diff-view painter makes.
      if c.start_line and c.start_line ~= c.line then
        body = body .. ("\n\n_(range L%d-%d)_"):format(
          math.min(c.start_line, c.line), math.max(c.start_line, c.line))
      end
      local entry = { path = c.path, body = body }
      -- LEFT (the a/ side) anchors by old_position; RIGHT (b/, the default) by
      -- new_position. A comment with no side defaults to RIGHT, as GitHub does.
      if (c.side or "RIGHT") == "LEFT" then
        entry.old_position = c.line
      else
        entry.new_position = c.line
      end
      comments[#comments + 1] = entry
    end
  end
  return {
    event = M.FORGEJO_EVENTS[review.verdict or "comment"] or "COMMENT",
    body = review.summary or "",
    -- Forgejo accepts a commit_id to anchor the review to a specific commit;
    -- the review already carries it, so pass it rather than letting the server
    -- default to the PR head.
    commit_id = review.commit,
    comments = comments,
  }
end

---provider_for derives the forge from a git remote URL — never hard-coded,
---because Forgejo is open-source and self-hosted on arbitrary hosts.
---
---`github.com` -> the GitHub REST API; ANY OTHER host is treated as a
---Forgejo/Gitea instance at `https://<host>/api/v1`. The SSH port (e.g. the
---`:2222` on git.johnosoft.org) is DROPPED: it addresses the git transport, not
---the HTTPS API, which is on 443. Accepts both scp-form (`git@host:owner/repo`)
---and URL-form (`scheme://[user@]host[:port]/owner/repo`) remotes.
---@param remote_url string
---@return { provider: string, host: string, owner: string, repo: string, api_base: string }?, string?
function M.provider_for(remote_url)
  remote_url = tostring(remote_url or "")
  local host, path
  -- scp-form: git@host:owner/repo(.git)
  host, path = remote_url:match("^[%w._-]+@([^:/]+):(.+)$")
  if not host then
    -- URL-form: scheme://[user@]host[:port]/owner/repo(.git). Grab the authority
    -- as one span, then strip an optional `user@` and a trailing `:port`. Doing
    -- it in one regex is fragile: a host character class wide enough to reject
    -- `:` and `/` still admits `@`, so `git@host` leaks into the host (the exact
    -- bug this replaced). The SSH port must go — it addresses the git transport,
    -- while the API is on HTTPS 443.
    local authority
    authority, path = remote_url:match("^%w+://([^/]+)/(.+)$")
    if authority then
      authority = authority:gsub("^[^@]*@", "")   -- drop userinfo
      host = authority:gsub(":%d+$", "")          -- drop the port
    end
  end
  if not host or not path or path == "" then
    return nil, "unrecognized remote URL: " .. remote_url
  end
  path = path:gsub("%.git$", "")
  local owner, repo = path:match("([^/]+)/([^/]+)$")
  if not owner or not repo then
    return nil, "no owner/repo in remote URL: " .. remote_url
  end
  local provider, api_base
  if host == "github.com" or host == "www.github.com" then
    provider, api_base = "github", "https://api.github.com"
  else
    provider, api_base = "forgejo", "https://" .. host .. "/api/v1"
  end
  return { provider = provider, host = host, owner = owner, repo = repo, api_base = api_base }
end

---payload_for is a one-call-site dispatcher onto the right projection, so a
---caller that has already resolved the provider does not branch on it. Defaults
---to GitHub for an unknown provider — the historical default, and the one whose
---transport (`gh`) is already available.
---@param review WorktreeReview
---@param provider string  "github" | "forgejo" | "gitea"
---@return table
function M.payload_for(review, provider)
  if provider == "forgejo" or provider == "gitea" then
    return M.forgejo_payload(review)
  end
  return M.github_payload(review)
end


return M
