# Agents

One bar icon and one panel for every AI coding subscription on the machine.
The panel is strictly a display: it watches the usage records that
`omarchy-agent-usage-update` writes to `~/.local/state/omarchy/agents/usage/`
and draws whatever appears there. `Panel.qml` owns the bar button and the
popup; `Main.qml` discovers and watches the records (and handles the optional
cross-device aggregation); `Agent.qml` is the per-record file watcher.

## Panel

Every subscription on one page, limits first.

- **Hero** — the agents robot, and a line that rotates through what the
  token counts add up to across every agent: tokens this week and today, the
  most used model, the busiest day, and today's prompts and sessions. Its
  corner has + to add a subscription and >_ to start the default agent.
- **One section per agent** — its mark, name, and plan, then a compact line
  per limit window: its meter and the time until it resets (the exact percentage
  on hover). A model-scoped allowance on the same clock (Claude's Fable weekly
  limit) is a tick on that window's meter rather than a line of its own; the
  row's tooltip names it. A lapsed or missing sign-in shows a _Sign-in required_ link that signs
  that account in again from the panel; other endpoint trouble shows under the
  name in the urgent color. Limits kept from an earlier check after a failed one dim, and their
  tooltip says how old they are.
- **Accounts** — an agent with more than one subscription account (see
  `omarchy agent account`) lists each: name and plan on one line (the email on hover), and its own limit
  lines. An _ACTIVE_ label marks the account new sessions start as; the
  others get a _Use_ link. Hovering the line also reveals Autoswitch, which
  moves new sessions over on their own once the active account reaches its
  threshold; while it's on it stands in for Use, which shows only when you're
  on the line, and clicking it again goes back to notifying. Click a name to
  rename the account in place.
- **Balance** — prepaid agents show a credit ledger instead of limits: a
  fuel-gauge meter that drains toward empty, the remaining credit, and
  funded-versus-spent detail.
- **Make something cool** — starter prompts (a new theme, plugin, or app) that
  start the default agent on the task through `omarchy agent prompt`.
- **Adding a subscription** — the + in the hero's corner swaps the page for
  Claude Code, Codex, and Grok as large marks, three across, with the first
  one focused, and the hero's line reads Add an account. The + becomes the
  X that goes back. An agent that can't be added is dimmed and says why on
  hover. A further account asks for a name first, and Enter signs it in. The
  panel then runs `omarchy-agent-account-add --events` and follows it: the
  status, the code Grok asks you to confirm in the browser, a field to paste
  Claude's code back if its page shows one instead of finishing, and a link to
  reopen the sign-in page. Esc or the X stops the login. The browser taking focus may close the panel; the sign-in
  carries on and its result arrives as a notification.

The icon is always in the bar. On a machine with no agent yet, the panel is
the blank slate for setting one up: it opens on the same choice of Claude,
Codex, or Grok, and the first agent signed in becomes the default agent if
none was picked. An agent appears once it is enabled in settings and has
recorded usage, on this machine or a synced one; a CLI installed
mid-session shows up at the next refresh. Drop the widget with
`omarchy plugin disable omarchy.agents`.

## Data

Each agent is one JSON record in `~/.local/state/omarchy/agents/usage/`,
written by `omarchy-agent-usage-update`. That command runs one
`omarchy-agent-usage-<agent>` collector per agent; the widget invokes it
on its refresh timer and whenever you ask for a refresh, and picks up any
record that lands in the directory regardless of who wrote it.

Adding an agent needs no QML changes: ship a collector that prints the record contract (see the `claude` and `codex` collectors in `bin/`), and the panel gains a section. An `assets/<id>.svg` mark is optional, with an `assets/<id>-light.svg` twin if the mark needs a dark variant for light surfaces; the bar glyph stands in when there is none.

