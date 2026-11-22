import QtQuick
import Quickshell
import Quickshell.Io
import "ShellEntry.js" as ShellEntry

// Keeps an eye on the active account while the panel is closed: one cheap pass
// every few minutes that refreshes the figures, warns once per threshold, and
// hands over to another account when this one is spent.
Item {
  id: service

  readonly property string tool: Qt.resolvedUrl("bin/swapkin").toString().replace(/^file:\/\//, "")
  property var settings: null

  // The shell never hands a service plugin its settings (only bar widgets get
  // them), so the owner's own entry is read from shell.json, the one place the
  // panel writes to. A settings object passed in still wins.
  readonly property string shellConfigPath: {
    var base = Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")
    return base + "/omarchy/shell.json"
  }
  property var fileSettings: null
  readonly property var effective: settings || fileSettings

  function parseShellConfig(content) {
    service.fileSettings = ShellEntry.parse(content, "io.github.sirallap.swapkin")
  }

  FileView {
    id: shellFile
    path: service.shellConfigPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { service.parseShellConfig(text()); service.startCheck() }
    onLoadFailed: { service.fileSettings = null; service.startCheck() }
  }

  // Every pass re-reads shell.json first: a watch lost to an editor's
  // write-and-rename would otherwise leave the old values in the env for good.
  // The check starts when that read ends, so it always sees the current file.
  // loadGuard starts it anyway if that read never answers, so a lost signal can
  // not hold a pass back until the next one.
  property bool pending: false
  property double runStartedMs: 0
  readonly property int staleRunMs: 180000

  function note(message) {
    console.warn("swapkin watchdog: " + message)
    noteProcess.command = [service.tool, "note", message]
    noteProcess.running = false
    noteProcess.running = true
  }
  function startCheck() {
    if (!pending) return
    pending = false
    loadGuard.stop()
    if (watchProcess.running) {
      var age = Date.now() - runStartedMs
      if (age < staleRunMs) { note("skipped: previous check still running (" + Math.round(age / 1000) + "s)"); return }
      // A check never takes minutes: the run is stuck or its exit was lost.
      note("previous check ran " + Math.round(age / 1000) + "s, restarting it")
      watchProcess.running = false
    }
    runStartedMs = Date.now()
    watchProcess.running = true
  }
  function requestCheck() {
    pending = true
    if (settings != null) { startCheck(); return }
    loadGuard.restart()
    shellFile.reload()
  }

  readonly property int intervalMinutes: effective && effective.watchIntervalMin > 0
    ? effective.watchIntervalMin : 5

  // The auto-switch and warn-at settings reach the script as SWAPKIN_<KEY>. A setting the
  // owner never touched is left out, so config.json keeps working for them.
  readonly property var checkEnv: {
    var env = {}
    var keys = ["autoSwitch", "autoSwitchLeftPct", "autoSwitchReturn", "alertAt"]
    for (var i = 0; i < keys.length; i++) {
      var v = effective ? effective[keys[i]] : undefined
      if (v !== undefined && v !== null && v !== "") env["SWAPKIN_" + keys[i].toUpperCase()] = String(v)
    }
    return env
  }

  Process {
    id: watchProcess
    command: [service.tool, "check"]
    environment: service.checkEnv
    onExited: service.runStartedMs = 0
  }

  Process { id: noteProcess }

  Timer {
    id: loadGuard
    interval: 5000
    onTriggered: service.startCheck()
  }

  Timer {
    interval: service.intervalMinutes * 60000
    running: true
    repeat: true
    // A desktop that just started is the moment a spent account matters most.
    triggeredOnStart: true
    onTriggered: service.requestCheck()
  }
}
