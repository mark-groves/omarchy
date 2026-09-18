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

var OP_PATH = 0   // [OP_PATH, role, alpha, lineWidth, cmds]
var OP_RECT = 1   // [OP_RECT, role, alpha, x, y, w, h]
var OP_GRAD = 2   // [OP_GRAD, role, alphaFrom, alphaTo, x, y, w, h, yFrom, yTo]

// Budgets. A chrome plugin that exceeds them is drawing nonsense or trying to
// stall the compositor, and either way the frame is truncated, not trusted.
var MAX_OPS = 6000
var MAX_CMDS = 600

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

function rgba(role, a, palette) {
  var hex = role === 2 ? palette.errorColor : (role === 1 ? palette.foreground : palette.accent)
  var h = String(hex).replace("#", "")
  if (h.length === 8) h = h.slice(2)
  var r = parseInt(h.slice(0, 2), 16)
  var g = parseInt(h.slice(2, 4), 16)
  var b = parseInt(h.slice(4, 6), 16)
  if (!isFinite(r) || !isFinite(g) || !isFinite(b)) return "rgba(0,0,0,0)"
  return "rgba(" + r + "," + g + "," + b + "," + alpha(a).toFixed(3) + ")"
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

function replay(ctx, size, op, palette) {
  if (!op || !op.length) return

  if (op[0] === OP_PATH) {
    var cmds = op[4]
    if (!cmds || !cmds.length) return
    ctx.strokeStyle = rgba(op[1], op[2], palette)
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
    ctx.fillStyle = rgba(op[1], op[2], palette)
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
    grad.addColorStop(0, rgba(op[1], op[2], palette))
    grad.addColorStop(1, rgba(op[1], op[3], palette))
    ctx.fillStyle = grad
    ctx.fillRect(gx, gy, gw, gh)
  }
}

// `ops` is whatever the plugin returned. It is treated as hostile input.
function paint(ctx, size, ops, palette) {
  ctx.reset()
  ctx.lineCap = "round"
  ctx.lineJoin = "round"
  if (!ops || !ops.length || !palette) return 0
  var n = Math.min(ops.length, MAX_OPS)
  for (var i = 0; i < n; i++) replay(ctx, size, ops[i], palette)
  return n
}
