.pragma library

// The weekly budget: where a window says you should be by now, when only the
// hours you work earn allowance. Pure functions, no QML, so the same file runs
// under node for the tests. Every time is a millisecond timestamp; days and
// hours are read off the local wall clock, so a daylight-saving change inside
// a window is measured in real time and not in a fixed 24 hours.

var DAY_NAMES = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
var MONTH_NAMES = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// A window that is at least this old has told you what it is: too little of it
// has passed to say whether you are early or late.
var TOO_EARLY = 0.02

// "On pace" covers a band around the budget, so a one-point wobble does not
// flip the wording: 10% of the budget, never less than one point.
function paceBand(budget) {
  return Math.max(0.01, 0.1 * budget)
}

// Settings arrive as plain strings and numbers. Anything that does not make a
// usable working pattern (no day picked, an empty or backwards hour range)
// behaves exactly like "every day": the popover always has a budget to show.
function config(spread, daysText, startHour, endHour) {
  var days = [false, false, false, false, false, false, false]
  var parts = String(daysText === undefined || daysText === null ? "" : daysText).split(/[\s,]+/)
  for (var i = 0; i < parts.length; i++) {
    var name = parts[i].slice(0, 3).toLowerCase()
    for (var d = 0; d < 7; d++)
      if (DAY_NAMES[d].toLowerCase() === name) days[d] = true
  }
  var start = Math.round(Number(startHour))
  var end = Math.round(Number(endHour))
  var usable = String(spread).toLowerCase().indexOf("work") >= 0
    && days.some(function(on) { return on })
    && isFinite(start) && isFinite(end) && start >= 0 && end <= 24 && start < end
  return { everyDay: !usable, days: days, startHour: start, endHour: end }
}

var DEFAULTS = { spread: "Working days", days: "Mon,Tue,Wed,Thu,Fri", startHour: 9, endHour: 19 }

function defaultConfig() {
  return config(DEFAULTS.spread, DEFAULTS.days, DEFAULTS.startHour, DEFAULTS.endHour)
}

// The hours of one calendar day that earn budget, as [start, end] timestamps.
function daySpan(cfg, dayStart) {
  var d = new Date(dayStart)
  var y = d.getFullYear(), m = d.getMonth(), n = d.getDate()
  return {
    weekday: d.getDay(),
    start: new Date(y, m, n, cfg.everyDay ? 0 : cfg.startHour).getTime(),
    end: new Date(y, m, n, cfg.everyDay ? 24 : cfg.endHour).getTime()
  }
}

function midnight(ms) {
  var d = new Date(ms)
  return new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime()
}

// Working stretches between a and b.
function segments(cfg, a, b) {
  var out = []
  if (!(b > a)) return out
  if (cfg.everyDay) return [[a, b]]
  var d = new Date(midnight(a))
  while (d.getTime() < b) {
    var span = daySpan(cfg, d.getTime())
    if (cfg.days[span.weekday]) {
      var s = Math.max(a, span.start), e = Math.min(b, span.end)
      if (e > s) out.push([s, e])
    }
    d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)
  }
  return out
}

function workMs(cfg, a, b) {
  return segments(cfg, a, b).reduce(function(total, seg) { return total + seg[1] - seg[0] }, 0)
}

// The first moment after `from` at which `need` working milliseconds have gone
// by, or -1 when the window closes first.
function walk(cfg, from, to, need) {
  if (!(need > 0)) return from
  var segs = segments(cfg, from, to)
  for (var i = 0; i < segs.length; i++) {
    var length = segs[i][1] - segs[i][0]
    if (length >= need) return segs[i][0] + need
    need -= length
  }
  return -1
}

