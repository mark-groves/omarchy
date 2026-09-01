#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3

TEST_HOME=$(mktemp -d)
trap 'rm -rf "$TEST_HOME"' EXIT

# Without a session the collector must still print a full, hidden-by-default
# record: the update runner writes whatever valid JSON appears on stdout.
no_key=$(HOME="$TEST_HOME" XDG_CONFIG_HOME="$TEST_HOME/.config" XDG_CACHE_HOME="$TEST_HOME/.cache" \
  CURSOR_SESSION_TOKEN="" CURSOR_STATE_DB="$TEST_HOME/missing.vscdb" \
  "$ROOT/bin/omarchy-agent-usage-cursor")

[[ $(jq -r '.id + ":" + (.ready | tostring) + ":" + .usageStatusText' <<<"$no_key") == "cursor:false:Waiting for auth" ]] ||
  fail "Cursor collector prints a valid record without credentials" "$no_key"
pass "Cursor collector prints a valid record without credentials"

result=$(python3 - "$ROOT/bin/omarchy-agent-usage-cursor" "$TEST_HOME" <<'PY'
import importlib.machinery
import importlib.util
import json
import os
import sys
import time
from datetime import date, datetime, timezone
from pathlib import Path

collector_path = str(Path(sys.argv[1]))
test_home = Path(sys.argv[2])
os.environ["HOME"] = str(test_home)
os.environ["XDG_CACHE_HOME"] = str(test_home / ".cache")
os.environ["TZ"] = "UTC"
time.tzset()

loader = importlib.machinery.SourceFileLoader("cursor_collector", collector_path)
spec = importlib.util.spec_from_loader(loader.name, loader)
scanner = importlib.util.module_from_spec(spec)
loader.exec_module(scanner)

summary = {
  "jwtSub": scanner.jwt_claim(
    "eyJhbGciOiJub25lIn0." +
    scanner.base64.urlsafe_b64encode(b'{"sub":"auth0|user"}').decode().rstrip("=") +
    ".x",
    "sub",
  ),
  "sessionFromJwt": scanner.normalize_session("aaa.bbb.ccc") == "aaa.bbb.ccc",
}

# A pre-formed cookie override keeps its user prefix.
summary["sessionOverride"] = scanner.normalize_session("auth0|user::jwt-token") == "auth0|user::jwt-token"

events = [
  {
    "timestamp": "1788048000000",
    "model": "cursor-grok-4.6",
    "conversationId": "c1",
    "tokenUsage": {"inputTokens": 100, "outputTokens": 20, "cacheReadTokens": 40, "cacheWriteTokens": 10},
  },
  {
    "timestamp": "1787961600000",
    "model": "composer-2",
    "conversationId": "c2",
    "tokenUsage": {"inputTokens": 50, "outputTokens": 5},
  },
]
stats = scanner.summarize_events(events, date(2026, 8, 30))
summary["todayTotalTokens"] = stats["todayTotalTokens"]
summary["todayPrompts"] = stats["todayPrompts"]
summary["todaySessions"] = stats["todaySessions"]
summary["yesterdayTokens"] = next(day["messageCount"] for day in stats["recentDays"] if day["date"] == "2026-08-29")

aggregations = {
  "aggregations": [
    {"modelIntent": "sand-default", "inputTokens": "10", "outputTokens": "4", "cacheReadTokens": "8"},
    {"modelIntent": "composer-2", "inputTokens": "3", "outputTokens": "1", "cacheWriteTokens": "2"},
  ]
}
summary["modelUsage"] = scanner.model_usage_from_aggregations(aggregations)

period = {
  "billingCycleEnd": "1790049627000",
  "planUsage": {"includedSpend": 6392, "remaining": 33608, "limit": 40000, "autoPercentUsed": 2.13, "apiPercentUsed": 0},
}
sand = {
  "usagePercent": 14.67,
  "hasNonZeroIncludedLimit": True,
  "nextResetTimestampUtc": "2026-09-01T06:44:00.862Z",
}
limits, reset_at = scanner.plan_limits(
  {"billingCycleEnd": "2026-09-22T04:00:27.000Z", "individualUsage": {"plan": {"autoPercentUsed": 2.13, "apiPercentUsed": 0, "used": 6392, "limit": 40000, "remaining": 33608}}},
  period,
  sand,
)
summary["cursorTitle"] = limits[0]["title"]
summary["autoPercent"] = limits[0]["percent"]
summary["otherTitle"] = limits[1]["title"]
summary["grokTitle"] = limits[2]["title"]
summary["grokPercent"] = limits[2]["percent"]
summary["grokResetIsIso"] = limits[2]["resetsAt"].startswith("2026-09-01")
summary["omitsGrokWithoutAllowance"] = [
  item["title"] for item in scanner.plan_limits({}, period, {"usagePercent": 14.67, "hasNonZeroIncludedLimit": False})[0]
]
summary["resetIsIso"] = reset_at.startswith("2026-09-22")

summary["subPercent"] = scanner.spending_page_fraction(0.177742)
summary["alignedWeekIsNotEarly"] = scanner.weekly_reset_was_early(
  "2026-09-01T06:44:00.862Z",
  "2026-09-08T06:44:00.862Z",
)
summary["complimentaryResetIsEarly"] = scanner.weekly_reset_was_early(
  "2026-09-01T15:47:23.732Z",
  "2026-09-08T06:44:00.862Z",
)
early_limits, _ = scanner.plan_limits({}, {}, {
  "usagePercent": 0.177742,
  "hasNonZeroIncludedLimit": True,
  "currentPeriodStart": "2026-09-01T15:47:23.732Z",
  "nextResetTimestampUtc": "2026-09-08T06:44:00.862Z",
})
summary["earlyGrokPercent"] = early_limits[0]["percent"]
summary["earlyGrokResetEarly"] = early_limits[0].get("resetEarly") is True
summary["earlyGrokStarted"] = early_limits[0].get("periodStartedAt", "").startswith("2026-09-01T15:47:23")
aligned_limits, _ = scanner.plan_limits({}, {}, {
  "usagePercent": 14.67,
  "hasNonZeroIncludedLimit": True,
  "currentPeriodStart": "2026-09-01T06:44:00.862Z",
  "nextResetTimestampUtc": "2026-09-08T06:44:00.862Z",
})
summary["alignedGrokHasStart"] = aligned_limits[0].get("periodStartedAt", "").startswith("2026-09-01T06:44:00")
summary["alignedGrokNotEarly"] = "resetEarly" not in aligned_limits[0]

pages = {
  1: {"totalUsageEventsCount": 2, "usageEventsDisplay": [events[0]]},
  2: {"totalUsageEventsCount": 2, "usageEventsDisplay": [events[1]]},
}

real_filtered_events = scanner.DashboardClient.filtered_events

class WorkingClient:
  def __init__(self, session, base_url):
    self.pages = []

  def usage_summary(self):
    return {
      "billingCycleStart": "2026-08-22T04:00:27.000Z",
      "billingCycleEnd": "2026-09-22T04:00:27.000Z",
      "membershipType": "ultra",
      "individualUsage": {"plan": {"autoPercentUsed": 2.13, "apiPercentUsed": 0, "used": 6392, "limit": 40000, "remaining": 33608}},
    }

  def current_period(self):
    return period

  def plan_info(self):
    return {"planInfo": {"planName": "Ultra", "includedAmountCents": 40000}}

  def sand_usage(self):
    return sand

  def aggregated(self, start_ms, end_ms):
    return aggregations

  def filtered_page(self, start_ms, end_ms, page):
    self.pages.append(page)
    return pages.get(page, {"usageEventsDisplay": []})

  def filtered_events(self, start_ms, end_ms):
    return real_filtered_events(self, start_ms, end_ms)

client = WorkingClient("auth0|user::jwt", "https://example.invalid")
record = scanner.collect_dashboard(client, include_events=True, force=True)
summary["record"] = {
  "schemaVersion": record["schemaVersion"],
  "id": record["id"],
  "ready": record["ready"],
  "hasPromptStats": record["hasPromptStats"],
  "scope": record["scope"],
  "tierLabel": record["tierLabel"],
  "limits": [{"title": item["title"], "percent": item["percent"]} for item in record["limits"]],
  "hasBalance": "balance" in record,
}
summary["paginationFollows"] = client.pages == [1, 2]
summary["recordHasModels"] = "sand-default" in record["modelUsage"]

limits_only = scanner.collect_dashboard(client, include_events=False, force=False)
summary["limitsOnlyKeepsWeek"] = (
  any(day["messageCount"] > 0 for day in limits_only["recentDays"])
  and limits_only["hasPromptStats"] is True
)

class SandlessClient(WorkingClient):
  def sand_usage(self):
    raise scanner.CursorError("Cursor's usage endpoint returned status 404.")

sandless = scanner.collect_dashboard(SandlessClient("auth0|user::jwt", "https://example.invalid"), include_events=False, force=False)
summary["sandFailureKeepsPools"] = [item["title"] for item in sandless["limits"]]

class ExpiredClient(WorkingClient):
  def usage_summary(self):
    raise scanner.CursorError("Cursor's usage session expired. Sign in to Cursor again.")

scanner.DashboardClient = ExpiredClient
scanned = scanner.scan(test_home / "missing.vscdb", "https://example.invalid", include_events=False, force=True)
os.environ["CURSOR_SESSION_TOKEN"] = "auth0|user::jwt"
scanned = scanner.scan(test_home / "missing.vscdb", "https://example.invalid", include_events=False, force=True)
summary["expiredKeepsContract"] = scanned["id"] == "cursor" and scanned["ready"] is False and "expired" in scanned["authHelpText"].lower()

print(json.dumps(summary, separators=(",", ":")))
PY
)

