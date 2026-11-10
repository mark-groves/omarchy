.pragma library

// Host-owned painter for third-party face-scan chrome.
//
// A chrome plugin returns one frame as a list of numeric draw ops. This file
// resolves those ops against the live theme and draws them into a host-owned
// canvas. The plugin never receives the canvas, the context, an Item, or any
// object that belongs to the host.
//
// That is not caution for its own sake. A 2D context exposes `canvas`, the
// canvas is a host Item, and on this build an Item's parent chain reaches the
// polkit password field. Handing a plugin the context to "just paint" would
// reopen the hole that moving the Loader was meant to close.
//
// Everything crossing the boundary is a number. Anything that is not a finite
// number in range is dropped rather than drawn.
//
// Op level 2 adds, without changing any level-1 op:
//   - a trailing glow value on paint ops: the op is also drawn on the glow
//     layer at that alpha, which the canvas blurs on the GPU into a bloom.
//     An op with alpha 0 and glow > 0 lights only the bloom.
//   - OP_BLEND, which switches later ops between normal and additive
//     ("lighter") compositing. Additive is ignored on light surfaces, where
//     adding light washes the card out.
//   - roles 3 (hot), 4 (secondary) and 5 (tertiary), which the host derives
//     from the theme (FaceTheme.js).
// Where the scene graph cannot run the bloom (the software renderer), the
// palette sets glowFallback and glow-only ops are drawn on the sharp layer
// as faint halos instead, much as a level-1 frame fakes its glow.
// A level-1 host ignores the trailing value and the unknown op, and paints
// roles above 2 in the accent, so a level-2 frame still draws there.
//
// The replay runs on the shell's GUI thread for every frame of the card: a
// thousand ops and five thousand path commands. Its loop is written out
// inline so a typical command costs a few comparisons. A value that is a
// number already in range passes one test and goes to the context as it is;
// anything else takes the slow path through coord(), alpha() and the rest,
// which convert it once and clamp or drop it. Style strings come from a
// cache, and the context is only told about a style, width or cap that
// changed since the last op.

var OP_PATH = 0   // [OP_PATH, role, alpha, lineWidth, cmds, glow?]
var OP_RECT = 1   // [OP_RECT, role, alpha, x, y, w, h, glow?]
var OP_GRAD = 2   // [OP_GRAD, role, alphaFrom, alphaTo, x, y, w, h, yFrom, yTo, glow?]
var OP_BLEND = 3  // [OP_BLEND, mode]  0 normal, 1 additive

var GLOW_AT = [5, 7, 10]

// Budgets. A chrome plugin that exceeds them is drawing nonsense or trying to
// stall the compositor, and either way the frame is truncated, not trusted.
// The glow layer replays a subset of the same ops, so it gets its own cap.
var MAX_OPS = 6000
var MAX_CMDS = 600
var MAX_GLOW_OPS = 2000
var ROLE_COUNT = 6
var FALLBACK_HALO = 0.18
// Round caps are most of the raster cost of a frame: a card is a few
// thousand short subpaths, each capped twice. A square cap keeps the stroke
// the same length and differs only at the corners, which under two pixels
// do not show, so only wider strokes pay for a round one.
var ROUND_CAP_WIDTH = 2
// Below one 8-bit step an op changes no pixel, and still costs a raster.
var MIN_ALPHA = 1 / 255
// Alpha reaches the context in thousandths, as it always has.
var ALPHA_STEPS = 1000

function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v) }

// Coordinates are allowed a generous margin outside the box because the card
// legitimately paints instrument marks past its own radius, but not an
// unbounded one: a wild coordinate is a way to make the rasteriser work hard.
function coord(v, size) {
  var n = Number(v)
  if (!isFinite(n)) return null
  return clamp(n, -4 * size, 5 * size)
}

function alpha(v) {
  var n = Number(v)
  return isFinite(n) ? clamp(n, 0, 1) : 0
}

function width(v, size) {
  var n = Number(v)
  if (!isFinite(n)) return 1
  return clamp(n, 0.1, Math.max(2, size))
}

function glowOf(op) {
  var at = op[0] >= 0 && op[0] <= 2 ? GLOW_AT[op[0]] : -1
  return at > 0 && op.length > at ? alpha(op[at]) : 0
}

function parseHex(hex) {
  var h = String(hex).replace("#", "")
  if (h.length === 8) h = h.slice(2)
  var r = parseInt(h.slice(0, 2), 16)
  var g = parseInt(h.slice(2, 4), 16)
  var b = parseInt(h.slice(4, 6), 16)
  if (!isFinite(r) || !isFinite(g) || !isFinite(b)) return null
  return r + "," + g + "," + b
}

