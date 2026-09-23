.pragma library

// Colour roles for the face-scan card, derived from the active theme.
//
// A chrome plugin never sees a colour. It paints with role indices and the
// host resolves them here. The first three roles are the surface's accent,
// text and error colours. The rest are derived, never hardcoded, so a theme
// switch recolours every role:
//
//   3 hot        the accent pushed toward the text colour: a white-hot core
//   4 secondary  the theme's palette colour furthest in hue from the accent
//   5 tertiary   the next most distinct palette colour
//
// A theme without a usable palette gets secondary and tertiary rotated off
// the accent's hue, so the roles still move with the theme.

var ROLE_COUNT = 6

// colors.toml keys worth considering as a second or third hue, in the order
// ties are broken. Error-like reds are not excluded by name because some
// themes map `red` to something else; they are excluded by hue distance from
// the error colour instead.
var CANDIDATE_KEYS = [
  "cyan", "magenta", "blue", "green", "yellow", "orange",
  "bright_cyan", "bright_magenta", "bright_blue", "bright_green", "bright_yellow",
  "color6", "color5", "color4", "color2", "color3",
  "color14", "color13", "color12", "color10", "color11"
]

function parseHex(value) {
  var h = String(value || "").replace(/^\s+|\s+$/g, "").replace("#", "")
  if (h.length === 8) h = h.slice(2)
  if (!/^[0-9A-Fa-f]{6}$/.test(h)) return null
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)]
}

function toHex(rgb) {
  var s = "#"
  for (var i = 0; i < 3; i++) {
    var v = Math.max(0, Math.min(255, Math.round(rgb[i]))).toString(16)
    s += v.length < 2 ? "0" + v : v
  }
  return s
}

function toHsl(rgb) {
  var r = rgb[0] / 255, g = rgb[1] / 255, b = rgb[2] / 255
  var max = Math.max(r, g, b), min = Math.min(r, g, b)
  var l = (max + min) / 2
  var d = max - min
  if (d === 0) return [0, 0, l]
  var s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
  var h
  if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6
  else if (max === g) h = ((b - r) / d + 2) / 6
  else h = ((r - g) / d + 4) / 6
  return [h, s, l]
}

function hue2rgb(p, q, t) {
  if (t < 0) t += 1
  if (t > 1) t -= 1
  if (t < 1 / 6) return p + (q - p) * 6 * t
  if (t < 1 / 2) return q
  if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6
  return p
}

function fromHsl(hsl) {
  var h = hsl[0], s = hsl[1], l = hsl[2]
  if (s === 0) return [l * 255, l * 255, l * 255]
  var q = l < 0.5 ? l * (1 + s) : l + s - l * s
  var p = 2 * l - q
  return [hue2rgb(p, q, h + 1 / 3) * 255, hue2rgb(p, q, h) * 255, hue2rgb(p, q, h - 1 / 3) * 255]
}

function hueDistance(a, b) {
  var d = Math.abs(a - b) % 1
  return d > 0.5 ? 1 - d : d
}

function mixRgb(a, b, k) {
  return [a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k]
}

function luminance(value) {
  var rgb = parseHex(value)
  if (!rgb) return 0
  return (0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]) / 255
}

// The accent pushed most of the way to the text colour, then lifted, so the
// core of a lit stroke reads hotter than its halo without leaving the theme.
function hotFrom(accent, foreground) {
  var a = parseHex(accent)
  var f = parseHex(foreground)
  if (!a) return foreground
  if (!f) f = a
  var hsl = toHsl(mixRgb(a, f, 0.55))
  hsl[2] = Math.min(0.94, hsl[2] + (1 - hsl[2]) * 0.35)
  return toHex(fromHsl(hsl))
}

function rotated(accent, turn) {
  var a = parseHex(accent)
  if (!a) return accent
  var hsl = toHsl(a)
  hsl[0] = (hsl[0] + turn + 1) % 1
  hsl[1] = Math.max(0.45, hsl[1])
  hsl[2] = Math.min(0.72, Math.max(0.5, hsl[2]))
  return toHex(fromHsl(hsl))
}

// Palette colours that can carry a second hue: saturated enough to read as
// a colour, light enough to glow on the card, and not the error colour.
function candidates(palette, accent, error) {
  var ah = toHsl(parseHex(accent) || [0, 0, 0])
  var eh = parseHex(error) ? toHsl(parseHex(error)) : null
  var seen = {}
  var out = []
  if (!palette) return out
  for (var i = 0; i < CANDIDATE_KEYS.length; i++) {
    var value = palette[CANDIDATE_KEYS[i]]
    var rgb = parseHex(value)
    if (!rgb) continue
    var hex = toHex(rgb)
    if (seen[hex]) continue
    seen[hex] = true
    var hsl = toHsl(rgb)
    if (hsl[1] < 0.22 || hsl[2] < 0.25 || hsl[2] > 0.9) continue
    if (eh && eh[1] > 0.22 && hueDistance(hsl[0], eh[0]) < 0.05) continue
    out.push({ hex: hex, hue: hsl[0], dist: hueDistance(hsl[0], ah[0]), order: i })
  }
  return out
}

function pickDistinct(list, awayFrom, minDist) {
  var best = null
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    var d = c.dist
    if (awayFrom !== null) d = Math.min(d, hueDistance(c.hue, awayFrom))
    if (d < minDist) continue
    if (!best || d > best.score + 1e-6) best = { c: c, score: d }
  }
  return best ? best.c : null
}

// All six role colours as "#rrggbb" strings, in role order.
function roles(accent, foreground, error, palette) {
  var list = candidates(palette, accent, error)
  var second = pickDistinct(list, null, 0.06)
  var third = second ? pickDistinct(list, second.hue, 0.06) : null
  return [
    String(accent),
    String(foreground),
    String(error),
    hotFrom(accent, foreground),
    second ? second.hex : rotated(accent, 0.42),
    third ? third.hex : rotated(accent, -0.18)
  ]
}