[[ $(jq -r '.jwtSub' <<<"$result") == "auth0|user" ]] ||
  fail "Cursor collector reads the JWT subject" "$result"
pass "Cursor collector reads the JWT subject"

[[ $(jq -r '.sessionOverride' <<<"$result") == "true" ]] ||
  fail "Cursor collector accepts a pre-formed session cookie" "$result"
pass "Cursor collector accepts a pre-formed session cookie"

[[ $(jq -r '.todayTotalTokens' <<<"$result") == "170" ]] ||
  fail "Cursor collector totals today's input, output, and cache tokens" "$result"
pass "Cursor collector totals today's input, output, and cache tokens"

[[ $(jq -r '.todayPrompts + .todaySessions | tostring' <<<"$result") == "2" ]] ||
  fail "Cursor collector counts today's prompts and sessions" "$result"
pass "Cursor collector counts today's prompts and sessions"

[[ $(jq -r '.yesterdayTokens' <<<"$result") == "55" ]] ||
  fail "Cursor collector builds the seven-day token series" "$result"
pass "Cursor collector builds the seven-day token series"

[[ $(jq -c '.modelUsage["sand-default"]' <<<"$result") == '{"inputTokens":10,"outputTokens":4,"cacheReadInputTokens":8,"cacheCreationInputTokens":0}' ]] ||
  fail "Cursor collector keeps cache separate in model totals" "$result"
