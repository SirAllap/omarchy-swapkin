// Run: node tests/models.test.js
const assert = require("assert")
const src = require("fs").readFileSync(require("path").join(__dirname, "../Models.js"), "utf8").replace(/^\.pragma library\n/, "")
const mod = { exports: {} }
new Function("module", src)(mod)
const M = mod.exports

assert.deepStrictEqual(M.parseHidden(""), [])
assert.deepStrictEqual(M.parseHidden(undefined), [])
assert.deepStrictEqual(M.parseHidden(" a-1 , b-2,,a-1 "), ["a-1", "b-2"])
assert.strictEqual(M.serializeHidden(["a-1", "b-2", "a-1"]), "a-1,b-2")
assert.strictEqual(M.toggleHidden("", "a-1"), "a-1")
assert.strictEqual(M.toggleHidden("a-1", "b-2"), "a-1,b-2")
assert.strictEqual(M.toggleHidden("a-1,b-2", "a-1"), "b-2")
assert.strictEqual(M.toggleHidden("a-1", "a-1"), "")
assert.ok(M.isHidden("a-1,b-2", "b-2"))
assert.ok(!M.isHidden("", "b-2"))

const usage = {
  "acme-big-4-8": { inputTokens: 10, outputTokens: 5, cacheReadInputTokens: 100, cacheCreationInputTokens: 1 },
  "acme-big-5": { inputTokens: 1 },
  "acme-small-4-5": { outputTokens: 7 }
}
// Nothing hidden: same models, untouched values; a new model is shown by default.
assert.deepStrictEqual(Object.keys(M.shownUsage(usage, "")), Object.keys(usage))
assert.deepStrictEqual(Object.keys(M.shownUsage(usage, "acme-big-4-8,gone-model")), ["acme-big-5", "acme-small-4-5"])
assert.strictEqual(M.shownUsage(usage, "acme-big-5")["acme-big-4-8"], usage["acme-big-4-8"])
assert.strictEqual(Object.keys(usage).length, 3) // the source is not mutated
assert.deepStrictEqual(M.shownUsage(null, "x"), {})

const c = M.chips(usage, "acme-big-5", (id) => id.toUpperCase())
assert.deepStrictEqual(c.map((x) => x.id), ["acme-big-4-8", "acme-small-4-5", "acme-big-5"])
assert.strictEqual(c[0].id, "acme-big-4-8")
assert.strictEqual(c[0].total, 116)
assert.strictEqual(c[0].name, "ACME-BIG-4-8")
assert.deepStrictEqual(c.map((x) => x.shown), [true, true, false])
console.log("models: all passed")

// payerText: chip text for the selected provider's paying account.
assert.strictEqual(M.payerText({ mode: "hot" }, { name: "work" }), "work")
assert.strictEqual(M.payerText({ mode: "cold", tierLabel: "Free" }, null), "Free")
assert.strictEqual(M.payerText({ mode: "never", tierLabel: "Starter Quota" }, null), "Starter Quota · one login")
assert.strictEqual(M.payerText({ mode: "never" }, { name: "me" }), "me · one login")
// canManage / keyHints: no manage or switch where they do nothing.
const agy = { mode: "never", addHint: "keeps one sign-in" }
assert.strictEqual(M.canManage(agy, false), true) // Antigravity gets a page too: its one login
assert.strictEqual(M.canManage(null, false), false)
assert.strictEqual(M.canManage({ mode: "cold", addHint: "add one" }, false), true)
assert.strictEqual(M.canManage(agy, true), true)
const keys = (h, c, m) => M.keyHints(h, c, m).map(x => x.k).join(",")
assert.strictEqual(keys(false, false, false), "↑ ↓,r")
assert.strictEqual(keys(false, true, false), "↑ ↓,m,r,\u002c")
assert.strictEqual(keys(true, true, false), "↑ ↓,← →,a,m,r,\u002c")
assert.strictEqual(keys(true, true, true), "↑ ↓,← →,u a,n,c,f,s,r,m,\u002c")
assert.strictEqual(M.keyHints(true, true, false, true, true).map(x => x.k).join("|"), "↑ ↓|← →|w|o|\u002c") // settings view: move, change, pace, models, back
console.log("models: payer and key bar ok")

