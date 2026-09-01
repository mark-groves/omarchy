#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

run_node_test <<'JS'
const fs = require('fs')
const panelSource = fs.readFileSync(root + '/shell/plugins/agents/Panel.qml', 'utf8')

assert(/function launchAgent\(\)/.test(panelSource), 'agents panel launches the default agent')
assert(/root\.bar\.run\("omarchy-agent --pick"\)/.test(panelSource), 'agents panel uses the desktop agent launcher')
assert(/if \(buttonCode === Qt\.RightButton\) root\.launchAgent\(\)/.test(panelSource), 'agents right click launches the agent')
assert(/else if \(buttonCode === Qt\.MiddleButton\) root\.selectProvider\(root\.providerIndex \+ 1\)/.test(panelSource), 'agents middle click still advances the subscription')
assert(/else root\.toggle\(\)/.test(panelSource), 'agents left click still toggles the panel')
assert(!/if \(buttonCode === Qt\.RightButton\) root\.refreshNow\(\)/.test(panelSource), 'agents right click no longer refreshes')

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
JS