// Where `used` (0..1) stands in the window that ends at `resetMs` and lasts
// `spanMs`. Null when now is not inside that window: an old figure is not a
// pace.
function pace(cfg, used, resetMs, spanMs, nowMs) {
  var start = resetMs - spanMs
  if (!(spanMs > 0) || !isFinite(resetMs) || !(nowMs >= start) || !(nowMs < resetMs)) return null
  if (!(used >= 0)) return null

  var total = workMs(cfg, start, resetMs)
  var flat = total <= 0
  var earned = function(a, b) { return flat ? Math.max(0, b - a) : workMs(cfg, a, b) }
  if (flat) total = spanMs

  var elapsed = earned(start, nowMs)
  var budget = elapsed / total
  var diff = used - budget
  // Heavy use in the first hours is not "too early to judge": it is over.
  var early = budget < TOO_EARLY && used < 0.1
  var state = early ? "early"
    : Math.abs(diff) <= paceBand(budget) ? "on"
    : diff < 0 ? "under" : "over"

  // At the rate of the hours so far. Only working hours earn budget, so only
  // they are counted on either side of the projection.
  var result = { budget: budget, diff: diff, state: state, projected: -1, emptyAtMs: -1, full: used >= 1 }
  if (!early && budget > 0 && used > 0 && !result.full) {
    result.projected = used / budget
    if (result.projected > 1) {
      var need = (1 - used) / (used / elapsed)
      result.emptyAtMs = flat ? nowMs + need : walk(cfg, nowMs, resetMs, need)
    }
  }
  return result
}

function clock(ms) {
  var d = new Date(ms)
  return String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0")
}

// "today 14:00", "tomorrow 09:00", "Wed 30 Sep 15:00". Two or more days out
// carries the date too, so "Wed" is never read as the Wednesday that just went.
function whenText(ms, nowMs) {
  var days = Math.round((midnight(ms) - midnight(nowMs)) / 86400000)
  if (days === 0) return "today " + clock(ms)
  if (days === 1) return "tomorrow " + clock(ms)
  var d = new Date(ms)
  return DAY_NAMES[d.getDay()] + " " + d.getDate() + " " + MONTH_NAMES[d.getMonth()] + " " + clock(ms)
}

function durationText(ms) {
  if (!(ms > 0)) return "now"
  var minutes = Math.floor(ms / 60000)
  var hours = Math.floor(minutes / 60)
  var days = Math.floor(hours / 24)
  if (days > 0) return days + "d " + (hours % 24) + "h"
  if (hours > 0) return minutes % 60 === 0 ? hours + "h" : hours + "h " + (minutes % 60) + "m"
  return Math.max(1, minutes) + "m"
}

function pct(x) { return Math.round(x * 100) + "%" }

// "12% used · budget 17% · 5% under pace", the line that says whether to switch.
function paceLine(used, p) {
  var head = pct(used) + " used"
  if (!p) return head
  var verdict = p.state === "early" ? "too early to judge"
    : p.state === "on" ? "on pace"
    : pct(Math.abs(p.diff)) + (p.state === "under" ? " under pace" : " over pace")
  return head + " · budget " + pct(p.budget) + " · " + verdict
}

// The forecast sentence; empty when there is nothing honest to say.
function forecastLine(used, p, resetMs, nowMs) {
  if (!p) return ""
  if (p.full) return "Empty now · back at " + whenText(resetMs, nowMs)
  if (p.projected < 0) return ""
  if (p.projected <= 1) return "At this rate: about " + pct(p.projected) + " at reset"
  if (p.emptyAtMs < 0) return "At this rate: full before the reset"
  return "At this rate: full " + whenText(p.emptyAtMs, nowMs) + " · " + durationText(resetMs - p.emptyAtMs) + " before the reset"
}

function resetLine(resetMs, nowMs) {
  return "Resets " + whenText(resetMs, nowMs) + " · in " + durationText(resetMs - nowMs)
}

// Loaded by node for the tests; QML never sees `module`.
if (typeof module !== "undefined") module.exports = {
  config: config, defaultConfig: defaultConfig, DEFAULTS: DEFAULTS, segments: segments, workMs: workMs, walk: walk,
  pace: pace, whenText: whenText, paceLine: paceLine, forecastLine: forecastLine, resetLine: resetLine,
  durationText: durationText
}