// Role index to "r,g,b". Level-1 palettes carry only the three named
// colours; unknown or missing roles fall back to the accent, exactly as a
// level-1 host paints them.
function resolveRoles(palette) {
  var named = [palette.accent, palette.foreground, palette.errorColor]
  var list = palette.roles && palette.roles.length ? palette.roles : named
  var out = []
  for (var i = 0; i < ROLE_COUNT; i++) {
    var hex = i < list.length && list[i] ? list[i] : (i < 3 ? named[i] : list[0])
    out.push(parseHex(hex))
  }
  return out
}

function roleIndex(role) {
  var r = Number(role)
  return r >= 1 && r < ROLE_COUNT && Math.floor(r) === r ? r : 0
}

function rgba(role, a, rgb) {
  var c = rgb[roleIndex(role)]
  if (!c) return "rgba(0,0,0,0)"
  return "rgba(" + c + "," + alpha(a).toFixed(3) + ")"
}

// Style strings by role and alpha step, kept until the theme changes. A
// frame asks for a few dozen distinct ones a thousand times. The replay
// looks a string up inline and only calls styleMiss() to build a new one.
var styleCacheKey = ""
var styleCache = []

function styleTable(rgb) {
  var key = rgb.join("|")
  if (key !== styleCacheKey) {
    styleCacheKey = key
    styleCache = []
  }
  return styleCache
}

function styleMiss(table, rgb, role, step) {
  var c = rgb[role]
  var s = c ? "rgba(" + c + "," + (step / ALPHA_STEPS).toFixed(3) + ")" : "rgba(0,0,0,0)"
  table[role * (ALPHA_STEPS + 1) + step] = s
  return s
}

function fillGradient(ctx, size, op, rgb, g, glowLayer) {
  var gx = coord(op[4], size)
  var gy = coord(op[5], size)
  var gw = coord(op[6], size)
  var gh = coord(op[7], size)
  var y0 = coord(op[8], size)
  var y1 = coord(op[9], size)
  if (gx === null || gy === null || gw === null || gh === null || y0 === null || y1 === null) return false
  var a0 = alpha(op[2])
  var a1 = alpha(op[3])
  // Glow stands in for alpha, as it does for a path or a rect. Scale a fade
  // so its brighter stop is the glow value. A glow-only gradient has no
  // stop alpha to scale, and still has to light the bloom.
  if (glowLayer) {
    var peak = a0 > a1 ? a0 : a1
    if (peak <= 0) {
      a0 = g
      a1 = g
    } else {
      var scale = g / peak
      a0 *= scale
      a1 *= scale
    }
  }
  var grad = ctx.createLinearGradient(0, y0, 0, y1)
  grad.addColorStop(0, rgba(op[1], a0, rgb))
  grad.addColorStop(1, rgba(op[1], a1, rgb))
  ctx.fillStyle = grad
  ctx.fillRect(gx, gy, gw, gh)
  return true
}

function blendMode(op, additive) {
  return additive && Number(op[1]) === 1 ? "lighter" : "source-over"
}

function applyScale(ctx, scale) {
  var s = Number(scale)
  if (isFinite(s) && s > 0 && s !== 1) ctx.scale(s, s)
}

