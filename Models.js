.pragma library

// Which models the "tokens by model" list shows. The hidden set is one plugin
// setting: model ids, comma-separated, empty meaning every model is shown, so a
// model that appears later is shown until somebody hides it. Hiding only
// filters what the panel draws; the usage numbers themselves are never touched.
// Pure functions, no QML, so the same file runs under node for the tests.

function parseHidden(text) {
  var out = []
  var parts = String(text === undefined || text === null ? "" : text).split(",")
  for (var i = 0; i < parts.length; i++) {
    var id = parts[i].trim()
    if (id !== "" && out.indexOf(id) < 0) out.push(id)
  }
  return out
}

function serializeHidden(ids) {
  return parseHidden(ids.join(",")).join(",")
}

function isHidden(text, id) {
  return parseHidden(text).indexOf(id) >= 0
}

// The new setting text with `id` flipped.
function toggleHidden(text, id) {
  var ids = parseHidden(text)
  var at = ids.indexOf(id)
  if (at >= 0) ids.splice(at, 1)
  else ids.push(id)
  return serializeHidden(ids)
}

// A copy of a provider's modelUsage without the hidden models. Families are
// built from what is left, so a family's sum counts only the shown versions,
// one with none left disappears, and the four-family cap is applied after.
function shownUsage(usageByModel, hiddenText) {
  var hidden = parseHidden(hiddenText)
  var out = {}
  for (var id in (usageByModel || {})) if (hidden.indexOf(id) < 0) out[id] = usageByModel[id]
  return out
}

function bucketTotal(bucket) {
  var b = bucket || {}
  return Number(b.inputTokens || 0) + Number(b.outputTokens || 0)
    + Number(b.cacheReadInputTokens || 0) + Number(b.cacheCreationInputTokens || 0)
}

// One entry per model id ever seen, heaviest first: {id, name, total, shown}.
// `nameOf` maps an id to its friendly label ("Opus 4.8").
function chips(usageByModel, hiddenText, nameOf) {
  var hidden = parseHidden(hiddenText)
  var list = []
  for (var id in (usageByModel || {}))
    list.push({ id: id, name: nameOf(id), total: bucketTotal(usageByModel[id]), shown: hidden.indexOf(id) < 0 })
  list.sort(function(a, b) { return b.total - a.total })
  return list
}

// "Antigravity Starter Quota" under the provider "Antigravity" reads "Starter Quota".
function stripProviderName(plan, providerName) {
  var t = String(plan || ""), n = String(providerName || "")
  if (n !== "" && t.toLowerCase().indexOf(n.toLowerCase() + " ") === 0) return t.slice(n.length + 1).trim()
  return t
}

// Text after "Name · " on the NEXT-MESSAGE-IS-PAID-BY chip for the selected
// provider: the active account, else the plan, plus "one login" when swapkin
// keeps no second account for it (mode "never").
function payerText(p, active) {
  if (!p) return ""
  var who = active ? String(active.name) : (stripProviderName(p.tierLabel, p.providerName) || "signed in")
  return p.mode === "never" ? who + " · one login" : who
}

// Manage opens for every provider: one with accounts lists them, one that is
// signed in but unsaved offers Save, and a one-login provider (Antigravity)
// shows its login and says how to change it.
function canManage(p) { return !!p }

// What an account is called on screen: the owner's own label when there is
// one, else its name. The name stays the id every command uses.
function accountLabel(a) {
  if (!a) return ""
  var l = String(a.label || "").trim()
  return l !== "" ? l : String(a.name || "")
}

// The CLI is logged in but swapkin keeps no account for it yet.
function unsavedLogin(p) {
  return !!p && p.signedIn === true && (p.accounts || []).length === 0
}

// The first line under the provider name: who or what pays for the next
// message. A plan is a plan, never a payer: "Free plan", not "Paid by Free".
function payerLine(p, active) {
  if (!p) return ""
  var one = p.mode === "never" ? " · one login" : ""
  if (active) return "Paid by " + accountLabel(active) + one
  var plan = stripProviderName(p.tierLabel, p.providerName).trim()
  if (plan !== "") return (/\bplan$/i.test(plan) ? plan : plan + " plan") + one
  return (p.signedIn === true ? "Signed in" : "No account") + one
}

// The help line under the hero. Anthropic rate limits the usage endpoint
// readily; that is not a sign-out, so never send people to a new login for it.
var RATE_LIMIT_TEXT = "Anthropic is rate limiting usage checks; showing local stats."
function helpLine(p) {
  if (!p) return ""
  var help = String(p.authHelpText || "")
  if (p.rateLimited === true || /rate limiting/i.test(help)) return RATE_LIMIT_TEXT
  return help
}

