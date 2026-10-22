#!/usr/bin/env bash
# Tests for the repository scripts. No network access needed: every case runs
# in a throwaway git repository with a copy of scripts/.
#
# Usage: tests/run.sh
#
# Leak fixtures below are split with "" so that this file itself passes the
# repository leak check; the shell joins them back at run time.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
ok() {
  printf 'ok   %s\n' "$1"
  passed=$((passed + 1))
}
not_ok() {
  printf 'FAIL %s\n' "$1"
  failed=$((failed + 1))
}

# expect <0|1> <description> <command...>: exit status must match (0 = success).
expect() {
  local want="$1" desc="$2"
  shift 2
  local got=0
  "$@" >"$tmp/out" 2>&1 || got=1
  if [ "$got" = "$want" ]; then
    ok "$desc"
  else
    not_ok "$desc"
    sed 's/^/     | /' "$tmp/out"
  fi
}

git_q() { git -c init.defaultBranch=main -c user.name=t -c user.email=t@example.invalid "$@"; }

# New repository with a copy of scripts/ and one clean commit.
new_repo() {
  local dir="$tmp/$1"
  mkdir -p "$dir"
  cp -R "$repo_root/scripts" "$dir/"
  printf 'docs use 192.0.2.10, 198.51.100.7 and the range 10.0.0.0/8\n' >"$dir/clean.txt"
  git_q -C "$dir" init -q
  git_q -C "$dir" add -A
  git_q -C "$dir" commit -qm "init"
  printf '%s\n' "$dir"
}

leak_check() {
  local dir="$1"
  shift
  (cd "$dir" && env LEAK_CHECK_SKIP_GITLEAKS=1 "$@" scripts/leak-check.sh)
}

# --- leak-check.sh ---------------------------------------------------------

d="$(new_repo clean)"
expect 0 "leak-check: clean repository passes" leak_check "$d"

for case in "private-ip|ssh admin@192.""168.1.5" "cgnat-ip|peer 100.""100.1.2" \
  "mac|link aa:bb:cc:dd:ee"":ff" "host|ssh run""ner3"; do
  name="${case%%|*}" text="${case#*|}"
  d="$(new_repo "$name")"
  printf '%s\n' "$text" >"$d/leak.txt"
  expect 1 "leak-check: $name in an untracked file fails" leak_check "$d"
done

d="$(new_repo deny)"
printf 'hello SecretWord\n' >"$d/leak.txt"
expect 1 "leak-check: denylisted word fails" leak_check "$d" LEAK_DENYLIST=$'# comment\n\nsecretword'
if grep -qi secretword "$tmp/out"; then
  not_ok "leak-check: denylisted word is not printed"
else
  ok "leak-check: denylisted word is not printed"
fi

d="$(new_repo ai-commit)"
git_q -C "$d" commit -q --allow-empty -m $'change\n\nCo-Authored'$'-By: Some Bot <noreply@anthropic.com>'
expect 1 "leak-check: AI attribution in a commit message fails" leak_check "$d"

d="$(new_repo identity)"
git -C "$d" -c user.name=x -c user.email=secretword@example.invalid commit -q --allow-empty -m "change"
expect 1 "leak-check: denylisted word in author e-mail fails" leak_check "$d" LEAK_DENYLIST=secretword

d="$(new_repo range)"
git_q -C "$d" commit -q --allow-empty -m "ok"
git_q -C "$d" checkout -q -b side
git_q -C "$d" commit -q --allow-empty -m "temporary merge ssh run""ner3"
expect 0 "leak-check: commits outside LEAK_CHECK_LOG_RANGE are ignored" \
  leak_check "$d" LEAK_CHECK_LOG_RANGE=main
expect 1 "leak-check: commits inside LEAK_CHECK_LOG_RANGE are checked" \
  leak_check "$d" LEAK_CHECK_LOG_RANGE=side

d="$(new_repo pr-text)"
expect 1 "leak-check: AI attribution in PR description fails" \
  leak_check "$d" PR_BODY="Generated with ""Claude Code"
expect 1 "leak-check: private address in PR title fails" \
  leak_check "$d" PR_TITLE="fix 10.""1.2.3"
expect 0 "leak-check: clean PR text passes" \
  leak_check "$d" PR_TITLE="Fix build" PR_BODY="Uses 192.0.2.1 in docs"

# --- fetch-source.sh -------------------------------------------------------

# Upstream with an annotated tag v1 and a lightweight tag v2.
up="$tmp/upstream"
git_q init -q "$up"
git_q -C "$up" commit -q --allow-empty -m one
git_q -C "$up" tag -a v1 -m v1
git_q -C "$up" commit -q --allow-empty -m two
git_q -C "$up" tag v2
c1="$(git -C "$up" rev-parse 'v1^{commit}')"
c2="$(git -C "$up" rev-parse v2)"

fs="$tmp/fs"
mkdir -p "$fs"
cp -R "$repo_root/scripts" "$fs/"
cat >"$fs/sources.lock" <<EOF
good-annotated  repo=file://$up  tag=v1  commit=$c1
good-light      repo=file://$up  tag=v2  commit=$c2
moved           repo=file://$up  tag=v1  commit=$c2
no-commit       repo=file://$up  tag=v1
EOF

expect 0 "fetch-source: annotated tag at pinned commit is cloned" \
  "$fs/scripts/fetch-source.sh" good-annotated "$tmp/c1"
expect 0 "fetch-source: lightweight tag at pinned commit is cloned" \
  "$fs/scripts/fetch-source.sh" good-light "$tmp/c2"
expect 1 "fetch-source: tag at another commit fails" \
  "$fs/scripts/fetch-source.sh" moved "$tmp/c3"
expect 0 "fetch-source --verify-only: annotated tag passes" \
  "$fs/scripts/fetch-source.sh" good-annotated --verify-only
expect 0 "fetch-source --verify-only: lightweight tag passes" \
  "$fs/scripts/fetch-source.sh" good-light --verify-only
expect 1 "fetch-source --verify-only: tag at another commit fails" \
  "$fs/scripts/fetch-source.sh" moved --verify-only
expect 1 "fetch-source: missing commit= fails" \
  "$fs/scripts/fetch-source.sh" no-commit --verify-only
expect 1 "fetch-source: unknown component fails" \
  "$fs/scripts/fetch-source.sh" nope --verify-only

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