// Both layers' replay. On the sharp layer an op draws at its alpha; on the
// glow layer only ops with a glow value draw, and the glow stands in for
// their alpha. Returns the ops considered (sharp) or drawn (glow).
function replayOps(ctx, size, ops, palette, scale, glowLayer) {
  ctx.reset()
  ctx.lineCap = "round"
  ctx.lineJoin = "round"
  if (!ops || !ops.length || !palette) return 0
  applyScale(ctx, scale)
  var rgb = resolveRoles(palette)
  var table = styleTable(rgb)
  var additive = !!palette.additive
  var fallback = !glowLayer && !!palette.glowFallback
  if (glowLayer) ctx.globalCompositeOperation = additive ? "lighter" : "source-over"
  var lo = -4 * size
  var hi = 5 * size
  var rowSteps = ALPHA_STEPS + 1
  // What the context was last told. `fill` is "" after a gradient, which no
  // style string matches.
  var stroke = ""
  var fill = ""
  var lineWidth = -1
  var cap = "round"
  var n = ops.length < MAX_OPS ? ops.length : MAX_OPS
  var drawn = 0

  for (var i = 0; i < n; i++) {
    var op = ops[i]
    if (!op) continue
    var kind = op[0]

    if (kind === OP_BLEND) {
      if (!glowLayer) ctx.globalCompositeOperation = blendMode(op, additive)
      continue
    }
    if (!op.length) continue

    var g = 1
    if (glowLayer) {
      if (drawn >= MAX_GLOW_OPS) break
      g = glowOf(op)
      if (g <= 0) continue
      drawn++
    }

    // The op's alpha on this layer.
    var a = glowLayer ? g : op[2]
    if (typeof a !== "number" || !(a >= 0 && a <= 1)) a = alpha(a)

    var role = op[1]
    if (role !== 0 && role !== 1 && role !== 2 && role !== 3 && role !== 4 && role !== 5) role = roleIndex(role)

    if (kind === OP_PATH) {
      var cmds = op[4]
      if (!cmds || !cmds.length) continue
      // Only a glow-only op has anything to fall back to.
      if (fallback && a <= 0) a = glowOf(op) * FALLBACK_HALO
      if (a < MIN_ALPHA) continue
      var step = (a * ALPHA_STEPS + 0.5) | 0
      var style = table[role * rowSteps + step]
      if (style === undefined) style = styleMiss(table, rgb, role, step)
      if (style !== stroke) {
        ctx.strokeStyle = style
        stroke = style
      }
      var lw = op[3]
      if (typeof lw !== "number" || !(lw >= 0.1 && lw <= 2)) lw = width(lw, size)
      if (lw !== lineWidth) {
        ctx.lineWidth = lw
        lineWidth = lw
      }
      var pathCap = lw >= ROUND_CAP_WIDTH ? "round" : "square"
      if (pathCap !== cap) {
        ctx.lineCap = pathCap
        cap = pathCap
      }

      ctx.beginPath()
      var count = cmds.length < MAX_CMDS ? cmds.length : MAX_CMDS
      var drew = false
      for (var j = 0; j < count; j++) {
        var c = cmds[j]
        if (!c) continue
        var x = c[1]
        var y = c[2]
        if (typeof x !== "number" || !(x >= lo && x <= hi)) {
          x = coord(x, size)
          if (x === null) continue
        }
        if (typeof y !== "number" || !(y >= lo && y <= hi)) {
          y = coord(y, size)
          if (y === null) continue
        }
        var verb = c[0]
        if (verb === 1) {
          ctx.lineTo(x, y)
          drew = true
        } else if (verb === 0) {
          ctx.moveTo(x, y)
          drew = true
        } else if (verb === 3) {
          var r = coord(c[3], size)
          var a0 = Number(c[4])
          var a1 = Number(c[5])
          if (r === null || r < 0 || !isFinite(a0) || !isFinite(a1)) continue
          // A sweep beyond a full turn costs the rasteriser nothing extra to
          // clamp and is never something this card legitimately asks for.
          if (Math.abs(a1 - a0) > Math.PI * 2) a1 = a0 + Math.PI * 2
          ctx.arc(x, y, r, a0, a1)
          drew = true
        } else if (verb === 2) {
          var qx = coord(c[3], size)
          var qy = coord(c[4], size)
          if (qx === null || qy === null) continue
          ctx.quadraticCurveTo(x, y, qx, qy)
          drew = true
        }
      }
      if (drew) ctx.stroke()
      continue
    }

    if (kind === OP_RECT) {
      if (a < MIN_ALPHA) continue
      var rx = op[3]
      var ry = op[4]
      var rw = op[5]
      var rh = op[6]
      if (typeof rx !== "number" || !(rx >= lo && rx <= hi)) {
        rx = coord(rx, size)
        if (rx === null) continue
      }
      if (typeof ry !== "number" || !(ry >= lo && ry <= hi)) {
        ry = coord(ry, size)
        if (ry === null) continue
      }
      if (typeof rw !== "number" || !(rw >= lo && rw <= hi)) {
        rw = coord(rw, size)
        if (rw === null) continue
      }
      if (typeof rh !== "number" || !(rh >= lo && rh <= hi)) {
        rh = coord(rh, size)
        if (rh === null) continue
      }
      var rectStep = (a * ALPHA_STEPS + 0.5) | 0
      var rectStyle = table[role * rowSteps + rectStep]
      if (rectStyle === undefined) rectStyle = styleMiss(table, rgb, role, rectStep)
      if (rectStyle !== fill) {
        ctx.fillStyle = rectStyle
        fill = rectStyle
      }
      ctx.fillRect(rx, ry, rw, rh)
      continue
    }

    if (kind === OP_GRAD && fillGradient(ctx, size, op, rgb, g, glowLayer)) fill = ""
  }

  ctx.globalCompositeOperation = "source-over"
  return glowLayer ? drawn : n
}

// `ops` is whatever the plugin returned. It is treated as hostile input.
// palette: { accent, foreground, errorColor, roles?: [6 colours], additive?, glowFallback? }
// `scale` maps card coordinates onto a canvas drawn smaller than the card.
function paint(ctx, size, ops, palette, scale) {
  return replayOps(ctx, size, ops, palette, scale, false)
}

// The bloom source: only ops that carry a glow value, drawn at that alpha
// and accumulated additively where the surface allows it. `scale` maps card
// coordinates onto a smaller glow canvas; the blur hides the resolution.
function paintGlow(ctx, size, ops, palette, scale) {
  return replayOps(ctx, size, ops, palette, scale, true)
}