// Provider name is not repeated in the plan text.
assert.strictEqual(M.stripProviderName("Antigravity Starter Quota", "Antigravity"), "Starter Quota")
assert.strictEqual(M.stripProviderName("Max 5x", "Claude Code"), "Max 5x")
assert.strictEqual(M.stripProviderName("Antigravity", "Antigravity"), "Antigravity")
assert.strictEqual(M.payerText({ providerName: "Antigravity", tierLabel: "Antigravity Starter Quota", mode: "never" }, null), "Starter Quota · one login")
console.log("models: provider-name strip ok")
// The legacy "next message" pill is gone from the provider list and detail title.
assert.ok(!/ModePill/.test(require("fs").readFileSync(require("path").join(__dirname, "../Panel.qml"), "utf8")))
console.log("models: no ModePill ok")

// Provider order: Claude with an active account first, then most used this week.
const day = n => ({ tokenCount: n })
const prov = (id, tokens, accounts) => ({ providerId: id, recentDays: [day(tokens)], accounts: accounts || [] })
const ordered = M.orderProviders([prov("antigravity", 5), prov("codex", 90), prov("claude", 1, [{ active: true }]), prov("copilot", 90)])
assert.deepStrictEqual(ordered.map(x => x.providerId), ["claude", "codex", "copilot", "antigravity"])
assert.deepStrictEqual(M.orderProviders([prov("codex", 1), prov("claude", 9, [{ active: false }])]).map(x => x.providerId), ["claude", "codex"])
assert.deepStrictEqual(M.orderProviders(ordered).map(x => x.providerId), ordered.map(x => x.providerId))
assert.strictEqual(M.weekTokens({ recentDays: Array.from({ length: 9 }, () => day(1)) }), 7)
// Bars read as a share of the family.
assert.strictEqual(M.shareOf(25, 100), 0.25)
assert.strictEqual(M.shareText(62, 100), "62%")
assert.strictEqual(M.shareText(1, 0), "")
console.log("models: order and share ok")
// The top "NEXT MESSAGE IS PAID BY" strip is gone; paid-by lives in the detail header.
assert.ok(!/NEXT MESSAGE IS PAID BY/.test(require("fs").readFileSync(require("path").join(__dirname, "../Panel.qml"), "utf8")))

// Harm fixes: auto-switch only for Claude, key bar follows, contrast, bar summary.
assert.ok(M.canAutoSwitch({ providerId: "claude" }))
assert.ok(!M.canAutoSwitch({ providerId: "codex" }) && !M.canAutoSwitch(null))
assert.ok(M.keyHints(true, true, true, false).every(h => h.k !== "s"))
assert.ok(M.keyHints(true, true, true, true).some(h => h.k === "s"))
assert.ok(M.keyHints(true, true, true).some(h => h.k === "s"))
assert.strictEqual(M.contrastRatio(1, 0), 21)
assert.ok(M.contrastRatio(0.2, 0.05) < 4.5)
assert.strictEqual(M.barSummary("Claude Code", "work", 0.92), "Claude Code · work · 92% used")
assert.strictEqual(M.barSummary("Codex", "", -1), "Codex")
{
  const panel = require("fs").readFileSync(require("path").join(__dirname, "../Panel.qml"), "utf8")
  assert.ok(/"sure\?"/.test(panel) && /forgetPending !== name/.test(panel))
  assert.ok(!/Qt\.darker\(foreground, 1\.55\)/.test(panel))
  assert.ok(!/duration: 160;/.test(panel))
}
console.log("models: harm fixes ok")

// Gauge maths
assert.strictEqual(M.arcSweep(0), 0)
assert.strictEqual(M.arcSweep(0.5), 180)
assert.strictEqual(M.arcSweep(1), 360)
assert.strictEqual(M.arcSweep(1.7), 360)
assert.strictEqual(M.arcSweep(-1), 0)
assert.strictEqual(M.arcSweep(undefined), 0)
assert.strictEqual(M.gaugeState(-1), "none")
assert.strictEqual(M.gaugeState(NaN), "none")
assert.strictEqual(M.gaugeState(0), "ok")
assert.strictEqual(M.gaugeState(0.899), "ok")
assert.strictEqual(M.gaugeState(0.9), "urgent")
assert.strictEqual(M.countUp(0.72, 0), 0)
assert.strictEqual(M.countUp(0.72, 0.5), 36)
assert.strictEqual(M.countUp(0.72, 1), 72)
assert.strictEqual(M.countUp(0.72, 9), 72)
assert.strictEqual(M.countUp(-1, 1), -1)
assert.deepStrictEqual(M.miniRings([{ name: "Claude Code", percent: 0.95 }, { name: "codex" }]),
  [{ letter: "C", percent: 0.95, state: "urgent" }, { letter: "C", percent: -1, state: "none" }])
