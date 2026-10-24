#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const panelSource = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')

const signInFunctions = ['supportsSignIn', 'needsSignIn', 'otherTrouble'].map(name => {
  const match = panelSource.match(new RegExp('function ' + name + '\\([^]*?\\n  \\}'))
  return match ? match[0] : ''
}).join('\n')
const signIn = new Function('addProviders', signInFunctions + '\nreturn {needsSignIn, otherTrouble}')(
  [{providerId: 'claude'}, {providerId: 'codex'}, {providerId: 'grok'}]
)
for (const id of ['claude', 'codex', 'grok'])
  assert(signIn.needsSignIn({providerId: id, usageStatusText: 'Sign-in expired'}), id + ' keeps its sign-in link')
assert(signIn.needsSignIn({usageStatusText: 'Sign-in expired'}), 'account rows keep their sign-in link')
for (const status of ['Sign-in expired', 'Waiting for auth']) {
  assert(!signIn.needsSignIn({providerId: 'agy', usageStatusText: status}), 'an agent the panel cannot sign in gets no link for ' + status)
  assert(signIn.otherTrouble({providerId: 'agy', usageStatusText: status}) === status, 'an agent the panel cannot sign in still shows ' + status)
}
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
assert(/I18n\.t\("agents\.lastUpdatedAgo"\)\.arg\(formatDuration/.test(panelSource) && /lines\.push\(root\.lastUpdatedText\(compact\.fetchedAt\)\)/.test(panelSource), 'stale limits say how old they are on hover too')
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

// The hiding rule: pull the real functions out of the panel and run them.
const hideStart = panelSource.indexOf('function pausedWithoutLimits(item)')
const hideEnd = panelSource.indexOf('// The agents left off the page by hasNothingToShow()')
assert(hideStart > 0 && hideEnd > hideStart, 'agents panel exposes the section-hiding rule')
let shownProviders, hiddenProviders, providers = []
let limitWindows = p => (p.limits || []).filter(l => Number(l.percent) >= 0)
let providerAccounts = p => (p && p.accounts && p.accounts.length > 0 ? p.accounts : [])
eval(panelSource.slice(hideStart, hideEnd))
const paused = { usageStatusText: 'Limits paused', authHelpText: '', limits: [], accounts: [], balance: null }
assert(hasNothingToShow(paused), 'paused with no limits, help, balance or accounts is left off the page')
assert(!hasNothingToShow({ ...paused, authHelpText: 'Start Claude Code to refresh it.' }), 'paused with a line of help keeps its section')
assert(!hasNothingToShow({ ...paused, limits: [{ title: 'Weekly', percent: 0.2 }] }), 'paused with limits still shows them')
assert(!hasNothingToShow({ ...paused, balance: { remaining: 3 } }), 'a balance keeps the section')
assert(!hasNothingToShow({ ...paused, accounts: [{}, {}] }), 'several accounts keep the section')
assert(!hasNothingToShow({ ...paused, usageStatusText: '' }), 'an agent with no status is still loading, not silent')
assert(!hasNothingToShow({ ...paused, usageStatusText: 'Sign-in expired' }), 'a lapsed sign-in is never hidden')
assert(!hasNothingToShow({ ...paused, usageStatusText: 'Waiting for auth' }), 'a missing sign-in is never hidden')
assert(!hasNothingToShow({ ...paused, usageStatusText: 'Grok unavailable' }), 'other trouble is never hidden')
assert(/for \(var p = 0; p < shownProviders\.length; p\+\+\)/.test(panelSource) && /model: root\.addStage === "" \? root\.shownProviders : \[\]/.test(panelSource), 'the sections and keyboard rows read the shown agents')
assert(/usage\.moveProvider\(shownProviders\[from\]\.providerId, providers\.indexOf\(shownProviders\[to\]\)\)/.test(panelSource), 'reordering counts only the shown agents but moves within all of them')
assert(/for \(var i = 0; i < providers\.length; i\+\+\) \{\s*var p = providers\[i\]/.test(panelSource), 'the hero totals still add up every agent, shown or not')

// The notes for hidden agents and the shared pool's tokens: run the real functions.
const noteStart = panelSource.indexOf('function coversProvider(covering, hidden)')
const noteEnd = panelSource.indexOf('// Sign an account that\'s already here in again')
assert(noteStart > hideEnd && noteEnd > noteStart, 'agents panel exposes the hidden-agent and shared-pool helpers')
const catalog = {
  'agents.providerLimitsUnavailable': '%1 limits unavailable',
  'agents.lastUpdatedAgo': 'Last updated %1 ago',
  'agents.lastUpdatedJustNow': 'Last updated less than a minute ago',
  'agents.lastUpdatedUnknown': 'Last updated time unavailable',
}
const Commons = { I18n: {
  t: key => Object.assign(new String(catalog[key]), { arg: value => catalog[key].replace('%1', value) }),
  tn: (key, count) => ({ arg: value => value + (count === 1 ? ' token' : ' tokens') + ' this week' }),
} }
const usage = { formatTokenCount: n => n >= 1e6 ? (n / 1e6).toFixed(1) + 'M' : n >= 1e3 ? (n / 1e3).toFixed(1) + 'K' : String(n) }
const week = tokens => [0, 0, 0, 0, 0, 0, tokens].map((messageCount, i) => ({ date: '2026-10-1' + i, messageCount }))
const pool = { providerId: 'cursor', providerName: 'X Subscription', ready: true, unified: true, limits: [{ title: 'Weekly', percent: 0.22 }], recentDays: week(900000), coverage: [{ id: 'grok', name: 'Grok' }, { id: 'grok-bot', name: 'Grok Bot' }, { id: 'cursor', name: 'Cursor' }] }
const grok = { providerId: 'grok', providerName: 'Grok', ready: true, unified: true, recentDays: week(300000), coverage: [{ id: 'grok', name: 'Grok' }, { id: 'grok-bot', name: 'Grok Bot' }], ...paused }
const fireworks = { providerId: 'fireworks', providerName: 'Fireworks', recentDays: [], coverage: [], ...paused }
function panelState(allProviders) {
  providers = allProviders
  return {
    providers,
    shownProviders: providers.filter(p => !hasNothingToShow(p)),
    get hiddenProviders() { return providers.filter(p => this.shownProviders.indexOf(p) < 0) },
  }
}
eval(panelSource.slice(noteStart, noteEnd))
;({ providers, shownProviders, hiddenProviders } = panelState([pool, grok]))
assertEqual(coveredTokensText(pool), '1.2M tokens this week \u00b7 Grok 300.0K \u00b7 Cursor 900.0K', 'the shared pool adds up its covered agents\' week and names each share')
assertEqual(uncoveredHiddenText(), '', 'a hidden agent a shown record covers gets no footer line')
;({ providers, shownProviders, hiddenProviders } = panelState([pool, grok, fireworks]))
assertEqual(uncoveredHiddenText(), 'Fireworks limits unavailable', 'a hidden agent nothing covers gets a quiet footer line')
;({ providers, shownProviders, hiddenProviders } = panelState([{ ...pool, recentDays: [] }, grok]))
assertEqual(coveredTokensText(providers[0]), '300.0K tokens this week', 'a single contributor is not itemized')
;({ providers, shownProviders, hiddenProviders } = panelState([{ ...pool, recentDays: [] }, { ...grok, recentDays: [] }]))
assertEqual(coveredTokensText(providers[0]), '', 'no tokens this week, no line')
;({ providers, shownProviders, hiddenProviders } = panelState([{ ...pool, coverage: [] }, { ...grok, unified: false }]))
assertEqual(coveredTokensText({ ...pool, coverage: [] }), '', 'an agent that covers nothing gets no shared-pool line')
assertEqual(uncoveredHiddenText(), 'Grok limits unavailable', 'with no pool covering it, a hidden Grok is noted in the footer')

// One X subscription pool at a time. Grok's own record is the pool when no
// Cursor record covers it, and is left out when one does.
const grokPool = { ...grok, usageStatusText: '', limits: [{ title: 'Weekly', percent: 0.31 }] }
const grokLegacy = { ...grok, unified: false, coverage: [], usageStatusText: '', limits: [{ title: 'Weekly', percent: 0.31 }] }
const grokUnavailable = { ...grok }
const names = list => panelState(list).shownProviders.map(p => p.providerId).join(',')
assertEqual(names([pool, grokPool]), 'cursor', 'a Cursor pool that covers Grok stands in for a unified Grok pool: only one X Subscription section')
assertEqual(names([grokPool, pool]), 'cursor', 'the order the records arrive in does not bring the second pool back')
assertEqual(names([grokPool]), 'grok', 'with no Cursor record, a unified Grok shows the pool itself')
assertEqual(names([grokUnavailable]), 'grok', 'a unified Grok with no data stays visible, as Usage unavailable')
assert(pausedWithoutLimits(grokUnavailable), 'a unified Grok with no data draws the quiet Usage unavailable line')
assertEqual(names([pool, grokUnavailable]), 'cursor', 'a unified Grok with no data is left out when Cursor shows the pool')
assertEqual(names([{ ...pool, ready: false }, grokPool]), 'cursor,grok', 'a Cursor record that is not ready does not cover Grok')
assertEqual(names([{ ...pool, limits: [], usageStatusText: 'Sign-in expired' }, grokPool]), 'cursor,grok', 'a Cursor record with no pool to draw does not cover Grok')
assertEqual(names([{ ...pool, coverage: [{ id: 'cursor', name: 'Cursor' }] }, grokPool]), 'cursor,grok', 'a Cursor record that does not list Grok does not cover it')
assertEqual(names([pool, grokLegacy]), 'cursor,grok', 'a legacy Grok record with limits of its own is never folded into another pool')
assertEqual(names([pool, { ...grokPool, usageStatusText: 'Sign-in expired' }]), 'cursor', 'a covered Grok is left out even with a lapsed sign-in: the pool is still drawn once')
assertEqual(names([grokLegacy]), 'grok', 'a legacy Grok record is untouched')
assertEqual(names([{ ...grokLegacy, limits: [], usageStatusText: 'Limits paused', unified: false }]), '', 'a legacy Grok that is paused with nothing to say is still left out')
assert(/text: section\.provider && section\.provider\.coverage && section\.provider\.coverage\.length > 0 \? root\.coveredTokensText\(section\.provider\) : ""/.test(panelSource), 'the shared-pool line shows only for a record with coverage')
// The hero's held line follows the records: a total shown from a half-loaded first pass must not outlive the data that completes it.
const phraseStart = panelSource.indexOf('function phraseTextFor(phrases, kind)')
assert(phraseStart > noteEnd, 'agents panel exposes the held-line lookup')
eval(panelSource.slice(phraseStart, panelSource.indexOf('function refreshShownPhrase()')))
const before = [{ kind: 'week', text: '36.0M tokens this week' }, { kind: 'today', text: '29.2M tokens today' }]
const after = [{ kind: 'week', text: '219.7M tokens this week' }, { kind: 'today', text: '29.2M tokens today' }]
assertEqual(phraseTextFor(before, 'week'), '36.0M tokens this week', 'the held line is found by its kind')
assertEqual(phraseTextFor(after, 'week'), '219.7M tokens this week', 'a held weekly total picks up an agent that loaded after it was first shown')
assertEqual(phraseTextFor(after, 'prompts'), '', 'a line that has gone is not found, so the hero keeps what it shows')
assert(/onSummaryPhrasesChanged: \{\s*if \(shownPhrase === "" \|\| summaryPhrases\.length <= 1\) showPhrase\(\)\s*else refreshShownPhrase\(\)/.test(panelSource), 'records landing refresh the held line instead of leaving it stale')
for (const kind of ['week', 'today', 'model', 'busiest', 'prompts', 'sessions'])
  assert(new RegExp('kind: "' + kind + '"').test(panelSource), 'the ' + kind + ' summary line carries its kind')
// The header's weekly total and the shared pool's are the same sum of the same records.
assertEqual(weekTokens({ recentDays: week(900000) }), 900000, 'one agent\'s week is the sum of its days')
const everyAgent = [pool, grok].reduce((sum, p) => sum + weekTokens(p), 0)
assertEqual(everyAgent, 1200000, 'the header adds every agent\'s week, the pool\'s included')
assert(!/[^n]coveredHidden(Text|Names)|coveredNote|coversHidden/.test(panelSource) && !fs.readFileSync(root + '/default/i18n/en/shell.json', 'utf8').includes('coversHidden'), 'the covered-agent note is gone: the coverage marks already say it')
assert(/text: root\.addStage === "" \? root\.uncoveredHiddenText\(\) : ""/.test(panelSource), 'the uncovered-agent note sits in the page footer, not the add view')
assert(!/Start Grok to see its limits/.test(panelSource) && !/helpStartToSeeLimits/.test(panelSource), 'the dead "Start Grok to see its limits" text is gone from the panel')
for (const code of fs.readdirSync(root + '/default/i18n')) {
  const file = root + '/default/i18n/' + code + '/shell.json'
  if (fs.existsSync(file)) assert(!fs.readFileSync(file, 'utf8').includes('helpStartToSeeLimits'), code + ' catalog dropped the dead help line')
}
assert(!fs.readFileSync(root + '/bin/omarchy-agent-usage-grok', 'utf8').includes('Start Grok to see'), 'the Grok collector no longer asks to start Grok for its limits')

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

// Stale limits: old numbers are called old, young ones are left alone.
const staleStart = panelSource.indexOf('function limitsDated(stale, fetchedAt)')
const staleEnd = panelSource.indexOf('// Window titles stay English in the records')
assert(staleStart > 0 && staleEnd > staleStart, 'agents panel exposes the stale-limits helpers')
let nowMs = 1792200000000
const staleAfterMs = 15 * 60 * 1000
eval(panelSource.slice(staleStart, staleEnd))
assert(/readonly property real staleAfterMs: 15 \* 60 \* 1000/.test(panelSource), 'limits count as old after fifteen minutes')
assert(!limitsDated(false, nowMs - 5 * 3600000), 'numbers the collector calls current are never marked old')
assert(!limitsDated(true, nowMs - 5 * 60000), 'stale numbers five minutes old are routine, not flagged')
assert(limitsDated(true, nowMs - 16 * 60000), 'stale numbers past fifteen minutes are flagged')
assert(limitsDated(true, 0), 'stale numbers with no known time are flagged')
assertEqual(lastUpdatedText(nowMs - 3 * 3600000), 'Last updated 6d 14h ago', 'the visible line says how long ago the numbers were read')
assertEqual(String(lastUpdatedText(nowMs - 20000)), 'Last updated less than a minute ago', 'a very recent read is said so')
assertEqual(String(lastUpdatedText(0)), 'Last updated time unavailable', 'an unknown read time is said so')
assert(/component StaleNote: Column/.test(panelSource) && /StaleNote \{\s*visible: !section\.multi && section\.windows\.length > 0 && root\.limitsDated\(stale, fetchedAt\)/.test(panelSource), 'a section with old limits shows the note in plain view')
assert(/StaleNote \{\s*visible: \(accountBlock\.modelData\.limits \|\| \[\]\)\.length > 0 && root\.limitsDated\(stale, fetchedAt\)/.test(panelSource), 'each account with old limits shows its own note')
assert(/text: root\.helpDisplayText\(note\.help\)/.test(panelSource), 'the note carries the collector\'s help text when there is some')
assert(/readonly property bool unknown: dated && !!window && window\.elapsed === true/.test(panelSource) && /value: compact\.window && !compact\.unknown \? compact\.window\.percent : -1/.test(panelSource), 'an allowance that reset while the numbers were old is drawn as unknown, not as 0%')
assert(/readonly property bool alarming: !dated && /.test(panelSource) && /muted: compact\.dated/.test(panelSource) && /opacity: meter\.muted \? 0\.4 : 1/.test(panelSource), 'old numbers are drawn muted and never alarm')
assert(/if \(expired\)\s*window\.elapsed = true/.test(panelSource), 'a window past its reset says so')
assert(/visible: !section\.multi && root\.needsSignIn\(section\.provider\)/.test(panelSource), 'a lapsed sign-in keeps its clickable Sign-in required link above the meters')
JS

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
eval(source.slice(source.indexOf('function needsSignIn'), source.indexOf('// Sign an account')))

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
assertDeepEqual(limitWindows(measured), [{ title: 'Session', percent: 0, resetAt: '' }], 'usage resets at the deadline while the panel stays open')
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
