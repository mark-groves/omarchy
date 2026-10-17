#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

empty_prs=$(mktemp)
printf '[]\n' >"$empty_prs"
trap 'rm -f "$empty_prs"' EXIT

run_shape() {
  shape_status=0
  shape_output=$(
    PR_HEAD_REF=$PR_HEAD_REF \
      PR_BASE_REF=$PR_BASE_REF \
      PR_NUMBER=${PR_NUMBER:-1} \
      PR_OPEN_JSON_FILE=${PR_OPEN_JSON_FILE:-$empty_prs} \
      FILE_COUNT=${FILE_COUNT:-0} \
      PR_MERGED=${PR_MERGED:-false} \
      MERGE_SHA=${MERGE_SHA:-} \
      HEAD_SHA=${HEAD_SHA:-} \
      BASE_SHA=${BASE_SHA:-} \
      bash "$ROOT/.github/pr-shape-check.sh" 2>&1
  ) || shape_status=$?
}

PR_NUMBER=1
PR_OPEN_JSON_FILE=$empty_prs
PR_MERGED=false
FILE_COUNT=200
PR_HEAD_REF=i18n-sync
PR_BASE_REF=quattro
run_shape
(( shape_status == 0 )) && [[ $shape_output == *"ok - i18n-sync into quattro"* ]] ||
  fail "the translation sync is exempt from the file cap" "$shape_output"
pass "the translation sync is exempt from the file cap"

PR_BASE_REF=dev
run_shape
(( shape_status == 1 )) && [[ $shape_output == *"A sync targets quattro. Retarget this pull request to quattro."* ]] ||
  fail "the translation sync still has to target quattro" "$shape_output"
pass "the translation sync still has to target quattro"

other_sync=$(mktemp)
printf '%s\n' '[{"number":9,"headRefName":"cursor/upstream-changes-pr-aaaa","baseRefName":"quattro"}]' >"$other_sync"
PR_BASE_REF=quattro
PR_OPEN_JSON_FILE=$other_sync
run_shape
(( shape_status == 0 )) ||
  fail "an open upstream sync does not block the translation sync" "$shape_output"
pass "an open upstream sync does not block the translation sync"

PR_HEAD_REF=cursor/upstream-changes-pr-bbbb
PR_OPEN_JSON_FILE=$other_sync
printf '%s\n' '[{"number":9,"headRefName":"i18n-sync","baseRefName":"quattro"}]' >"$other_sync"
run_shape
(( shape_status == 0 )) ||
  fail "an open translation sync does not block an upstream sync" "$shape_output"
pass "an open translation sync does not block an upstream sync"
rm -f "$other_sync"
PR_OPEN_JSON_FILE=$empty_prs

FILE_COUNT=41
PR_HEAD_REF=cursor/oversized-topic
PR_BASE_REF=quattro
run_shape
(( shape_status == 1 )) &&
  [[ $shape_output == *"This topic changes 41 files. The cap is 40. Split it into a stacked pull request set whose root targets quattro."* ]] ||
  fail "a topic over 40 files is still a hard failure" "$shape_output"
pass "a topic over 40 files is still a hard failure"

FILE_COUNT=200
PR_HEAD_REF=i18n-sync-extra
run_shape
(( shape_status == 1 )) &&
  [[ $shape_output == *"This topic changes 200 files. The cap is 40. Split it into a stacked pull request set whose root targets quattro."* ]] ||
  fail "only the i18n-sync branch is the translation sync" "$shape_output"
pass "only the i18n-sync branch is the translation sync"

FILE_COUNT=40
PR_HEAD_REF=cursor/fits-the-cap
run_shape
(( shape_status == 0 )) ||
  fail "a topic of 40 files passes" "$shape_output"
pass "a topic of 40 files passes"

# Merge fixtures. The event BASE_SHA is the stale snapshot. The bare remote
# is what the check fetches, so the branch tip there is the live one.
new_fixture() {
  bare=$(mktemp -d)
  work=$(mktemp -d)
  git init --bare -q -b quattro "$bare"
  git init -q -b quattro "$work"
  git -C "$work" config user.email cursoragent@cursor.com
  git -C "$work" config user.name "Cursor Agent"
  git -C "$work" config commit.gpgsign false
  git -C "$work" remote add origin "$bare"
  fixture_dirs+=("$bare" "$work")
}

commit_on() {
  local path=$1
  local message=$2
  printf '%s\n' "$message" >>"$work/$path"
  git -C "$work" add "$path"
  git -C "$work" commit -q -m "$message"
}

push_branch() {
  git -C "$work" push -q origin "$1"
}

