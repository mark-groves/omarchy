.pragma library
// A face chrome module with real timings and one rect for art.
function frame(size, spec) { return [[1, 0, 1, 0, 0, size, size]] }
function holdMs(state) { return state === "scanning" ? 0 : 250 }
function scanMs() { return 200 }
