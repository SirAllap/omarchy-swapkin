import QtQuick
import Quickshell.Io

// Keeps an eye on the active account while the panel is closed: one cheap pass
// every few minutes that refreshes the figures, warns once per threshold, and
// hands over to another account when this one is spent.
Item {
  id: service

  readonly property string tool: Qt.resolvedUrl("bin/swapkin").toString().replace(/^file:\/\//, "")
  property var settings: null

  readonly property int intervalMinutes: settings && settings.watchIntervalMin > 0
    ? settings.watchIntervalMin : 5

  Process {
    id: watchProcess
    command: [service.tool, "check"]
  }

  Timer {
    interval: service.intervalMinutes * 60000
    running: true
    repeat: true
    // A desktop that just started is the moment a spent account matters most.
    triggeredOnStart: true
    onTriggered: if (!watchProcess.running) watchProcess.running = true
  }
}
