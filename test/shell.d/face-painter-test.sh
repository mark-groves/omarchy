#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

# Behaviour of the host painter's op level 2 (glow, additive blending, theme
# roles 3..5) against a recording context, and of the theme role derivation.

run_node_test <<'JS'
const fs = require('fs')

function loadLibrary(rel, names) {
  const src = fs.readFileSync(path.join(root, rel), 'utf8').replace(/^\.pragma library\n/, '')
  return new Function(src + '\nreturn {' + names.map(n => n + ':' + n).join(',') + '}')()
}

const painter = loadLibrary('shell/Commons/FaceCardPainter.js', ['paint', 'paintGlow', 'MAX_GLOW_OPS'])
const theme = loadLibrary('shell/Commons/FaceTheme.js', ['roles', 'luminance', 'parseHex'])

function recordingContext() {
  const log = []
  const ctx = { log, globalCompositeOperation: 'source-over' }
  for (const name of ['reset', 'beginPath', 'moveTo', 'lineTo', 'arc', 'quadraticCurveTo', 'stroke', 'fillRect', 'scale']) {
    ctx[name] = (...args) => log.push([name, ctx.globalCompositeOperation, ctx.strokeStyle, ctx.fillStyle, ...args])
  }
  ctx.createLinearGradient = () => ({ addColorStop() {} })
  return ctx
}

const nord = { cyan: '#88c0d0', magenta: '#b48ead', green: '#a3be8c', red: '#bf616a', blue: '#81a1c1' }
const roles = theme.roles('#88c0d0', '#eceff4', '#bf616a', nord)
const palette = { accent: '#88c0d0', foreground: '#eceff4', errorColor: '#bf616a', roles, additive: true }
const line = [[0, 1, 1], [1, 20, 20]]

let ctx = recordingContext()
painter.paint(ctx, 100, [[0, 0, 1, 1, line]], { accent: '#88c0d0', foreground: '#eceff4', errorColor: '#bf616a' })
assert(ctx.log.some(e => e[0] === 'stroke' && /^rgba\(136,192,208,1\.000\)$/.test(e[2])),
  'a level-1 frame paints exactly as before')

ctx = recordingContext()
painter.paint(ctx, 100, [[3, 1], [0, 3, 1, 1, line], [3, 0], [0, 4, 1, 1, line]], palette)
const strokes = ctx.log.filter(e => e[0] === 'stroke')
assertEqual(strokes[0][1], 'lighter', 'OP_BLEND 1 composites later ops additively')
assertEqual(strokes[1][1], 'source-over', 'OP_BLEND 0 returns to normal compositing')
assert(strokes[0][2] !== strokes[1][2], 'roles 3 and 4 resolve to their own colours')

ctx = recordingContext()
painter.paint(ctx, 100, [[3, 1], [0, 0, 1, 1, line]], Object.assign({}, palette, { additive: false }))
assertEqual(ctx.log.find(e => e[0] === 'stroke')[1], 'source-over', 'a light surface never composites additively')

ctx = recordingContext()
painter.paint(ctx, 100, [[0, 9, 1, 1, line], [0, 1.5, 1, 1, line]], palette)
const accentStyle = 'rgba(136,192,208,1.000)'
assert(ctx.log.filter(e => e[0] === 'stroke').every(e => e[2] === accentStyle), 'an unknown role paints in the accent')

ctx = recordingContext()
painter.paint(ctx, 100, [[0, 0, 0, 1, line, 0.8]], palette)
assertEqual(ctx.log.filter(e => e[0] === 'stroke').length, 0, 'a glow-only op draws nothing on the sharp layer')

ctx = recordingContext()
painter.paint(ctx, 100, [[0, 0, 0, 1, line, 1], [0, 0, 0.5, 1, line, 1]], Object.assign({}, palette, { glowFallback: true }))
const fb = ctx.log.filter(e => e[0] === 'stroke')
assert(fb.length === 2 && /,0\.180\)$/.test(fb[0][2]) && /,0\.500\)$/.test(fb[1][2]),
  'without a GPU bloom a glow-only op falls back to a faint halo and lit ops keep their alpha')

