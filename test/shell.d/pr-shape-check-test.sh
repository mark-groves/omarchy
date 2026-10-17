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
