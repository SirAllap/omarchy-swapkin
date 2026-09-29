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
