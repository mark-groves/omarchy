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

# The collector asks for the last week from the real clock, so its pages hold
# events from now rather than the fixed day above.
now_ms = str(round(time.time() * 1000))
pages = {
  1: {"totalUsageEventsCount": 2, "usageEventsDisplay": [dict(events[0], timestamp=now_ms)]},
  2: {"totalUsageEventsCount": 2, "usageEventsDisplay": [dict(events[1], timestamp=now_ms)]},
}

real_filtered_events = scanner.DashboardClient.filtered_events

class WorkingClient:
  def __init__(self, session, base_url):
    self.session = session
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

summary["legacyIdentity"] = {"name": record["name"], "hasIcon": "icon" in record, "hasCoverage": "coverage" in record}

# The unified X subscription, shaped like the live answers: the monthly
# usage-summary block is stale and all zero, the weekly pool is in the sand
# status and the period usage, and nothing has been bought as top-up credit.
unified_sand = {
  "currentPeriodStart": "2026-10-13T00:03:29.173Z",
  "nextResetTimestampUtc": "2026-10-20T00:03:29.173Z",
  "usagePercent": 20.812347684809097,
  "hasAvailableUsage": True,
  "hasNonZeroIncludedLimit": True,
  "cursorPlanName": "Ultra",
  "isUnified": True,
  "billingBrand": "SAND_BILLING_BRAND_GROK",
}
unified_period = {
  "billingCycleStart": "1791849809173",
  "billingCycleEnd": "1792454609173",
  "planUsage": {"autoPercentUsed": 20.812347684809097, "apiPercentUsed": 0, "totalPercentUsed": 20.812347684809097},
}
unified_summary = {
  "billingCycleStart": "2026-10-01T00:00:00.000Z",
  "billingCycleEnd": "2026-11-01T00:00:00.000Z",
  "membershipType": "unified_ultra",
  "individualUsage": {
    "plan": {"enabled": True, "used": 0, "limit": 55395, "autoPercentUsed": 0, "apiPercentUsed": 0, "totalPercentUsed": 0},
    "onDemand": {"enabled": False, "used": 0, "limit": None, "remaining": None},
  },
}

class UnifiedClient(WorkingClient):
  credits = {}
  summary_override = None
  sand_override = None
  plan_name = "Ultra"

  def usage_summary(self):
    return self.summary_override or unified_summary

  def current_period(self):
    return unified_period

  def plan_info(self):
    return {"planInfo": {"planName": self.plan_name, "includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY", "includedUsageResetsAt": "1792454609173"}, "isMerged": True}

  def sand_usage(self):
    return self.sand_override if self.sand_override is not None else unified_sand

  def credit_grants(self):
    return self.credits

def collect_unified(**attrs):
  client_class = type("Client", (UnifiedClient,), attrs)
  return scanner.collect_dashboard(client_class("auth0|user::jwt", "https://example.invalid"), include_events=False, force=False)

def brief(limits):
  return [{key: item[key] for key in ("title", "percent", "resetsAt", "valueText", "detail") if key in item} for item in limits]

pool = collect_unified()
summary["unified"] = {
  "id": pool["id"],
  "name": pool["name"],
  "icon": pool.get("icon"),
  "coverage": pool.get("coverage"),
  "tierLabel": pool["tierLabel"],
  "ready": pool["ready"],
  "limits": brief(pool["limits"]),
  "poolStarted": pool["limits"][0].get("periodStartedAt", "")[:19],
  "poolNotEarly": "resetEarly" not in pool["limits"][0],
}

granted = collect_unified(credits={"hasCreditGrants": True, "creditBalanceCents": "1250", "totalCents": "2000", "usedCents": "750"})
summary["unifiedCredit"] = brief(granted["limits"])

# Zero fields are left out of protobuf JSON: only a total and a balance here.
partial = collect_unified(credits={"hasCreditGrants": True, "creditBalanceCents": "500", "totalCents": "2000"})
summary["unifiedCreditPartial"] = brief(partial["limits"])[1]["percent"]

drained = collect_unified(credits={"hasCreditGrants": True, "totalCents": "2000", "usedCents": "2000"})
summary["unifiedCreditDrained"] = brief(drained["limits"])[1]

on_demand_summary = json.loads(json.dumps(unified_summary))
on_demand_summary["individualUsage"]["onDemand"] = {"enabled": True, "used": 2500, "limit": 10000, "remaining": 7500}
on_demand = collect_unified(summary_override=on_demand_summary)
summary["unifiedOnDemand"] = brief(on_demand["limits"])[1:]