pass "Cursor collector keeps cache separate in model totals"

[[ $(jq -r '.cursorTitle + "/" + .otherTitle + "/" + .grokTitle' <<<"$result") == "Cursor Models/Other Models/Grok Bot" ]] ||
  fail "Cursor collector titles the three dashboard pools" "$result"
pass "Cursor collector titles the three dashboard pools"

[[ $(jq -r '.autoPercent' <<<"$result") == "0.0213" ]] ||
  fail "Cursor collector stores dashboard percents as fractions" "$result"
pass "Cursor collector stores dashboard percents as fractions"

[[ $(jq -r '.grokPercent' <<<"$result") == "0.1467" ]] ||
  fail "Cursor collector stores Grok Bot weekly percent as a fraction" "$result"
pass "Cursor collector stores Grok Bot weekly percent as a fraction"

[[ $(jq -r '.subPercent < 0.002 and .subPercent > 0.001' <<<"$result") == "true" ]] ||
  fail "Cursor collector keeps a sub-1% Grok reading on the 0-100 scale" "$result"
pass "Cursor collector keeps a sub-1% Grok reading on the 0-100 scale"

[[ $(jq -r '.alignedWeekIsNotEarly' <<<"$result") == "false" ]] ||
  fail "Cursor collector treats a Grok week that started on schedule as current" "$result"