console.log("gauge maths ok")

// Sync: time-ago text and button state
assert.strictEqual(M.agoText(-1), "not updated yet")
assert.strictEqual(M.agoText(undefined), "not updated yet")
assert.strictEqual(M.agoText(0), "updated just now")
assert.strictEqual(M.agoText(59), "updated just now")
assert.strictEqual(M.agoText(60), "updated 1m ago")
assert.strictEqual(M.agoText(240), "updated 4m ago")
assert.strictEqual(M.agoText(7200), "updated 2h ago")
assert.strictEqual(M.agoText(200000), "updated 2d ago")
assert.strictEqual(M.syncReason("warn\nclaude: login expired\n", 1), "claude: login expired")
assert.strictEqual(M.syncReason("", 3), "sync failed (exit 3)")
assert.strictEqual(M.syncReason("x".repeat(200), 1).length, 90)
assert.deepStrictEqual(M.syncView(true, "", true), { label: "Syncing", disabled: true, resting: false, spin: true, error: "" })
assert.deepStrictEqual(M.syncView(true, "old", false), { label: "Syncing…", disabled: true, resting: false, spin: false, error: "" })
assert.deepStrictEqual(M.syncView(false, "boom", true), { label: "Sync", disabled: false, resting: false, spin: false, error: "boom" })
assert.ok(["↑ ↓", "m", "r"].every((k, i) => M.keyHints(false, true, false)[i].k === k))
for (const [h, c] of [[true, true], [false, true], [false, false]]) assert.ok(M.keyHints(h, c, false).some(x => x.k === "r" && x.l === "sync"))
console.log("models: sync ok")

// ---- manage and settings helpers ----
assert.strictEqual(M.accountLabel({ name: "work", label: "Day job" }), "Day job")
assert.strictEqual(M.accountLabel({ name: "work", label: "  " }), "work")
assert.strictEqual(M.accountLabel({ name: "work" }), "work")
assert.strictEqual(M.unsavedLogin({ signedIn: true, accounts: [] }), true)
assert.strictEqual(M.unsavedLogin({ signedIn: true, accounts: [{ name: "a" }] }), false)
assert.strictEqual(M.unsavedLogin({ signedIn: false, accounts: [] }), false)
// A plan is a plan, never a payer.
assert.strictEqual(M.payerLine({ mode: "cold", tierLabel: "Free", providerName: "Codex" }, null), "Free plan")
assert.strictEqual(M.payerLine({ mode: "cold", tierLabel: "Pro plan", providerName: "Codex" }, null), "Pro plan")
assert.strictEqual(M.payerLine({ mode: "hot" }, { name: "work", label: "Day job" }), "Paid by Day job")
assert.strictEqual(M.payerLine({ mode: "never", tierLabel: "Antigravity Starter Quota", providerName: "Antigravity" }, null), "Starter Quota plan · one login")
assert.strictEqual(M.payerLine({ mode: "cold", signedIn: true }, null), "Signed in")
assert.ok(!/Paid by Free/.test(M.payerLine({ mode: "cold", tierLabel: "Free" }, null)))
assert.strictEqual(M.ageLine({ age: 240 }), "updated 4m ago")
assert.strictEqual(M.ageLine({ age: -1 }), "no limits yet")
// Hero ring window by setting.
const wins = [{ kind: "session", percent: 0.2 }, { kind: "weekly", percent: 0.6 }, { kind: "other", percent: 0.9 }]
assert.strictEqual(M.pickHero(wins, "tightest").percent, 0.9)
assert.strictEqual(M.pickHero(wins, "weekly").percent, 0.6)
assert.strictEqual(M.pickHero(wins, "session").percent, 0.2)
assert.strictEqual(M.pickHero([{ kind: "other", percent: 0.4 }], "weekly").percent, 0.4)
assert.strictEqual(M.pickHero([], "weekly"), null)
assert.strictEqual(M.heroMode("junk"), "tightest")
// Steps snap to what the code supports, whatever was written by hand.
assert.strictEqual(M.snapStep(M.WATCH_STEPS, 7, 5), 5)
assert.strictEqual(M.snapStep(M.WATCH_STEPS, "abc", 5), 5)
assert.strictEqual(M.stepBy(M.WARN_STEPS, 90, 1, 90), 95)
assert.strictEqual(M.stepBy(M.WARN_STEPS, 95, 1, 90), 95)
assert.strictEqual(M.stepBy(M.WARN_STEPS, 50, -1, 90), 50)
// Motion: follow the system unless told otherwise.
assert.strictEqual(M.motionReduced("system", true), true)
assert.strictEqual(M.motionReduced("system", false), false)
assert.strictEqual(M.motionReduced("reduce", false), true)
assert.strictEqual(M.motionReduced("full", true), false)
assert.strictEqual(M.motionReduced("junk", true), true)
// Hiding providers keeps at least one.
const pl = [{ providerId: "claude" }, { providerId: "codex" }]
assert.deepStrictEqual(M.visibleProviders(pl, "codex").map(p => p.providerId), ["claude"])
assert.deepStrictEqual(M.visibleProviders(pl, "claude,codex").map(p => p.providerId), ["claude", "codex"])
assert.strictEqual(M.toggleProviderHidden("codex", "claude", ["claude", "codex"]), "codex")
assert.strictEqual(M.toggleProviderHidden("", "codex", ["claude", "codex"]), "codex")
// Key bar: manage and settings views.
assert.ok(M.keyHints(true, true, true, false).some(h => h.k === "u a" && h.l === "use"))
assert.ok(M.keyHints(true, true, true, false).some(h => h.k === "f" && h.l === "forget"))
assert.ok(M.keyHints(false, true, true, false).some(h => h.k === "v" && h.l === "save"))
assert.ok(M.keyHints(true, true, true, false, false, false).every(h => h.k !== "u a"))
console.log("models: manage and settings helpers ok")