// Sync twice in quick succession is what causes the rate limit: after a Sync
// the owner pressed, wait this long before the next.
var SYNC_COOLDOWN_MS = 30000
function syncCooldownLeft(lastEndMs, nowMs) {
  var left = SYNC_COOLDOWN_MS - (Number(nowMs) - Number(lastEndMs))
  return lastEndMs > 0 && left > 0 ? Math.ceil(left / 1000) : 0
}

// How to read one account at a glance: its plan, its limits, its age.
function ageLine(a) {
  if (!a) return ""
  var seconds = Number(a.age)
  if (!(seconds >= 0)) return "no limits yet"
  return agoText(seconds)
}

// The window the hero ring shows. "tightest" is the fullest one; "weekly" and
// "session" pick that kind and fall back to the fullest when the account has none.
function pickHero(windows, mode) {
  var list = windows || []
  var best = null, kind = mode === "weekly" ? "weekly" : mode === "session" ? "session" : ""
  for (var i = 0; i < list.length; i++) {
    if (kind !== "" && list[i].kind === kind && (!best || list[i].percent > best.percent)) best = list[i]
  }
  if (best) return best
  for (var j = 0; j < list.length; j++) if (!best || list[j].percent > best.percent) best = list[j]
  return best
}

var HERO_MODES = ["tightest", "weekly", "session"]
function heroMode(v) { return HERO_MODES.indexOf(String(v)) >= 0 ? String(v) : "tightest" }

// Settings written by hand can hold anything: clamp to what the code supports.
var WATCH_STEPS = [1, 2, 5, 10, 15, 30, 60]
var WARN_STEPS = [50, 60, 70, 75, 80, 85, 90, 95]
function snapStep(steps, v, fallback) {
  var n = Number(v)
  if (!isFinite(n)) return fallback
  var best = steps[0]
  for (var i = 0; i < steps.length; i++) if (Math.abs(steps[i] - n) < Math.abs(best - n)) best = steps[i]
  return best
}
function stepBy(steps, v, delta, fallback) {
  var at = steps.indexOf(snapStep(steps, v, fallback))
  return steps[Math.max(0, Math.min(steps.length - 1, at + delta))]
}

var MOTION_MODES = ["system", "reduce", "full"]
function motionMode(v) { return MOTION_MODES.indexOf(String(v)) >= 0 ? String(v) : "system" }
// null means "follow the shell".
function motionReduced(mode, systemReduced) {
  var m = motionMode(mode)
  return m === "reduce" ? true : m === "full" ? false : !!systemReduced
}

// Providers the owner chose to leave out of the strip. One is always kept, so
// the panel never opens empty because of a setting.
function hiddenProviders(text) { return parseHidden(text) }
function visibleProviders(list, hiddenText) {
  var out = (list || []).filter(function(p) { return !isHidden(hiddenText, p.providerId) })
  return out.length > 0 ? out : (list || [])
}
function toggleProviderHidden(hiddenText, id, allIds) {
  var next = toggleHidden(hiddenText, id)
  var left = (allIds || []).filter(function(x) { return !isHidden(next, x) })
  return left.length === 0 ? String(hiddenText || "") : next
}

// Key bar entries for the normal view (no cursor sub-page open).
// Only Claude can hand a login over on its own, so only it gets auto-switch.
function canAutoSwitch(p) { return !!p && p.providerId === "claude" }

// WCAG contrast ratio between two relative luminances.
function contrastRatio(a, b) {
  var hi = Math.max(a, b), lo = Math.min(a, b)
  return (hi + 0.05) / (lo + 0.05)
}

// Bar icon tooltip / accessible name: who, and how full the tightest limit is.
function barSummary(providerName, accountName, percent) {
  var s = String(providerName || "") + (accountName ? " · " + accountName : "")
  return percent >= 0 ? s + " · " + Math.round(percent * 100) + "% used" : s
}