| Collector | Limits | Local stats |
|---|---|---|
| `claude` | Anthropic's OAuth usage endpoint (5-hour session + 7-day weekly) | `~/.claude/projects` transcripts, opencode sessions on an Anthropic provider, plus `stats-cache.json` and `history.jsonl` as fallback |
| `codex` | The Codex app-server RPC | native Codex CLI session files on the built-in `openai` provider (plus pi and opencode sessions) |
| `cursor` | Cursor's dashboard session API, in one of two shapes (see _Cursor's two shapes_ below) | Aggregated token totals by model for the billing cycle, plus the last week of usage events |
| `grok` | The credits endpoint behind Grok's `/usage` view (the billing period's included usage; the unified X subscription's shared weekly pool), else the answer Grok's own log last recorded for a unified account | Each session's `usage.json` (the ledger `grok usage` prints: tokens by model per finished turn), plus `summary.json` for sessions |
| `fireworks` | Estimated prepaid balance: configured funding minus rated account costs | Fireworks billing API, grouped by day and model for the last 30 days |
| `kimi` | Kimi Code quotas (5-hour session, weekly, and monthly allowances) | none; quota only |

### Cursor's two shapes

The `cursor` collector decides per account which subscription it is looking at, from the dashboard's sand usage status (`isUnified`), falling back to a `unified_*` membership type when that status is unavailable, and prints a different record for each.

- **Cursor subscription** (legacy plans): a section named _Cursor_ with Cursor Models and Other Models meters for the billing cycle, plus Grok Bot's own weekly meter, which counts down to its own reset and notes a complimentary mid-week reset.
- **X subscription** (the unified plan): a section named _X Subscription_ that wears Grok's mark, shows the tier at its right (Free, Plus, Premium, Super, or Ultra; see _Plan names_ below), and carries small marks for Grok, Grok Bot, and Cursor beside the name (hover one for its name). Cursor's own models, Grok, and Grok Bot all draw from one weekly pool, so there is one _Weekly_ meter for it, with its reset and any mid-week start. Third-party models (Anthropic, OpenAI, Gemini, …) are paid from separately bought top-up credit instead, which gets a _Top-up Credit_ meter, but only once credit exists: bought credit grants, or an on-demand spend limit that is switched on. The meter fills as the credit is spent, shows the dollars left where a countdown would be (the tooltip gives left of total), and has no reset.

The last unified detection is remembered per account in `~/.cache/omarchy/agent-usage/cursor-plan.json` (the user id and plan name, never the session), so a dashboard that errors out (a lapsed session, no network) still prints the section as _X Subscription_ instead of flipping back to _Cursor_. Cursor's saved membership in `state.vscdb` outranks the memory when it is readable: `unified_*` stands on its own, anything else clears it, and a legacy detection from the dashboard clears it too.

The record keeps `id: "cursor"` in both shapes, so caches, ordering, and the `providers` setting are unaffected. A record asks for another agent's mark with `"icon": "<id>"`; the panel looks for `assets/<icon>.svg` (and its `-light` twin) before falling back to the id. A record can also carry `"coverage": [{"id": "grok", "name": "Grok"}, …]`, the agents one subscription pays for: each draws its `assets/<id>.svg` mark (and `-light` twin) in a small row beside the section name, with `name` as the tooltip. Only the unified X subscription sets it, together with `"unified": true` (a legacy record says `false`); the Grok collector reads that flag as a hint that its own account is unified. Under the meter the section adds a dim line with the week's tokens across the covered agents that have records (Cursor's own plus Grok's local stats, itemized when more than one contributed), and, when a covered agent's own section is left out (see below), a note that its usage counts toward the subscription. A limit with no reset can carry `valueText` (shown where the countdown would be) and `detail` (an extra tooltip line).

### Plan names

The label beside the section name comes from the plan the account is actually on.