// Rate limit: the real reason, and a cooldown for Sync.
assert.strictEqual(M.helpLine({ authHelpText: "Run `claude auth login` to restore authoritative usage.", rateLimited: true }), "Anthropic is rate limiting usage checks; showing local stats.")
assert.strictEqual(M.helpLine({ authHelpText: "Anthropic's usage endpoint is rate limiting checks right now (retry after 30s). Local Claude Code stats are still shown." }), M.RATE_LIMIT_TEXT)
assert.strictEqual(M.helpLine({ authHelpText: "Run `claude auth login` to restore authoritative usage." }), "Run `claude auth login` to restore authoritative usage.")
assert.strictEqual(M.syncCooldownLeft(0, 100000), 0)
assert.strictEqual(M.syncCooldownLeft(100000, 105000), 25)
assert.strictEqual(M.syncCooldownLeft(100000, 131000), 0)
assert.deepStrictEqual(M.syncView(false, "", true, 12), { label: "Sync", disabled: false, resting: true, spin: false, error: "" })
assert.deepStrictEqual(M.syncView(false, "", true, 0), { label: "Sync", disabled: false, resting: false, spin: false, error: "" })
assert.strictEqual(M.syncView(true, "", true, 12).resting, false)
assert.strictEqual(M.SYNC_REST_HINT, "just synced, try again in a few seconds")
console.log("models: rate limit ok")

// Last sync line: newest updatedAt on disk, read only.
{
  const t = new Date(2026, 10, 22, 12, 47, 0)
  const older = new Date(2026, 10, 22, 9, 0, 0)
  const provs = [{ accounts: [{ updatedAt: older.toISOString() }, { updatedAt: t.toISOString() }] }, { accounts: [{}, { updatedAt: "junk" }] }]
  assert.strictEqual(M.lastSyncMs(provs), t.getTime())
  assert.strictEqual(M.syncedLine(provs, t.getTime() + 3 * 60000 + 5000), "Synced 12:47 · 3 min ago")
  assert.strictEqual(M.syncedLine(provs, t.getTime() + 20000), "Synced 12:47 · just now")
  assert.strictEqual(M.syncedLine(provs, t.getTime() + 125 * 60000), "Synced 12:47 · 2 h ago")
  const until = t.getTime() + 15 * 60000
  const limited = [{ rateLimited: true, rateLimitedUntilMs: until, accounts: [{ updatedAt: t.toISOString() }] }]
  assert.strictEqual(M.syncedLine(limited, t.getTime() + 60000), "Last update 12:47 · rate limited until 13:02")
  assert.strictEqual(M.syncedLine([{ rateLimited: true, accounts: [{ updatedAt: t.toISOString() }] }], t.getTime() + 60000), "Last update 12:47 · rate limited")
  assert.strictEqual(M.syncedLine([], 1), "")
  assert.strictEqual(M.syncedLine([{ accounts: [{ updatedAt: "" }] }], 1), "")
  console.log("models: synced line ok")
}