ctx = recordingContext()
painter.paintGlow(ctx, 100, [[0, 0, 1, 1, line], [0, 0, 0, 1, line, 0.8], [1, 3, 1, 0, 0, 4, 4, 0.5], [0, 0, 1, 1, line, NaN]], palette, 0.5)
const glowStrokes = ctx.log.filter(e => e[0] === 'stroke')
assertEqual(glowStrokes.length, 1, 'the glow layer draws only ops that carry a finite glow value')
assert(/,0\.800\)$/.test(glowStrokes[0][2]), 'a glow op is drawn on the glow layer at its glow alpha')
assert(ctx.log.some(e => e[0] === 'scale' && e[4] === 0.5), 'the glow layer maps card coordinates onto its own scale')
assert(ctx.log.some(e => e[0] === 'fillRect'), 'a glowing rect lights the glow layer')

ctx = recordingContext()
painter.paintGlow(ctx, 100, [[0, 0, 1, 1, line, 5]], palette, 1)
assert(/,1\.000\)$/.test(ctx.log.find(e => e[0] === 'stroke')[2]), 'glow is clamped like alpha')

const many = []
for (let i = 0; i < painter.MAX_GLOW_OPS + 500; i++) many.push([0, 0, 1, 1, line, 1])
ctx = recordingContext()
assertEqual(painter.paintGlow(ctx, 100, many, palette, 1), painter.MAX_GLOW_OPS, 'the glow layer has its own op cap')

assertEqual(roles.length, 6, 'the theme yields six role colours')
assertDeepEqual(roles.slice(0, 3), ['#88c0d0', '#eceff4', '#bf616a'], 'roles 0..2 are the surface colours')
assert(roles.slice(3).every(c => theme.parseHex(c)), 'derived roles are real colours')
assert(roles[4] !== roles[0] && roles[5] !== roles[0] && roles[4] !== roles[5], 'secondary and tertiary are distinct hues')
assert(roles[4] !== '#bf616a' && roles[5] !== '#bf616a', 'derived roles never reuse the error colour')
assert(theme.luminance(roles[3]) > theme.luminance(roles[0]), 'hot is brighter than the accent')

const gruvbox = { cyan: '#89b482', magenta: '#d3869b', green: '#a9b665', blue: '#7daea3', yellow: '#d8a657', red: '#ea6962' }
const other = theme.roles('#7daea3', '#d4be98', '#ea6962', gruvbox)
assert(other[4] !== roles[4] || other[3] !== roles[3], 'another theme recolours the derived roles')
assert(Object.values(gruvbox).includes(other[4]), 'secondary comes from the theme palette')

const bare = theme.roles('#88c0d0', '#eceff4', '#bf616a', {})
assert(bare[4] !== bare[0] && theme.parseHex(bare[4]), 'a theme without a palette still gets a secondary computed from its accent')
assertDeepEqual(theme.roles('#88c0d0', '#eceff4', '#bf616a', nord), roles, 'role derivation is deterministic')

const canvasQml = fs.readFileSync(path.join(root, 'shell/Ui/FaceChromeCanvas.qml'), 'utf8')
assert(/FaceTheme\.roles\([\s\S]*?Color\.palette\)/.test(canvasQml), 'the card derives its roles from the live theme palette')
assert(/MultiEffect/.test(canvasQml) && /source:\s*glowCanvas/.test(canvasQml), 'the bloom is a host-owned GPU effect over the glow layer')
const colorQml = fs.readFileSync(path.join(root, 'shell/Commons/Color.qml'), 'utf8')
assert(/palette = named/.test(colorQml), 'a theme load replaces the palette whole, so bindings re-evaluate')
const chromeQml = fs.readFileSync(path.join(root, 'shell/Commons/FaceChrome.qml'), 'utf8')
assert(/host:\s*root\.opLevel/.test(chromeQml), 'the plugin is told the op level as a number')
JS
