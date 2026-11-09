// Probe lines for the face surfaces.
//
// Every face card writes one JSON object per line to the shell's journal:
//
//   face-probe-event {"surface", "state", "t", "rect", "window"}
//     when a card is shown and on every state it enters while shown. `t` is
//     epoch milliseconds, `rect` the card in its window's coordinates
//     (logical pixels, laid out: an entrance scale is not a move) and
//     `window` the layer-shell namespace, or "lock" for the lock surface.
//
//   face-probe {"surface", "shownAt", "firstSwapAt", "hiddenAt", "swaps",
//               "ticks", "paints", "swapGapMs", "frameMs", "paintMs",
//               "quality", "moved", ...}
//     once when a showing ends, with counters for that showing alone:
//     swaps of its window, animation ticks, frames of the card that landed,
//     the plugin's frame() on the GUI thread (frameMs), the canvas thread's
//     raster of a frame from the end of its replay to painted (paintMs), and
//     the quality level painted at. The host card adds the painter's replay
//     on the GUI thread (replayMs), the frames it dispatched, and the level
//     it leaves for the next showing (nextQuality).
//
// Recordings are lined up against these lines, so their names and fields
// are shared with the face plugin and the dev tools. Add fields; do not
// rename them.

// Swap gaps are kept as a histogram in whole milliseconds, so a card left
// up for minutes costs no more than one up for a second. The last bucket
// holds every gap from it up; `max` keeps the real longest one.
var GAP_BUCKETS = 251

// Window names by surface, for the event lines.
var WINDOWS = {
  "lock": "lock",
  "lock-preview": "omarchy-lock-preview",
  "polkit": "omarchy-polkit",
  "polkit-preview": "omarchy-polkit-preview",
  "sudo": "markgroves-face-card"
}

function windowFor(surface) {
  return Object.prototype.hasOwnProperty.call(WINDOWS, surface) ? WINDOWS[surface] : ""
}

function newStat() {
  return { n: 0, sum: 0, max: 0 }
}

function note(stat, ms) {
  if (!(ms >= 0)) return
  stat.n += 1
  stat.sum += ms
  if (ms > stat.max) stat.max = ms
}

function mean(stat) {
  return stat.n ? stat.sum / stat.n : 0
}

function newGaps() {
  var hist = []
  for (var i = 0; i < GAP_BUCKETS; i++) hist.push(0)
  return { hist: hist, n: 0, max: 0 }
}

function noteGap(gaps, ms) {
  if (!(ms >= 0)) return
  var bucket = Math.round(ms)
  if (bucket > GAP_BUCKETS - 1) bucket = GAP_BUCKETS - 1
  gaps.hist[bucket] += 1
  gaps.n += 1
  if (ms > gaps.max) gaps.max = ms
}

// The smallest whole millisecond at or under which a fraction p of the gaps
// fall.
function gapPercentile(gaps, p) {
  if (!gaps.n) return 0
  var want = Math.max(1, Math.ceil(p * gaps.n))
  var seen = 0
  for (var i = 0; i < GAP_BUCKETS; i++) {
    seen += gaps.hist[i]
    if (seen >= want) return i
  }
  return GAP_BUCKETS - 1
}

function round1(v) {
  return Math.round(v * 10) / 10
}

// A showing's counters. The canvas fills them in; summaryLine reads them.
function newShowing(now, quality) {
  return {
    shownAt: now,
    firstSwapAt: 0,
    hiddenAt: 0,
    lastSwapAt: 0,
    swaps: 0,
    ticks: 0,
    paints: 0,
    dispatches: 0,
    gaps: newGaps(),
    frame: newStat(),
    replay: newStat(),
    raster: newStat(),
    quality: quality,
    rect: null,
    moved: false
  }
}

function sameRect(a, b) {
  return a.x === b.x && a.y === b.y && a.w === b.w && a.h === b.h
}

// Record where the card is laid out now; a showing whose card is ever laid
// out somewhere else has moved. A card not laid out yet has no size.
function noteRect(showing, rect) {
  if (!(rect.w > 0 && rect.h > 0)) return
  if (!showing.rect) showing.rect = rect
  else if (!sameRect(showing.rect, rect)) showing.moved = true
}

function eventLine(surface, state, t, rect, window) {
  return "face-probe-event " + JSON.stringify({
    surface: surface,
    state: state,
    t: t,
    rect: rect,
    window: window
  })
}

function summaryLine(surface, showing, nextQuality) {
  return "face-probe " + JSON.stringify({
    surface: surface,
    shownAt: showing.shownAt,
    firstSwapAt: showing.firstSwapAt,
    hiddenAt: showing.hiddenAt,
    swaps: showing.swaps,
    ticks: showing.ticks,
    paints: showing.paints,
    swapGapMs: {
      p50: gapPercentile(showing.gaps, 0.5),
      p95: gapPercentile(showing.gaps, 0.95),
      max: Math.round(showing.gaps.max)
    },
    frameMs: { mean: round1(mean(showing.frame)), max: showing.frame.max },
    paintMs: { mean: round1(mean(showing.raster)), max: showing.raster.max },
    quality: showing.quality,
    moved: showing.moved,
    replayMs: { mean: round1(mean(showing.replay)), max: showing.replay.max },
    dispatches: showing.dispatches,
    nextQuality: nextQuality
  })
}

if (typeof module !== "undefined") {
  module.exports = {
    GAP_BUCKETS: GAP_BUCKETS,
    windowFor: windowFor,
    newStat: newStat,
    note: note,
    mean: mean,
    newGaps: newGaps,
    noteGap: noteGap,
    gapPercentile: gapPercentile,
    newShowing: newShowing,
    noteRect: noteRect,
    eventLine: eventLine,
    summaryLine: summaryLine
  }
}
