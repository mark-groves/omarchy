#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

printf '[]\n' >"$scratch/no-prs.json"
printf 'null\n' >"$scratch/no-stack.json"
printf '{"baseRefName":"quattro"}\n' >"$scratch/stack-quattro.json"
printf '{"baseRefName":"dev"}\n' >"$scratch/stack-dev.json"

# One repository holds the fork and a stand-in for upstream quattro, so every
# commit the check needs is already local and nothing is fetched.
repo=$scratch/repo
git init -q -b quattro "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name Test
git -C "$repo" config commit.gpgsign false

commit_files() {
  local count=$1
  local prefix=${2//\//-}
  local i
  for (( i = 1; i <= count; i++ )); do
    printf '%s\n' "$prefix $i" >"$repo/$prefix-$i"
  done
  git -C "$repo" add -A
  git -C "$repo" commit -q -m "$2"
}

commit_files 1 base
git -C "$repo" checkout -q -b upstream
commit_files 2 upstream-change
git -C "$repo" checkout -q -b cursor/upstream-changes-pr-aaaa
git -C "$repo" checkout -q quattro

reset_env() {
  PR_NUMBER=1
  PR_OPEN_JSON_FILE=$scratch/no-prs.json
  PR_STACK_JSON_FILE=$scratch/no-stack.json
  HEAD_SHA=
  BASE_SHA=
}

run_shape() {
  shape_status=0
  shape_output=$(
    cd "$repo" &&
      PR_HEAD_REF=$PR_HEAD_REF \
        PR_BASE_REF=$PR_BASE_REF \
        PR_NUMBER=$PR_NUMBER \
        PR_OPEN_JSON_FILE=$PR_OPEN_JSON_FILE \
        PR_STACK_JSON_FILE=$PR_STACK_JSON_FILE \
        HEAD_SHA=$HEAD_SHA \
        BASE_SHA=$BASE_SHA \
        UPSTREAM_REF=upstream \
        bash "$ROOT/.github/pr-shape-check.sh" 2>&1
  ) || shape_status=$?
}

# A branch off $1 named $2 with $3 changed files; sets HEAD_SHA and BASE_SHA.
topic() {
  git -C "$repo" checkout -q -b "$2" "$1"
  commit_files "$3" "$2"
  BASE_SHA=$(git -C "$repo" rev-parse "$1")
  HEAD_SHA=$(git -C "$repo" rev-parse "$2")
  git -C "$repo" checkout -q quattro
}

expect_pass() {
  (( shape_status == 0 )) || fail "$1" "$shape_output"
  pass "$1"
}

expect_fail() {
  (( shape_status == 1 )) && [[ $shape_output == *"$2"* ]] || fail "$1" "$shape_output"
  pass "$1"
}

reset_env
PR_HEAD_REF=i18n-sync
PR_BASE_REF=quattro
run_shape
expect_pass "the translation sync is exempt from the file cap"

PR_BASE_REF=dev
run_shape
expect_fail "the translation sync still has to target quattro" "A sync targets quattro. Retarget this pull request to quattro."

printf '%s\n' '[{"number":9,"headRefName":"cursor/upstream-changes-pr-aaaa","baseRefName":"quattro"}]' >"$scratch/open-sync.json"
PR_BASE_REF=quattro
PR_OPEN_JSON_FILE=$scratch/open-sync.json
run_shape
expect_pass "an open upstream sync does not block the translation sync"

PR_HEAD_REF=cursor/upstream-changes-pr-bbbb
run_shape
expect_fail "a second upstream sync names the open one" "#9 cursor/upstream-changes-pr-aaaa -> quattro"

printf '%s\n' '[{"number":9,"headRefName":"i18n-sync","baseRefName":"quattro"}]' >"$scratch/open-i18n.json"
PR_OPEN_JSON_FILE=$scratch/open-i18n.json
run_shape
expect_pass "an open translation sync does not block an upstream sync"

reset_env
topic quattro cursor/fits-the-cap 40
PR_HEAD_REF=cursor/fits-the-cap
PR_BASE_REF=quattro
run_shape
expect_pass "a topic of 40 files passes"

reset_env
topic quattro cursor/oversized-topic 41
PR_HEAD_REF=cursor/oversized-topic
PR_BASE_REF=quattro
run_shape
expect_fail "a topic over 40 files fails with the stack message" "This pull request changes 41 files against quattro. The cap is 40 per pull request. Split it into a stack with gh stack"

reset_env
topic quattro i18n-sync-extra 41
PR_HEAD_REF=i18n-sync-extra
PR_BASE_REF=quattro
run_shape
expect_fail "only the i18n-sync branch is the translation sync" "changes 41 files"

# A native stack three layers deep: quattro <- layer-1 <- layer-2 <- layer-3.
reset_env
topic quattro layer-1 30
topic layer-1 layer-2 30
topic layer-2 layer-3 30
PR_STACK_JSON_FILE=$scratch/stack-quattro.json
PR_HEAD_REF=layer-3
PR_BASE_REF=layer-2
run_shape
expect_pass "a native stack layer is capped against its own base, not quattro"

topic layer-2 layer-3-oversized 41
PR_HEAD_REF=layer-3-oversized
run_shape
expect_fail "an oversized layer above the bottom of a stack fails" "changes 41 files against layer-2"

topic layer-2 layer-3-dev 1
PR_STACK_JSON_FILE=$scratch/stack-dev.json
PR_HEAD_REF=layer-3-dev
run_shape
expect_fail "a native stack whose trunk is not quattro fails" "the stack under it ends at dev, not quattro"

# Without native metadata the check walks open pull requests to the trunk.
printf '%s\n' '[
  {"number":11,"headRefName":"layer-1","baseRefName":"quattro"},
  {"number":12,"headRefName":"layer-2","baseRefName":"layer-1"}
]' >"$scratch/walked.json"
reset_env
PR_OPEN_JSON_FILE=$scratch/walked.json
PR_HEAD_REF=layer-3
PR_BASE_REF=layer-2
HEAD_SHA=$(git -C "$repo" rev-parse layer-3)
BASE_SHA=$(git -C "$repo" rev-parse layer-2)
run_shape
expect_pass "a hand-built stack of any depth walks down to quattro"

