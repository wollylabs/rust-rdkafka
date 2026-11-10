#!/usr/bin/env bash
# rebase-onto-upstream — replay this fork's own commits onto an upstream rust-rdkafka line and
# say whether they still apply.
#
#   ci/rebase-onto-upstream.sh <target> [fork-ref]
#
# <target> is `master` (upstream's master), `release` (upstream's latest release tag,
# vMAJOR.MINOR.PATCH) or any upstream ref or tag name. [fork-ref] is the fork line whose
# commits are replayed, HEAD by default.
#
# THE FORK'S COMMITS ARE COMPUTED, NEVER LISTED: every non-merge commit reachable from
# [fork-ref] and from no upstream branch or tag. A commit upstream has taken is dropped by that
# rule, and one the fork adds is carried by it, so the script never goes stale.
#
# THE WORK IS DONE IN A THROWAWAY WORKTREE, detached at the target, and the caller's checkout
# is never touched. Each commit is cherry-picked in order. The first commit that conflicts is
# reported with the files it conflicted on, and the replay stops there: every later commit is
# reported `not-tried`, since a conflict after a skipped commit says nothing about upstream. A
# commit whose change upstream already holds is reported `already-upstream` and dropped.
#
# IT PRINTS one line per commit, then `conflicts: none` or `conflicts: <commit>`, then the
# result's commit. Exit 0 when nothing conflicted, 1 when something did, 2 on a usage or fetch error.
# With RESULT_BRANCH set and nothing conflicted, the result is kept as that local branch; with
# GITHUB_STEP_SUMMARY set, the report is written there too.
#
# UPSTREAM_URL is the upstream repository, fede1024/rust-rdkafka by default.

set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/fede1024/rust-rdkafka.git}"

usage() {
  echo "usage: $0 <master|release|upstream-ref> [fork-ref]" >&2
  exit 2
}

if [ $# -lt 1 ] || [ $# -gt 2 ]; then usage; fi
target_name="$1"
fork_ref="${2:-HEAD}"

fork_sha="$(git rev-parse --verify "${fork_ref}^{commit}")" || {
  echo "rebase: ${fork_ref} is not a commit here" >&2
  exit 2
}

# Upstream lands under refs/upstream/ only, so it can never be mistaken for a fork branch.
echo "fetching ${UPSTREAM_URL}" >&2
git fetch --quiet --no-tags --force "$UPSTREAM_URL" \
  '+refs/heads/*:refs/upstream/heads/*' \
  '+refs/tags/*:refs/upstream/tags/*' || {
  echo "rebase: could not fetch ${UPSTREAM_URL}" >&2
  exit 2
}

case "$target_name" in
  master)
    target_ref=refs/upstream/heads/master
    ;;
  release)
    target_ref="$(git for-each-ref --format='%(refname)' 'refs/upstream/tags/v*' \
      | grep -E '^refs/upstream/tags/v[0-9]+\.[0-9]+\.[0-9]+$' \
      | sort -t/ -k4 -V | tail -n1)"
    [ -n "$target_ref" ] || {
      echo "rebase: upstream has no vMAJOR.MINOR.PATCH tag" >&2
      exit 2
    }
    ;;
  *)
    if git rev-parse --verify --quiet "refs/upstream/heads/${target_name}^{commit}" >/dev/null; then
      target_ref="refs/upstream/heads/${target_name}"
    elif git rev-parse --verify --quiet "refs/upstream/tags/${target_name}^{commit}" >/dev/null; then
      target_ref="refs/upstream/tags/${target_name}"
    else
      echo "rebase: upstream has no branch or tag ${target_name}" >&2
      exit 2
    fi
    ;;
esac
target_sha="$(git rev-parse "${target_ref}^{commit}")"

mapfile -t upstream_refs < <(git for-each-ref --format='%(refname)' refs/upstream/)
mapfile -t commits < <(git rev-list --reverse --no-merges "$fork_sha" --not "${upstream_refs[@]}")

work="$(mktemp -d "${TMPDIR:-/tmp}/rdkafka-rebase.XXXXXX")"
cleanup() {
  git worktree remove --force "$work" >/dev/null 2>&1 || rm -rf "$work"
  git worktree prune >/dev/null 2>&1 || true
}
trap cleanup EXIT
git worktree add --quiet --detach "$work" "$target_sha"

# The result is a throwaway: it is never signed, and it needs an identity on a bare runner.
pick() {
  git -C "$work" \
    -c commit.gpgsign=false \
    -c user.name="${GIT_COMMITTER_NAME:-rdkafka-rebase}" \
    -c user.email="${GIT_COMMITTER_EMAIL:-rdkafka-rebase@users.noreply.github.com}" \
    "$@"
}

report=()
say() {
  report+=("$1")
  echo "$1"
}

say "target: ${target_ref#refs/upstream/} ${target_sha}"
say "fork: ${fork_ref} ${fork_sha}, ${#commits[@]} commit(s) of its own"

conflict=""
for commit in "${commits[@]}"; do
  subject="$(git log -1 --format=%s "$commit")"
  short="$(git rev-parse --short "$commit")"
  if [ -n "$conflict" ]; then
    say "not-tried ${short} ${subject}"
  elif pick cherry-pick --keep-redundant-commits "$commit" >/dev/null 2>&1; then
    if git -C "$work" diff --quiet HEAD~1 HEAD; then
      git -C "$work" reset --quiet --hard HEAD~1
      say "already-upstream ${short} ${subject}"
    else
      say "applied ${short} ${subject}"
    fi
  else
    files="$(git -C "$work" diff --name-only --diff-filter=U | paste -sd, -)"
    pick cherry-pick --abort >/dev/null 2>&1 || git -C "$work" reset --quiet --hard HEAD
    conflict="$short"
    say "conflict ${short} ${subject} — ${files:-no file named}"
  fi
done

result_sha="$(git -C "$work" rev-parse HEAD)"
if [ -z "$conflict" ]; then
  say "conflicts: none"
  if [ -n "${RESULT_BRANCH:-}" ]; then
    git branch --force "$RESULT_BRANCH" "$result_sha"
    say "result: ${result_sha} (branch ${RESULT_BRANCH})"
  else
    say "result: ${result_sha}"
  fi
else
  say "conflicts: ${conflict}"
  say "result: ${result_sha} (partial — stopped before ${conflict})"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### rebase onto upstream ${target_name}"
    echo
    echo '```'
    printf '%s\n' "${report[@]}"
    echo '```'
  } >>"$GITHUB_STEP_SUMMARY"
fi

[ -z "$conflict" ]
