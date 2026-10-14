#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command python3
require_command jq

test_tmp=$(mktemp -d)
trap 'rm -rf "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin"
cat >"$test_tmp/bin/omarchy-agent-usage-update" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$OMARCHY_TEST_REFRESH"
SH
chmod +x "$test_tmp/bin"/*
export OMARCHY_PATH="$ROOT"
export OMARCHY_TEST_ROOT="$test_tmp"
export OMARCHY_TEST_REFRESH="$test_tmp/refresh"
export PATH="$test_tmp/bin:$ROOT/bin:$PATH"
unset CLAUDE_CONFIG_DIR CODEX_HOME GROK_HOME

python3 - <<'PY'
import base64, copy, ctypes, importlib.machinery, importlib.util, json, os, subprocess, sys
from pathlib import Path

loader = importlib.machinery.SourceFileLoader("transfer", str(Path(os.environ["OMARCHY_PATH"]) / "bin/omarchy-agent-account-transfer"))
spec = importlib.util.spec_from_loader(loader.name, loader)
transfer = importlib.util.module_from_spec(spec)
loader.exec_module(transfer)
state = transfer.accounts
root = Path(os.environ["OMARCHY_TEST_ROOT"])

def machine(name):
  os.environ["HOME"] = str(root / name)
  os.environ["XDG_STATE_HOME"] = str(root / name / "state")
  Path.home().mkdir(exist_ok=True)

def claude(home, uuid, token):
  home.mkdir(parents=True, exist_ok=True)
  account_file = state.claude_account_file(home)
  existing = state.read_json(account_file) or {}
  existing["oauthAccount"] = {"accountUuid": uuid, "emailAddress": uuid + "@example.com"}
  transfer.write_json(account_file, existing)
  transfer.write_json(home / ".credentials.json", {"claudeAiOauth": {"accessToken": token, "refreshToken": "fake-refresh", "subscriptionType": "max"}})

machine("source")
claude(state.primary_home("claude"), "personal", "fake-personal")
config = state.read_json(Path.home() / ".claude.json")
config["mcpServers"] = {"private-source": "SOURCE_SETTINGS_SENTINEL"}
transfer.write_json(Path.home() / ".claude.json", config)
registry = state.load("claude")
registry["accounts"][0]["label"] = "Personal"
for label in ["Work", "Third"]:
  pending = state.begin("claude")
  claude(pending, label.lower(), "fake-" + label.lower())
  state.register("claude", label, pending)
registry = state.load("claude")
registry["accounts"][0]["label"] = "Personal"
registry.update(active="third", switch="auto", threshold=90)
state.save("claude", registry)
codex = state.primary_home("codex")
claims = base64.urlsafe_b64encode(json.dumps({"email": "codex@example.com"}).encode()).decode().rstrip("=")
transfer.write_json(codex / "auth.json", {"tokens": {"account_id": "codex-main", "access_token": "fake-codex", "id_token": "h." + claims + ".s"}})
grok = state.primary_home("grok")
transfer.write_json(grok / "auth.json", {"issuer": {"user_id": "grok-main", "email": "grok@example.com", "access_token": "fake-grok"}})
transfer.write_json(grok / "settings_cache.json", {"payload": json.dumps({"settings": {"subscription_tier_display": "SuperGrok"}})})
payload = transfer.export_accounts(["claude", "codex", "grok"])
transfer.validate(payload)
encoded = json.dumps(payload)
assert str(Path.home()) not in encoded, "source paths must not be exported"
assert "SOURCE_SETTINGS_SENTINEL" not in encoded, "only account metadata is exported"
assert set(payload["providers"]) == {"claude", "codex", "grok"}
(root / "payload.json").write_text(encoded)

machine("destination")
transfer.write_json(Path.home() / ".claude.json", {"mcpServers": {"local": "destination-settings"}, "projects": {"local": {"trusted": True}}})
for provider, incoming in payload["providers"].items():
  results = transfer.import_provider(provider, incoming, False)
  assert all("fake-" not in line for line in results), "status must not expose tokens"
registry = state.load("claude")
assert [a["label"] for a in registry["accounts"]] == ["Personal", "Work", "Third"]
assert registry["active"] == "third" and registry["switch"] == "auto" and registry["threshold"] == 90
assert state.read_json(Path.home() / ".claude.json")["mcpServers"] == {"local": "destination-settings"}
for account in registry["accounts"]:
  home = state.account_home("claude", account)
  assert str(home).startswith(str(Path.home()))
  assert (home / ".credentials.json").stat().st_mode & 0o777 == 0o600
  if not account["primary"]:
    assert (home / "projects").resolve() == (Path.home() / ".claude/projects").resolve()
    assert state.read_json(home / ".claude.json")["mcpServers"] == {"local": "destination-settings"}
assert state.identity("codex", state.primary_home("codex"))["accountId"] == "codex-main"
assert state.identity("grok", state.primary_home("grok"))["plan"] == "SuperGrok"

# Default copy is idempotent and never replaces an existing token.
claude(state.primary_home("claude"), "personal", "destination-token")
transfer.import_provider("claude", payload["providers"]["claude"], False)
assert state.read_json(state.primary_home("claude") / ".credentials.json")["claudeAiOauth"]["accessToken"] == "destination-token"
assert len(state.load("claude")["accounts"]) == 3

# Explicit replacement rolls back credentials and new homes if commit fails.
original_save = state.save
def failed_save(provider, registry):
  raise OSError("disk full")
state.save = failed_save
try:
  transfer.import_provider("claude", payload["providers"]["claude"], True)
except OSError:
  pass
else:
  raise AssertionError("expected registry commit failure")
state.save = original_save
assert state.read_json(state.primary_home("claude") / ".credentials.json")["claudeAiOauth"]["accessToken"] == "destination-token"
assert not list(Path.home().rglob(".account-copy-backup-*"))
transfer.import_provider("claude", payload["providers"]["claude"], True)
assert state.read_json(state.primary_home("claude") / ".credentials.json")["claudeAiOauth"]["accessToken"] == "fake-personal"

# Detect a native CLI using the primary home without a config-dir variable.
code = 'import ctypes,time; ctypes.CDLL(None).prctl(15,b"claude",0,0,0); print("ready",flush=True); time.sleep(30)'
child = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True)
try:
  assert child.stdout.readline().strip() == "ready"
  try:
    transfer.import_provider("claude", payload["providers"]["claude"], True)
  except state.AccountError as error:
    assert "running" in str(error)
  else:
    raise AssertionError("must refuse to replace a running primary login")
finally:
  child.terminate()
  child.wait()

# A pinned primary session is detected even with an unrelated process name.
child_env = dict(os.environ, OMARCHY_AGENT_CLAUDE_HOME="")
child = subprocess.Popen([sys.executable, "-c", 'import time; print("ready",flush=True); time.sleep(30)'], env=child_env, stdout=subprocess.PIPE, text=True)
try:
  assert child.stdout.readline().strip() == "ready"
  assert transfer.home_in_use("claude", state.primary_home("claude"))
finally:
  child.terminate()
  child.wait()

# Native release names and interpreter-hosted CLIs are also recognized.
child_env = dict(os.environ)
for key in ["OMARCHY_AGENT_CLAUDE_HOME", "OMARCHY_AGENT_CODEX_HOME", "CLAUDE_CONFIG_DIR", "CODEX_HOME"]:
  child_env.pop(key, None)
release = root / "codex-x86_64-release"
release.symlink_to(sys.executable)
child = subprocess.Popen([str(release), "-c", 'import time; print("ready",flush=True); time.sleep(30)'], env=child_env, stdout=subprocess.PIPE, text=True)
try:
  assert child.stdout.readline().strip() == "ready"
  assert transfer.home_in_use("codex", state.primary_home("codex"))
finally:
  child.terminate()
  child.wait()
script = root / "claude" / "cli.py"
script.parent.mkdir()
script.write_text('import time; print("ready",flush=True); time.sleep(30)')
for name, expected in [("node", True), ("nvim", False)]:
  executable = root / name
  executable.symlink_to(sys.executable)
  child = subprocess.Popen([str(executable), str(script)], env=child_env, stdout=subprocess.PIPE, text=True)
  try:
    assert child.stdout.readline().strip() == "ready"
    assert transfer.home_in_use("claude", state.primary_home("claude")) == expected
  finally:
    child.terminate()
    child.wait()

# Abrupt receiver death after copying files is recovered on the next refresh.
machine("interrupted")
transfer.write_json(Path.home() / ".claude.json", {"mcpServers": {"local": "interrupted-settings"}})
code = """
import importlib.machinery, importlib.util, json, os, sys
from pathlib import Path
loader = importlib.machinery.SourceFileLoader("transfer", str(Path(os.environ["OMARCHY_PATH"]) / "bin/omarchy-agent-account-transfer"))
spec = importlib.util.spec_from_loader(loader.name, loader)
transfer = importlib.util.module_from_spec(spec)
loader.exec_module(transfer)
def crash(provider, registry):
  os._exit(78)
transfer.accounts.save = crash
transfer.import_provider("claude", json.load(sys.stdin), False)
"""
result = subprocess.run([sys.executable, "-c", code], input=json.dumps(payload["providers"]["claude"]), text=True)
assert result.returncode == 78
state.refresh("claude")
assert len(state.load("claude")["accounts"]) == 3
assert {a["accountId"] for a in state.load("claude")["accounts"]} == {"personal", "work", "third"}
assert not list(Path.home().rglob(state.LOGIN_RECEIPT))
for account in state.load("claude")["accounts"]:
  if not account["primary"]:
    home = state.account_home("claude", account)
    assert (home / "projects").is_symlink()
    assert state.read_json(home / ".claude.json")["mcpServers"] == {"local": "interrupted-settings"}

# A killed replacement leaves private backups; the next import removes them.
machine("destination")
claude(state.primary_home("claude"), "personal", "before-crash")
replace_code = code.replace('False)', 'True)')
result = subprocess.run([sys.executable, "-c", replace_code], input=json.dumps(payload["providers"]["claude"]), text=True)
assert result.returncode == 78
folders = list(Path.home().rglob(".account-copy-backup-*"))
assert folders and all(p.is_dir() and p.stat().st_mode & 0o777 == 0o700 for p in folders)
transfer.import_provider("claude", payload["providers"]["claude"], False)
assert not list(Path.home().rglob(".account-copy-backup-*"))
assert state.read_json(state.primary_home("claude") / ".credentials.json")["claudeAiOauth"]["accessToken"] == "fake-personal"

# An unrelated destination primary stays in place; source Main is additional.
machine("existing")
claude(state.primary_home("claude"), "local", "local-token")
registry = state.load("claude")
registry["accounts"][0]["label"] = "Personal"
state.save("claude", registry)
transfer.import_provider("claude", payload["providers"]["claude"], False)
assert state.identity("claude", state.primary_home("claude"))["accountId"] == "local"
assert len(state.load("claude")["accounts"]) == 4
assert [a["label"] for a in state.load("claude")["accounts"]][:2] == ["Personal", "Personal 2"]
assert state.load("claude")["active"] == "main"
assert state.load("claude")["switch"] == "manual" and state.load("claude")["threshold"] == 95

# Reject invalid preferences before any credentials are written.
bad = copy.deepcopy(payload)
bad["providers"]["claude"]["threshold"] = float("inf")
try:
  transfer.validate(bad)
except state.AccountError:
  pass
else:
  raise AssertionError("must reject invalid preferences")

# Reject arbitrary paths and non-account Claude configuration before writes.
bad = copy.deepcopy(payload)
bad["providers"]["claude"]["accounts"][0]["files"]["../../bad"] = {}
try:
  transfer.validate(bad)
except state.AccountError:
  pass
else:
  raise AssertionError("must reject arbitrary files")
bad = copy.deepcopy(payload)
bad["providers"]["claude"]["accounts"][0]["files"][".claude.json"]["mcpServers"] = {}
try:
  transfer.validate(bad)
except state.AccountError:
  pass
else:
  raise AssertionError("must reject imported local settings")
PY
pass "account transfer copies all providers, rebuilds homes, preserves settings, and protects existing logins"

cat >"$test_tmp/bin/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$@" >"$OMARCHY_TEST_ROOT/ssh-args"
[[ $1 == "-T" && $2 == "--" && $3 == "user@remote" ]] || exit 99
exec env HOME="$OMARCHY_TEST_ROOT/ssh-destination" XDG_STATE_HOME="$OMARCHY_TEST_ROOT/ssh-destination/state" bash -c "$4"
SH
chmod +x "$test_tmp/bin/ssh"
mkdir -p "$test_tmp/ssh-destination"
HOME="$test_tmp/source" XDG_STATE_HOME="$test_tmp/source/state" omarchy-agent-account-copy user@remote claude >"$test_tmp/copy-output"
[[ $(sed -n '4p' "$test_tmp/ssh-args") == "omarchy-agent-account-transfer import" ]] || fail "SSH invokes the fixed receiver command"
[[ $(jq '.accounts | length' "$test_tmp/ssh-destination/state/omarchy/agents/accounts/claude.json") == 3 ]] || fail "SSH copy imports all three Claude subscriptions"
[[ $(cat "$test_tmp/copy-output") != *fake-* ]] || fail "copy output contains no tokens"
[[ ! -e $test_tmp/ssh-destination/state/omarchy/agents/accounts/codex.json ]] || fail "provider selection excludes other subscriptions"
pass "SSH streams selected accounts to the receiver without exposing tokens"

HOME="$test_tmp/source" XDG_STATE_HOME="$test_tmp/source/state" omarchy-agent-account-copy --replace user@remote claude >"$test_tmp/replace-output"
[[ $(sed -n '4p' "$test_tmp/ssh-args") == "omarchy-agent-account-transfer import --replace" ]] || fail "replacement requires an explicit option"
pass "SSH copy forwards explicit replacement"

rm -f "$test_tmp/ssh-args"
if HOME="$test_tmp/source" XDG_STATE_HOME="$test_tmp/source/state" omarchy-agent-account-copy user@remote unknown >"$test_tmp/bad-output" 2>&1; then
  fail "invalid providers fail before SSH"
fi
[[ ! -e $test_tmp/ssh-args ]] || fail "invalid providers do not start SSH"
pass "invalid providers do not start SSH"

HOME="$test_tmp/source" XDG_STATE_HOME="$test_tmp/source/state" omarchy-agent-account-copy user@remote --replace claude >"$test_tmp/replace-after-output"
[[ $(sed -n '4p' "$test_tmp/ssh-args") == "omarchy-agent-account-transfer import --replace" ]] || fail "replacement can appear after the host"
pass "replacement can appear after the host"
