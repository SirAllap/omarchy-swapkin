.pragma library

// Finds one plugin's own entry in shell.json, the same places the shell's
// updateEntryInline writes to: a bar layout entry (any Util.barSections array) first,
// then the top-level plugins list. Pure functions, no QML, so the same file runs
// under node for the tests.

var SECTIONS = ["left", "centerBegin", "center", "centerEnd", "right", "tray"]

function find(config, id) {
  if (!config || typeof config !== "object") return null
  var layout = config.bar && typeof config.bar === "object" ? config.bar.layout : null
  if (layout && typeof layout === "object") {
    for (var s = 0; s < SECTIONS.length; s++) {
      var arr = Array.isArray(layout[SECTIONS[s]]) ? layout[SECTIONS[s]] : []
      for (var i = 0; i < arr.length; i++) if (arr[i] && arr[i].id === id) return arr[i]
    }
  }
  var plugins = Array.isArray(config.plugins) ? config.plugins : []
  for (var j = 0; j < plugins.length; j++) if (plugins[j] && plugins[j].id === id) return plugins[j]
  return null
}

function parse(text, id) {
  try { return find(JSON.parse(String(text || "")), id) } catch (e) { return null }
}
