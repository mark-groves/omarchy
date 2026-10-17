#!/bin/bash

source "$(dirname "$0")/base-test.sh"

require_command jq
require_command python3

# probe_limits reaches Anthropic, so the reader that interprets its answer is
# exercised on its own: the collector loads as a module, and a recorded payload
# stands in for the response.
read_limits() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" PAYLOAD="$1" python3 - <<'PY'
import importlib.machinery, importlib.util, io, json, os

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

collector.urllib.request.urlopen = lambda request, timeout=None: io.BytesIO(os.environ["PAYLOAD"].encode())

print(json.dumps(collector.probe_limits("token")))
PY
}

# The two flat buckets, then every scoped shape that matters: a model's weekly
# window, a second window for that same model, a model that names only an id,
# and — dropped — a repeat of a window already read, a blank name, and a
# percent that will not parse.
limits=$(read_limits '{
  "five_hour": { "utilization": 78.0 },
  "seven_day": { "utilization": 12.0 },
  "seven_day_opus": null,
  "limits": [
    { "kind": "session", "percent": 78, "scope": null },
    { "kind": "weekly_all", "percent": 12, "scope": null },
    { "kind": "weekly_scoped", "percent": 17, "resets_at": "2026-08-15T03:00:00+00:00",
      "scope": { "model": { "id": "claude-fable-5", "display_name": "Fable" }, "surface": null } },
    { "kind": "weekly_scoped", "percent": 99, "scope": { "model": { "display_name": "Fable" } } },
    { "kind": "five_hour_scoped", "percent": 95, "scope": { "model": { "display_name": "Fable" } } },
    { "kind": "weekly_scoped", "percent": 42, "scope": { "model": { "id": "claude-opus-5", "display_name": null } } },
    { "kind": "weekly_scoped", "percent": 5, "scope": { "model": { "display_name": "  " } } },
    { "kind": "weekly_scoped", "percent": "unknown", "scope": { "model": { "display_name": "Opus" } } }
  ]
}')

expected='[{"label":"Session (5-hour)","percent":0.78,"resetsAt":""},{"label":"Weekly (7-day)","percent":0.12,"resetsAt":""},{"label":"Fable Weekly","title":"Fable Weekly","percent":0.17,"resetsAt":"2026-08-15T03:00:00+00:00"},{"label":"Fable Session","title":"Fable Session","percent":0.95,"resetsAt":""},{"label":"claude-opus-5 Weekly","title":"claude-opus-5 Weekly","percent":0.42,"resetsAt":""}]'
[[ $(jq -c '.limits' <<<"$limits") == "$expected" ]] ||
  fail "Claude collector reads every model-scoped window once and drops unusable entries" "$limits"
pass "Claude collector reads every model-scoped window once and drops unusable entries"

# A payload that speaks fractions says so in its buckets, and the scoped
# entries are read on the same scale rather than assuming percentages.
fractions=$(read_limits '{
  "five_hour": { "utilization": 0.78 },
  "limits": [
    { "kind": "session", "percent": 0.78, "scope": null },
    { "kind": "weekly_scoped", "percent": 0.42, "scope": { "model": { "display_name": "Fable" } } }
  ]
}')

[[ $(jq -c '[.limits[].percent]' <<<"$fractions") == "[0.78,0.42]" ]] ||
  fail "Claude collector reads scoped percentages on the payload's own scale" "$fractions"
pass "Claude collector reads scoped percentages on the payload's own scale"

# An account with no model-scoped allowance, and an endpoint that never grew
# the array, both keep the session and weekly windows they always had.
for payload in '{"five_hour":{"utilization":78.0},"limits":[{"kind":"session","percent":78,"scope":null}]}' \
  '{"five_hour":{"utilization":78.0},"seven_day":{"utilization":12.0}}'; do
  [[ $(jq -c '[.limits[].label]' <<<"$(read_limits "$payload")") != *" Weekly"* ]] ||
    fail "Claude collector adds no limit when the payload scopes none" "$payload"
done
pass "Claude collector adds no limit when the payload scopes none"

# The saved login carries two plan facts: the subscription and the rate-limit
# tier it runs under. Read the label off a planted credential store so the
# whole path is exercised, not just the formatter.
plan_label() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" TIER="$1" SUBSCRIPTION="$2" python3 - <<'PY'
import importlib.machinery, importlib.util, json, os, pathlib, tempfile

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

claude_dir = pathlib.Path(tempfile.mkdtemp())
(claude_dir / ".credentials.json").write_text(json.dumps({"claudeAiOauth": {
  "accessToken": "token", "expiresAt": 1,
  "rateLimitTier": os.environ["TIER"], "subscriptionType": os.environ["SUBSCRIPTION"],
}}), encoding="utf-8")
print(collector.oauth_login(claude_dir)[-1])
PY
}

# A Team premium seat runs on the Max 5x rate-limit tier, and the tier alone
# used to label it "Max 5x" — the plan the seat is not on.
[[ $(plan_label default_claude_max_5x team) == "Team 5x" ]] ||
  fail "Claude collector labels a Team seat by its subscription, not its rate-limit tier" "$(plan_label default_claude_max_5x team)"