pass "Cursor collector treats a Grok week that started on schedule as current"

[[ $(jq -r '.complimentaryResetIsEarly' <<<"$result") == "true" ]] ||
  fail "Cursor collector flags a complimentary mid-week Grok reset" "$result"
pass "Cursor collector flags a complimentary mid-week Grok reset"

[[ $(jq -r '.earlyGrokPercent < 0.002 and .earlyGrokResetEarly and .earlyGrokStarted' <<<"$result") == "true" ]] ||
  fail "Cursor collector records a complimentary Grok reset as a tiny current week" "$result"
pass "Cursor collector records a complimentary Grok reset as a tiny current week"

[[ $(jq -r '.alignedGrokHasStart and .alignedGrokNotEarly' <<<"$result") == "true" ]] ||
  fail "Cursor collector keeps the Grok week start without marking a scheduled week early" "$result"
pass "Cursor collector keeps the Grok week start without marking a scheduled week early"

[[ $(jq -r '.grokResetIsIso' <<<"$result") == "true" ]] ||
  fail "Cursor collector keeps Grok Bot on its own weekly reset" "$result"
pass "Cursor collector keeps Grok Bot on its own weekly reset"

[[ $(jq -c '.omitsGrokWithoutAllowance' <<<"$result") == '["Cursor Models","Other Models"]' ]] ||
  fail "Cursor collector omits Grok Bot when the account has no weekly allowance" "$result"
pass "Cursor collector omits Grok Bot when the account has no weekly allowance"

[[ $(jq -r '.record.hasBalance' <<<"$result") == "false" ]] ||
  fail "Cursor collector does not treat included API spend as prepaid credits" "$result"
pass "Cursor collector does not treat included API spend as prepaid credits"

[[ $(jq -c '.sandFailureKeepsPools' <<<"$result") == '["Cursor Models","Other Models"]' ]] ||
  fail "Cursor collector keeps plan meters when Grok Bot status is unavailable" "$result"
pass "Cursor collector keeps plan meters when Grok Bot status is unavailable"

[[ $(jq -c '.record | {schemaVersion,id,ready,hasPromptStats,scope,tierLabel}' <<<"$result") == '{"schemaVersion":1,"id":"cursor","ready":true,"hasPromptStats":true,"scope":"account","tierLabel":"Ultra"}' ]] ||
  fail "Cursor collector prints the display-ready record contract" "$result"
pass "Cursor collector prints the display-ready record contract"

[[ $(jq -r '.paginationFollows' <<<"$result") == "true" ]] ||
  fail "Cursor collector follows filtered-usage-event pages" "$result"
pass "Cursor collector follows filtered-usage-event pages"

[[ $(jq -r '.limitsOnlyKeepsWeek' <<<"$result") == "true" ]] ||
  fail "Cursor collector keeps cached daily stats on a limits-only refresh" "$result"
pass "Cursor collector keeps cached daily stats on a limits-only refresh"

[[ $(jq -r '.expiredKeepsContract' <<<"$result") == "true" ]] ||
  fail "Cursor collector keeps the record contract when the session expires" "$result"
pass "Cursor collector keeps the record contract when the session expires"
