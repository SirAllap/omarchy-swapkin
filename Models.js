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

// Loaded by node for the tests; QML never sees `module`.
if (typeof module !== "undefined") module.exports = {
  parseHidden: parseHidden, serializeHidden: serializeHidden, isHidden: isHidden,
  toggleHidden: toggleHidden, shownUsage: shownUsage, chips: chips
}