pass "Claude collector labels a Team seat by its subscription, not its rate-limit tier"

# Max keeps its multiplier, with or without a subscription type alongside the
# tier, and a plan whose tier names no multiplier is just the plan.
[[ $(plan_label default_claude_max_20x max) == "Max 20x" && $(plan_label default_claude_max_5x "") == "Max 5x" ]] ||
  fail "Claude collector still labels Max by its multiplier" "$(plan_label default_claude_max_20x max) / $(plan_label default_claude_max_5x "")"
[[ $(plan_label default_claude_pro pro) == "Pro" && $(plan_label "" team) == "Team" ]] ||
  fail "Claude collector labels a plan without a multiplier by its subscription alone" "$(plan_label default_claude_pro pro) / $(plan_label "" team)"
pass "Claude collector keeps Max multipliers and plain plan names"

# The access token lapses about every eight hours while the refresh token
# behind it stays good. Drive collect_limits over a planted cache with the
# network unreachable and no home to refresh in, so nothing but the credential
# state decides the answer; the refresh itself is covered further down.
CACHE_HOME=$(mktemp -d)
trap 'rm -rf "$CACHE_HOME"' EXIT

collect_limits() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" TOKEN="$1" EXPIRES_AT="$2" \
    REFRESH_EXPIRES_AT="$3" CACHED="$4" CACHE_MTIME_OFFSET="${5:-0}" \
    XDG_CACHE_HOME="$CACHE_HOME" python3 - <<'PY'
import importlib.machinery, importlib.util, json, os, pathlib, time

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

cache = collector.cache_root() / "claude-limits.json"
cached = os.environ["CACHED"]
if cached:
  cache.write_text(cached, encoding="utf-8")
  offset = float(os.environ["CACHE_MTIME_OFFSET"])
  if offset:
    timestamp = time.time() + offset
    os.utime(cache, (timestamp, timestamp))
elif cache.exists():
  cache.unlink()

def unreachable(request, timeout=None):
  raise OSError("no route to host")

collector.urllib.request.urlopen = unreachable
print(json.dumps(collector.collect_limits(
  os.environ["TOKEN"],
  int(os.environ["EXPIRES_AT"]),
  int(os.environ["REFRESH_EXPIRES_AT"]),
  False,
)))
PY
}

# An open window and one that already reset, cached long enough ago that a live
# token would re-probe rather than reuse them.
open_at=$(python3 -c 'import datetime as dt; print((dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=3)).isoformat())')
past_at=$(python3 -c 'import datetime as dt; print((dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=3)).isoformat())')
cache=$(jq -nc --arg open "$open_at" --arg past "$past_at" '{
  fetchedAtMs: 1,
  limits: [
    { label: "Session (5-hour)", percent: 0.31, resetsAt: $past },
    { label: "Weekly (7-day)", percent: 0.11, resetsAt: $open }
  ]
}')

# Both tokens lapsed is a genuine sign-out. It used to return an empty limits
# list and no status at all, which hides the panel's whole limits section
# without saying why.
expired=$(collect_limits "token" 1000 1000 "$cache")
[[ $(jq -r '.usageStatusText' <<<"$expired") == "Sign-in expired" ]] ||
  fail "Claude collector reports an expired sign-in" "$expired"
[[ $(jq -r '.authHelpText' <<<"$expired") == *"claude auth login"* ]] ||
  fail "Claude collector says how to refresh an expired sign-in" "$expired"
pass "Claude collector reports an expired sign-in instead of hiding the section"

