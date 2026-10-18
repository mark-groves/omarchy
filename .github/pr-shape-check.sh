#!/bin/bash
set -euo pipefail

# A pull request into this fork is a sync onto quattro, a topic onto quattro,
# or a layer of a stack whose trunk is quattro. Every topic and layer is held
# to the file cap against its own base and may not carry upstream commits;
# those arrive only through a sync.

FILE_CAP=40

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

: "${PR_HEAD_REF:?PR_HEAD_REF is required}"
: "${PR_BASE_REF:?PR_BASE_REF is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"

is_sync_ref() {
  local ref=$1
  [[ $ref == cursor/upstream-changes-pr-* || $ref == cursor/fork-upstream-updates-* || $ref == "i18n-sync" ]]
}

ensure_commit() {
  local sha=$1
  local ref=$2
  if ! git cat-file -e "${sha}^{commit}" 2>/dev/null; then
    git fetch --no-tags origin "$ref" ||
      fail "Could not fetch ${ref}. The shape check needs it to compare this pull request."
  fi
}

if [[ -n ${PR_OPEN_JSON_FILE:-} ]]; then
  open_json=$(cat "$PR_OPEN_JSON_FILE")
else
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  open_json=$(gh pr list --repo "$GITHUB_REPOSITORY" --state open --limit 200 --json number,headRefName,baseRefName) ||
    fail "Could not list open pull requests. The shape check needs that list."
fi

open_count=$(jq 'length' <<<"$open_json")
if (( open_count == 200 )); then
  fail "The open pull request list stopped at 200, so a second sync or a stack layer could be missing. Wait, then rerun the check."
fi

# The trunk of the stack this pull request belongs to, from GitHub's native
# stack metadata. Empty when it is not in a native stack.
native_stack_trunk() {
  local owner name
  if [[ -n ${PR_STACK_JSON_FILE:-} ]]; then
    jq -r '.baseRefName // empty' "$PR_STACK_JSON_FILE"
    return
  fi
  owner=${GITHUB_REPOSITORY%%/*}
  name=${GITHUB_REPOSITORY#*/}
  # The $ names are GraphQL variables, not shell expansions.
  # shellcheck disable=SC2016
  gh api graphql \
    -f query='query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) { stack { baseRefName } }
      }
    }' \
    -f owner="$owner" -f name="$name" -F number="$PR_NUMBER" \
    --jq '.data.repository.pullRequest.stack.baseRefName // empty' 2>/dev/null || true
}

# Walk a hand-built stack down through open pull requests to its trunk.
walked_stack_trunk() {
  local base=$1
  local depth layers
  for (( depth = 0; depth < 50; depth++ )); do
    layers=$(jq -c --arg base "$base" '[.[] | select(.headRefName == $base)]' <<<"$open_json")
    case $(jq 'length' <<<"$layers") in
      0)
        printf '%s\n' "$base"
        return
        ;;
      1)
        base=$(jq -r '.[0].baseRefName' <<<"$layers")
        ;;
      *)
        fail "More than one open pull request has head ${base}. A stack layer has exactly one pull request."
        ;;
    esac
  done
  fail "The stack under ${PR_BASE_REF} is more than 50 layers deep or loops back on itself."
}

if is_sync_ref "$PR_HEAD_REF"; then
  if [[ $PR_BASE_REF != "quattro" ]]; then
    fail "A sync targets quattro. Retarget this pull request to quattro."
  fi
  # The translation branch is its own job. An upstream import does not block
  # it, and it does not block an upstream import.
  if [[ $PR_HEAD_REF != "i18n-sync" ]]; then
    sync_heads=$(jq -r --arg n "$PR_NUMBER" '
      .[]
      | select((.number | tostring) != $n)
      | select(
          (.headRefName | startswith("cursor/upstream-changes-pr-"))
          or (.headRefName | startswith("cursor/fork-upstream-updates-"))
        )
      | "#\(.number) \(.headRefName) -> \(.baseRefName)"
    ' <<<"$open_json")
    if [[ -n $sync_heads ]]; then
      fail "Another sync is already open:
${sync_heads}
Push onto that branch, or wait until it merges."
    fi
  fi
  printf 'ok - sync %s into %s\n' "$PR_HEAD_REF" "$PR_BASE_REF"
  exit 0
fi

if [[ $PR_BASE_REF != "quattro" ]]; then
  trunk=$(native_stack_trunk)
  if [[ -z $trunk ]]; then
    trunk=$(walked_stack_trunk "$PR_BASE_REF")
  fi
  if [[ $trunk != "quattro" ]]; then
    fail "This pull request targets ${PR_BASE_REF}, and the stack under it ends at ${trunk}, not quattro. Build the stack with gh stack so its bottom pull request targets quattro, or retarget this pull request to quattro."
  fi
fi

: "${HEAD_SHA:?HEAD_SHA is required}"
: "${BASE_SHA:?BASE_SHA is required}"
ensure_commit "$BASE_SHA" "$PR_BASE_REF"
ensure_commit "$HEAD_SHA" "$HEAD_SHA"

# Each layer is measured against the branch it targets, so a stack splits a
# large change instead of hiding it above the bottom layer.
file_count=$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}" | grep -c . || true)
if (( file_count > FILE_CAP )); then
  fail "This pull request changes ${file_count} files against ${PR_BASE_REF}. The cap is ${FILE_CAP} per pull request. Split it into a stack with gh stack, each layer under the cap, with the bottom layer targeting quattro."
fi

# Upstream commits that this branch carries and its base does not have mean
# an import is riding in a topic. Stacking on an open sync is fine: the sync
# branch is then the base and already has them.
if [[ -n ${UPSTREAM_REF:-} ]]; then
  upstream_ref=$UPSTREAM_REF
else
  : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
  parent=$(gh api "repos/${GITHUB_REPOSITORY}" --jq '.parent.full_name // empty') ||
    fail "Could not look up the upstream repository of ${GITHUB_REPOSITORY}."
  [[ -n $parent ]] || fail "${GITHUB_REPOSITORY} has no upstream repository to compare against."
  git fetch --no-tags "https://github.com/${parent}.git" "+refs/heads/quattro:refs/remotes/upstream/quattro" ||
    fail "Could not fetch quattro from ${parent}. The shape check needs it to find upstream commits."
  upstream_ref=refs/remotes/upstream/quattro
fi

mapfile -t shared < <(git merge-base --all "$HEAD_SHA" "$upstream_ref" || true)
upstream_count=0
if (( ${#shared[@]} > 0 )); then
  upstream_count=$(git rev-list --count "${shared[@]}" "^${BASE_SHA}")
fi
if (( upstream_count > 0 )); then
  fail "This pull request carries ${upstream_count} upstream commits that ${PR_BASE_REF} does not have. Upstream changes arrive only through a sync branch (cursor/upstream-changes-pr-*). Rebase onto ${PR_BASE_REF} without them, or stack this pull request on the open sync."
fi

printf 'ok - %s into %s (%s files)\n' "$PR_HEAD_REF" "$PR_BASE_REF" "$file_count"