printf '%s\n' '[
  {"number":11,"headRefName":"layer-1","baseRefName":"dev"},
  {"number":12,"headRefName":"layer-2","baseRefName":"layer-1"}
]' >"$scratch/walked-dev.json"
PR_OPEN_JSON_FILE=$scratch/walked-dev.json
run_shape
expect_fail "a hand-built stack that ends off quattro fails" "the stack under it ends at dev, not quattro"

PR_OPEN_JSON_FILE=$scratch/no-prs.json
run_shape
expect_fail "a base branch with no pull request under it fails" "the stack under it ends at layer-2, not quattro"

# Upstream commits only arrive through a sync.
reset_env
git -C "$repo" checkout -q -b cursor/import-in-topic quattro
git -C "$repo" merge -q --no-ff upstream -m "Take upstream"
commit_files 1 import-in-topic
git -C "$repo" checkout -q quattro
PR_HEAD_REF=cursor/import-in-topic
PR_BASE_REF=quattro
HEAD_SHA=$(git -C "$repo" rev-parse cursor/import-in-topic)
BASE_SHA=$(git -C "$repo" rev-parse quattro)
run_shape
expect_fail "a topic carrying upstream commits fails" "carries 1 upstream commits that quattro does not have"

reset_env
topic cursor/upstream-changes-pr-aaaa cursor/on-the-sync 1
printf '%s\n' '[{"number":9,"headRefName":"cursor/upstream-changes-pr-aaaa","baseRefName":"quattro"}]' >"$scratch/open-sync.json"
PR_OPEN_JSON_FILE=$scratch/open-sync.json
PR_HEAD_REF=cursor/on-the-sync
PR_BASE_REF=cursor/upstream-changes-pr-aaaa
run_shape
expect_pass "a layer stacked on the open sync passes the upstream check"

git -C "$repo" merge -q --no-ff upstream -m "Merge sync"
reset_env
topic quattro cursor/after-the-sync 1
PR_HEAD_REF=cursor/after-the-sync
PR_BASE_REF=quattro
run_shape
expect_pass "a topic after the sync merged does not count upstream commits"