# The elapsed session resets to zero while the weekly usage stays intact.
[[ $(jq -c '[.limits[].label]' <<<"$expired") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector keeps cached windows and resets elapsed ones" "$expired"
[[ $(jq '[.limits[].percent] == [0,0.11]' <<<"$expired") == "true" && $(jq -r '.limits[0].resetsAt' <<<"$expired") == "" ]] ||
  fail "Claude collector resets just the elapsed window" "$expired"
pass "Claude collector keeps cached windows and resets elapsed ones"

# A wholly reset cache still shows the empty allowance.
stale=$(collect_limits "token" 1000 1000 "$(jq -c '.limits |= [.[0]]' <<<"$cache")")
[[ $(jq '.limits | map(.percent) == [0]' <<<"$stale") == "true" && $(jq -r '.usageStatusText' <<<"$stale") == "Sign-in expired" ]] ||
  fail "Claude collector resets a wholly elapsed cache to zero" "$stale"
[[ $(jq -r '.authHelpText' <<<"$stale") == *"last known"* ]] ||
  fail "Claude collector keeps the timestamp and guidance for a reset cache" "$stale"
pass "Claude collector resets a wholly elapsed cache to zero"

# The access token lives about eight hours; the refresh token behind it lives
# about thirty days, and the CLI mints a new access token from it on its next
# run. A machine left overnight finds the first lapsed and the second fine --
# routine, and nothing a person fixes by signing in again.
live_refresh=$(python3 -c 'import time; print(round((time.time() + 30 * 86400) * 1000))')
paused=$(collect_limits "token" 1000 "$live_refresh" "$cache")
[[ $(jq -r '.usageStatusText' <<<"$paused") == "Limits paused" ]] ||
  fail "Claude collector calls a lapsed access token paused, not signed out" "$paused"
[[ $(jq -r '.authHelpText' <<<"$paused") != *"claude auth login"* ]] ||
  fail "Claude collector does not send a signed-in machine back through login" "$paused"
# Without a home to refresh, the only thing left to say is how to get a new
# token by hand; with one, the same text appears only after a refresh failed.
[[ $(jq -r '.authHelpText' <<<"$paused") == *"couldn't refresh it just now"* && $(jq -r '.authHelpText' <<<"$paused") == *'`claude` in a terminal'* ]] ||
  fail "Claude collector words a paused token as a refresh that did not work" "$paused"
[[ $(jq -c '[.limits[].label]' <<<"$paused") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector keeps open cached windows while the access token is stale" "$paused"
pass "Claude collector calls a lapsed access token paused, not signed out"

# The Claude desktop app keeps its own sign-in and never rewrites the CLI's
# credential file, so the collector refreshes a lapsed access token itself,
# speaking the CLI's own refresh protocol. These drive a scenario against a
# planted home with the HTTP layer stubbed (no network, fake tokens) and print
# what the scenario observed, never a token.
refresh_run() {
  # The collector reports a failed refresh on stderr, which these scenarios
  # provoke on purpose; a crash still shows as missing output.
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" SCENARIO="$1" python3 - 2>/dev/null <<'PY'
import hashlib, importlib.machinery, importlib.util, io, json, os, pathlib, stat, tempfile, time, urllib.error

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

scenario = os.environ["SCENARIO"]
base = pathlib.Path(tempfile.mkdtemp())
os.environ["XDG_CACHE_HOME"] = str(base / "cache")
collector.lock_sleep = lambda: None
collector.time.sleep = lambda seconds: None

now = round(time.time() * 1000)
HOUR = 3600 * 1000
OTHER = {"mcpOAuth": {"server": {"accessToken": "mcp-token"}}, "organizationUuid": "org"}

def plant(name, access="old-access", refresh="old-refresh", expires=now - HOUR, refresh_expires=now + 30 * 24 * HOUR):
  home = base / name
  home.mkdir()
  path = home / ".credentials.json"
  login = {
    "accessToken": access, "refreshToken": refresh, "expiresAt": expires,
    "refreshTokenExpiresAt": refresh_expires, "scopes": ["user:inference", "user:profile"],
    "subscriptionType": "max", "rateLimitTier": "default_claude_max_5x", "clientId": "custom-client",
  }
  path.write_text(json.dumps({"claudeAiOauth": login, **OTHER}), encoding="utf-8")
  path.chmod(0o600)
  return home

def creds(home):
  return json.loads((home / ".credentials.json").read_text(encoding="utf-8"))

def digest(home):
  return hashlib.sha256((home / ".credentials.json").read_bytes()).hexdigest()

token_requests, usage_requests, replaces = [], [], []
answers = {}

def respond(refresh_token):
  answer = answers.get(refresh_token)
  if isinstance(answer, Exception):
    raise answer
  if isinstance(answer, int):
    body = {"error": "invalid_grant"} if answer in (400, 401) else {}
    raise urllib.error.HTTPError(collector.TOKEN_URL, answer, "err", {}, io.BytesIO(json.dumps(body).encode()))
  return io.BytesIO(json.dumps(answer).encode())

def urlopen(request, timeout=None):
  if request.full_url == collector.TOKEN_URL:
    body = json.loads(request.data)
    token_requests.append({
      "method": request.get_method(), "type": request.get_header("Content-type"),
      "grant": body["grant_type"], "client": body["client_id"], "scope": body["scope"],
      "refresh": body["refresh_token"],
    })
    return respond(body["refresh_token"])
  usage_requests.append(request.get_header("Authorization"))
  return io.BytesIO(b'{"five_hour":{"utilization":44.0}}')

collector.urllib.request.urlopen = urlopen

# Record, at the moment of the swap, what os.replace is handed.
real_replace = os.replace
def replace(src, dst, *a, **k):
  source = pathlib.Path(src)
  if pathlib.Path(dst).name != ".credentials.json":
    return real_replace(src, dst, *a, **k)
  replaces.append({
    "sameDirectory": source.parent == pathlib.Path(dst).parent,
    "mode": stat.S_IMODE(source.stat().st_mode),
    "complete": isinstance(json.loads(source.read_text(encoding="utf-8")).get("claudeAiOauth"), dict),
    "lockHeld": (pathlib.Path(dst).parent / collector.STORAGE_LOCK_NAME).is_dir(),
  })
  return real_replace(src, dst, *a, **k)
collector.os.replace = replace

fresh = lambda access, refresh: {
  "access_token": access, "refresh_token": refresh, "expires_in": 28800,
  "refresh_token_expires_in": 2592000, "scope": "user:inference user:profile user:sessions:claude_code",
}
out = {}

def run(home, force=False, cache="claude-limits.json"):
  login = collector.oauth_login(home)
  result = collector.collect_limits(login[0], login[1], login[2], force, cache, home)
  return {
    "status": result["usageStatusText"], "help": result["authHelpText"], "live": result["live"],
    "percents": [l["percent"] for l in result["limits"]],
  }

def leftovers(home):
  return sorted(p.name for p in home.iterdir() if p.name != ".credentials.json")

home = plant("a")
before = digest(home)

if scenario in ("refreshed", "near_expiry", "stale_lock"):
  if scenario == "near_expiry":
    home = plant("n", expires=now + 120 * 1000)
  if scenario == "stale_lock":
    # A holder that died long ago must not block the refresh.
    lock = home / collector.REFRESH_LOCK_NAME
    lock.mkdir()
    old = time.time() - 600
    os.utime(lock, (old, old))
  rt = creds(home)["claudeAiOauth"]["refreshToken"]
  answers[rt] = fresh("new-access", "new-refresh")
  out["run"] = run(home)
  after = creds(home)
  login = after["claudeAiOauth"]
  out["file"] = {
    "access": login["accessToken"] == "new-access", "refresh": login["refreshToken"] == "new-refresh",
    "expiresInFuture": login["expiresAt"] > now + 7 * HOUR, "refreshExpiresInFuture": login["refreshTokenExpiresAt"] > now + 29 * 24 * HOUR,
    "scopes": login["scopes"], "kept": [login["subscriptionType"], login["rateLimitTier"], login["clientId"]],
    "otherKeys": {k: after[k] for k in OTHER} == OTHER, "mode": stat.S_IMODE((home / ".credentials.json").stat().st_mode),
    "leftovers": leftovers(home), "legacyLockLeft": pathlib.Path(str(home) + ".lock").exists(),
  }
  out["usageBearer"] = usage_requests

elif scenario == "raced_busy":
  # The CLI holds the lock; by the time it lets go it has saved a fresh login.
  lock = home / collector.REFRESH_LOCK_NAME
  lock.mkdir()
  def finish():
    peer = creds(home)
    peer["claudeAiOauth"].update(accessToken="peer-access", refreshToken="peer-refresh", expiresAt=now + 8 * HOUR)
    (home / ".credentials.json").write_text(json.dumps(peer), encoding="utf-8")
    lock.rmdir()
  collector.lock_sleep = finish
  out["run"] = run(home)
  out["usageBearer"] = usage_requests
  out["refresh"] = creds(home)["claudeAiOauth"]["refreshToken"] == "peer-refresh"

elif scenario == "raced_unseen":
  # Nothing contends, but another process saved a login after this one looked.
  acquire = collector.DirLock.acquire
  def acquire_after_peer(self):
    if self.path.name == collector.REFRESH_LOCK_NAME and not getattr(acquire_after_peer, "done", False):
      acquire_after_peer.done = True
      peer = creds(home)
      peer["claudeAiOauth"].update(accessToken="peer-access", refreshToken="peer-refresh", expiresAt=now + 8 * HOUR)
      (home / ".credentials.json").write_text(json.dumps(peer), encoding="utf-8")
    return acquire(self)
  collector.DirLock.acquire = acquire_after_peer
  out["run"] = run(home)
  out["usageBearer"] = usage_requests
  out["refresh"] = creds(home)["claudeAiOauth"]["refreshToken"] == "peer-refresh"

elif scenario in ("rejected_400", "rejected_401"):
  answers["old-refresh"] = int(scenario[-3:])
  out["run"] = run(home)
  out["again"] = run(home)
  out["forced"] = run(home, force=True)
  out["unchanged"] = digest(home) == before
  out["replacesBefore"] = list(replaces)
  # A new sign-in replaces the refresh token, and is tried again.
  home2 = plant("b", refresh="relogin-refresh")
  answers["relogin-refresh"] = fresh("relogin-access", "relogin-refresh-2")
  out["relogin"] = run(home2)

elif scenario in ("server_error", "transport_error"):
  answers["old-refresh"] = 503 if scenario == "server_error" else OSError("no route to host")
  out["run"] = run(home)
  out["requestsAfterFirst"] = len(token_requests)
  out["again"] = run(home)
  out["requestsAfterBackoff"] = len(token_requests)
  out["forced"] = run(home, force=True)
  out["unchanged"] = digest(home) == before
  out["leftovers"] = leftovers(home)

elif scenario == "refresh_expired":
  home = plant("e", refresh_expires=now - HOUR)
  before = digest(home)
  out["run"] = run(home)
  out["unchanged"] = digest(home) == before

elif scenario == "two_homes":
  a, b = plant("one", refresh="refresh-one"), plant("two", refresh="refresh-two")
  answers["refresh-one"] = fresh("access-one", "refresh-one-next")
  answers["refresh-two"] = fresh("access-two", "refresh-two-next")
  accounts = [{"id": "one", "home": str(a), "active": True}, {"id": "two", "home": str(b), "active": False}]
  out["accounts"] = [collector.account_limits(account, False)["usageStatusText"] for account in accounts]
  out["tokens"] = [[creds(h)["claudeAiOauth"][k] for k in ("accessToken", "refreshToken")] for h in (a, b)]
  out["usageBearer"] = sorted(usage_requests)

out["tokenRequests"] = [
  {k: v for k, v in r.items() if k != "refresh"} | {"refreshMatches": r["refresh"] in ("old-refresh", "refresh-one", "refresh-two", "relogin-refresh")}
  for r in token_requests
]
out["replaces"] = replaces
print(json.dumps(out))
PY
}

# A lapsed access token is refreshed with the saved refresh token, the way the
# CLI does it: a JSON POST to the OAuth token endpoint with the CLI's client id
# and the login's own scopes.
refreshed=$(refresh_run refreshed)
[[ $(jq -c '[.tokenRequests[] | [.method, .type, .grant, .client, .scope, .refreshMatches]]' <<<"$refreshed") == '[["POST","application/json","refresh_token","custom-client","user:inference user:profile",true]]' ]] ||
  fail "Claude collector refreshes a lapsed token with one JSON refresh_token request" "$refreshed"
[[ $(jq -r '.run.status' <<<"$refreshed") == "" && $(jq -r '.run.live' <<<"$refreshed") == "true" && $(jq -c '.run.percents' <<<"$refreshed") == "[0.44]" ]] ||
  fail "Claude collector goes on to read the limits after refreshing" "$refreshed"
[[ $(jq -c '.usageBearer' <<<"$refreshed") == '["Bearer new-access"]' ]] ||
  fail "Claude collector asks for the limits with the refreshed token" "$refreshed"
pass "Claude collector refreshes a lapsed access token and reads the limits with it"

# The new tokens and expiries land in the file; everything else in it stays,
# at the same permissions, swapped in whole from beside it under the CLI's
# storage lock.
[[ $(jq -c '.file | [.access, .refresh, .expiresInFuture, .refreshExpiresInFuture]' <<<"$refreshed") == "[true,true,true,true]" ]] ||
  fail "Claude collector saves the refreshed tokens and their expiries" "$refreshed"
[[ $(jq -c '.file | [.kept, .otherKeys, .scopes]' <<<"$refreshed") == '[["max","default_claude_max_5x","custom-client"],true,["user:inference","user:profile","user:sessions:claude_code"]]' ]] ||
  fail "Claude collector keeps every other field of the credential file" "$refreshed"
[[ $(jq -r '.file.mode' <<<"$refreshed") == "384" ]] ||
  fail "Claude collector keeps the credential file private (0600)" "$refreshed"
[[ $(jq -c '.replaces' <<<"$refreshed") == '[{"sameDirectory":true,"mode":384,"complete":true,"lockHeld":true}]' ]] ||
  fail "Claude collector writes the credential file atomically from a private temp file under the storage lock" "$refreshed"
[[ $(jq -c '.file.leftovers' <<<"$refreshed") == "[]" && $(jq -r '.file.legacyLockLeft' <<<"$refreshed") == "false" ]] ||
  fail "Claude collector leaves no temp file or lock behind" "$refreshed"
pass "Claude collector writes the refreshed login atomically and keeps the rest of the file"

# An access token about to lapse is refreshed too, as the CLI does within five
# minutes of expiry, and a lock left by a dead holder does not block it.
near=$(refresh_run near_expiry)
[[ $(jq -r '.file.access' <<<"$near") == "true" && $(jq -r '.tokenRequests | length' <<<"$near") == "1" ]] ||
  fail "Claude collector refreshes an access token about to lapse" "$near"
stale_lock=$(refresh_run stale_lock)
[[ $(jq -r '.file.access' <<<"$stale_lock") == "true" && $(jq -c '.file.leftovers' <<<"$stale_lock") == "[]" ]] ||
  fail "Claude collector clears a stale refresh lock and refreshes" "$stale_lock"
pass "Claude collector refreshes shortly before expiry and past a stale lock"

# Refresh tokens rotate, so spending the old one twice signs the account out.
# Another process that refreshed first (before we locked, or while we waited
# for its lock) is adopted after re-reading the file, with no second request.
for scenario in raced_busy raced_unseen; do
  raced=$(refresh_run "$scenario")
  [[ $(jq -r '.tokenRequests | length' <<<"$raced") == "0" ]] ||
    fail "Claude collector does not refresh again after another process did ($scenario)" "$raced"
  [[ $(jq -c '.usageBearer' <<<"$raced") == '["Bearer peer-access"]' && $(jq -r '.refresh' <<<"$raced") == "true" && $(jq -c '.replaces' <<<"$raced") == "[]" ]] ||
    fail "Claude collector adopts the login another process saved ($scenario)" "$raced"
done
pass "Claude collector re-reads the credentials under the lock and adopts a refresh another process made"

# A refresh token the server refuses (invalid_grant, or any 401) is a real
# sign-out. The file is not touched, the request is not repeated for the same
# token, and a new sign-in is tried again.
for scenario in rejected_400 rejected_401; do
  rejected=$(refresh_run "$scenario")
  [[ $(jq -r '.run.status' <<<"$rejected") == "Sign-in expired" && $(jq -r '.run.help' <<<"$rejected") == *"claude auth login"* ]] ||
    fail "Claude collector reports a refused refresh token as an expired sign-in ($scenario)" "$rejected"
  [[ $(jq -r '.unchanged' <<<"$rejected") == "true" && $(jq -c '.replacesBefore' <<<"$rejected") == "[]" ]] ||
    fail "Claude collector leaves the credential file alone after a refused refresh ($scenario)" "$rejected"
  [[ $(jq -r '[.again.status, .forced.status] | unique | .[]' <<<"$rejected") == "Sign-in expired" ]] ||
    fail "Claude collector keeps reporting the expired sign-in ($scenario)" "$rejected"
  [[ $(jq -r '.tokenRequests | map(select(.refreshMatches)) | length' <<<"$rejected") == "2" && $(jq -r '.relogin.live' <<<"$rejected") == "true" ]] ||
    fail "Claude collector does not retry a refused token but tries a new sign-in ($scenario)" "$rejected"
done
pass "Claude collector reports a refused refresh token as an expired sign-in and stops asking"

# A server or network failure may pass: the panel stays paused on the last
# numbers, the file is untouched, and the next panel refreshes inside the
# backoff do not ask again (only --force does).
for scenario in server_error transport_error; do
  failed=$(refresh_run "$scenario")
  [[ $(jq -r '.run.status' <<<"$failed") == "Limits paused" && $(jq -r '.run.help' <<<"$failed") == *"couldn't refresh it just now"* ]] ||
    fail "Claude collector pauses on a transient refresh failure ($scenario)" "$failed"
  [[ $(jq -r '.unchanged' <<<"$failed") == "true" && $(jq -c '.leftovers' <<<"$failed") == "[]" && $(jq -c '.replaces' <<<"$failed") == "[]" ]] ||
    fail "Claude collector leaves the credential file alone after a transient failure ($scenario)" "$failed"
  [[ $(jq -c '[.requestsAfterFirst, .requestsAfterBackoff, (.tokenRequests | length)]' <<<"$failed") == "[1,1,2]" && $(jq -r '.again.status' <<<"$failed") == "Limits paused" ]] ||
    fail "Claude collector backs off after a transient refresh failure ($scenario)" "$failed"
done
pass "Claude collector pauses without touching the file on a transient failure and backs off"

# A refresh token past its own expiry cannot work, so nothing is requested.
dead=$(refresh_run refresh_expired)
[[ $(jq -r '.tokenRequests | length' <<<"$dead") == "0" && $(jq -r '.run.status' <<<"$dead") == "Sign-in expired" && $(jq -r '.unchanged' <<<"$dead") == "true" ]] ||
  fail "Claude collector makes no request with an expired refresh token" "$dead"
pass "Claude collector makes no request with an expired refresh token"

# Every registered account refreshes in its own home, under its own locks.
homes=$(refresh_run two_homes)
[[ $(jq -c '.tokens' <<<"$homes") == '[["access-one","refresh-one-next"],["access-two","refresh-two-next"]]' && $(jq -c '.usageBearer' <<<"$homes") == '["Bearer access-one","Bearer access-two"]' ]] ||
  fail "Claude collector refreshes each account's own login" "$homes"
pass "Claude collector refreshes each account's own login"

# A signed-out machine says so, and still shows what it last knew.
signed_out=$(collect_limits "" 0 0 "$cache")
[[ $(jq -r '.usageStatusText' <<<"$signed_out") == "Waiting for auth" ]] ||
  fail "Claude collector still reports a missing token" "$signed_out"
[[ $(jq -c '[.limits[].label]' <<<"$signed_out") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector serves open cached windows without a token" "$signed_out"
pass "Claude collector serves open cached windows without a token"

# The limits cache is a last-known fallback governed by each window's reset
# time, not by the file's age. A backwards clock correction must not discard
# an otherwise open fallback when no token is available to replace it.
future_fallback=$(collect_limits "" 0 0 "$cache" 3600)
[[ $(jq -c '[.limits[].label]' <<<"$future_fallback") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector keeps open fallback limits after a backwards clock correction" "$future_fallback"
pass "Claude collector keeps open fallback limits after a backwards clock correction"

# A live token that cannot reach the endpoint keeps the old contract: the open
# window stands in, and the shell is asked to retry sooner than its interval.
unreachable=$(collect_limits "token" 0 0 "$cache")
[[ $(jq -c '[.limits[].label]' <<<"$unreachable") == '["Session (5-hour)","Weekly (7-day)"]' ]] ||
  fail "Claude collector falls back to cache when the probe cannot connect" "$unreachable"
[[ $(jq -r '.retryAdvised' <<<"$unreachable") == "true" ]] ||
  fail "Claude collector advises a retry after a transport failure" "$unreachable"
pass "Claude collector falls back to cache when the probe cannot connect"

# Reuse and --force are decided against a cache that is fresh by the clock, so
# the probe is answered rather than refused: what matters is whether it ran.
probe_with_cache() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" FORCE="$1" CACHED="$2" PAYLOAD="$3" CACHE_MTIME_OFFSET="${4:-0}" \
    XDG_CACHE_HOME="$CACHE_HOME" python3 - <<'PY'
import importlib.machinery, importlib.util, io, json, os, time

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

cache = collector.cache_root() / "claude-limits.json"
cache.write_text(os.environ["CACHED"], encoding="utf-8")
offset = float(os.environ["CACHE_MTIME_OFFSET"])
if offset:
  timestamp = time.time() + offset
  os.utime(cache, (timestamp, timestamp))

probes = []

def urlopen(request, timeout=None):
  probes.append(1)
  return io.BytesIO(os.environ["PAYLOAD"].encode())

collector.urllib.request.urlopen = urlopen
result = collector.collect_limits("token", 0, 0, os.environ["FORCE"] == "true")
print(json.dumps({
  "result": result,
  "probes": len(probes),
  "cached": json.loads(cache.read_text(encoding="utf-8")),
}))
PY
}

fresh=$(jq -nc --arg open "$open_at" --argjson now "$(python3 -c 'import time; print(round(time.time() * 1000))')" '{
  fetchedAtMs: $now,
  limits: [{ label: "Weekly (7-day)", percent: 0.11, resetsAt: $open }]
}')
payload='{"five_hour":{"utilization":44.0}}'

# Repeated panel opens share one answer rather than one request apiece.
reused=$(probe_with_cache false "$fresh" "$payload")
[[ $(jq -r '.probes' <<<"$reused") == "0" && $(jq -c '[.result.limits[].percent]' <<<"$reused") == "[0.11]" ]] ||
  fail "Claude collector reuses a cache younger than the probe interval" "$reused"
[[ $(jq -r '.result.authHelpText' <<<"$reused") == "" ]] ||
  fail "Claude collector clears login guidance when reusing authenticated limits" "$reused"
pass "Claude collector reuses a cache younger than the probe interval"

# An early boot probe can be stamped ahead of corrected wall time when NTP
# moves the clock backwards. That cache must not suppress live probes until
# the clock catches up.
future=$(jq -nc --arg open "$open_at" --argjson future "$(python3 -c 'import time; print(round((time.time() + 3600) * 1000))')" '{
  fetchedAtMs: $future,
  limits: [{ label: "Weekly (7-day)", percent: 0.11, resetsAt: $open }]
}')

# If the clock correction makes a probe necessary but that probe cannot
# connect, the cache remains the last-known answer. Its reset time, rather than
# its future mtime, decides whether the fallback is still usable.
future_unreachable=$(collect_limits "token" 0 0 "$future" 3600)
[[ $(jq -c '[.limits[].percent]' <<<"$future_unreachable") == "[0.11]" && $(jq -r '.retryAdvised' <<<"$future_unreachable") == "true" ]] ||
  fail "Claude collector keeps future-dated fallback when the re-probe fails" "$future_unreachable"
pass "Claude collector keeps future-dated fallback when the re-probe fails"

# Numbers stamped in the future have no age to trust, so a kept fallback is
# reported as stale rather than as measured just now.
[[ $(jq -r '.live' <<<"$future_unreachable") == "false" ]] ||
  fail "Claude collector marks a future-dated fallback stale" "$future_unreachable"
pass "Claude collector marks a future-dated fallback stale"

corrected=$(probe_with_cache false "$future" "$payload" 3600)
[[ $(jq -r '.probes' <<<"$corrected") == "1" && $(jq -c '[.result.limits[].percent]' <<<"$corrected") == "[0.44]" ]] ||
  fail "Claude collector re-probes after a backwards clock correction" "$corrected"
pass "Claude collector re-probes after a backwards clock correction"

# --force is someone pressing refresh, and its help text promises the caches are
# ignored — so the reuse window must not outrank it.
forced=$(probe_with_cache true "$fresh" "$payload")
[[ $(jq -r '.probes' <<<"$forced") == "1" ]] ||
  fail "Claude collector re-probes on --force despite a fresh cache" "$forced"
[[ $(jq -c '[.result.limits[].percent]' <<<"$forced") == "[0.44]" ]] ||
  fail "Claude collector returns the forced probe's numbers" "$forced"
[[ $(jq -r '.result.authHelpText' <<<"$forced") == "" ]] ||
  fail "Claude collector clears login guidance after a successful probe" "$forced"
pass "Claude collector re-probes on --force despite a fresh cache"

# A probe that lands becomes the next run's fallback.
[[ $(jq -c '[.cached.limits[].percent]' <<<"$forced") == "[0.44]" ]] ||
  fail "Claude collector caches a successful probe" "$forced"
pass "Claude collector caches a successful probe"

# The panel reads a window out of a label, and that guess cannot survive a
# model name — "Opus 5 (1M context)" parses as a one-minute window. A collector
# that states the title outright is taken at its word.
run_node_test <<'JS'
const fs = require('fs')
const source = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')
const panelRoot = { nowMs: Date.now() }
const start = source.indexOf('function windowIsLong')
const end = source.indexOf('// The window that decides')
assert(start > 0 && end > start, 'agents panel exposes its limit-window helpers')
eval(source.slice(start, end).replaceAll('root.nowMs', 'panelRoot.nowMs'))
eval(source.slice(source.indexOf('function needsSignIn'), source.indexOf('// A section with no limits to draw')))

const paused = { usageStatusText: 'Limits paused', limits: [] }
assertEqual(pausedWithoutLimits(paused), true, 'paused usage without a cache shows a recovery placeholder')
assertEqual(otherTrouble(paused), '', 'paused usage never puts the confusing status in the header')
assertEqual(pausedWithoutLimits({ ...paused, limits: [{ label: 'Session (5-hour)', percent: 0, resetsAt: '' }] }), false, 'cached usage replaces the recovery placeholder')
assertEqual(pausedWithoutLimits({ usageStatusText: 'Sign-in expired', limits: [] }), false, 'expired sign-ins retain their sign-in action')
assertEqual(pausedWithoutLimits(null), false, 'missing records do not show a paused-usage placeholder')

assertDeepEqual(
  limitWindows({ limits: [
    { label: 'Session (5-hour)', percent: 0.78, resetsAt: '' },
    { label: 'Opus 5 (1M context) Weekly', title: 'Opus 5 (1M context) Weekly', percent: 0.42, resetsAt: '' }
  ] }),
  [
    { title: 'Session', percent: 0.78, resetAt: '' },
    { title: 'Opus 5 (1M context) Weekly', percent: 0.42, resetAt: '' }
  ],
  'agents panel titles a limit off the collector when it states one'
)

assertDeepEqual(
  limitWindows({ limits: [{ label: 'Weekly (7-day)', percent: 0.12, resetsAt: '' }] }),
  [{ title: 'Weekly', percent: 0.12, resetAt: '' }],
  'agents panel still reads a window out of a label that carries no title'
)

const resetAt = new Date(panelRoot.nowMs + 1000).toISOString()
const measured = { limits: [{ label: 'Session (5-hour)', percent: 0.78, resetsAt: resetAt }] }
assertEqual(limitWindows(measured)[0].percent, 0.78, 'usage remains until the reset time')
panelRoot.nowMs += 1000
assertDeepEqual(limitWindows(measured), [{ title: 'Session', percent: 0, resetAt: '', elapsed: true }], 'usage resets at the deadline while the panel stays open')
assertEqual(measured.limits[0].percent, 0.78, 'display reset leaves the measured record intact')

// A model's weekly allowance rides under the Weekly row; one whose window has
// no row of its own keeps a row.
assertDeepEqual(
  displayWindows({ limits: [
    { label: 'Session (5-hour)', percent: 0.94, resetsAt: '' },
    { label: 'Weekly (7-day)', percent: 0.25, resetsAt: 'w' },
    { label: 'Fable Weekly', title: 'Fable Weekly', percent: 0.09, resetsAt: 'w' },
    { label: 'Opus Monthly', title: 'Opus Monthly', percent: 0.5, resetsAt: '' }
  ] }),
  [
    { title: 'Session', percent: 0.94, resetAt: '', scoped: [] },
    { title: 'Weekly', percent: 0.25, resetAt: 'w', scoped: [{ title: 'Fable', percent: 0.09, resetAt: 'w' }] },
    { title: 'Opus Monthly', percent: 0.5, resetAt: '', scoped: [] }
  ],
  'agents panel shows a model-scoped window under the window it runs on'
)
JS

# Anthropic rate-limits its usage endpoint readily. A refused re-check of
# numbers measured minutes ago still describes the account; only older numbers
# count as stale, and either way the record says when they were measured.
rate_limited() {
  COLLECTOR="$ROOT/bin/omarchy-agent-usage-claude" FETCHED_AGO="$1" XDG_CACHE_HOME="$CACHE_HOME" python3 - <<'PY'
import datetime as dt, importlib.machinery, importlib.util, json, os, time, urllib.error

loader = importlib.machinery.SourceFileLoader("collector", os.environ["COLLECTOR"])
spec = importlib.util.spec_from_loader(loader.name, loader)
collector = importlib.util.module_from_spec(spec)
loader.exec_module(collector)

reset = (dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=3)).isoformat()
fetched = round((time.time() - float(os.environ["FETCHED_AGO"])) * 1000)
(collector.cache_root() / "claude-limits-rate.json").write_text(json.dumps(
  {"fetchedAtMs": fetched, "limits": [{"label": "Session (5-hour)", "percent": 0.4, "resetsAt": reset}]}))

def refused(request, timeout=None):
  raise urllib.error.HTTPError(request.full_url, 429, "Too Many Requests", {}, None)

collector.urllib.request.urlopen = refused
result = collector.collect_limits("token", int((time.time() + 3600) * 1000), 0, True, "claude-limits-rate.json")
print(json.dumps({"live": result["live"], "percent": result["limits"][0]["percent"], "fetched": result["fetchedAtMs"] == fetched}))
PY
}

[[ $(rate_limited 60) == '{"live": true, "percent": 0.4, "fetched": true}' ]] ||
  fail "a refused re-check of numbers a minute old still counts as current" "$(rate_limited 60)"
[[ $(rate_limited 1800) == '{"live": false, "percent": 0.4, "fetched": true}' ]] ||
  fail "a refused re-check of half-hour-old numbers counts as stale" "$(rate_limited 1800)"
pass "a rate-limited check only goes stale once the numbers are old"