unlimited_summary = json.loads(json.dumps(unified_summary))
unlimited_summary["individualUsage"]["onDemand"] = {"enabled": True, "used": 2500, "limit": None, "remaining": None}
summary["unifiedOnDemandNoLimit"] = [item["title"] for item in collect_unified(summary_override=unlimited_summary)["limits"]]

summary["unifiedEmptyGrantsHidden"] = [item["title"] for item in collect_unified(credits={"hasCreditGrants": False})["limits"]]

class CreditlessClient(UnifiedClient):
  def credit_grants(self):
    raise scanner.CursorError("Cursor's usage endpoint returned status 500.")

failed_credit = scanner.collect_dashboard(CreditlessClient("auth0|user::jwt", "https://example.invalid"), include_events=False, force=False)
summary["unifiedCreditFailure"] = [item["title"] for item in failed_credit["limits"]]

# Detection falls back to the membership when the sand status is unavailable,
# and the sand status wins when it speaks.
fallback = collect_unified(sand_override={})
summary["unifiedFallback"] = {"name": fallback["name"], "tierLabel": fallback["tierLabel"], "limits": brief(fallback["limits"])}
legacy_summary = dict(unified_summary, membershipType="ultra")
summary["legacySandWins"] = collect_unified(sand_override=dict(unified_sand, isUnified=False), summary_override=legacy_summary)["name"]

class ExpiredClient(WorkingClient):
  def usage_summary(self):
    raise scanner.CursorError("Cursor's usage session expired. Sign in to Cursor again.")

# A unified record says so in a field of its own; a legacy one says it isn't.
summary["unifiedFlag"] = [pool.get("unified"), collect_unified(sand_override=dict(unified_sand, isUnified=False), summary_override=legacy_summary).get("unified")]

scanner.DashboardClient = ExpiredClient
scanned = scanner.scan(test_home / "missing.vscdb", "https://example.invalid", include_events=False, force=True)
os.environ["CURSOR_SESSION_TOKEN"] = "auth0|user::jwt"
scanned = scanner.scan(test_home / "missing.vscdb", "https://example.invalid", include_events=False, force=True)
summary["expiredKeepsContract"] = scanned["id"] == "cursor" and scanned["ready"] is False and "expired" in scanned["authHelpText"].lower()

# The last detected plan survives a dashboard that doesn't answer, per account.
plan_cache = test_home / ".cache" / "omarchy" / "agent-usage" / "cursor-plan.json"

def failing_scan(db):
  return scanner.scan(db, "https://example.invalid", include_events=False, force=True)

def identity(record):
  return {key: record.get(key) for key in ("name", "icon", "unified", "tierLabel", "usageStatusText")} | {"coverage": [c["id"] for c in record.get("coverage", [])]}