function keyHints(hasAccounts, canManage, managing, canAuto, settings, canSwitch, canStatusline) {
  if (settings) return [{ k: "↑ ↓", l: "setting" }, { k: "← →", l: "change" }, { k: "w", l: "weekly pace" }, { k: "o", l: "models" }, { k: ",", l: "back" }]
  if (managing) {
    var acts = [{ k: "← →", l: "account" }]
    if (canSwitch !== false) acts.push({ k: "u a", l: "use" })
    if (hasAccounts) acts.push({ k: "n", l: "rename" }, { k: "c", l: "colour" }, { k: "f", l: "forget" })
    else if (canSwitch !== false) acts.push({ k: "v", l: "save" })
    if (canAuto !== false) acts.push({ k: "s", l: "auto-switch" })
    return [{ k: "↑ ↓", l: "provider" }].concat(acts, [{ k: "r", l: "sync" }, { k: "m", l: "back" }, { k: ",", l: "settings" }])
  }
  var extra = canStatusline === true ? [{ k: "t", l: "status line" }] : []
  var gear = { k: ",", l: "settings" }
  if (hasAccounts)
    return [{ k: "↑ ↓", l: "provider" }, { k: "← →", l: "account" }, { k: "a", l: "switch" }, { k: "m", l: "manage" }, { k: "r", l: "sync" }, gear].concat(extra)
  if (canManage)
    return [{ k: "↑ ↓", l: "provider" }, { k: "m", l: "manage" }, { k: "r", l: "sync" }, gear].concat(extra)
  return [{ k: "↑ ↓", l: "provider" }, { k: "r", l: "sync" }]
}

// Tokens in the last 7 dated days of a provider's recentDays.
function weekTokens(p) {
  var days = (p && p.recentDays) || []
  var sum = 0
  for (var i = Math.max(0, days.length - 7); i < days.length; i++) sum += Number(days[i].tokenCount || 0)
  return sum
}

// Provider in use first: Claude with an active account, then the rest by most
// tokens this week. Ties keep id order, so a refresh never shuffles the list.
function orderProviders(list) {
  var items = (list || []).slice()
  function inUse(p) {
    if (!p || p.providerId !== "claude") return false
    var a = p.accounts || []
    for (var i = 0; i < a.length; i++) if (a[i] && a[i].active) return true
    return false
  }
  items.sort(function(a, b) {
    if (inUse(a) !== inUse(b)) return inUse(a) ? -1 : 1
    var d = weekTokens(b) - weekTokens(a)
    if (d !== 0) return d
    return String(a.providerId).localeCompare(String(b.providerId))
  })
  return items
}

// A version's share of its family, as a 0..1 bar fill and a "62%" label.
function shareOf(total, whole) {
  return whole > 0 ? Math.max(0, Math.min(1, total / whole)) : 0
}
function shareText(total, whole) {
  return whole > 0 ? Math.round(shareOf(total, whole) * 100) + "%" : ""
}

// ---- Gauge maths (pure, so node can test the ring) ----------------------
var GAUGE_URGENT = 0.9

// A 0..1 percent as the degrees a ring arc sweeps. Out of range clamps; a
// missing value (negative or not a number) draws an empty ring.
function arcSweep(percent) {
  var p = Number(percent)
  if (!(p > 0)) return 0
  return Math.min(1, p) * 360
}

// "none" with no data, "urgent" from 90% up, else "ok".
function gaugeState(percent) {
  var p = Number(percent)
  if (!(p >= 0)) return "none"
  return p >= GAUGE_URGENT ? "urgent" : "ok"
}

// The number shown while the ring sweeps: `progress` 0..1 of the way to `value`.
function countUp(value, progress) {
  var v = Number(value), t = Math.max(0, Math.min(1, Number(progress)))
  return v >= 0 ? Math.round(v * t * 100) : -1
}

// One mini ring per provider for the bar: a letter under the ring (identity
// without colour) and the tightest limit as its arc.
function miniRings(entries) {
  var out = []
  for (var i = 0; i < (entries || []).length; i++) {
    var e = entries[i] || {}
    var name = String(e.name || "")
    var pc = e.percent === undefined || e.percent === null ? -1 : Number(e.percent)
    out.push({ letter: name.charAt(0).toUpperCase(), percent: pc >= 0 ? pc : -1, state: gaugeState(pc) })
  }
  return out
}

// ---- Sync: fresh usage for every saved account ---------------------------
// "updated just now" / "updated 4m ago" from an age in seconds; "not updated
// yet" when the account has never been probed.
function agoText(seconds) {
  var s = Number(seconds)
  if (!(s >= 0)) return "not updated yet"
  if (s < 60) return "updated just now"
  if (s < 3600) return "updated " + Math.floor(s / 60) + "m ago"
  if (s < 86400) return "updated " + Math.floor(s / 3600) + "h ago"
  return "updated " + Math.floor(s / 86400) + "d ago"
}