- **Unified X subscription** (tiers Free, Plus, Premium, Super, Ultra; teams get per-seat Premium, Super, and Ultra, and Enterprise is custom): Cursor's sand usage status `cursorPlanName`, which is the name the Grok Bot app shows, but only when the same status says `isUnified`. `get-plan-info`'s `planName` cross-checks it when the status has none. Cursor's saved or dashboard `membershipType` is not reliable for the unified tiers (its client enum is free, pro, pro_plus, enterprise, free_trial, ultra, pro_student, express, premium, plus, super and unified_ultra, and an unknown value reads as free), so it is the last resort: a `unified_` prefix is dropped and the value mapped to Free, Pro, Pro+, Trial, Student, Enterprise, Express, Ultra, Premium, Plus, or Super, and an unknown one is title-cased. The sand status's `grokPlanLabel` ("Grok Bot Plan") is a placeholder and is ignored.
- **Cursor subscription** (legacy Cursor Pro, Pro+, Ultra): `get-plan-info`'s `planName` verbatim, else the membership mapped as above.
- **Grok alone** (SuperGrok without Cursor): `subscription_tier_display` from `~/.grok/settings_cache.json` verbatim, else the `subscription_tier` enum (x_basic is X Basic, x_premium X Premium, x_premium_plus X Premium+, supergrok_lite SuperGrok Lite, supergrok SuperGrok, supergrok_plus SuperGrok Plus, supergrok_heavy SuperGrok Heavy), and an unknown value is title-cased with underscores as spaces. A unified Grok-only record shows this value, which can name the legacy plan the account was linked from (SuperGrok Heavy where Cursor says Ultra).

The Plus and Free tiers include no Grok Bot, so on either one both collectors leave it out of `coverage`.

### Grok limits

