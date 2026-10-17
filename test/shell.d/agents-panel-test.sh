#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const panelSource = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')

assert(/function launchAgent\(\)/.test(panelSource), 'agents panel launches the default agent')
assert(/root\.bar\.run\("omarchy-agent --pick"\)/.test(panelSource), 'agents panel uses the desktop agent launcher')
assert(/if \(buttonCode === Qt\.RightButton\) root\.launchAgent\(\)/.test(panelSource), 'agents right click launches the agent')
assert(/else if \(buttonCode === Qt\.MiddleButton\) root\.refreshNow\(\)/.test(panelSource), 'agents middle click refreshes the limits')
assert(/else root\.toggle\(\)/.test(panelSource), 'agents left click still toggles the panel')
assert(!/if \(buttonCode === Qt\.RightButton\) root\.refreshNow\(\)/.test(panelSource), 'agents right click no longer refreshes')
assert(/if \(root\.addStage === "" \|\| root\.picking\) root\.moveKey\(dx, dy\)/.test(panelSource), 'arrows move the agents panel cursor on the page and while picking an agent to add')
assert(/target\.kind === "choice"\) chooseAddProvider\(/.test(panelSource), 'Enter on an agent to add chooses it')
assert(!/text: root\.addStage === "running" \? "Cancel" : "Back"/.test(panelSource), 'the hero X is the only way back from adding')
assert(/hasCursor: root\.hasKey\("add"\)/.test(panelSource) && /hasCursor: root\.hasKey\("launch"\)/.test(panelSource), 'the hero buttons take the keyboard cursor')
assert(/hasCursor: root\.hasKey\("starter", index\)/.test(panelSource), 'the starter tiles take the keyboard cursor')
assert(/root\.pointAt\("account", Number\(t\) - 1\)/.test(panelSource), 'number keys move the cursor to an account')
assert(/target\.kind === "launch"\) launchAgent\(\)/.test(panelSource), 'Enter on the launcher starts the default agent')
assert(/row\.push\(\{ kind: "autoswitch", index: entry \}\)/.test(panelSource), 'an inactive account offers Autoswitch and Use as separate stops')
assert(/kind: "signin", index: entry/.test(panelSource) && /kind: "providerSignin", index: p/.test(panelSource), 'Sign-in required links are keyboard stops')
assert(/target\.kind === "signin"\) signInAgain\(/.test(panelSource) && /target\.kind === "providerSignin"\) signInAgain\(/.test(panelSource), 'Enter on Sign-in required signs in again')
assert(/target\.kind === "autoswitch"\) setSwitchMode\(/.test(panelSource), 'Enter on Autoswitch flips the switch mode')
assert(/keyColumn = use >= 0 \? use : /.test(panelSource), 'moving up or down onto an account lands on Use')
assert(/Qt\.callLater\(function\(\) \{ if \(picking\) pointAt\("choice", 0\) \}\)/.test(panelSource), 'picking an agent to add starts with the first one focused')
assert(!/opacity: stale \?/.test(panelSource) && /I18n\.t\("agents\.lastUpdatedAgo"\)\.arg\(root\.formatDuration/.test(panelSource), 'stale limits say how old they are only on hover')
assert(/onPickingChanged: resetKeys\(\)/.test(panelSource), 'the cursor starts over when the agent list comes or goes')
assert(!/t === "a" \|\| t === "A"/.test(panelSource), 'adding an account has no hotkey; the + is the way in')
assert(/if \(!accounts\[a\]\.active\) \{/.test(panelSource) && /if \(row\.length > 0\) rows\.push\(row\)/.test(panelSource), 'the active account with nothing to fix is not a keyboard stop')
assert(/text: section\.provider \? \(root\.helpDisplayText\(section\.provider\.authHelpText\) \|\| root\.statusDisplayText\(section\.provider\.usageStatusText\) \|\| ""\) : ""/.test(panelSource), 'the trouble line falls back to the usage status when a record has no auth help')
assert(/case "Run `codex login` to authenticate\.":\s*return Commons\.I18n\.t\("agents\.helpRunToAuthenticate"\)\.arg\("`codex login`"\)/.test(panelSource), 'known collector help lines are translated at display, commands kept verbatim')
// A reworded collector line would silently fall back to English, so every
// fixed help line the collectors cache must still be one the panel maps.
for (const name of ['claude', 'codex', 'grok', 'fireworks']) {
  const collector = fs.readFileSync(root + '/bin/omarchy-agent-usage-' + name, 'utf8')
  const help = collector.match(/^AUTH_HELP = "([^"]+)"$/m)
  assert(help && panelSource.includes('case ' + JSON.stringify(help[1]) + ':'), name + ' auth help is translated in the panel')
}
const mainSource = fs.readFileSync(root + '/shell/plugins/agents/Main.qml', 'utf8')
assert(/var from = Math\.min\(0\.8, \(threshold - 15\) \/ 100\)/.test(mainSource), 'faster checks start 15 points below the switch threshold')
assert(/rows\.push\(\[\{ kind: "provider", index: p \}\]\)/.test(panelSource), "every agent's header is a keyboard stop")
assert(/reorderable: root\.addStage === "" && !root\.renaming/.test(panelSource) && /onEditingChanged: root\.renaming = editing/.test(panelSource) && /onReorderRequested: function\(dy\) \{ root\.reorderProvider\(dy\) \}/.test(panelSource), 'Ctrl+Up/Down moves the agent the cursor is in')
assert(/onReleased: root\.dropProvider\(\)/.test(panelSource), 'an agent can be dragged by its mark')
assert(/function moveProvider\(id, to\)/.test(mainSource) && /return orderedProviders\(result\)/.test(mainSource), 'the agents keep the order they were moved into')
const catcherSource = fs.readFileSync(root + '/shell/Ui/PanelKeyCatcher.qml', 'utf8')
assert(/if \(reorderable && \(event\.modifiers & Qt\.ControlModifier\)\)/.test(catcherSource), 'only panels that ask for it turn Ctrl+Up/Down into a reorder')
assert(/if \(\["account", "autoswitch", "signin"\]\.indexOf\(target\.kind\) < 0\) return -1/.test(panelSource), 'Ctrl+Up/Down does nothing outside an agent')

assert(/providerIcon: String\(record\.icon \|\| record\.id\)/.test(mainSource), 'a record can ask for another agent\'s mark without changing its id')
assert(/var mark = p\.providerIcon \|\| p\.providerId/.test(panelSource) && /"assets\/" \+ mark \+ "-light\.svg"/.test(panelSource), 'the panel resolves marks from the requested icon before the id')
assert(/window\.valueText = String\(extras\.valueText\)/.test(panelSource) && /lines\.push\(compact\.window\.detail\)/.test(panelSource), 'a limit with no reset can show what is left in place of a countdown, and detail in its tooltip')

assert(/coverage: coverageList\(record\.coverage\)/.test(mainSource), 'a record can list the agents a subscription covers')
assert(/coverage: section\.provider \? section\.provider\.coverage : \[\]/.test(panelSource) && /textFallback: false/.test(panelSource), 'the section header draws a mark for each covered agent, with no bar glyph standing in for a missing one')
assert(/PanelToolTip \{\s*visible: coverageHover\.hovered/.test(panelSource), 'each covered agent names itself on hover')
for (const mark of ['grok', 'grok-bot', 'cursor', 'claude', 'codex']) {
  assert(fs.existsSync(root + '/shell/plugins/agents/assets/' + mark + '.svg'), mark + ' has a mark')
}
for (const mark of ['grok', 'grok-bot', 'cursor', 'codex']) {
  assert(fs.existsSync(root + '/shell/plugins/agents/assets/' + mark + '-light.svg'), mark + ' has a light-surface twin')
}
for (const file of fs.readdirSync(root + '/shell/plugins/agents/assets')) {
  const svg = fs.readFileSync(root + '/shell/plugins/agents/assets/' + file, 'utf8')
  assert(!/<script|href=|url\(|<image|<style/i.test(svg.replace(/url\(#[^)]*\)/g, '')), file + ' carries no script, external reference, or embedded image')
}

// The shared pool's tokens: run the real functions.
const noteStart = panelSource.indexOf('function weekTokens(p)')
const noteEnd = panelSource.indexOf('// Sign an account that\'s already here in again')
assert(noteStart > 0 && noteEnd > noteStart, 'agents panel exposes the shared-pool helpers')
let providers = []
const Commons = { I18n: {
  tn: (key, count) => ({ arg: value => value + (count === 1 ? ' token' : ' tokens') + ' this week' }),
} }
const usage = { formatTokenCount: n => n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'K' : String(n) }
const week = tokens => [0, 0, 0, 0, 0, 0, tokens].map((messageCount, i) => ({ date: '2026-10-1' + i, messageCount }))
const pool = { providerId: 'cursor', providerName: 'X Subscription', ready: true, unified: true, limits: [{ title: 'Weekly', percent: 0.22 }], recentDays: week(900000), coverage: [{ id: 'grok', name: 'Grok' }, { id: 'grok-bot', name: 'Grok Bot' }, { id: 'cursor', name: 'Cursor' }] }
const grok = { providerId: 'grok', providerName: 'Grok', ready: true, unified: true, recentDays: week(300000), coverage: [{ id: 'grok', name: 'Grok' }, { id: 'grok-bot', name: 'Grok Bot' }] }
eval(panelSource.slice(noteStart, noteEnd))
providers = [pool, grok]
assertEqual(coveredTokensText(pool), '1.2M tokens this week \u00b7 Grok 300.0K \u00b7 Cursor 900.0K', 'the shared pool adds up its covered agents\' week and names each share')
providers = [{ ...pool, recentDays: [] }, grok]
assertEqual(coveredTokensText(providers[0]), '300.0K tokens this week', 'a single contributor is not itemized')
providers = [{ ...pool, recentDays: [] }, { ...grok, recentDays: [] }]
assertEqual(coveredTokensText(providers[0]), '', 'no tokens this week, no line')
assertEqual(coveredTokensText({ ...pool, coverage: [] }), '', 'an agent that covers nothing gets no shared-pool line')
assert(/text: section\.provider && section\.provider\.coverage && section\.provider\.coverage\.length > 0 \? root\.coveredTokensText\(section\.provider\) : ""/.test(panelSource), 'the shared-pool line shows only for a record with coverage')
// The header's weekly total and the shared pool's are the same sum of the same records.
assertEqual(weekTokens({ recentDays: week(900000) }), 900000, 'one agent\'s week is the sum of its days')
const everyAgent = [pool, grok].reduce((sum, p) => sum + weekTokens(p), 0)
assertEqual(everyAgent, 1200000, 'the header adds every agent\'s week, the pool\'s included')

const formatStart = panelSource.indexOf('function formatLimitPercent')
const formatEnd = panelSource.indexOf('// ---------------------------------------------------------------- balance')
assert(formatStart > 0 && formatEnd > formatStart, 'agents panel exposes usage format helpers')
function resetMsFor() { return 6 * 24 * 3600 * 1000 + 14 * 3600 * 1000 }
function formatDuration() { return '6d 14h' }
eval(panelSource.slice(formatStart, formatEnd))

assertEqual(formatLimitPercent(0), '0%', 'agents panel shows 0% when a pool is untouched')
assertEqual(formatLimitPercent(0.00177742), '1%', 'agents panel shows 1% after a sub-1% complimentary reset')
assertEqual(formatLimitPercent(0.04233), '4%', 'agents panel still rounds a mid-range dashboard percent')
assertEqual(formatLimitPercent(0.1467), '15%', 'agents panel still rounds a Grok week above 1%')
assertEqual(
  formatResetCaption({ resetEarly: true, periodStartedAt: '2026-09-01T15:47:23.732Z', resetAt: '2026-09-08T06:44:00.862Z' }),
  'Reset ' + formatShortDate('2026-09-01T15:47:23.732Z') + ' · Resets in 6d 14h',
  'agents panel names a complimentary Grok reset on the countdown'
)
assertEqual(
  formatResetCaption({ resetAt: '2026-09-08T06:44:00.862Z' }),
  'Resets in 6d 14h',
  'agents panel keeps a scheduled-week countdown without a reset label'
)
assert(/root\.formatLimitPercent\(compact\.window\.percent\)/.test(panelSource), 'agents panel tooltips use the fork percent helper')
assert(/root\.formatResetCaption\(compact\.window\)/.test(panelSource), 'agents panel tooltips name a complimentary reset')
JS
