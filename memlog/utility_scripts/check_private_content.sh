#!/bin/zsh
# Blocks private JoesProxy-Pro content from entering this public repository.
#
# Rules (reported by path and rule name only; matched content is never printed):
#   pro_path        a path under Pro/, the private Pro subtree
#   private_marker  a file whose comment or heading starts with the private marker, the
#                   word in capitals followed by a colon (// # <!-- /* forms), or an HTML
#                   comment holding only that word
#
# It cannot recognise unmarked private writing, so business and Pro documents must be
# written in the private JoesProxy-Pro checkout in the first place (see AGENTS.md).
# Binary files are not content-checked. Read-only: no Git writes, no network.
#
# Usage:
#   memlog/utility_scripts/check_private_content.sh --staged      # index contents (pre-commit)
#   memlog/utility_scripts/check_private_content.sh <path>...     # working-tree files
#   memlog/utility_scripts/check_private_content.sh --self-test
set -uo pipefail

SCRIPT_PATH="${0:A}"

# Built from pieces so this script does not match its own rule.
MARKER="PRI""VATE"
MARKER_PATTERN="(^|[^A-Za-z])(//|#|<!--|/\\*)[[:space:]]*${MARKER}:|<!--[[:space:]]*${MARKER}[[:space:]]*-->"

usage() {
  sed -n '2,17p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'
  exit 64
}

# check_one <path> <content-source-command...>: prints findings, returns 1 if any.
check_one() {
  local file="$1"; shift
  local found=0
  if [[ "$file" == Pro/* ]]; then
    print -r -- "$file [pro_path]"
    found=1
  fi
  # grep -c reads all input. grep -q would exit at the first match, and under pipefail the
  # producer's SIGPIPE would then turn a match in a large file into a miss.
  local matches
  matches=$("$@" 2>/dev/null | grep -I -c -E -- "$MARKER_PATTERN")
  if [[ "${matches:-0}" -gt 0 ]]; then
    print -r -- "$file [private_marker]"
    found=1
  fi
  return $found
}

run_staged() {
  local findings=0 file
  while IFS= read -r -d '' file; do
    check_one "$file" git show ":$file" || findings=1
  done < <(git diff --cached --name-only -z --diff-filter=ACMR)
  return $findings
}

run_paths() {
  local findings=0 file
  for file in "$@"; do
    [[ -f "$file" ]] || continue
    check_one "$file" cat -- "$file" || findings=1
  done
  return $findings
}

report() {
  if [[ "$1" -ne 0 ]]; then
    print -u2 -- "Blocked: private JoesProxy-Pro content must not enter this public repository."
    print -u2 -- "Move it to the private JoesProxy-Pro checkout, or unstage it with: git restore --staged <path>"
    return 1
  fi
  return 0
}

self_test() {
  local scratch failures=0 out
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/private-content-selftest.XXXXXX") || return 2
  trap "rm -rf '$scratch'" EXIT
  git -C "$scratch" init -q || return 2
  mkdir -p "$scratch/Pro/Sources" "$scratch/docs" "$scratch/memlog"

  print -r -- "// ${MARKER}: newly authored Pro source" > "$scratch/docs/marked.swift"
  print -r -- "<!-- ${MARKER} -->"$'\n'"# Plan" > "$scratch/memlog/marked plan.md"
  print -r -- "# ${MARKER}: pricing notes" > "$scratch/memlog/heading.md"
  print -r -- "let ok = 1" > "$scratch/Pro/Sources/Unmarked.swift"
  print -r -- "Private vulnerability reporting is not enabled." > "$scratch/docs/clean.md"
  print -r -- "let label = \"${MARKER}KEY: value\"" > "$scratch/docs/near-miss.swift"
  # Marker on the first line of a file far larger than a pipe buffer.
  { print -r -- "<!-- ${MARKER} -->"; for _ in {1..20000}; do print -r -- "filler line for size"; done; } \
    > "$scratch/memlog/large.md"
  git -C "$scratch" add -A || return 2

  out=$(cd "$scratch" && run_staged)
  for expected in "docs/marked.swift [private_marker]" "memlog/marked plan.md [private_marker]" \
                  "memlog/heading.md [private_marker]" "memlog/large.md [private_marker]" \
                  "Pro/Sources/Unmarked.swift [pro_path]"; do
    if ! print -r -- "$out" | grep -q -F -x -- "$expected"; then
      print -u2 -- "FAIL: expected finding: $expected"; failures=1
    fi
  done
  for clean in "docs/clean.md" "docs/near-miss.swift"; do
    if print -r -- "$out" | grep -q -F -- "$clean"; then
      print -u2 -- "FAIL: false positive: $clean"; failures=1
    fi
  done
  if print -r -- "$out" | grep -q -F -- "pricing notes"; then
    print -u2 -- "FAIL: matched content was printed"; failures=1
  fi

  # A clean index passes.
  git -C "$scratch" rm -q --cached -r Pro docs/marked.swift "memlog/marked plan.md" memlog/heading.md memlog/large.md || return 2
  if ! (cd "$scratch" && run_staged >/dev/null); then
    print -u2 -- "FAIL: clean index was blocked"; failures=1
  fi

  # The real hook, wired through core.hooksPath, blocks a commit and allows a clean one.
  local repo_root hook_repo
  repo_root="${SCRIPT_PATH:h:h:h}"
  hook_repo="$scratch/hook-repo"
  git init -q "$hook_repo" || return 2
  mkdir -p "$hook_repo/.githooks" "$hook_repo/memlog/utility_scripts" "$hook_repo/docs"
  cp "$repo_root/.githooks/pre-commit" "$hook_repo/.githooks/pre-commit" || return 2
  cp "$SCRIPT_PATH" "$hook_repo/memlog/utility_scripts/check_private_content.sh" || return 2
  git -C "$hook_repo" config core.hooksPath .githooks
  local -a identity=(-c user.name=selftest -c user.email=selftest@example.invalid -c commit.gpgsign=false)
  print -r -- "// ${MARKER}: Pro only" > "$hook_repo/docs/marked.swift"
  git -C "$hook_repo" add docs/marked.swift
  if git -C "$hook_repo" "${identity[@]}" commit -q -m blocked >/dev/null 2>&1; then
    print -u2 -- "FAIL: pre-commit hook allowed a marked file"; failures=1
  fi
  git -C "$hook_repo" rm -q --cached docs/marked.swift
  print -r -- "public text" > "$hook_repo/docs/clean.md"
  git -C "$hook_repo" add docs/clean.md
  if ! git -C "$hook_repo" "${identity[@]}" commit -q -m clean >/dev/null 2>&1; then
    print -u2 -- "FAIL: pre-commit hook blocked a clean commit"; failures=1
  fi

  if [[ "$failures" -eq 0 ]]; then
    print -- "PASS: private content checker self-test"
  fi
  return $failures
}

[[ "$#" -gt 0 ]] || usage
case "$1" in
  --staged) run_staged; report $? ;;
  --self-test) self_test ;;
  -h|--help) usage ;;
  -*) print -u2 -- "Unsupported argument: $1"; usage ;;
  *) run_paths "$@"; report $? ;;
esac
