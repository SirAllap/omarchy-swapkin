// Run: node tests/shellentry.test.js
const assert = require("assert")
const src = require("fs").readFileSync(require("path").join(__dirname, "../ShellEntry.js"), "utf8").replace(/^\.pragma library\n/, "")
const mod = {}
const M = new Function(src + "; return { find: find, parse: parse }")()
const ID = "io.github.sirallap.swapkin"
const real = { bar: { layout: { left: [{ id: "clock" }], center: [{ id: ID, autoSwitch: true, autoSwitchLeftPct: 1 }], right: [] } }, plugins: [{ id: "other" }] }
assert.strictEqual(M.find(real, ID).autoSwitchLeftPct, 1)
assert.strictEqual(M.find({ bar: { layout: { right: [{ id: ID, a: 1 }] } } }, ID).a, 1)
assert.strictEqual(M.find({ plugins: [{ id: ID, b: 2 }] }, ID).b, 2)
assert.strictEqual(M.find({ bar: { layout: { left: [{ id: ID, a: 1 }] } }, plugins: [{ id: ID, b: 2 }] }, ID).a, 1)
assert.strictEqual(M.find({ plugins: [{ id: "x" }] }, ID), null)
assert.strictEqual(M.find(null, ID), null)
assert.strictEqual(M.parse("{bad", ID), null)
assert.strictEqual(M.parse(JSON.stringify(real), ID).autoSwitch, true)
console.log("shellentry ok")
