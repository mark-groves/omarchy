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

function rgba(role, a, rgb) {
  var r = Number(role)
  var c = r >= 1 && r < ROLE_COUNT && Math.floor(r) === r ? rgb[r] : rgb[0]
  if (!c) return "rgba(0,0,0,0)"
  return "rgba(" + c + "," + alpha(a).toFixed(3) + ")"
}

function replayPath(ctx, size, cmds) {
  var n = Math.min(cmds.length, MAX_CMDS)
  var drew = false
  for (var i = 0; i < n; i++) {
    var c = cmds[i]
    if (!c || !c.length) continue
    var a = coord(c[1], size)
    var b = coord(c[2], size)
    if (a === null || b === null) continue

    if (c[0] === 0) {
      ctx.moveTo(a, b)
      drew = true
    } else if (c[0] === 1) {
      ctx.lineTo(a, b)
      drew = true
    } else if (c[0] === 2) {
      var x = coord(c[3], size)
      var y = coord(c[4], size)
      if (x === null || y === null) continue
      ctx.quadraticCurveTo(a, b, x, y)
      drew = true
    } else if (c[0] === 3) {
      var r = coord(c[3], size)
      var a0 = Number(c[4])
      var a1 = Number(c[5])
      if (r === null || r < 0 || !isFinite(a0) || !isFinite(a1)) continue
      // A sweep beyond a full turn costs the rasteriser nothing extra to clamp
      // and is never something this card legitimately asks for.
      if (Math.abs(a1 - a0) > Math.PI * 2) a1 = a0 + Math.PI * 2
      ctx.arc(a, b, r, a0, a1)
      drew = true
    }
  }
  return drew
}

// Draw one paint op. On the sharp layer an op draws at its alpha; on the
// glow layer its glow value stands in for its alpha.
function replay(ctx, size, op, rgb, glowLayer, fallback) {
  if (!op || !op.length) return
  var g = glowLayer ? glowOf(op) : 1
  if (g <= 0) return
  // Only a glow-only op has anything to fall back to.
  var halo = !glowLayer && fallback && op[0] === OP_PATH && alpha(op[2]) <= 0 ? glowOf(op) * FALLBACK_HALO : 0

  if (op[0] === OP_PATH) {
    var cmds = op[4]
    if (!cmds || !cmds.length) return
    var pa = glowLayer ? g : (halo > 0 ? halo : alpha(op[2]))
    if (pa <= 0) return
    ctx.strokeStyle = rgba(op[1], pa, rgb)
    ctx.lineWidth = width(op[3], size)
    ctx.beginPath()
    if (replayPath(ctx, size, cmds)) ctx.stroke()
    return
  }

  if (op[0] === OP_RECT) {
    var rx = coord(op[3], size)
    var ry = coord(op[4], size)
    var rw = coord(op[5], size)
    var rh = coord(op[6], size)
    if (rx === null || ry === null || rw === null || rh === null) return
    var ra = glowLayer ? g : alpha(op[2])
    if (ra <= 0) return
    ctx.fillStyle = rgba(op[1], ra, rgb)
    ctx.fillRect(rx, ry, rw, rh)
    return
  }

  if (op[0] === OP_GRAD) {
    var gx = coord(op[4], size)
    var gy = coord(op[5], size)
    var gw = coord(op[6], size)
    var gh = coord(op[7], size)
    var y0 = coord(op[8], size)
    var y1 = coord(op[9], size)
    if (gx === null || gy === null || gw === null || gh === null || y0 === null || y1 === null) return
    var grad = ctx.createLinearGradient(0, y0, 0, y1)
    grad.addColorStop(0, rgba(op[1], alpha(op[2]) * g, rgb))
    grad.addColorStop(1, rgba(op[1], alpha(op[3]) * g, rgb))
    ctx.fillStyle = grad
    ctx.fillRect(gx, gy, gw, gh)
  }
}

function blendMode(op, additive) {
  return additive && Number(op[1]) === 1 ? "lighter" : "source-over"
}

// `ops` is whatever the plugin returned. It is treated as hostile input.
// palette: { accent, foreground, errorColor, roles?: [6 colours], additive?, glowFallback? }
function paint(ctx, size, ops, palette) {
  ctx.reset()
  ctx.lineCap = "round"
  ctx.lineJoin = "round"
  if (!ops || !ops.length || !palette) return 0
  var rgb = resolveRoles(palette)
  var additive = !!palette.additive
  var fallback = !!palette.glowFallback
  var n = Math.min(ops.length, MAX_OPS)
  for (var i = 0; i < n; i++) {
    var op = ops[i]
    if (op && op[0] === OP_BLEND) ctx.globalCompositeOperation = blendMode(op, additive)
    else replay(ctx, size, op, rgb, false, fallback)
  }
  ctx.globalCompositeOperation = "source-over"
  return n
}

// The bloom source: only ops that carry a glow value, drawn at that alpha
// and accumulated additively where the surface allows it. `scale` maps card
// coordinates onto a smaller glow canvas; the blur hides the resolution.
function paintGlow(ctx, size, ops, palette, scale) {
  ctx.reset()
  ctx.lineCap = "round"
  ctx.lineJoin = "round"
  if (!ops || !ops.length || !palette) return 0
  var s = Number(scale)
  if (isFinite(s) && s > 0 && s !== 1) ctx.scale(s, s)
  var rgb = resolveRoles(palette)
  ctx.globalCompositeOperation = palette.additive ? "lighter" : "source-over"
  var n = Math.min(ops.length, MAX_OPS)
  var drawn = 0
  for (var i = 0; i < n && drawn < MAX_GLOW_OPS; i++) {
    var op = ops[i]
    if (!op || op[0] === OP_BLEND || glowOf(op) <= 0) continue
    replay(ctx, size, op, rgb, true)
    drawn++
  }
  ctx.globalCompositeOperation = "source-over"
  return drawn
}