fixture_dirs=()
trap 'rm -rf "$empty_prs" "${fixture_dirs[@]}"' EXIT

new_fixture
commit_on file "base A"
stale=$(git -C "$work" rev-parse HEAD)
git -C "$work" branch feature
commit_on file "base moved"
live=$(git -C "$work" rev-parse HEAD)
git -C "$work" checkout -q feature
commit_on extra "feature"
git -C "$work" checkout -q quattro
git -C "$work" merge -q --no-ff feature -m "Merge feature"
merge_sha=$(git -C "$work" rev-parse HEAD)
push_branch quattro
pushd "$work" >/dev/null
PR_HEAD_REF=feature
PR_BASE_REF=quattro
PR_NUMBER=82
FILE_COUNT=1
PR_MERGED=true
MERGE_SHA=$merge_sha
HEAD_SHA=$(git rev-parse feature)
BASE_SHA=$stale
PR_OPEN_JSON_FILE=$empty_prs
run_shape
popd >/dev/null
(( shape_status == 0 )) ||
  fail "a stale event base SHA does not fail a merge onto the live tip" "$shape_output"
pass "a stale event base SHA does not fail a merge onto the live tip"

new_fixture
commit_on file "base A"
stale=$(git -C "$work" rev-parse HEAD)
git -C "$work" branch feature
commit_on file "base moved"
git -C "$work" checkout -q feature
commit_on extra "squashed change"
git -C "$work" checkout -q quattro
git -C "$work" merge -q --squash feature >/dev/null 2>&1
git -C "$work" commit -q -m "Squashed feature (#82)"
merge_sha=$(git -C "$work" rev-parse HEAD)
push_branch quattro
pushd "$work" >/dev/null
PR_HEAD_REF=feature
PR_BASE_REF=quattro
PR_NUMBER=82
FILE_COUNT=1
PR_MERGED=true
MERGE_SHA=$merge_sha
HEAD_SHA=$(git rev-parse feature)
BASE_SHA=$stale
PR_OPEN_JSON_FILE=$empty_prs
run_shape
popd >/dev/null
(( shape_status == 0 )) ||
  fail "a stale event base SHA does not fail a squash onto the live tip" "$shape_output"
pass "a stale event base SHA does not fail a squash onto the live tip"

new_fixture
commit_on file "base A"
stale=$(git -C "$work" rev-parse HEAD)
git -C "$work" branch feature
commit_on file "base moved"
git -C "$work" checkout -q feature
commit_on extra "replay one"
commit_on extra "replay two"
git -C "$work" rebase -q quattro
merge_sha=$(git -C "$work" rev-parse HEAD)
first_parent=$(git -C "$work" rev-parse HEAD^1)
git -C "$work" checkout -q quattro
git -C "$work" merge -q --ff-only feature
push_branch quattro
[[ $first_parent != "$stale" ]] ||
  fail "the rebase fixture first parent is not the stale snapshot"
pushd "$work" >/dev/null
PR_HEAD_REF=feature
PR_BASE_REF=quattro
PR_NUMBER=40
FILE_COUNT=2
PR_MERGED=true
MERGE_SHA=$merge_sha
HEAD_SHA=$(git rev-parse feature)
BASE_SHA=$stale
PR_OPEN_JSON_FILE=$empty_prs
run_shape
popd >/dev/null
(( shape_status == 0 )) ||
  fail "a rebase of two commits is not judged against the stale base SHA" "$shape_output"
pass "a rebase of two commits is not judged against the stale base SHA"

new_fixture
commit_on file "base A"
stale=$(git -C "$work" rev-parse HEAD)
git -C "$work" branch feature
commit_on file "base moved"
live=$(git -C "$work" rev-parse HEAD)
push_branch quattro
git -C "$work" checkout -q feature
commit_on extra "feature"
git -C "$work" checkout -q quattro
git -C "$work" merge -q --no-ff feature -m "Merge feature"
merge_sha=$(git -C "$work" rev-parse HEAD)
pushd "$work" >/dev/null
PR_HEAD_REF=feature
PR_BASE_REF=quattro
PR_NUMBER=82
FILE_COUNT=1
PR_MERGED=true
MERGE_SHA=$merge_sha
HEAD_SHA=$(git rev-parse feature)
BASE_SHA=$stale
PR_OPEN_JSON_FILE=$empty_prs
run_shape
popd >/dev/null
(( shape_status == 0 )) ||
  fail "a merge parents the fetched pre-merge tip when the ref has not moved" "$shape_output"
pass "a merge parents the fetched pre-merge tip when the ref has not moved"
[[ $live != "$stale" ]] || fail "the live tip fixture did not move the base"