Grok's credits endpoint answering with an error, or not at all, is different from a lapsed sign-in. A rejected token (401/403) keeps the last credits and asks to sign in, and an access token that has merely expired while Grok wasn't running rolls the last credits forward, as before. But when the request was made and failed (a server error, a network failure, an answer that isn't credits), the cached numbers are dropped and the record says `Limits paused` with no help text.

Accounts on the unified X subscription share one weekly pool with Grok Bot and Cursor's own models. The collector always asks the credits endpoint: an answer with `isUnifiedBillingUser` carries `creditUsagePercent` and `currentPeriod`, which becomes the _Weekly_ limit. The endpoint has been answering these accounts with a server error, so the collector falls back to the last `billing: fetched credits config` entry in Grok's own log (`logs/unified.jsonl` in the Grok home), but only a unified one logged within the last hour, rolled past a reset, and dated by when Grok logged it (so the panel marks it stale as it ages). Whether an account is unified is known from, in order, the credits answer, that log entry, the Cursor record's `unified: true` (primary home only), and what an earlier run remembered in the limits cache. Nothing in `settings_cache.json` or `auth.json` says it. A unified Grok record is named _X Subscription_ (`"icon": "grok"`, `"coverage"` of Grok and Grok Bot, `"unified": true`); with no pool obtainable it keeps those fields and `Limits paused`, which the panel shows as a quiet "Usage unavailable" instead of hiding the section. Because Cursor spends the same pool while Grok sits idle, a unified pool kept past a lapsed access token is marked stale rather than treated as current.

The collector never defers to another record. The panel decides which record draws the pool: a unified Grok record is left out when another shown record whose `coverage` lists Grok has a pool of its own to draw (Cursor's X Subscription), so an X Subscription section appears once. Without such a record (SuperGrok without Cursor, or Cursor signed out), Grok's own section shows the pool.

### Sections with nothing to show

An agent whose record says `Limits paused` (Grok does so after a failed credits call, or when its token has lapsed with no numbers cached), has no limits, no balance, no help text (`authHelpText`), and fewer than two accounts has nothing to draw and nothing to act on, so the panel leaves its section out (and its keyboard stop and drag slot). Its local stats still count in the hero's totals and the bar. So it isn't mistaken for missing, a small dim line at the foot of the page reads "<agent> limits unavailable", unless a shown subscription covers it (see `coverage`), whose coverage marks already account for it, in which case there is no line. An agent that is still loading (no status yet), signed out, or carrying any help line (Claude Code's lapsed access token while a refresh keeps failing, for one) keeps its section, so those messages are never hidden. A record with `"unified": true` is the exception in both directions: it is never left out for having nothing to show (it reads "Usage unavailable"), and always left out when a shown record covers it.

### Stale limits

A record whose `limitsStale` is true with a `limitsFetchedAt` more than 15 minutes old (or none) is showing the last known numbers, not the present. The panel says so in plain view, for every agent and each account: the meters are drawn muted and never alarm, a window whose reset has passed since is drawn as unknown (an empty meter and a dash) rather than as 0%, and a dim line under the meters reads "Last updated 3h ago" followed by the collector's `authHelpText` when it has one (Claude's "access token has lapsed" explanation, say). A lapsed or missing sign-in additionally keeps its _Sign-in required_ link above the meters. A younger stale record only says so in the meters' tooltips.

When `~/.local/state/omarchy/agents/accounts/<claude|codex|grok>.json`
registers more than one account, the `claude`, `codex`, and `grok` records
also carry
`accounts: [{ id, label, email, plan, active, limits, stale, usageStatusText,
authHelpText }]`, each account probed with its own sign-in (Claude caches each
account's limits separately; Codex runs one app-server per account home), and
`accountSwitch: { mode, threshold }`. The record's top-level `limits` and
`tierLabel` keep describing the active account, and local stats stay one set,
since every account shares the primary home's history. After each run,
`omarchy-agent-usage-update` hands the fresh limits to
`omarchy-agent-account-state autoswitch`, which notifies or switches when the
active account crosses its threshold, and re-collects the record if the active
account changed.

Codex CLI will front any OpenAI-compatible backend — `--oss`, or a custom `model_provider` in `config.toml` aimed at Ollama, LM Studio, or a gateway — and those rollouts sit in the same sessions directory as OpenAI-backed ones. The Codex collector skips a rollout whose first `session_meta.model_provider` names anything but the built-in `openai` provider. Rollouts written before Codex recorded that field carry no provider and still count.

Claude limits need a signed-in CLI; without credentials the panel says so and
falls back to local stats only. A non-default Claude directory is honored via
`CLAUDE_CONFIG_DIR`, Codex via `CODEX_HOME`, Grok via `GROK_HOME`. Cursor
reads the session the Cursor app already stored in `state.vscdb` (or
`CURSOR_SESSION_TOKEN`). Grok's plan comes from the settings it caches in
its home, and its limit from the credits endpoint its own `/usage` view
reads, asked with each account's sign-in; a sign-in left to lapse shows the
last credits until Grok runs again, while a credits request that fails drops them (a unified account falls back to the pool Grok last logged). Fireworks reads
`FIREWORKS_API_KEY` and `FIREWORKS_ACCOUNT_ID` first, then
`~/.fireworks/auth.ini` (which `firectl set-api-key` creates), then the key
pi stores in `~/.pi/agent/auth.json` when Fireworks is signed in there
(honoring `PI_CODING_AGENT_DIR`, and pi's literal and `$ENV_VAR` key forms),
and finally the key opencode stores in `~/.local/share/opencode/auth.json`.

Kimi reads `KIMI_API_KEY` first, then `credentials/kimi-code.json` under an explicit `KIMI_CODE_HOME`. Without that override it prefers `~/.kimi-code/credentials/kimi-code.json`, with the legacy `~/.kimi/credentials/kimi-code.json` as a compatibility fallback. An explicit home never borrows another home's sign-in. Its record reports account quotas, without local token or prompt statistics.

Expired tokens are refreshed under the current CLI's renewable directory lock at `<home>/oauth/kimi-code.lock`; legacy credentials use their sibling file lock. The rotated token pair is flushed and published atomically with private permissions. Credentials are reread after the exchange so a sign-in or logout completed during the request takes precedence. A failed lock prevents refresh, and credentials are sent only to trusted Kimi HTTPS hosts without following redirects. When sign-in expires, run `kimi login`; an invalid overriding `KIMI_API_KEY` must instead be updated or unset.

Limits probes reuse a result for one minute unless `--force` is requested. A failed probe retains the last-known limits with stale metadata. Cache identity follows the token used by the request, and a refresh this collector performs carries the same account's previous limits forward. Different credentials or endpoints never share cached quota.

### Fireworks balance

The collector first asks the account's `:getBalance` endpoint for the real
prepaid ledger. That endpoint exists but is permission-gated, and as of
August 2026 no console-issued API key passes it — Fireworks appears to
reserve it for the dashboard session. The probe stays because it is cheap
and the live figure lights up automatically if Fireworks ever opens it to
keys. Until then the collector falls back to estimating the balance from
configuration in `~/.config/omarchy/agents/fireworks.json`:

```json
{
  "accountId": "",
  "fundedAmount": 20,
  "fundedAt": "2026-07-01"
}
```

Set `fundedAmount` to the credits purchased and optionally `fundedAt` to the
purchase date; with no date, the collector uses the account creation time. It
subtracts rated account costs and the panel labels the result as estimated.
For a later top-up, increase `fundedAmount` by the new credit while keeping
the original `fundedAt`, so both the funding and spend still cover the same
period. `accountId` only matters when one API key can access several
accounts. Without a configured `fundedAmount` the tab still shows token
usage, just no balance. With a live ledger, `fundedAmount` is optional and
only adds the meter and the spent-of-funded line under the real figure.

## Interactions

- Bar icon: left = panel, right = launch agent, middle = refresh. It turns
  urgent when any account new sessions use is at 90% of a window, or a
  prepaid balance is down to its last 10%.
- Panel: the arrows (or `h`/`j`/`k`/`l`) walk a cursor over everything that
  does something, row by row: the hero's buttons, each agent's header, each
  switchable account (landing on Use, with Autoswitch to its left), and the
  starter tiles, or the agents to add. Ctrl+Up/Down (or Ctrl+`k`/`j`) moves the
  agent the cursor is in up or down the page; dragging an agent by its mark
  does the same, lighting the header it will land on. The order is kept in
  `~/.local/state/omarchy/agents/order.json`. Hovering moves the same cursor. Enter acts on it, or
  refreshes when nothing is lit; `r` refreshes, Tab moves to the neighboring
  bar panel, Esc closes.
- Accounts: `1`–`9` jump to an account across every agent, and Enter makes it
  active (picking alone never switches). `m` toggles automatic switching for
  the picked account's agent. While an agent
  with several accounts has its active one within 15 points of its switch
  threshold (80% at the default), the limits refresh every three minutes.
- IPC: `omarchy-shell omarchy.agents <open|close|toggle|refresh>`.

## Settings

Settings live in the widget's entry in `~/.config/omarchy/shell.json`. The
top-level keys can be set with
`omarchy bar set omarchy.agents <key> <value>`:

| Key | Default | What it does |
|---|---|---|
| `refreshIntervalSec` | `900` | How often the usage records regenerate |
| `syncMode` | `"Off"` | `"On"` writes this machine's snapshot and merges the others |
| `syncDir` | `""` | A folder synced by Syncthing, Dropbox, rsync, … |
| `syncFileName` | `<hostname>.json` | This machine's snapshot file |
| `syncDeviceId` | hostname | Stable device name inside the snapshot |

Numbers need `--json`, or they land in `shell.json` as strings:

```bash
omarchy bar set omarchy.agents refreshIntervalSec 300 --json
omarchy bar set omarchy.agents syncDir '~/Sync/agent-usage'
```

Per-agent enablement is nested, and `set` writes its key literally rather
than walking a dotted path — so pass the whole `providers` object as JSON (or
edit `shell.json` directly):

```bash
omarchy bar set omarchy.agents providers '{
  "claude": { "enabled": true },
  "codex": { "enabled": false },
  "cursor": { "enabled": true },
  "grok": { "enabled": true },
  "fireworks": { "enabled": true },
  "kimi": { "enabled": true }
}' --json
```

`enabled` defaults to `true` for every discovered agent; set it to `false` to
hide a subscription that is installed. Disabled agents are also skipped when
the records regenerate.

With `syncMode` on, every `*.json` snapshot in `syncDir` is merged, so today,
the last 7 days, and the all-time totals cover every machine you code on —
active days are unioned by date rather than summed. Rate limits stay
per-account and are never merged. A record may declare `"scope": "account"`
when its stats are account-global rather than machine-local (Fireworks'
billing API); those merge by taking the widest value instead of summing, so
the same account synced from two machines is not counted twice.

One caveat on "all-time": the Codex collector only reads native session files
touched in the last 30 days, and Fireworks requests the last 30 days from its
billing API, so their totals and day counts cover that window. Claude's cover
every transcript still on disk.
