#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

: "${PR_HEAD_REF:?PR_HEAD_REF is required}"
: "${PR_BASE_REF:?PR_BASE_REF is required}"
: "${PR_NUMBER:?PR_NUMBER is required}"

is_sync_ref() {
  local ref=$1
  [[ $ref == cursor/upstream-changes-pr-* || $ref == cursor/fork-upstream-updates-* ]]
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
  fail "The open pull request list stopped at 200, so a second sync could be missing. Wait, then rerun the check."
fi

sync_heads=$(jq -r --arg n "$PR_NUMBER" '
  [ .[]
    | select((.number | tostring) != $n)
    | select(
        (.headRefName | startswith("cursor/upstream-changes-pr-"))
        or (.headRefName | startswith("cursor/fork-upstream-updates-"))
      )
    | "#\(.number) \(.headRefName) -> \(.baseRefName)"
  ] | .[]
' <<<"$open_json")

if is_sync_ref "$PR_HEAD_REF"; then
  if [[ $PR_BASE_REF != "quattro" ]]; then
    fail "A sync targets quattro. Retarget this pull request to quattro."
  fi
  if [[ -n $sync_heads ]]; then
    fail "Another sync is already open:
${sync_heads}
Push onto that branch, or wait until it merges."
  fi
elif [[ $PR_BASE_REF == "quattro" ]]; then
  if [[ -z ${FILE_COUNT:-} ]]; then
    : "${HEAD_SHA:?HEAD_SHA is required to count files}"
    : "${BASE_SHA:?BASE_SHA is required to count files}"
    if ! git cat-file -e "${BASE_SHA}^{commit}" 2>/dev/null; then
      git fetch --no-tags origin "$PR_BASE_REF"
    fi
    if ! git cat-file -e "${HEAD_SHA}^{commit}" 2>/dev/null; then
      git fetch --no-tags origin "$HEAD_SHA"
    fi
    FILE_COUNT=$(git diff --name-only "${BASE_SHA}...${HEAD_SHA}" | grep -c . || true)
  fi
  if (( FILE_COUNT > 40 )); then
    fail "This topic changes ${FILE_COUNT} files. The cap is 40. Split it into a stacked pull request set whose root targets quattro."
  fi
else
  root=$(jq -c --arg base "$PR_BASE_REF" '[.[] | select(.headRefName == $base)]' <<<"$open_json")
  root_count=$(jq 'length' <<<"$root")
  if (( root_count == 0 )); then
    fail "This pull request stacks on ${PR_BASE_REF}, and no open pull request from that branch targets quattro. Open that root into quattro, or retarget this pull request to quattro."
  fi
  if (( root_count > 1 )); then
    fail "More than one open pull request has head ${PR_BASE_REF}. Leave one root, and point that root at quattro."
  fi
  root_base=$(jq -r '.[0].baseRefName' <<<"$root")
  root_number=$(jq -r '.[0].number' <<<"$root")
  if [[ $root_base != "quattro" ]]; then
    fail "Pull request #${root_number} is the stack root and it targets ${root_base}. The root must target quattro."
  fi
fi

if [[ ${PR_MERGED:-false} == "true" ]]; then
  : "${MERGE_SHA:?MERGE_SHA is required once the pull request has merged}"
  : "${BASE_SHA:?BASE_SHA is required once the pull request has merged}"
  if ! git cat-file -e "${MERGE_SHA}^{commit}" 2>/dev/null; then
    git fetch --no-tags origin "$MERGE_SHA"
  fi
  first=$(git rev-parse "${MERGE_SHA}^1")
  if [[ $first != "$BASE_SHA" ]]; then
    fail "The merge commit ${MERGE_SHA} has first parent ${first}. The pull request named ${PR_BASE_REF} at ${BASE_SHA}. Merge this pull request into ${PR_BASE_REF}. Merge only the sync pull request into quattro."
  fi
fi

printf 'ok - %s into %s\n' "$PR_HEAD_REF" "$PR_BASE_REF"
