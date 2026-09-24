// Run: TZ=Europe/Madrid node tests/budget.test.js
const assert = require("assert")
// Budget.js starts with QML's ".pragma library", which is not JavaScript.
const src = require("fs").readFileSync(require("path").join(__dirname, "../Budget.js"), "utf8").replace(/^\.pragma library\n/, "")
const mod = { exports: {} }
new Function("module", src)(mod)
const B = mod.exports

const H = 3600000, D = 24 * H
const at = (y, m, d, h, min) => new Date(y, m - 1, d, h || 0, min || 0).getTime()
const week = (resetMs) => ({ reset: resetMs, span: 7 * D })
const work = B.defaultConfig()
const every = B.config("Every day", "", 9, 19)

// A week that ends Wed 30 Sep 15:00 and started Wed 23 Sep 15:00.
const reset = at(2026, 9, 30, 15)
const p = (cfg, used, now) => B.pace(cfg, used, reset, 7 * D, now)

// Working days: Wed 4h + Thu..Tue 5x10h... (Wed 23 15-19, Thu, Fri, Mon, Tue full, Wed 9-15).
assert.strictEqual(B.workMs(work, reset - 7 * D, reset) / H, 50)
assert.ok(Math.abs(p(work, 0.12, at(2026, 9, 24, 13, 37)).budget - 0.1723) < 0.001)
// Flat all weekend and overnight.
assert.strictEqual(p(work, 0.3, at(2026, 9, 26, 20)).budget, p(work, 0.3, at(2026, 9, 27, 12)).budget)
// Every day is linear.
assert.ok(Math.abs(p(every, 0.5, reset - 3.5 * D).budget - 0.5) < 1e-9)

// Audit: zero working days behaves as every day, and says so in the config.
const none = B.config("Working days", "", 9, 19)
assert.strictEqual(none.everyDay, true)
assert.ok(Math.abs(p(none, 0.5, reset - 3.5 * D).budget - 0.5) < 1e-9)
// Audit: a backwards or empty hour range also falls back.
assert.strictEqual(B.config("Working days", "Mon", 19, 9).everyDay, true)
assert.strictEqual(B.config("Working days", "Mon", 9, 9).everyDay, true)

// Audit: a figure outside its window is not a pace (stale reset, or not started).
assert.strictEqual(p(work, 0.1, reset + 1), null)
assert.strictEqual(p(work, 0.1, reset - 8 * D), null)

// Pace words.
assert.strictEqual(p(work, 0.12, at(2026, 9, 24, 13, 37)).state, "under")
assert.strictEqual(p(work, 0.5, at(2026, 9, 24, 13, 37)).state, "over")
assert.strictEqual(p(work, 0.17, at(2026, 9, 24, 13, 37)).state, "on")
assert.strictEqual(p(work, 0.05, reset - 7 * D + H / 2).state, "early")
assert.strictEqual(B.paceLine(0.12, p(work, 0.12, at(2026, 9, 24, 13, 37))), "12% used · budget 17% · 5% under pace")

// Projection: fits at exactly 100% is "fits" (audit), no "0m before the reset".
const now = at(2026, 9, 24, 13, 37)
const q = p(work, 0.12, now)
assert.ok(Math.abs(q.projected - 0.12 / q.budget) < 1e-9)
assert.match(B.forecastLine(0.12, q, reset, now), /^At this rate: about 70% at reset$/)
const exact = B.pace(every, 0.5, reset, 7 * D, reset - 3.5 * D)
assert.strictEqual(exact.projected, 1)
assert.match(B.forecastLine(0.5, exact, reset, reset - 3.5 * D), /about 100% at reset/)
// Burning too fast: says when it empties, always before the reset.
const fast = p(work, 0.6, now)
assert.ok(fast.projected > 1 && fast.emptyAtMs > now && fast.emptyAtMs < reset)
assert.match(B.forecastLine(0.6, fast, reset, now), /^At this rate: full .* before the reset$/)
// Audit: a full window says so, it does not print "empty today 13:37".
assert.match(B.forecastLine(1, p(work, 1, now), reset, now), /^Empty now · back at Wed 30 Sep 15:00$/)
// No use, nothing to project.
assert.strictEqual(B.forecastLine(0, p(work, 0, now), reset, now), "")

// Audit: labels say tomorrow, and carry the date a week out.
assert.strictEqual(B.whenText(at(2026, 9, 25, 9), now), "tomorrow 09:00")
assert.strictEqual(B.whenText(at(2026, 9, 24, 18), now), "today 18:00")
assert.strictEqual(B.whenText(at(2026, 9, 30, 15), at(2026, 9, 23, 16)), "Wed 30 Sep 15:00")

// Audit: DST. The week Wed 21 Oct 15:00 to Wed 28 Oct 15:00 is 169 real hours in
// Madrid; the pace must follow real time, so the midpoint is not 84 h in.
if (process.env.TZ === "Europe/Madrid") {
  const r = at(2026, 10, 28, 15), span = 7 * D + H
  const real = B.pace(every, 0.5, r, span, at(2026, 10, 21, 15) + span / 2)
  assert.ok(Math.abs(real.budget - 0.5) < 1e-9)
  assert.strictEqual(B.workMs(work, at(2026, 10, 25), at(2026, 10, 26)), 0) // Sunday
  assert.strictEqual(B.workMs(B.config("Working days", "Sun", 0, 24), at(2026, 10, 25), at(2026, 10, 26)), 25 * H)
}
// Review: heavy use in the first hours reads as over, and never divides by zero.
const eager = B.pace(work, 0.6, at(2026, 9, 25, 20), 7 * D, at(2026, 9, 21, 9, 20))
assert.strictEqual(eager.state, "over")
const atStart = B.pace(work, 0.6, reset, 7 * D, reset - 7 * D)
assert.ok(atStart === null || atStart.projected < 0 || isFinite(atStart.projected))
console.log("budget: all passed")
