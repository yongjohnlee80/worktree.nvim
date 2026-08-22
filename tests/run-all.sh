#!/usr/bin/env bash
# tests/run-all.sh — run every worktree.nvim test suite and turn a silent
# abort into a loud failure. Enforces the family runner contract (see the
# shared convention `lua-nvim-plugin-development.md` § "The runner contract").
#
#   tests/run-all.sh                        # every suite in tests/
#   tests/run-all.sh smoke                  # one suite (basename, no .lua)
#
# Why: tests/adr0060-review-json-e2e.lua was an orphan — present, green,
# and run by nothing (only tests/smoke.lua was ever invoked by hand), so a
# regression in it would go unnoticed. This runner is the single entry
# point; it fails the run when ANY suite prints no summary (a silent
# mid-run abort), reports failures, or exits non-zero with no counted
# failures.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

overall=0
only="${1:-}"

run_suite() {
  local name="$1" file="$2"
  local out rc summary fail_n
  echo "── $name ──────────────────────────────────"
  out="$(nvim --headless -u NONE -l "$file" 2>&1)"
  rc=$?
  # Match both summary formats used across the family; the failed count is
  # the last integer on the line.
  summary="$(printf '%s\n' "$out" \
    | grep -oE "([0-9]+ passed, [0-9]+ failed|Passed: [0-9]+, Failed: [0-9]+)" \
    | tail -1 || true)"
  printf '%s\n' "$out" | grep -E "^  FAIL" | head -10

  if [ -z "$summary" ]; then
    echo "   ✗ $name: NO SUMMARY LINE — aborted mid-run (silent partial run)"
    echo "     ── tail of output ──"
    printf '%s\n' "$out" | tail -15 | sed 's/^/     /'
    overall=1
    return
  fi
  echo "   $name: $summary (exit=$rc)"

  fail_n="$(printf '%s' "$summary" | grep -oE "[0-9]+" | tail -1)"
  if [ "${fail_n:-0}" -gt 0 ]; then
    echo "   ✗ $name: $fail_n failed"
    overall=1
    return
  fi
  if [ "$rc" -ne 0 ]; then
    echo "   ✗ $name: exit=$rc despite '$summary' — crashed after the summary"
    overall=1
    return
  fi
  echo "   ✓ $name OK"
}

for f in tests/*.lua; do
  name="$(basename "$f" .lua)"
  if [ -n "$only" ] && [ "$name" != "$only" ]; then continue; fi
  run_suite "$name" "$f"
done

echo "────────────────────────────────────────────"
if [ "$overall" -eq 0 ]; then
  echo "run-all: OK"
else
  echo "run-all: FAILED"
fi
exit "$overall"
