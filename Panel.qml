import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Budget.js" as Budget

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
  readonly property var limits: providerWindows(provider, candidate)
  readonly property bool accountsRefreshing: accountsProcess.running || probeProcess.running
  readonly property var models: modelRows(provider)
  readonly property var headline: tightest(limits)
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
    var name = String(title || "") !== "" ? String(title) : windowTitle(label)
    return {
      title: name,
      kind: name === "Session" ? "session" : name === "Weekly" ? "weekly" : name === "Monthly" ? "month" : "other",
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
  function tightest(windows) {
    var best = null
    for (var i = 0; i < (windows || []).length; i++) {
      if (!best || windows[i].percent > best.percent) best = windows[i]
    }
    return best
  }

  // A provider's windows. For Claude they come from the account being read, not
  // from the shared collector record: right after a switch that record still
  // holds the other account's figures, and showing those is worse than nothing.
  function providerWindows(p, account) {
    // Another account has its own figures or none: the active account's must
    // never show under its name. The active one falls back to the record.
    if (p && p.providerId === "claude" && account && (!account.active || (account.limits || []).length > 0))
      return limitWindows(account)
    return limitWindows(p)
  }

  // Pace: where the budget says you should be by now, and where you are. Only
  // the weekly window earns budget by the hours you work; a month, if a
  // provider has one, runs on the calendar. A session or a model's own cap has
  // no pace to keep.
  readonly property var budgetConfig: Budget.config(
    setting("budgetSpread", Budget.DEFAULTS.spread), setting("budgetDays", Budget.DEFAULTS.days),
    setting("budgetStartHour", Budget.DEFAULTS.startHour), setting("budgetEndHour", Budget.DEFAULTS.endHour))
  readonly property var calendarConfig: Budget.config("Every day", "", 0, 24)

  function paceFor(w) {
    if (!w || (w.kind !== "weekly" && w.kind !== "month")) return null
    var span = windowSpanMs(w.kind === "month" ? "month" : "week")
    var reset = resetAtMs(w)
    if (!(reset > 0)) return null
    return Budget.pace(w.kind === "weekly" ? budgetConfig : calendarConfig, Number(w.percent), reset, span, root.nowMs)
  }

  function resetAtMs(w) {
    if (!w || w.resetAt === "") return -1
    var ms = new Date(w.resetAt).getTime()
    return isFinite(ms) ? ms : -1
  }

  // A long window says the day it frees up as well as how long that is; a
  // session only says how long.
  function resetText(w) {
    var ms = resetAtMs(w)
    if (!(ms > root.nowMs)) return ""
    return w.kind === "session" ? "Resets in " + Budget.durationText(ms - root.nowMs) : Budget.resetLine(ms, root.nowMs)
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

  onOpenedChanged: if (opened) {
    cursorActive = false
    candName = ""
    managing = false
    colourEditing = ""
    nowMs = Date.now()
    if (detailFlick) detailFlick.contentY = 0
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
  // The account being looked at: the active one until you move to another. It
  // is only a preview; a switch is a separate, deliberate key.
  property string candName: ""
  readonly property var candidate: {
    for (var i = 0; i < accounts.length; i++) if (accounts[i].name === candName) return accounts[i]
    return activeAccount
  }
  // Keyed on the name: a reload hands over a fresh list, and that alone must
  // not throw away the account you are looking at.
  readonly property string activeName: activeAccount ? activeAccount.name : ""
  onActiveNameChanged: candName = ""

  function stepCandidate(direction) {
    if (accounts.length < 2 || !candidate) return
    var at = 0
    for (var i = 0; i < accounts.length; i++) if (accounts[i].name === candidate.name) at = i
    candName = accounts[(at + direction + accounts.length) % accounts.length].name
  }

  // On the account already in view, `a` still hands over to the next one, the
  // way it did before there was a preview.
  function switchToCandidate() {
    if (!candidate || accounts.length < 2) return
    if (candidate.active) cycleAccount()
    else useAccount(candidate.name)
  }

  function toggleManage() {
    managing = !managing
    colourEditing = ""
  }

  function peakText(a) {
    var peak = tightest(limitWindows(a))
    return peak ? " · " + Math.round(peak.percent * 100) + "% peak" : ""
  }

  // Providers whose paying account Swapkin knows, for the strip on top.
  readonly property var payers: {
    var out = []
    for (var i = 0; i < providers.length; i++) {
      if (providers[i].providerId === "claude" && activeAccount)
        out.push({ providerId: "claude", providerName: providers[i].providerName,
                   payer: activeAccount.name, tint: accountColour(activeAccount) })
    }
    return out
  }

  function switchNoteText() {
    if (!candidate) return ""
    if (!candidate.active) return "Open sessions use " + candidate.name + " on their next message."
    if (roomier) return roomier.name + " has " + Math.round((1 - accountWeekly(roomier)) * 100) + "% of its week free."
    return accounts.length > 1 ? "Open sessions follow a switch on their next message." : "One account. Add another in manage."
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
    return seconds < 120 ? "just now" : Budget.durationText(seconds * 1000) + " ago"
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
    contentWidth: panel.fittedContentWidth(Style.space(760))
    // As tall as the content wants, and no taller than the screen allows. On a
    // screen that fits it, nothing scrolls; on a shorter one the two columns
    // scroll inside the popover, under a header and a key bar that stay put.
    contentHeight: panel.fittedContentHeight(
      header.implicitHeight + bodyHeight + keyBar.implicitHeight + Style.space(12) * 2)

    readonly property real bodyHeight: Math.max(sideColumn.implicitHeight, detailColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        root.cursorActive = true
        if (dy !== 0) root.selectProvider(root.providerIndex + dy)
        if (dx !== 0) root.stepCandidate(dx)
      }
      onActivateRequested: root.refreshNow()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refreshNow()
        else if ((t === "a" || t === "A") && root.accounts.length > 1) root.switchToCandidate()
        else if ((t === "m" || t === "M") && root.hasAccounts) root.toggleManage()
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- Header: who am I, and who pays for the next message ----------
        Column {
          id: header
          width: parent.width
          spacing: Style.space(10)

          PanelHero {
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
                width: ring * 1.5
                height: ring

                Rectangle {
                  width: parent.ring
                  height: width
                  radius: width / 2
                  color: root.accountColour(root.activeAccount)
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

          Text {
            visible: root.providers.length === 0
            width: parent.width
            topPadding: Style.space(24)
            bottomPadding: Style.space(24)
            text: "No AI coding subscriptions found.\nAgents show up here once you've used them."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          // Only providers whose paying account Swapkin knows are listed: a
          // provider with one login has no "which account" to answer.
          Column {
            visible: root.payers.length > 0
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "NEXT MESSAGE IS PAID BY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Flow {
              width: parent.width
              spacing: Style.space(8)

              Repeater {
                model: root.payers

                Button {
                  required property var modelData

                  text: modelData.providerName + " · " + modelData.payer
                  selected: modelData.providerId === root.provider.providerId
                  bordered: true
                  foreground: modelData.tint
                  fontFamily: root.fontFamily
                  fontSize: Style.font.bodySmall
                  verticalPadding: Style.space(3)
                  onClicked: root.selectedProviderId = modelData.providerId
                }
              }
            }
          }
        }

        // ---------- Body: providers on the left, the chosen one on the right ----------
        Row {
          visible: root.providers.length > 0
          width: parent.width
          height: parent.height - header.height - keyBar.height - parent.spacing * 2

          Flickable {
            id: sideFlick
            width: Style.space(224)
            height: parent.height
            contentWidth: width
            contentHeight: sideColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Column {
              id: sideColumn
              width: sideFlick.width - (sideFlick.interactive ? Style.space(10) : 0)
              spacing: Style.space(4)

              Repeater {
                model: root.providers

                ProviderRow {
                  required property var modelData
                  required property int index

                  width: sideColumn.width
                  provider: modelData
                  selected: index === root.providerIndex
                  onClicked: {
                    root.cursorActive = true
                    root.selectProvider(index)
                  }
                }
              }
            }
          }

          Rectangle {
            width: 1
            height: parent.height
            color: root.alpha(root.foreground, 0.18)
          }

          Flickable {
            id: detailFlick
            width: parent.width - sideFlick.width - 1
            height: parent.height
            contentWidth: width
            contentHeight: detailColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            flickableDirection: Flickable.VerticalFlick
            interactive: contentHeight > height
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            Connections {
              target: root
              function onProviderIndexChanged() { detailFlick.contentY = 0 }
              function onCandNameChanged() { detailFlick.contentY = 0 }
            }

            Column {
              id: detailColumn
              x: Style.space(16)
              width: detailFlick.width - Style.space(16) - (detailFlick.interactive ? Style.space(10) : Style.space(2))
              spacing: Style.space(10)

              // ---- Provider title, the way it switches, and who is affected ----
              Item {
                width: parent.width
                implicitHeight: Math.max(detailTitle.implicitHeight, manageButton.implicitHeight)

                Row {
                  id: detailTitle
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(8)

                  Text {
                    textFormat: Text.PlainText
                    text: root.provider ? root.provider.providerName : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }

                  ModePill { visible: root.hasAccounts }
                }

                Button {
                  id: manageButton
                  visible: root.hasAccounts
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.managing ? "done" : "manage"
                  bordered: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  verticalPadding: Style.space(3)
                  onClicked: root.toggleManage()
                }
              }

              Text {
                visible: root.hasAccounts && root.openSessions > 0
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.openSessions === 1 ? "1 Claude Code session open" : root.openSessions + " Claude Code sessions open"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // ---- Manage: recolour, forget, add ----
              Column {
                visible: root.hasAccounts && root.managing
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

              // ---- Accounts: the highlighted one is previewed; a switches to it ----
              Flow {
                visible: root.hasAccounts && !root.managing
                width: parent.width
                spacing: Style.space(8)

                Repeater {
                  model: root.accounts

                  Button {
                    required property var modelData

                    width: Math.max(Style.space(140), (parent.width - Style.space(8) * (root.accounts.length > 3 ? 2 : root.accounts.length - 1)) / Math.min(root.accounts.length, 3))
                    text: modelData.name + (modelData.active ? " · active" : "")
                      + (root.accountPlan(modelData) ? "\n" + root.accountPlan(modelData) + root.peakText(modelData) : "")
                    selected: !!root.candidate && modelData.name === root.candidate.name
                    bordered: true
                    foreground: root.accountColour(modelData)
                    fontFamily: root.fontFamily
                    fontSize: Style.font.bodySmall
                    verticalPadding: Style.space(4)
                    onClicked: root.candName = modelData.name
                  }
                }
              }

              Item {
                visible: root.hasAccounts && !root.managing
                width: parent.width
                implicitHeight: Math.max(switchButton.visible ? switchButton.implicitHeight : 0, switchNote.implicitHeight)

                Button {
                  id: switchButton
                  visible: !!root.candidate && !root.candidate.active
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Switch to " + (root.candidate ? root.candidate.name : "") + "  (a)"
                  bordered: true
                  selected: true
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  verticalPadding: Style.space(4)
                  onClicked: root.switchToCandidate()
                }

                Text {
                  id: switchNote
                  textFormat: Text.PlainText
                  anchors.left: switchButton.visible ? switchButton.right : parent.left
                  anchors.leftMargin: switchButton.visible ? Style.space(12) : 0
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  wrapMode: Text.WordWrap
                  text: root.switchNoteText()
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // ---- Status ----
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

              // ---- Balance ----
              Column {
                id: balanceSection
                visible: !!root.balance
                width: parent.width
                spacing: Style.space(6)

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

              // ---- Limits of the highlighted account ----
              PanelSeparator {
                visible: limitsSection.visible && !root.managing
                foreground: root.foreground
              }

              Column {
                id: limitsSection
                visible: root.limits.length > 0 && !root.managing
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  // The header doubles as the progress light: a probe takes about
                  // a second, and a silent stale number is worse than saying so.
                  text: (root.hasAccounts && !!root.candidate ? root.candidate.name.toUpperCase() + " · " + root.accountPlan(root.candidate).toUpperCase()
                                           : "LIMITS")
                    + (root.hasAccounts && !root.candidate.active ? " · PREVIEW" : "")
                    + (root.accountsRefreshing ? " · UPDATING" : "")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                // A window that is full has one useful number left: the wait.
                Column {
                  readonly property var full: {
                    for (var i = 0; i < root.limits.length; i++)
                      if (root.limits[i].percent >= 1 && root.resetAtMs(root.limits[i]) > root.nowMs) return root.limits[i]
                    return null
                  }

                  visible: !!full
                  width: parent.width
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    text: parent.full ? Budget.durationText(root.resetAtMs(parent.full) - root.nowMs) : ""
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.display * 1.4
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

              // ---- Tokens by day ----
              PanelSeparator {
                visible: usageSection.visible && !root.managing
                foreground: root.foreground
              }

              Column {
                id: usageSection
                visible: !root.managing && !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
                width: parent.width
                spacing: Style.space(6)

                readonly property var days: root.provider ? (root.provider.recentDays || []) : []
                readonly property real peak: Math.max(1, root.weekPeak(root.provider))
                readonly property real total: {
                  var sum = 0
                  for (var i = 0; i < days.length; i++) sum += Number(days[i].messageCount || 0)
                  return sum
                }

                Item {
                  width: parent.width
                  implicitHeight: usageHeader.implicitHeight

                  PanelSectionHeader {
                    id: usageHeader
                    anchors.left: parent.left
                    text: "TOKENS BY DAY"
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                  }

                  Text {
                    textFormat: Text.PlainText
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: usage.formatTokenCount(usageSection.total) + " this week"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }

                Row {
                  id: dayBars
                  width: parent.width
                  height: Style.space(84)
                  spacing: Style.space(6)

                  Repeater {
                    model: usageSection.days

                    DayBar {
                      required property var modelData

                      width: (dayBars.width - dayBars.spacing * Math.max(0, usageSection.days.length - 1)) / Math.max(1, usageSection.days.length)
                      height: dayBars.height
                      day: modelData
                      ratio: Number(modelData.messageCount || 0) / usageSection.peak
                      // By date, not by position: the Claude stats-cache fallback can
                      // hand us a window that stops short of today.
                      today: String(modelData.date || "") === root.todayDate()
                    }
                  }
                }
              }

              // Today, in the other unit people think in.
              Text {
                visible: !root.managing && root.hasAccounts && root.todayCost >= 0
                width: parent.width
                textFormat: Text.PlainText
                text: "Today ≈ $" + root.todayCost.toFixed(2) + " at API prices · estimated from prices.json"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }

              // ---- Tokens by model ----
              PanelSeparator {
                visible: modelSection.visible
                foreground: root.foreground
              }

              Column {
                id: modelSection
                visible: !root.managing && root.models.length > 0
                width: parent.width
                spacing: Style.space(6)

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

        // ---------- Key bar ----------
        Row {
          id: keyBar
          visible: root.providers.length > 0
          spacing: Style.space(16)

          Repeater {
            model: root.hasAccounts
              ? [{ k: "↑ ↓", l: "provider" }, { k: "← →", l: "account" }, { k: "a", l: "switch" }, { k: "m", l: "manage" }]
              : [{ k: "↑ ↓", l: "provider" }, { k: "r", l: "refresh" }]

            Row {
              required property var modelData
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: parent.modelData.k
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: parent.modelData.l
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }

  // "next message" and its kin: how a switch reaches a session that is already open.
  component ModePill: Rectangle {
    implicitWidth: pillText.implicitWidth + Style.space(12)
    implicitHeight: pillText.implicitHeight + Style.space(2)
    radius: height / 2
    color: "transparent"
    border.width: 1
    border.color: root.alpha(root.foreground, 0.5)

    Text {
      id: pillText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: "next message"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
  }

  // One provider in the left column: name, account and plan, how full it is.
  component ProviderRow: MouseArea {
    id: providerRow
    property var provider: null
    property bool selected: false

    readonly property var windows: root.providerWindows(provider, root.activeAccount)
    readonly property var tight: root.tightest(windows)
    readonly property bool isClaude: !!provider && provider.providerId === "claude" && root.hasAccounts

    implicitHeight: rowBody.implicitHeight + Style.space(16)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: providerRow.selected ? root.alpha(root.foreground, 0.12)
           : providerRow.containsMouse ? root.alpha(root.foreground, 0.06) : "transparent"
    }

    Rectangle {
      visible: providerRow.selected
      width: Style.space(3)
      height: parent.height
      color: root.foreground
    }

    Column {
      id: rowBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(12)
      anchors.rightMargin: Style.space(10)
      spacing: Style.space(3)

      Text {
        textFormat: Text.PlainText
        width: parent.width
        elide: Text.ElideRight
        text: providerRow.provider ? providerRow.provider.providerName : ""
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        font.bold: true
      }

      Text {
        textFormat: Text.PlainText
        width: parent.width
        elide: Text.ElideRight
        text: providerRow.isClaude && root.activeAccount
          ? root.activeAccount.name + " · " + root.accountPlan(root.activeAccount)
          : root.heroMeta(providerRow.provider)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        visible: !!providerRow.tight
        width: parent.width
        spacing: Style.space(8)

        Meter {
          width: parent.width - percentLabel.width - parent.spacing
          anchors.verticalCenter: parent.verticalCenter
          value: providerRow.tight ? providerRow.tight.percent : -1
          alarming: !!providerRow.tight && providerRow.tight.percent >= 0.9
        }

        Text {
          id: percentLabel
          textFormat: Text.PlainText
          width: Style.space(34)
          horizontalAlignment: Text.AlignRight
          text: providerRow.tight ? Math.round(providerRow.tight.percent * 100) + "%" : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }

      ModePill { visible: providerRow.isClaude }
    }
  }

  // A limit window: label and percentage, meter, and what the pace says. Only a
  // long window has a budget; a five-hour session or a model's own cap just
  // shows how full it is and when it frees up.
  component LimitRow: Column {
    id: limitRow
    property var window: null

    readonly property bool alarming: window && window.percent >= 0.9
    readonly property var pace: root.paceFor(window)
    readonly property double resetMs: root.resetAtMs(window)

    spacing: Style.space(4)

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

      // Where the budget says you should be by now.
      Rectangle {
        visible: !!limitRow.pace && limitRow.pace.state !== "early"
        width: 2
        height: rowMeter.implicitHeight + Style.space(6)
        color: root.urgent
        x: limitRow.pace ? Math.round((parent.width - width) * root.clamp(limitRow.pace.budget, 0, 1)) : 0
        anchors.verticalCenter: rowMeter.verticalCenter
      }
    }

    CaptionText {
      visible: !!limitRow.pace
      text: limitRow.window ? Budget.paceLine(limitRow.window.percent, limitRow.pace) : ""
      color: limitRow.pace && limitRow.pace.state === "over" ? root.foreground : root.dim
    }

    CaptionText {
      text: limitRow.window ? Budget.forecastLine(limitRow.window.percent, limitRow.pace,
                                                  limitRow.resetMs, root.nowMs) : ""
      color: limitRow.pace && (limitRow.pace.full || limitRow.pace.projected > 1) ? root.urgent : root.dim
    }

    CaptionText { text: root.resetText(limitRow.window) }
  }

  // A small line of wrapped text under a meter; hidden when it has nothing to say.
  component CaptionText: Text {
    textFormat: Text.PlainText
    visible: text !== ""
    width: parent.width
    wrapMode: Text.WordWrap
    color: root.dim
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
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

  // One day of the week as a column: the bar, its weekday underneath. Today is
  // picked out in full foreground so the week reads as a run-up to right now.
  component DayBar: Item {
    id: dayBar
    property var day: null
    property real ratio: 0
    property bool today: false

    Item {
      id: barArea
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: dayName.top
      anchors.bottomMargin: Style.space(4)

      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        width: Math.min(parent.width, Style.space(28))
        height: Math.max(Style.space(3), parent.height * root.clamp(dayBar.ratio, 0, 1))
        radius: Style.space(2)
        color: dayBar.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on height {
          NumberAnimation { duration: 160; easing.type: Easing.OutCubic }
        }
      }
    }

    Text {
      id: dayName
      textFormat: Text.PlainText
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.bottom: parent.bottom
      horizontalAlignment: Text.AlignHCenter
      text: dayBar.today ? "Today" : root.dayName(dayBar.day ? dayBar.day.date : "")
      color: dayBar.today ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: dayBar.today
    }

    MouseArea {
      id: dayHover
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
    }

    PanelToolTip {
      visible: dayHover.containsMouse
      text: root.dayTooltip(dayBar.day, dayBar.today)
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