// "Synced 12:47 · 3 min ago" from the newest updatedAt of every saved account's
// record on disk; "" when no record has a usable time. Reads only, never fetches.
function lastSyncMs(providers) {
  var best = 0
  for (var i = 0; i < (providers || []).length; i++) {
    var accs = (providers[i] && providers[i].accounts) || []
    for (var j = 0; j < accs.length; j++) {
      var t = Date.parse(String((accs[j] && accs[j].updatedAt) || ""))
      if (t > best) best = t
    }
  }
  return best
}
function syncedLine(providers, nowMs) {
  var t = lastSyncMs(providers)
  if (!(t > 0)) return ""
  var d = new Date(t)
  var hh = (d.getHours() < 10 ? "0" : "") + d.getHours()
  var mm = (d.getMinutes() < 10 ? "0" : "") + d.getMinutes()
  var clock = function(ms) { var x = new Date(ms); return (x.getHours() < 10 ? "0" : "") + x.getHours() + ":" + (x.getMinutes() < 10 ? "0" : "") + x.getMinutes() }
  // Rate limited: the figures are the last real ones, so say so instead of "Synced".
  var limited = false, untilMs = 0
  for (var k = 0; k < (providers || []).length; k++) {
    if (providers[k] && providers[k].rateLimited === true) {
      limited = true
      untilMs = Math.max(untilMs, Number(providers[k].rateLimitedUntilMs || 0))
    }
  }
  if (limited) return "Last update " + hh + ":" + mm + " · rate limited" + (untilMs > Number(nowMs) ? " until " + clock(untilMs) : "")
  var mins = Math.max(0, Math.floor((Number(nowMs) - t) / 60000))
  var ago = mins < 1 ? "just now" : mins < 60 ? mins + " min ago" : mins < 1440 ? Math.floor(mins / 60) + " h ago" : Math.floor(mins / 1440) + " d ago"
  return "Synced " + hh + ":" + mm + " · " + ago
}

// The one-line reason a failed sync shows: the last non-empty line the tool
// printed, trimmed; else the exit code.
function syncReason(stderr, code) {
  var lines = String(stderr || "").split("\n").map(function(l) { return l.trim() }).filter(function(l) { return l !== "" })
  var line = lines.length ? lines[lines.length - 1] : "sync failed (exit " + code + ")"
  return line.length > 90 ? line.slice(0, 89) + "…" : line
}

// What the Sync button shows. `motion` false = no spinning: a static word.
// `resting` = the owner's own Sync ended a moment ago: same word, dimmed, and
// a press only shows SYNC_REST_HINT.
var SYNC_REST_HINT = "just synced, try again in a few seconds"
function syncView(running, error, motion, cooldownLeft) {
  if (running) return { label: motion ? "Syncing" : "Syncing…", disabled: true, resting: false, spin: !!motion, error: "" }
  return { label: "Sync", disabled: false, resting: cooldownLeft > 0, spin: false, error: String(error || "") }
}

// Loaded by node for the tests; QML never sees `module`.
if (typeof module !== "undefined") module.exports = {
  parseHidden: parseHidden, serializeHidden: serializeHidden, isHidden: isHidden,
  toggleHidden: toggleHidden, shownUsage: shownUsage, chips: chips, payerText: payerText, stripProviderName: stripProviderName, canManage: canManage, keyHints: keyHints, canAutoSwitch: canAutoSwitch, contrastRatio: contrastRatio, barSummary: barSummary,
  helpLine: helpLine, RATE_LIMIT_TEXT: RATE_LIMIT_TEXT, syncCooldownLeft: syncCooldownLeft, SYNC_COOLDOWN_MS: SYNC_COOLDOWN_MS, SYNC_REST_HINT: SYNC_REST_HINT, lastSyncMs: lastSyncMs, syncedLine: syncedLine,
  accountLabel: accountLabel, unsavedLogin: unsavedLogin, payerLine: payerLine, ageLine: ageLine,
  pickHero: pickHero, heroMode: heroMode, HERO_MODES: HERO_MODES, WATCH_STEPS: WATCH_STEPS, WARN_STEPS: WARN_STEPS,
  snapStep: snapStep, stepBy: stepBy, motionMode: motionMode, motionReduced: motionReduced, MOTION_MODES: MOTION_MODES,
  hiddenProviders: hiddenProviders, visibleProviders: visibleProviders, toggleProviderHidden: toggleProviderHidden,
  weekTokens: weekTokens, orderProviders: orderProviders, shareOf: shareOf, shareText: shareText,
  arcSweep: arcSweep, gaugeState: gaugeState, countUp: countUp, miniRings: miniRings, GAUGE_URGENT: GAUGE_URGENT,
  agoText: agoText, syncReason: syncReason, syncView: syncView
}