new_fixture
commit_on file "base A"
git -C "$work" branch feature
commit_on file "base moved"
git -C "$work" checkout -q feature
commit_on extra "feature"
git -C "$work" checkout -q quattro
git -C "$work" merge -q --no-ff feature -m "Merge feature"
merge_sha=$(git -C "$work" rev-parse HEAD)
git -C "$work" commit -q --allow-empty -m "later commit"
push_branch quattro
pushd "$work" >/dev/null
PR_HEAD_REF=feature
PR_BASE_REF=quattro
PR_NUMBER=82
FILE_COUNT=1
PR_MERGED=true
MERGE_SHA=$merge_sha
HEAD_SHA=$(git rev-parse feature)
BASE_SHA=$(git rev-parse 'quattro~3')
PR_OPEN_JSON_FILE=$empty_prs
run_shape
popd >/dev/null
(( shape_status == 0 )) ||
  fail "a later commit on the base does not hide a merge that landed there" "$shape_output"
pass "a later commit on the base does not hide a merge that landed there"

new_fixture
commit_on file "base A"
git -C "$work" branch sync
git -C "$work" checkout -q sync
commit_on sync-file "sync tip"
sync_tip=$(git -C "$work" rev-parse HEAD)
push_branch sync
git -C "$work" checkout -q quattro
commit_on file "quattro tip"
quattro_tip=$(git -C "$work" rev-parse HEAD)
git -C "$work" checkout -q -b layout sync
commit_on layout-file "layout"
git -C "$work" checkout -q quattro
git -C "$work" merge -q --no-ff layout -m "Merge layout into quattro"
merge_sha=$(git -C "$work" rev-parse HEAD)
first_parent=$(git -C "$work" rev-parse HEAD^1)
push_branch quattro
root_prs=$(mktemp)
fixture_dirs+=("$root_prs")
printf '%s\n' '[{"number":73,"headRefName":"sync","baseRefName":"quattro"}]' >"$root_prs"
[[ $first_parent == "$quattro_tip" ]] ||
  fail "the wrong-branch fixture merged onto quattro"
pushd "$work" >/dev/null
PR_HEAD_REF=layout
PR_BASE_REF=sync
PR_NUMBER=75
FILE_COUNT=1
PR_MERGED=true
MERGE_SHA=$merge_sha
HEAD_SHA=$(git rev-parse layout)
BASE_SHA=$quattro_tip
PR_OPEN_JSON_FILE=$root_prs
run_shape
popd >/dev/null
(( shape_status == 1 )) &&
  [[ $shape_output == *"first parent ${first_parent}"* ]] &&
  [[ $shape_output == *"sync was at ${sync_tip}"* ]] ||
  fail "a merge onto another branch fails even when the event SHA is that parent" "$shape_output"
pass "a merge onto another branch fails even when the event SHA is that parent"

# Pull request 75 named the sync branch and the merge commit landed on quattro.
bad_merge=cee24cbf572e8861a13856e20d1a9c6a38bb1119
bad_base=b493942827fd8fbca26bed5abb6a55b5702bf652
git -C "$ROOT" cat-file -e "${bad_merge}^{commit}"
git -C "$ROOT" cat-file -e "${bad_base}^{commit}"
bad_parent=$(git -C "$ROOT" rev-parse "${bad_merge}^1")
bare=$(mktemp -d)
work=$(mktemp -d)
fixture_dirs+=("$bare" "$work")
git clone --local --bare -q "$ROOT" "$bare"
git -C "$bare" update-ref refs/heads/sync "$bad_base"
git -C "$bare" update-ref refs/heads/landed "$bad_merge"
git clone --local -q "$bare" "$work"
git -C "$work" config user.email cursoragent@cursor.com
git -C "$work" config user.name "Cursor Agent"
git -C "$work" config commit.gpgsign false
pushd "$work" >/dev/null
PR_HEAD_REF=cursor/keep-minimized-layout-a84f
PR_BASE_REF=sync
PR_NUMBER=75
FILE_COUNT=8
PR_MERGED=true
MERGE_SHA=$bad_merge
HEAD_SHA=$(git rev-parse origin/landed^2)
BASE_SHA=$bad_parent
PR_OPEN_JSON_FILE=$root_prs
run_shape
popd >/dev/null
(( shape_status == 1 )) &&
  [[ $shape_output == *"first parent ${bad_parent}"* ]] &&
  [[ $shape_output == *"sync was at ${bad_base}"* ]] ||
  fail "the layout merge that landed on quattro still fails" "$shape_output"
pass "the layout merge that landed on quattro still fails"
