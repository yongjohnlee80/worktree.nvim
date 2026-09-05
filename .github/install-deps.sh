#!/usr/bin/env bash
# .github/install-deps.sh — materialise the dependencies this test tree
# resolves, in BOTH shapes it resolves them from.
#
# Enumerated from every file under tests/, not from smoke.lua's header:
# reading one file per repo and generalising is what hid a dependency during
# the auto-agents rollout. The suites look for auto-core in `$lazy/auto-core.nvim`
# AND in `<workspace>/auto-core.nvim/main`, and pick between candidates by FILE
# AND SYMBOL — so both shapes must exist, and they are ONE clone with a symlink
# so the two cannot resolve to different code. A suite binding to a copy that
# cannot serve the request is the defect #9 fixed.
#
# Refs come from the environment. An EMPTY ref means "whatever the default
# branch is now" — that is the drift job's whole purpose, so it is a supported
# value and not a mistake:
#   AUTO_CORE_REF  PLENARY_REF
#
# gitgraph.nvim is NOT a dependency: it appears once, in a comment explaining
# why the full open path is not driven headless.
set -euo pipefail

lazy="$HOME/.local/share/nvim/lazy"
mkdir -p "$lazy"

# The suites derive their sibling root as fnamemodify(plugin_root, ":h:h"),
# which on a runner is dirname(dirname($GITHUB_WORKSPACE)) — the checkout lives
# at /home/runner/work/<repo>/<repo>.
siblings="$(dirname "$(dirname "$GITHUB_WORKSPACE")")"

clone_at() {
  local url="$1" dest="$2" ref="$3"
  git clone --filter=blob:none "$url" "$dest"
  if [ -n "$ref" ]; then
    git -C "$dest" checkout "$ref"
  fi
  printf '  %s -> %s\n' "$dest" "$(git -C "$dest" log --oneline -1)"
}

echo "dependencies:"
clone_at https://github.com/yongjohnlee80/auto-core.nvim \
         "$siblings/auto-core.nvim/main" "${AUTO_CORE_REF:-}"
ln -s "$siblings/auto-core.nvim/main" "$lazy/auto-core.nvim"
clone_at https://github.com/nvim-lua/plenary.nvim \
         "$lazy/plenary.nvim" "${PLENARY_REF:-}"

# Assert the candidate can SERVE, not merely exist — the same predicate
# smoke.lua applies. Failing here names the missing symbol; failing there costs
# a suite that aborts mid-run before its summary line.
for req in "lua/auto-core/git/log.lua:function M.unpushed" \
           "lua/auto-core/docstore/init.lua:function M.write_json"; do
  f="${req%%:*}"; sym="${req#*:}"
  if ! grep -qF "$sym" "$siblings/auto-core.nvim/main/$f" 2>/dev/null; then
    echo "FATAL: auto-core at this ref cannot serve: $f lacks '$sym'" >&2
    exit 1
  fi
done
echo "  auto-core serves: unpushed + docstore.write_json"