def state_db(membership):
  path = test_home / ("state-" + (membership or "none") + ".vscdb")
  path.unlink(missing_ok=True)
  if membership:
    import sqlite3
    with sqlite3.connect(path) as connection:
      connection.execute("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
      connection.execute("INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType', ?)", (membership,))
  return path

plan_cache.unlink(missing_ok=True)
collect_unified()
summary["planRemembered"] = json.loads(plan_cache.read_text())
summary["planCacheHoldsNoToken"] = "jwt" not in plan_cache.read_text()
no_state = state_db("")
summary["failedKeepsUnified"] = identity(failing_scan(no_state))
os.environ["CURSOR_SESSION_TOKEN"] = "other|user::jwt"
summary["otherAccountNotRemembered"] = identity(failing_scan(no_state))
os.environ["CURSOR_SESSION_TOKEN"] = "auth0|user::jwt"
summary["membershipUnifiedWithoutCache"] = (plan_cache.unlink(), identity(failing_scan(state_db("unified_ultra"))))[1]
collect_unified()
summary["legacyMembershipClears"] = [identity(failing_scan(state_db("pro")))["name"], plan_cache.exists(), identity(failing_scan(no_state))["name"]]
collect_unified()
collect_unified(sand_override=dict(unified_sand, isUnified=False), summary_override=legacy_summary)
summary["legacyDetectionClears"] = [plan_cache.exists(), identity(failing_scan(no_state))["name"]]

# Tier labels. The unified plan is named as the Grok Bot app names it (the sand
# status's cursorPlanName, only when it says the account is unified), checked
# against planInfo.planName, with the saved membership as the last resort.
def tier_of(record):
  return [record["name"], record["tierLabel"], [c["id"] for c in record["coverage"]] if "coverage" in record else None]

for tier in ("Free", "Plus", "Premium", "Super", "Ultra"):
  record = collect_unified(sand_override=dict(unified_sand, cursorPlanName=tier), plan_name="Different")
  summary["tier" + tier] = tier_of(record)
summary["tierFromPlanInfo"] = tier_of(collect_unified(sand_override=dict(unified_sand, cursorPlanName=""), plan_name="Super"))
summary["tierFromPlanInfoNoName"] = tier_of(collect_unified(sand_override={k: v for k, v in unified_sand.items() if k != "cursorPlanName"}, plan_name="Premium"))
# A cursorPlanName without isUnified is not a unified tier: it is ignored.
summary["tierNameNeedsIsUnified"] = tier_of(collect_unified(sand_override={"cursorPlanName": "Zzz"}, plan_name="", summary_override=dict(unified_summary, membershipType="unified_super")))
for membership in ("unified_premium", "unified_super", "unified_plus", "unified_ultra", "unified_free", "unified_mystery_tier"):
  summary["tierMembership_" + membership] = tier_of(collect_unified(sand_override={}, plan_name="", summary_override=dict(unified_summary, membershipType=membership)))
summary["membershipLabels"] = {m: scanner.membership_label(m) for m in (
  "free", "pro", "pro_plus", "enterprise", "free_trial", "ultra", "pro_student", "express", "premium", "plus", "super",
  "unified_ultra", "unified_premium", "unified_super", "unified_plus", "PRO_PLUS", "mystery_tier", "",
)}

class LegacyClient(UnifiedClient):
  def sand_usage(self):
    return {"isUnified": False}

def legacy_tier(membership, plan_name):
  client = type("Client", (LegacyClient,), {"summary_override": dict(unified_summary, membershipType=membership), "plan_name": plan_name})
  record = scanner.collect_dashboard(client("auth0|user::jwt", "https://example.invalid"), include_events=False, force=False)
  return [record["name"], record["tierLabel"], record["unified"]]

summary["legacyPlanName"] = legacy_tier("pro_plus", "Pro+")
for membership in ("free", "pro", "pro_plus", "free_trial", "pro_student", "enterprise", "express", "ultra", "premium", "plus", "super", "mystery_tier"):
  summary["legacyMembership_" + membership] = legacy_tier(membership, "")[1]

# A remembered Plus tier keeps its coverage when the dashboard fails.
plan_cache.unlink(missing_ok=True)
collect_unified(sand_override=dict(unified_sand, cursorPlanName="Plus"))
summary["failedKeepsPlusCoverage"] = identity(failing_scan(state_db("")))
summary["failedMembershipPlus"] = (plan_cache.unlink(missing_ok=True), identity(failing_scan(state_db("unified_plus"))))[1]
summary["failedMembershipSuper"] = (plan_cache.unlink(missing_ok=True), identity(failing_scan(state_db("unified_super"))))[1]

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

[[ $(jq -c '.legacyIdentity' <<<"$result") == '{"name":"Cursor","hasIcon":false,"hasCoverage":false}' ]] ||
  fail "Cursor collector keeps the legacy subscription named Cursor with its own mark" "$result"
pass "Cursor collector keeps the legacy subscription named Cursor with its own mark"

[[ $(jq -c '.unified | {id, name, icon, tierLabel, ready}' <<<"$result") == '{"id":"cursor","name":"X Subscription","icon":"grok","tierLabel":"Ultra","ready":true}' ]] ||
  fail "Cursor collector records a unified account as the X Subscription with Grok's mark under the same id" "$result"
pass "Cursor collector records a unified account as the X Subscription with Grok's mark under the same id"

[[ $(jq -c '.unified.coverage' <<<"$result") == '[{"id":"grok","name":"Grok"},{"id":"grok-bot","name":"Grok Bot"},{"id":"cursor","name":"Cursor"}]' ]] ||
  fail "Cursor collector lists the agents a unified account covers, and a legacy one lists none" "$result"
pass "Cursor collector lists the agents a unified account covers, and a legacy one lists none"

[[ $(jq -c '.unified.limits' <<<"$result") == '[{"title":"Weekly","percent":0.20812347684809096,"resetsAt":"2026-10-20T00:03:29.173000Z"}]' ]] ||
  fail "Cursor collector gives a unified account one weekly pool and no credit meter" "$result"
pass "Cursor collector gives a unified account one weekly pool and no credit meter"

[[ $(jq -r '.unified | .poolStarted + ":" + (.poolNotEarly | tostring)' <<<"$result") == "2026-10-13T00:03:29:true" ]] ||
  fail "Cursor collector keeps the unified week's start without marking it early" "$result"
pass "Cursor collector keeps the unified week's start without marking it early"

[[ $(jq -c '.unifiedCredit[1]' <<<"$result") == '{"title":"Top-up Credit","percent":0.375,"resetsAt":"","valueText":"$12.50","detail":"$12.50 left of $20.00"}' ]] ||
  fail "Cursor collector shows top-up credit as used over total with the dollars left" "$result"
pass "Cursor collector shows top-up credit as used over total with the dollars left"

[[ $(jq -r '.unifiedCreditPartial' <<<"$result") == "0.75" ]] ||
  fail "Cursor collector derives credit used from the balance when the grant omits it" "$result"
pass "Cursor collector derives credit used from the balance when the grant omits it"

[[ $(jq -c '.unifiedCreditDrained | {percent, valueText}' <<<"$result") == '{"percent":1.0,"valueText":"$0.00"}' ]] ||
  fail "Cursor collector shows spent top-up credit as full with nothing left" "$result"
pass "Cursor collector shows spent top-up credit as full with nothing left"

[[ $(jq -c '.unifiedOnDemand' <<<"$result") == '[{"title":"Top-up Credit","percent":0.25,"resetsAt":"","valueText":"$75.00","detail":"$75.00 left of $100.00"}]' ]] ||
  fail "Cursor collector shows an enabled on-demand limit as the top-up meter" "$result"
pass "Cursor collector shows an enabled on-demand limit as the top-up meter"

[[ $(jq -c '[.unifiedOnDemandNoLimit, .unifiedEmptyGrantsHidden, .unifiedCreditFailure]' <<<"$result") == '[["Weekly"],["Weekly"],["Weekly"]]' ]] ||
  fail "Cursor collector hides the top-up meter without credit, without an on-demand limit, or when credit is unreadable" "$result"
pass "Cursor collector hides the top-up meter without credit, without an on-demand limit, or when credit is unreadable"

[[ $(jq -c '.unifiedFallback | {name, tierLabel, titles: [.limits[].title], resetsAt: .limits[0].resetsAt}' <<<"$result") == '{"name":"X Subscription","tierLabel":"Ultra","titles":["Weekly"],"resetsAt":"2026-10-20T00:03:29.173000Z"}' ]] ||
  fail "Cursor collector detects a unified account from its membership when the sand status is unavailable" "$result"
pass "Cursor collector detects a unified account from its membership when the sand status is unavailable"

[[ $(jq -r '.legacySandWins' <<<"$result") == "Cursor" ]] ||
  fail "Cursor collector trusts the sand status over the membership" "$result"
pass "Cursor collector trusts the sand status over the membership"

[[ $(jq -c '.unifiedFlag' <<<"$result") == '[true,false]' ]] ||
  fail "Cursor collector marks a unified record with unified true and a legacy one false" "$result"
pass "Cursor collector marks a unified record with unified true and a legacy one false"

[[ $(jq -c '.planRemembered | {unified, tierLabel}' <<<"$result") == '{"unified":true,"tierLabel":"Ultra"}' && $(jq -r '.planCacheHoldsNoToken' <<<"$result") == "true" ]] ||
  fail "Cursor collector remembers a unified plan by account without keeping the session" "$result"
pass "Cursor collector remembers a unified plan by account without keeping the session"

[[ $(jq -c '.failedKeepsUnified' <<<"$result") == '{"name":"X Subscription","icon":"grok","unified":true,"tierLabel":"Ultra","usageStatusText":"Sign-in expired","coverage":["grok","grok-bot","cursor"]}' ]] ||
  fail "Cursor collector keeps the last detected plan when the dashboard call fails" "$result"
pass "Cursor collector keeps the last detected plan when the dashboard call fails"

[[ $(jq -r '.otherAccountNotRemembered.name' <<<"$result") == "Cursor" ]] ||
  fail "Cursor collector doesn't lend one account's remembered plan to another" "$result"
pass "Cursor collector doesn't lend one account's remembered plan to another"

[[ $(jq -c '.membershipUnifiedWithoutCache | [.name, .unified, .tierLabel]' <<<"$result") == '["X Subscription",true,"Ultra"]' ]] ||
  fail "Cursor collector reads a unified plan from Cursor's saved membership when nothing is remembered" "$result"
pass "Cursor collector reads a unified plan from Cursor's saved membership when nothing is remembered"

[[ $(jq -c '.legacyMembershipClears' <<<"$result") == '["Cursor",false,"Cursor"]' && $(jq -c '.legacyDetectionClears' <<<"$result") == '[false,"Cursor"]' ]] ||
  fail "Cursor collector forgets the remembered plan on legacy detection" "$result"
pass "Cursor collector forgets the remembered plan on legacy detection"

# One case per tier, per source, and per fallback. Plus and Free have no Grok Bot.
tiers=$(jq -c '[.tierFree, .tierPlus, .tierPremium, .tierSuper, .tierUltra]' <<<"$result")
[[ $tiers == '[["X Subscription","Free",["grok","cursor"]],["X Subscription","Plus",["grok","cursor"]],["X Subscription","Premium",["grok","grok-bot","cursor"]],["X Subscription","Super",["grok","grok-bot","cursor"]],["X Subscription","Ultra",["grok","grok-bot","cursor"]]]' ]] ||
  fail "Cursor collector names every X Subscription tier from the sand status and drops Grok Bot on Free and Plus" "$tiers"
pass "Cursor collector names every X Subscription tier from the sand status and drops Grok Bot on Free and Plus"

[[ $(jq -c '[.tierFromPlanInfo, .tierFromPlanInfoNoName]' <<<"$result") == '[["X Subscription","Super",["grok","grok-bot","cursor"]],["X Subscription","Premium",["grok","grok-bot","cursor"]]]' ]] ||
  fail "Cursor collector cross-checks the tier against planInfo.planName when the sand status has no plan name" "$result"
pass "Cursor collector cross-checks the tier against planInfo.planName when the sand status has no plan name"

[[ $(jq -c '.tierNameNeedsIsUnified' <<<"$result") == '["X Subscription","Super",["grok","grok-bot","cursor"]]' ]] ||
  fail "Cursor collector ignores a sand plan name unless the status says the account is unified" "$result"
pass "Cursor collector ignores a sand plan name unless the status says the account is unified"

membership_tiers=$(jq -c '[.["tierMembership_unified_premium"], .["tierMembership_unified_super"], .["tierMembership_unified_plus"], .["tierMembership_unified_ultra"], .["tierMembership_unified_free"], .["tierMembership_unified_mystery_tier"]] | map(.[1:3])' <<<"$result")
[[ $membership_tiers == '[["Premium",["grok","grok-bot","cursor"]],["Super",["grok","grok-bot","cursor"]],["Plus",["grok","cursor"]],["Ultra",["grok","grok-bot","cursor"]],["Free",["grok","cursor"]],["Mystery Tier",["grok","grok-bot","cursor"]]]' ]] ||
  fail "Cursor collector falls back to the unified_ membership for the tier" "$membership_tiers"
pass "Cursor collector falls back to the unified_ membership for the tier"

[[ $(jq -c '.membershipLabels' <<<"$result") == '{"free":"Free","pro":"Pro","pro_plus":"Pro+","enterprise":"Enterprise","free_trial":"Trial","ultra":"Ultra","pro_student":"Student","express":"Express","premium":"Premium","plus":"Plus","super":"Super","unified_ultra":"Ultra","unified_premium":"Premium","unified_super":"Super","unified_plus":"Plus","PRO_PLUS":"Pro+","mystery_tier":"Mystery Tier","":""}' ]] ||
  fail "Cursor collector maps every membership type to a label, title-casing unknown ones" "$result"
pass "Cursor collector maps every membership type to a label, title-casing unknown ones"

[[ $(jq -c '.legacyPlanName' <<<"$result") == '["Cursor","Pro+",false]' ]] ||
  fail "Cursor collector shows a legacy plan name verbatim" "$result"
pass "Cursor collector shows a legacy plan name verbatim"

legacy=$(jq -c '[.legacyMembership_free, .legacyMembership_pro, .legacyMembership_pro_plus, .legacyMembership_free_trial, .legacyMembership_pro_student, .legacyMembership_enterprise, .legacyMembership_express, .legacyMembership_ultra, .legacyMembership_premium, .legacyMembership_plus, .legacyMembership_super, .legacyMembership_mystery_tier]' <<<"$result")
[[ $legacy == '["Free","Pro","Pro+","Trial","Student","Enterprise","Express","Ultra","Premium","Plus","Super","Mystery Tier"]' ]] ||
  fail "Cursor collector labels a legacy subscription from its membership when planInfo has no name" "$legacy"
pass "Cursor collector labels a legacy subscription from its membership when planInfo has no name"

[[ $(jq -c '[.failedKeepsPlusCoverage, .failedMembershipPlus] | map(.coverage)' <<<"$result") == '[["grok","cursor"],["grok","cursor"]]' && $(jq -c '.failedMembershipSuper | [.tierLabel, .coverage]' <<<"$result") == '["Super",["grok","grok-bot","cursor"]]' ]] ||
  fail "Cursor collector keeps the tier's coverage when the dashboard fails" "$result"
pass "Cursor collector keeps the tier's coverage when the dashboard fails"
