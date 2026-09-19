import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.sirallap.swapkin"
  ipcTarget: "io.github.sirallap.swapkin"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var providers: usage.enabledProviders
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  // Limits come from the account's own probe, not from the shared collector
  // record: right after a switch that record still holds the other account's
  // figures, and showing those is worse than showing nothing.
  readonly property var limits: activeAccount && (activeAccount.limits || []).length > 0
    ? limitWindows(activeAccount)
    : limitWindows(provider)
  readonly property bool accountsRefreshing: accountsProcess.running || probeProcess.running
  readonly property var models: modelRows(provider)
  readonly property var headline: bindingWindow(provider)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  readonly property bool alarming: (!!headline && headline.percent >= 0.9) || balanceAlarming

  function clamp(v, lo, hi) { return Math.max(lo, Math.min(hi, v)) }
  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  function selectProvider(index) {
    if (providers.length === 0) return
    var wrapped = ((index % providers.length) + providers.length) % providers.length
    selectedProviderId = providers[wrapped].providerId
  }

  function refreshNow() {
    usage.refreshAll(true)
  }

  function launchAgent() {
    if (root.bar) root.bar.run("omarchy-agent --pick")
    root.close()
  }

  // ---------------------------------------------------------------- limits
  //
  // Both providers report the same two shapes: a short rolling session window
  // and a long weekly one. Everything below normalizes them into one record so
  // the meters and the hero speak a single language.

  // Claude spells its windows out ("Session (5-hour)"), Codex abbreviates
  // them ("5h window", "30m window"). Both have to land on the same record.
  function windowIsLong(text) {
    return text.indexOf("week") >= 0 || text.indexOf("7-day") >= 0 || text.indexOf("seven") >= 0
      || text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0
  }

  function windowSpanMs(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0 || text.indexOf("30-day") >= 0) return 30 * 24 * 3600 * 1000
    if (windowIsLong(text)) return 7 * 24 * 3600 * 1000
    var hours = text.match(/(\d+)\s*-?\s*h(?:our)?\b/)
    if (hours) return Number(hours[1]) * 3600 * 1000
    var minutes = text.match(/(\d+)\s*-?\s*m(?:in(?:ute)?s?)?\b/)
    if (minutes) return Number(minutes[1]) * 60 * 1000
    return 0
  }

  function windowTitle(label) {
    var text = String(label || "").toLowerCase()
    if (text.indexOf("month") >= 0) return "Monthly"
    if (windowIsLong(text)) return "Weekly"
    if (text.indexOf("session") >= 0 || windowSpanMs(label) > 0) return "Session"
    var plain = String(label || "").replace(/\s*\(.*\)\s*/, "").trim()
    return plain === "" ? "Limit" : plain
  }

  // A collector that already knows which window a limit belongs to says so,
  // and that beats reading it back out of the label: a model-scoped limit is
  // titled after its model, and a name like "Opus 5 (1M context)" would parse
  // as a one-minute window.
  function limitWindow(label, percent, resetAt, title) {
    return {
      title: String(title || "") !== "" ? String(title) : windowTitle(label),
      percent: Number(percent),
      resetAt: String(resetAt || "")
    }
  }

  function limitWindows(p) {
    if (!p) return []
    var out = []
    var list = p.limits || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i] || {}
      var percent = Number(entry.percent)
      if (percent >= 0) out.push(limitWindow(entry.label, percent, entry.resetsAt, entry.title))
    }
    return out
  }

  // The window that decides how much room is left — the fullest one, since
  // that is what stops the next prompt.
  function bindingWindow(p) {
    var windows = limitWindows(p)
    var best = null
    for (var i = 0; i < windows.length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  // Pace: where a rolling window says you should be by now, and where you are.
  // A week that resets in 3d 19h is 4d 5h old, so 60% of it is spent.
  function paceFor(w) {
    if (!w) return null
    var span = windowSpanMs(w.title === "Weekly" ? "week" : w.title)
    if (!(span > 0)) return null
    var remaining = resetMsFor(w)
    if (!(remaining > 0)) return null
    var elapsed = clamp(span - remaining, 0, span)
    var budget = elapsed / span
    if (!(budget > 0.02)) return null
    var used = Number(w.percent)
    if (!(used >= 0)) return null
    var rate = used / elapsed
    var exhaustsIn = rate > 0 ? (1 - used) / rate : Infinity
    return {
      budget: budget,
      diff: used - budget,
      day: Math.min(7, Math.floor(elapsed / 86400000) + 1),
      days: Math.round(span / 86400000),
      runsOutMs: used < 1 && exhaustsIn < remaining ? exhaustsIn : -1
    }
  }

  function paceText(w) {
    var p = paceFor(w)
    if (!p) return ""
    var ahead = Math.round(Math.abs(p.diff) * 100)
    var pacing = p.diff > 0.03 ? ahead + "% ahead of pace"
      : p.diff < -0.03 ? ahead + "% under pace" : "on pace"
    return "Day " + p.day + "/" + p.days + " · budget " + Math.round(p.budget * 100) + "% · " + pacing
  }

  // The sentence that actually decides whether to switch account today.
  function forecastText(w) {
    var p = paceFor(w)
    if (!p) return ""
    if (Number(w.percent) >= 1) return "Out of quota until it resets"
    if (p.runsOutMs < 0) return ""
    return "At this pace it runs out in " + formatDuration(p.runsOutMs)
  }

  function paceColour(w) {
    var p = paceFor(w)
    if (!p) return root.dim
    if (Number(w.percent) >= 1 || p.runsOutMs >= 0) return root.urgent
    return p.diff > 0.03 ? root.foreground : root.dim
  }

  function resetMsFor(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms - root.nowMs : -1
  }

  function formatDuration(ms) {
    if (!(ms > 0)) return "now"
    var minutes = Math.floor(ms / 60000)
    var hours = Math.floor(minutes / 60)
    var days = Math.floor(hours / 24)
    if (days > 0) return days + "d " + (hours % 24) + "h"
    if (hours > 0) return hours + "h " + (minutes % 60) + "m"
    return Math.max(1, minutes) + "m"
  }

  // ---------------------------------------------------------------- balance
  //
  // Prepaid agents report a credit ledger instead of rate-limit windows: the
  // record's balance object carries remaining, funded, and spent amounts.

  function currencyPrefix(currency) {
    var code = String(currency || "USD").toUpperCase()
    if (code === "USD") return "$"
    if (code === "EUR") return "€"
    if (code === "GBP") return "£"
    return code + " "
  }

  function formatMoney(value, currency) {
    var amount = Number(value)
    if (!isFinite(amount)) amount = 0
    return currencyPrefix(currency) + amount.toFixed(2)
  }

  function balanceDetailText(b) {
    if (!b || !(b.funded > 0)) return ""
    var text = formatMoney(b.spent, b.currency) + " spent of " + formatMoney(b.funded, b.currency) + " funded"
    if (b.estimated) text += " · estimated"
    return text
  }

  // ---------------------------------------------------------------- content

  // The plan you pay for, under the name of the tool it pays for. Limits live
  // in their own section; the hero just says what this is.
  function heroMeta(p) {
    if (!p) return ""
    if (String(p.usageStatusText || "") !== "") return p.usageStatusText
    var tier = String(p.tierLabel || "")
    if (tier === "") return "Subscription"
    return tier.charAt(0).toUpperCase() + tier.slice(1)
  }

  // Local calendar date, recomputed from nowMs so a panel left open across
  // midnight moves the "Today" row with the clock.
  function todayDate() {
    var now = new Date(root.nowMs)
    return now.getFullYear()
      + "-" + String(now.getMonth() + 1).padStart(2, "0")
      + "-" + String(now.getDate()).padStart(2, "0")
  }

  function dayName(date) {
    var parsed = new Date(String(date || "") + "T00:00:00")
    if (isNaN(parsed.getTime())) return String(date || "")
    return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][parsed.getDay()]
  }

  function dayLabel(date, today) {
    if (today) return "Today"
    return dayName(date)
  }

  function dayTooltip(day, today) {
    if (!day) return ""
    var parsed = new Date(String(day.date) + "T00:00:00")
    var label = isNaN(parsed.getTime())
      ? String(day.date)
      : dayName(day.date) + " " + (parsed.getMonth() + 1) + "/" + parsed.getDate()
    var text = label + " · " + usage.formatTokenCount(Number(day.messageCount || 0)) + " tokens"
    // Prompt and session counts only exist for today, so they ride along here
    // instead of taking a section of their own. Billing-API agents never
    // count prompts, and "0 prompts" would read as a quiet day, not a gap.
    if (today && provider && provider.hasPromptStats !== false)
      text += " · " + Number(provider.todayPrompts || 0) + " prompts · "
        + Number(provider.todaySessions || 0) + " sessions"
    return text
  }

  function weekPeak(p) {
    var days = p ? (p.recentDays || []) : []
    var peak = 0
    for (var i = 0; i < days.length; i++) peak = Math.max(peak, Number(days[i].messageCount || 0))
    return peak
  }

  function modelRows(p) {
    var usageByModel = p ? (p.modelUsage || {}) : {}
    var rows = []
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      rows.push({
        name: usage.friendlyModelName(id),
        total: input + output + cacheRead + cacheWrite,
        input: input,
        output: output,
        cacheRead: cacheRead,
        cacheWrite: cacheWrite
      })
    }
    rows.sort(function(a, b) { return b.total - a.total })
    return rows.slice(0, 4)
  }

  function modelTooltip(row) {
    if (!row) return ""
    return "In " + usage.formatTokenCount(row.input)
      + " · out " + usage.formatTokenCount(row.output)
      + " · cache read " + usage.formatTokenCount(row.cacheRead)
      + " · cache write " + usage.formatTokenCount(row.cacheWrite)
  }

  // Only speaks up when the numbers cover more than this machine.
  function footerText() {
    if (usage.syncStatusText !== "") return usage.syncStatusText
    if (provider && provider.syncEnabled && provider.syncDeviceCount > 0)
      return "Merged from " + provider.syncDeviceCount + " device" + (provider.syncDeviceCount === 1 ? "" : "s")
    return ""
  }

  // Used to tell a light bar from a dark one, which decides how much contrast
  // the drawn marks and meters need.
  function colorChannelLuminance(value) {
    var channel = Number(value)
    if (!isFinite(channel)) return 0
    return channel <= 0.03928 ? channel / 12.92 : Math.pow((channel + 0.055) / 1.055, 2.4)
  }

  function colorLuminance(color) {
    return 0.2126 * colorChannelLuminance(color.r)
      + 0.7152 * colorChannelLuminance(color.g)
      + 0.0722 * colorChannelLuminance(color.b)
  }

  // Nothing to report, nothing in the bar: Bar.qml collapses a slot whose item
  // is invisible, so the icon appears the moment the first scan finds usage and
  // stays away entirely on a machine that has never run either CLI.
  visible: providers.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onProviderIndexChanged: if (panelFlick) panelFlick.contentY = 0
  onOpenedChanged: if (opened) {
    cursorActive = false
    nowMs = Date.now()
    if (panelFlick) panelFlick.contentY = 0
    usage.refreshLimits()
    reloadAccounts()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // ------------------------------------------------------------- accounts
  // Accounts are saved by the bundled swapkin tool. Switching swaps the Claude
  // login inside one shared config dir, so settings, sessions and MCP logins are
  // untouched and open sessions pick up the new account on their next request.
  readonly property string accountTool: Qt.resolvedUrl("bin/swapkin").toString().replace(/^file:\/\//, "")
  readonly property var palette: ["#7fa7d9", "#d97757", "#8fb572", "#d9a54a", "#b98fd9",
                                  "#6fc7c0", "#d98fa8", "#a8a35c", "#7f8fd9", "#c98f6f"]
  property var accounts: []
  property bool managing: false
  property string colourEditing: ""
  readonly property bool hasAccounts: !!provider && provider.providerId === "claude" && accounts.length > 0
  readonly property var activeAccount: {
    for (var i = 0; i < accounts.length; i++) if (accounts[i].active) return accounts[i]
    return null
  }
  // The account in use stays on top - it is the one the limits below belong to.
  // The rest follow with the most room left first, so the next row is the one
  // worth switching to.
  readonly property var accountsByRoom: {
    var rest = accounts.filter(function(a) { return !a.active })
    rest.sort(function(a, b) { return accountWeekly(a) - accountWeekly(b) })
    var current = accounts.filter(function(a) { return a.active })
    return current.concat(rest)
  }

  // Only offer colours nobody else is using, plus this account's own.
  function coloursFor(a) {
    var taken = {}
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].name !== a.name) taken[String(accounts[i].colour || "")] = true
    var free = palette.filter(function(c) { return !taken[c] })
    var mine = accountColour(a)
    if (free.indexOf(mine) < 0) free.unshift(mine)
    return free
  }

  function accountColour(a) {
    if (a && String(a.colour || "") !== "") return a.colour
    var index = 0
    for (var i = 0; i < accounts.length; i++) if (accounts[i] === a) index = i
    return palette[index % palette.length]
  }

  function accountWeekly(a) {
    var value = a ? Number(a.weekly) : NaN
    return isFinite(value) ? value : 0
  }

  function accountPlan(a) {
    return String((a && (a.tierLabel || a.plan)) || "")
  }

  // An idle login is only probed while its token is valid, so say how old the figure is.
  function accountAge(a) {
    if (a && a.active) return "active"
    var seconds = a ? Number(a.age) : -1
    if (!(seconds >= 0)) return "no limits yet"
    return seconds < 120 ? "just now" : formatDuration(seconds * 1000) + " ago"
  }

  Process {
    id: accountsProcess
    command: [root.accountTool, "list", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.accounts = JSON.parse(text) } catch (e) { root.accounts = [] }
      }
    }
  }

  // How many Claude Code sessions a switch would move. They pick the new login
  // up on their next request, so this is "who is affected", not "who must restart".
  property int openSessions: 0

  // Today's tokens priced at API rates. An estimate, from prices.json.
  property real todayCost: -1

  Process {
    id: costProcess
    command: [root.accountTool, "cost"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var value = JSON.parse(text).today
          root.todayCost = value === null ? -1 : Number(value)
        } catch (e) { root.todayCost = -1 }
      }
    }
  }

  Process {
    id: sessionCountProcess
    command: ["bash", "-c", "pgrep -x claude | wc -l"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.openSessions = parseInt(text) || 0
    }
  }

  Process {
    id: accountActionProcess
    onExited: function(exitCode) {
      root.reloadAccounts()
      root.refreshNow()
    }
  }

  Process {
    id: probeProcess
    command: [root.accountTool, "usage"]
    // Fresh figures land on the next listing.
    onExited: root.reloadAccounts(false)
  }

  function reloadAccounts(probe) {
    if (!accountsProcess.running) accountsProcess.running = true
    if (probe !== false && !probeProcess.running) probeProcess.running = true
    if (!sessionCountProcess.running) sessionCountProcess.running = true
    if (!costProcess.running) costProcess.running = true
  }

  // Worth suggesting only when the difference is big enough to act on.
  readonly property var roomier: {
    var current = activeAccount
    if (!current || accounts.length < 2) return null
    var best = null
    for (var i = 0; i < accounts.length; i++) {
      var other = accounts[i]
      if (other.active || !isFinite(Number(other.weekly))) continue
      if (!best || accountWeekly(other) < accountWeekly(best)) best = other
    }
    if (!best) return null
    return (accountWeekly(current) - accountWeekly(best)) >= 0.2 ? best : null
  }

  function runAccountAction(args) {
    if (accountActionProcess.running) return
    accountActionProcess.command = [accountTool].concat(args)
    accountActionProcess.running = true
  }

  function useAccount(name) { runAccountAction(["use", name]) }
  function recolourAccount(name, colour) { runAccountAction(["colour", name, colour]) }
  function forgetAccount(name) { runAccountAction(["remove", name]) }

  // Signing in needs a terminal: the tool opens Claude Code in a throwaway
  // config dir and imports the login once you are done.
  function addAccount() {
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation " + accountTool + " add")
    root.close()
  }

  function cycleAccount() {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].active) {
        useAccount(accounts[(i + 1) % accounts.length].name)
        return
      }
  }

  Component.onCompleted: reloadAccounts()

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refreshNow(); return "ok" }
    function next(): string { root.selectProvider(root.providerIndex + 1); return "ok" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󱚣"

    // Two rings overlapping by half: the filled one is the account in
    // use, in its own colour. Drawn rather than shipped as an asset, because
    // the colour changes with the account.
    iconComponent: Component {
      // The loader hands this item the whole optical canvas, so fill it and
      // centre the drawing inside: otherwise the pair sits against the left
      // edge and the bar spacing looks lopsided.
      Item {
        anchors.fill: parent

        Item {
          readonly property real ring: Math.round(Style.font.display * 0.5)
          readonly property color tint: root.accountColour(root.activeAccount)

          width: ring * 1.5
          height: ring
          anchors.centerIn: parent

          Rectangle {
            width: parent.ring
            height: width
            radius: width / 2
            color: parent.tint
            x: 0
          }

          Rectangle {
            width: parent.ring
            height: width
            radius: width / 2
            color: "transparent"
            border.width: Math.max(1.5, Math.round(parent.ring * 0.22))
            border.color: root.foreground
            x: parent.ring * 0.5
          }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.launchAgent()
      else if (buttonCode === Qt.MiddleButton) root.selectProvider(root.providerIndex + 1)
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    // Taller than the control panels on purpose: this one is a dashboard, and
    // the whole point is reading limits and history without scrolling.
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(820))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dx !== 0) {
          root.cursorActive = true
          root.selectProvider(root.providerIndex + dx)
        }
        if (dy !== 0)
          panelFlick.contentY = root.clamp(panelFlick.contentY + dy * Style.space(56), 0,
                                           Math.max(0, panelFlick.contentHeight - panelFlick.height))
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if ((t === "a" || t === "A") && root.accounts.length > 1) root.cycleAccount()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { id: panelScrollBar; policy: ScrollBar.AsNeeded }

        Column {
          id: column
          // Leave a lane for the scroll bar so it never sits on top of the numbers.
          width: panelFlick.width - (panelFlick.interactive ? panelScrollBar.width + Style.space(8) : 0)
          spacing: Style.space(12)

          // ---------- Hero: provider mark · name · plan ----------
          PanelHero {
            id: hero
            visible: !!root.provider
            width: parent.width
            title: "Swapkin"
            meta: root.activeAccount
              ? root.activeAccount.name + " · " + root.accountPlan(root.activeAccount)
              : root.heroMeta(root.provider)
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Item {
                // The hero sizes itself to this item, so state the size here:
                // one and a half rings wide, one ring tall.
                readonly property real ring: Math.round(Style.font.display * 0.72)
                readonly property color tint: root.accountColour(root.activeAccount)

                width: ring * 1.5
                height: ring

                Item {
                  readonly property real ring: parent.ring
                  readonly property color tint: parent.tint

                  width: parent.width
                  height: parent.height

                  Rectangle {
                    width: parent.ring
                    height: width
                    radius: width / 2
                    color: parent.tint
                    x: 0
                  }

                  Rectangle {
                    width: parent.ring
                    height: width
                    radius: width / 2
                    color: "transparent"
                    border.width: Math.max(1.5, Math.round(parent.ring * 0.20))
                    border.color: root.foreground
                    x: parent.ring * 0.5
                  }
                }
              }
            }
          }

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // ---------- Provider switch ----------
          Row {
            id: providerSwitch
            visible: root.providers.length > 1
            width: parent.width
            spacing: Style.spacing.md

            readonly property real cellWidth: root.providers.length > 0
              ? (width - spacing * (root.providers.length - 1)) / root.providers.length
              : 0

            Repeater {
              model: root.providers

              Button {
                required property var modelData
                required property int index

                width: providerSwitch.cellWidth
                text: modelData.providerName
                selected: index === root.providerIndex
                hasCursor: root.cursorActive && index === root.providerIndex
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: {
                  root.cursorActive = true
                  root.selectProvider(index)
                }
                onHovered: function(isHovered) { if (isHovered) root.cursorActive = true }
              }
            }
          }

          // ---------- Switch advice ----------
          // One sentence, and the button that acts on it.
          BorderSurface {
            visible: !!root.roomier
            width: parent.width
            implicitHeight: adviceRow.implicitHeight + Style.spacing.lg * 2
            color: root.alpha(root.foreground, 0.05)
            borderSpec: Border.flat(root.alpha(root.foreground, 0.20), 1)

            Item {
              id: adviceRow
              anchors.fill: parent
              anchors.margins: Style.spacing.lg
              implicitHeight: Math.max(adviceText.implicitHeight, adviceButton.implicitHeight)

              Text {
                id: adviceText
                textFormat: Text.PlainText
                anchors.left: parent.left
                anchors.right: adviceButton.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
                wrapMode: Text.WordWrap
                text: root.roomier
                  ? root.roomier.name + " has " + Math.round((1 - root.accountWeekly(root.roomier)) * 100) + "% of its week free"
                  : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Button {
                id: adviceButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "switch"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                verticalPadding: Style.space(3)
                onClicked: if (root.roomier) root.useAccount(root.roomier.name)
              }
            }
          }

          Text {
            visible: root.hasAccounts && root.openSessions > 0
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: root.openSessions === 1
              ? "1 Claude Code session open · it follows the switch on its next message"
              : root.openSessions + " Claude Code sessions open · they follow the switch on their next message"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          // ---------- Accounts ----------
          // One row per account: its colour, its plan, how full its week is. The
          // list scrolls, so two accounts and ten look the same.
          Column {
            id: accountsSection
            visible: root.hasAccounts
            width: parent.width
            spacing: Style.space(8)

            Item {
              width: parent.width
              implicitHeight: Math.max(accountsHeader.implicitHeight, manageButton.implicitHeight)

              PanelSectionHeader {
                id: accountsHeader
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: root.accounts.length > 2 ? "ACCOUNTS · " + root.accounts.length : "ACCOUNTS"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              Button {
                id: manageButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: root.managing ? "done" : "manage"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                verticalPadding: Style.space(3)
                onClicked: {
                  root.managing = !root.managing
                  root.colourEditing = ""
                }
              }
            }

            // Two accounts are a swap, not a list: one chip each, side by side.
            Row {
              id: accountChips
              visible: root.accounts.length <= 2
              width: parent.width
              spacing: Style.spacing.md

              readonly property real cellWidth: root.accounts.length > 0
                ? (width - spacing * (root.accounts.length - 1)) / root.accounts.length
                : 0

              Repeater {
                model: root.accounts

                Button {
                  required property var modelData

                  width: accountChips.cellWidth
                  text: modelData.name + (root.accountPlan(modelData) ? " · " + root.accountPlan(modelData) : "")
                  selected: !!modelData.active
                  bordered: true
                  foreground: root.accountColour(modelData)
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.spacing.controlPaddingY
                  onClicked: if (!modelData.active) root.useAccount(modelData.name)
                }
              }
            }

            BorderSurface {
              visible: root.accounts.length > 2
              width: parent.width
              implicitHeight: visible ? accountsFlick.height : 0
              color: "transparent"
              borderSpec: Border.flat(root.alpha(root.foreground, 0.18), 1)

              Flickable {
                id: accountsFlick
                // Six rows fit; past that the list scrolls instead of growing.
                width: parent.width
                height: Math.min(accountsColumn.implicitHeight, Style.space(216))
                contentWidth: width
                contentHeight: accountsColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                interactive: contentHeight > height

                Column {
                  id: accountsColumn
                  width: accountsFlick.width

                  Repeater {
                    model: root.accountsByRoom

                    MouseArea {
                      id: accountRow
                      required property var modelData

                      readonly property bool isActive: !!modelData.active
                      readonly property color tint: root.accountColour(modelData)

                      width: accountsColumn.width
                      implicitHeight: rowBody.implicitHeight + Style.space(12)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (!isActive) root.useAccount(modelData.name)

                      Rectangle {
                        anchors.fill: parent
                        color: accountRow.isActive ? root.alpha(root.foreground, 0.10)
                             : accountRow.containsMouse ? root.alpha(root.foreground, 0.05) : "transparent"
                      }

                      Row {
                        id: rowBody
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.leftMargin: Style.space(10)
                        anchors.rightMargin: Style.space(10)
                        spacing: Style.space(9)

                        Rectangle {
                          width: Style.space(9)
                          height: width
                          radius: width / 2
                          color: accountRow.tint
                          anchors.verticalCenter: parent.verticalCenter
                        }

                        Column {
                          width: rowBody.width - Style.space(9) - meterBox.width - percentText.width - Style.space(27)
                          spacing: Style.space(2)
                          anchors.verticalCenter: parent.verticalCenter

                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            elide: Text.ElideRight
                            text: accountRow.modelData.name
                            color: accountRow.isActive ? root.foreground : root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.bodySmall
                            font.bold: accountRow.isActive
                          }

                          Text {
                            textFormat: Text.PlainText
                            width: parent.width
                            elide: Text.ElideRight
                            text: root.accountPlan(accountRow.modelData) + " · " + root.accountAge(accountRow.modelData)
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                          }
                        }

                        Item {
                          id: meterBox
                          width: Style.space(64)
                          height: Style.space(4)
                          anchors.verticalCenter: parent.verticalCenter

                          Rectangle { anchors.fill: parent; color: root.alpha(root.foreground, 0.16) }
                          Rectangle {
                            height: parent.height
                            width: parent.width * root.clamp(root.accountWeekly(accountRow.modelData), 0, 1)
                            color: accountRow.tint
                          }
                        }

                        Text {
                          id: percentText
                          textFormat: Text.PlainText
                          width: Style.space(34)
                          horizontalAlignment: Text.AlignRight
                          anchors.verticalCenter: parent.verticalCenter
                          text: root.accountWeekly(accountRow.modelData) > 0
                            ? Math.round(root.accountWeekly(accountRow.modelData) * 100) + "%" : "—"
                          color: accountRow.isActive ? root.foreground : root.dim
                          font.family: root.fontFamily
                          font.pixelSize: Style.font.caption
                        }
                      }
                    }
                  }
                }
              }
            }

            // Manage mode: one row per account. The dot opens that account's
            // colours; nothing else competes for the eye.
            Column {
              visible: root.managing
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.accounts

                Column {
                  id: manageEntry
                  required property var modelData

                  readonly property bool expanded: root.colourEditing === modelData.name

                  width: parent.width
                  spacing: Style.space(6)

                  Item {
                    width: parent.width
                    implicitHeight: Math.max(manageName.implicitHeight, forgetButton.implicitHeight)

                    Rectangle {
                      id: colourDot
                      width: Style.space(14)
                      height: width
                      radius: width / 2
                      color: root.accountColour(manageEntry.modelData)
                      border.width: manageEntry.expanded ? 2 : 0
                      border.color: root.foreground
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter

                      MouseArea {
                        anchors.fill: parent
                        anchors.margins: -Style.space(4)
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.colourEditing = manageEntry.expanded ? "" : manageEntry.modelData.name
                      }
                    }

                    Text {
                      id: manageName
                      textFormat: Text.PlainText
                      anchors.left: colourDot.right
                      anchors.leftMargin: Style.space(10)
                      anchors.right: forgetButton.left
                      anchors.rightMargin: Style.space(10)
                      anchors.verticalCenter: parent.verticalCenter
                      elide: Text.ElideRight
                      text: manageEntry.modelData.name + " · " + root.accountPlan(manageEntry.modelData)
                      color: manageEntry.modelData.active ? root.foreground : root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    Button {
                      id: forgetButton
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      visible: !manageEntry.modelData.active
                      text: "forget"
                      bordered: true
                      foreground: root.foreground
                      fontFamily: root.fontFamily
                      fontSize: Style.font.caption
                      verticalPadding: Style.space(3)
                      onClicked: root.forgetAccount(manageEntry.modelData.name)
                    }
                  }

                  Row {
                    visible: manageEntry.expanded
                    width: parent.width
                    spacing: Style.space(6)
                    leftPadding: Style.space(24)

                    Repeater {
                      model: root.coloursFor(manageEntry.modelData)

                      Rectangle {
                        required property var modelData

                        width: Style.space(14)
                        height: width
                        radius: width / 2
                        color: modelData
                        border.width: root.accountColour(manageEntry.modelData) === modelData ? 2 : 0
                        border.color: root.foreground

                        MouseArea {
                          anchors.fill: parent
                          cursorShape: Qt.PointingHandCursor
                          onClicked: {
                            root.recolourAccount(manageEntry.modelData.name, parent.modelData)
                            root.colourEditing = ""
                          }
                        }
                      }
                    }
                  }
                }
              }

              Button {
                width: parent.width
                text: "+ add account"
                bordered: true
                foreground: root.foreground
                fontFamily: root.fontFamily
                fontSize: Style.font.caption
                verticalPadding: Style.spacing.controlPaddingY
                onClicked: root.addAccount()
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.WordWrap
                text: "Signing in happens in a throwaway folder. Click a dot to recolour an account."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------- Status ----------
          BorderSurface {
            visible: !!root.provider && String(root.provider.usageStatusText || "") !== ""
            width: parent.width
            implicitHeight: statusText.implicitHeight + Style.spacing.xl * 2
            color: root.alpha(root.urgent, 0.10)
            borderSpec: Border.flat(root.alpha(root.urgent, 0.35), 1)
            radius: Style.cornerRadius

            Text {
              id: statusText
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(12)
              anchors.rightMargin: Style.space(12)
              text: root.provider ? String(root.provider.authHelpText || "") : ""
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Balance / limits ----------
          PanelSeparator {
            visible: balanceSection.visible || limitsSection.visible
            foreground: root.foreground
          }

          Column {
            id: balanceSection
            visible: !!root.balance
            width: parent.width
            spacing: Style.space(10)

            // The meter shows what is left, not what is used: a prepaid
            // account drains toward empty rather than filling toward a cap.
            readonly property real ratio: root.balance && root.balance.funded > 0
              ? root.clamp(root.balance.remaining / root.balance.funded, 0, 1)
              : -1

            PanelSectionHeader {
              width: parent.width
              text: "BALANCE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(balanceLabel.implicitHeight, balanceValue.implicitHeight)

              Text {
                id: balanceLabel
                text: "Prepaid credits"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                id: balanceValue
                textFormat: Text.PlainText
                text: root.balance ? root.formatMoney(root.balance.remaining, root.balance.currency) : ""
                color: root.balanceAlarming ? root.urgent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Meter {
              visible: balanceSection.ratio >= 0
              width: parent.width
              value: balanceSection.ratio
              alarming: root.balanceAlarming
            }

            Text {
              textFormat: Text.PlainText
              visible: text !== ""
              width: parent.width
              text: root.balanceDetailText(root.balance)
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Column {
            id: limitsSection
            visible: root.limits.length > 0
            width: parent.width
            spacing: Style.space(10)

            PanelSectionHeader {
              // The header doubles as the progress light: a probe takes about
              // a second, and a silent stale number is worse than saying so.
              text: root.accountsRefreshing ? "LIMITS · UPDATING" : "LIMITS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // A window that is full has one useful number left: the wait.
            Column {
              readonly property var full: {
                for (var i = 0; i < root.limits.length; i++)
                  if (root.limits[i].percent >= 1) return root.limits[i]
                return null
              }

              visible: !!full
              width: parent.width
              spacing: Style.space(2)
              topPadding: Style.space(4)
              bottomPadding: Style.space(8)

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: parent.full ? root.formatDuration(root.resetMsFor(parent.full)) : ""
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.display * 1.6
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: parent.full ? "until " + parent.full.title.toLowerCase() + " frees up" : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            Repeater {
              model: root.limits

              LimitRow {
                required property var modelData
                width: limitsSection.width
                window: modelData
              }
            }
          }

          // ---------- Idle Claude accounts ----------
          Repeater {
            model: root.accounts.length === 2 && !root.managing
              ? root.accounts.filter(function(a) { return !a.active && (a.limits || []).length > 0 })
              : []

            Column {
              id: idleAccount
              required property var modelData

              width: column.width
              spacing: Style.space(10)

              PanelSeparator { foreground: root.foreground }

              // Same meters as the active account, receded: readable, clearly not in use.
              Column {
                width: parent.width
                spacing: Style.space(10)
                opacity: 0.45

                PanelSectionHeader {
                  text: idleAccount.modelData.name.toUpperCase() + " · " + root.accountPlan(idleAccount.modelData).toUpperCase()
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: root.limitWindows(idleAccount.modelData)

                  LimitRow {
                    required property var modelData
                    width: idleAccount.width
                    window: modelData
                  }
                }
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                text: "Inactive · updated " + root.accountAge(idleAccount.modelData) + " · press a to switch"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // ---------- Usage ----------
          PanelSeparator {
            visible: usageSection.visible
            foreground: root.foreground
          }

          Column {
            id: usageSection
            visible: !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
            width: parent.width
            spacing: Style.spacing.md

            readonly property var days: root.provider ? (root.provider.recentDays || []) : []
            readonly property real peak: Math.max(1, root.weekPeak(root.provider))

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY DAY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: usageSection.days

              DayRow {
                required property var modelData
                required property int index

                width: usageSection.width
                day: modelData
                ratio: Number(modelData.messageCount || 0) / usageSection.peak
                // By date, not by position: the Claude stats-cache fallback can
                // hand us a window that stops short of today.
                today: String(modelData.date || "") === root.todayDate()
              }
            }
          }

          // Today, in the other unit people think in.
          Text {
            visible: root.todayCost >= 0
            width: parent.width
            textFormat: Text.PlainText
            text: "Today ≈ $" + root.todayCost.toFixed(2) + " at API prices · estimated from prices.json"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // ---------- Models ----------
          PanelSeparator {
            visible: modelSection.visible
            foreground: root.foreground
          }

          Column {
            id: modelSection
            visible: root.models.length > 0
            width: parent.width
            spacing: Style.spacing.md

            PanelSectionHeader {
              width: parent.width
              text: "TOKENS BY MODEL"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.models

              ModelRow {
                required property var modelData
                width: modelSection.width
                row: modelData
                // Scaled to the heaviest model, so the top row is always full —
                // the same scale-to-peak the weekly chart uses for its busiest day.
                share: modelData.total / Math.max(1, root.models[0].total)
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: text !== ""
            width: parent.width
            topPadding: Style.space(2)
            text: root.footerText()
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
          }
        }
      }
    }
  }

  // A limit window: label and percentage, meter, and reset countdown.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9

    spacing: Style.space(6)

    Item {
      width: parent.width
      implicitHeight: Math.max(limitLabel.implicitHeight, limitValue.implicitHeight)

      Text {
        id: limitLabel
        textFormat: Text.PlainText
        // A model-scoped window is titled after its model, and those names run
        // long enough to reach the percentage, so the title gives way first.
        text: limitRow.window ? limitRow.window.title : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        elide: Text.ElideRight
        anchors.left: parent.left
        anchors.right: limitValue.left
        anchors.rightMargin: Style.spacing.sm
        anchors.verticalCenter: parent.verticalCenter
      }

      Text {
        id: limitValue
        textFormat: Text.PlainText
        text: limitRow.window && limitRow.window.percent >= 0
          ? Math.round(limitRow.window.percent * 100) + "%"
          : "—"
        color: limitRow.alarming ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
      }
    }

    Item {
      width: parent.width
      implicitHeight: rowMeter.implicitHeight

      Meter {
        id: rowMeter
        width: parent.width
        value: limitRow.window ? limitRow.window.percent : -1
        alarming: limitRow.alarming
      }

      // Where the window says you should be by now.
      Rectangle {
        readonly property var pace: root.paceFor(limitRow.window)
        visible: !!pace
        width: 2
        height: rowMeter.implicitHeight + Style.space(6)
        color: root.urgent
        x: pace ? Math.round((parent.width - width) * pace.budget) : 0
        anchors.verticalCenter: rowMeter.verticalCenter
      }
    }

    Text {
      id: paceLine
      textFormat: Text.PlainText
      visible: text !== ""
      width: parent.width
      wrapMode: Text.WordWrap
      text: {
        var pace = root.paceText(limitRow.window)
        var forecast = root.forecastText(limitRow.window)
        return forecast !== "" ? pace + " · " + forecast : pace
      }
      color: root.paceColour(limitRow.window)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Text {
      id: resetText
      textFormat: Text.PlainText
      width: parent.width
      text: {
        var remainingMs = root.resetMsFor(limitRow.window)
        return remainingMs > 0 ? "Resets in " + root.formatDuration(remainingMs) : ""
      }
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }

  // Rounded track showing the percentage of the allowance used.
  component Meter: Item {
    id: meter
    property real value: -1
    property bool alarming: false
    property real thickness: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))

    implicitHeight: thickness

    Rectangle {
      id: meterTrack
      anchors.fill: parent
      radius: height / 2
      color: root.track
    }

    Rectangle {
      anchors.left: meterTrack.left
      anchors.verticalCenter: meterTrack.verticalCenter
      height: meterTrack.height
      radius: meterTrack.radius
      width: meterTrack.width * root.clamp(meter.value, 0, 1)
      color: meter.alarming ? root.urgent : root.foreground

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

  }

  // One row per day: label, bar, tokens. Today is picked out in full
  // foreground so the week reads as a run-up to right now.
  component DayRow: Item {
    id: dayRow
    property var day: null
    property real ratio: 0
    property bool today: false

    implicitHeight: Math.max(dayLabel.implicitHeight, dayValue.implicitHeight) + Style.spacing.sm

    Text {
      id: dayLabel
      textFormat: Text.PlainText
      text: root.dayLabel(dayRow.day ? dayRow.day.date : "", dayRow.today)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayRow.today
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    Rectangle {
      id: dayTrack
      anchors.left: dayLabel.right
      anchors.right: dayValue.left
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(10)
      anchors.verticalCenter: parent.verticalCenter
      height: Math.max(Style.space(4), Math.round(Style.spacing.controlHeight * 0.14))
      radius: height / 2
      color: root.track

      Rectangle {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        radius: parent.radius
        width: parent.width * root.clamp(dayRow.ratio, 0, 1)
        color: dayRow.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on width {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayValue
      textFormat: Text.PlainText
      text: usage.formatTokenCount(dayRow.day ? Number(dayRow.day.messageCount || 0) : 0)
      color: dayRow.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(52)
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayRow.day, dayRow.today)
      fontFamily: root.fontFamily
    }
  }

  // Model rows read as a table: the share bar fills the row behind the label
  // instead of stacking under it, which keeps the whole dashboard on one screen.
  component ModelRow: Item {
    id: modelRow
    property var row: null
    property real share: 0

    implicitHeight: modelName.implicitHeight + Style.spacing.lg

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: modelRow.row ? usage.formatTokenCount(modelRow.row.total) : ""
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
      anchors.right: parent.right
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    MouseArea {
      id: modelHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: modelHover.containsMouse
      text: root.modelTooltip(modelRow.row)
      fontFamily: root.fontFamily
    }
  }
}
