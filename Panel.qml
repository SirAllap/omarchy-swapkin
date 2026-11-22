import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import QtQuick.Shapes
import "Budget.js" as Budget
import "Models.js" as Models

Panel {
  id: root
  moduleName: "io.github.sirallap.swapkin"
  ipcTarget: "io.github.sirallap.swapkin"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Foreground eased toward the surface, but never under 4.5:1 against it.
  readonly property color dimSoft: Qt.tint(surface, Qt.rgba(foreground.r, foreground.g, foreground.b, 0.75))
  readonly property color dim: Models.contrastRatio(colorLuminance(dimSoft), colorLuminance(surface)) >= 4.5 ? dimSoft : foreground
  property string forgetPending: ""
  readonly property color surface: Color.popups.background
  readonly property color track: Style.selectedFillFor(foreground, Color.accent)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- Settings read here, written by SettingsPage ----
  readonly property string motionSetting: Models.motionMode(setting("motion", "system"))
  // Follow the shell's own reduced-motion switch unless the owner chose.
  readonly property bool reduced: Models.motionReduced(motionSetting, Style.reduceMotion)
  function dur(ms) { return reduced ? 0 : ms }
  readonly property string heroRingSetting: Models.heroMode(setting("heroRing", "tightest"))
  readonly property string providersHiddenText: String(setting("providersHidden", ""))
  readonly property string firstProviderSetting: String(setting("firstProvider", ""))
  readonly property bool showCost: truthy(setting("showCost", true))
  readonly property int watchMinutes: Models.snapStep(Models.WATCH_STEPS, setting("watchIntervalMin", 5), 5)
  readonly property int warnAtPct: Models.snapStep(Models.WARN_STEPS, setting("alertAt", 90), 90)

  readonly property var allProviders: Models.orderProviders(usage.enabledProviders)
  readonly property var providers: Models.visibleProviders(allProviders, providersHiddenText)
  // The selection follows the provider, not the slot it happens to sit in: a
  // provider whose first scan lands while the panel is open would otherwise
  // shift the list underneath you and swap out what you were reading.
  property string selectedProviderId: ""
  readonly property int providerIndex: {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === selectedProviderId) return i
    return 0
  }
  readonly property string selectedProviderIdOrFirst: providers.length > 0 ? providers[providerIndex].providerId : ""
  readonly property var provider: providers.length > 0 ? providers[providerIndex] : null

  property bool cursorActive: false
  // Bumped when the panel opens and when the provider changes: the one signal
  // the hero sweep and the staggered entries play on. Nothing else animates.
  property int enterTick: 0
  // The provider strip enters once, when the panel opens. Its own tick: a
  // provider change or a data refresh must never replay it.
  property int stripTick: 0
  // The strip's Repeater is keyed on ids that only change when the set of
  // providers does. Models.orderProviders hands back a new array on every
  // refresh, and a Repeater on that array rebuilt every chip mid-entry.
  property var providerIds: []
  onProvidersChanged: {
    var ids = []
    for (var i = 0; i < providers.length; i++) ids.push(providers[i].providerId)
    if (ids.join("\n") !== providerIds.join("\n")) providerIds = ids
  }
  function providerById(id) {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === id) return providers[i]
    return null
  }

  // Countdowns and "updated" read this instead of Date.now() so the
  // panel keeps telling the truth while it sits open.
  property double nowMs: Date.now()

  // Limits come from the account's own probe, not from the shared collector
  // record: right after a switch that record still holds the other account's
  // figures, and showing those is worse than showing nothing.
  readonly property var limits: providerWindows(provider, candidate)
  readonly property bool accountsRefreshing: usage.swapkinLoading || syncProcess.running
  readonly property var models: modelRows(provider, modelsHiddenText)
  readonly property var headline: Models.pickHero(limits, heroRingSetting)
  readonly property var balance: provider ? (provider.balance || null) : null
  // A prepaid account runs low the way a subscription window fills up: the
  // last 10% of the funded credits lights the same alarm.
  readonly property bool balanceAlarming: !!balance && balance.funded > 0
    && balance.remaining / balance.funded <= 0.1
  // What the bar draws: the tightest limit of every provider, by its own
  // active account. A prepaid provider with no window reads as credit spent.
  readonly property var barRings: {
    var entries = []
    for (var i = 0; i < providers.length; i++) {
      var p = providers[i]
      var t = tightest(providerWindows(p, activeAccountFor(p)))
      var pct = t ? t.percent : -1
      var b = p.balance
      if (pct < 0 && b && b.funded > 0) pct = 1 - b.remaining / b.funded
      entries.push({ name: p.providerName, percent: pct })
    }
    return Models.miniRings(entries)
  }
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

  // Sync: ask for fresh usage of every saved account of every provider, not
  // only the active one, via `swapkin usage`. One run at a time.
  property string syncError: ""
  readonly property bool syncing: syncProcess.running
  // After a Sync the owner pressed, Sync rests for a few seconds: two quick
  // presses are what makes Anthropic rate limit the usage endpoint. The panel's
  // own refresh on open never starts the rest.
  property double syncEndMs: 0
  property string syncHint: ""
  readonly property int syncCooldown: Models.syncCooldownLeft(syncEndMs, nowMs)
  readonly property var syncView: Models.syncView(syncing, syncError, !root.reduced, syncCooldown)
  Timer { interval: 1000; repeat: true; running: root.syncCooldown > 0 && root.opened; onTriggered: root.nowMs = Date.now() }
  function syncNow() {
    if (syncProcess.running) return
    if (syncCooldown > 0) { syncHint = Models.SYNC_REST_HINT; return }
    syncHint = ""
    syncError = ""
    syncProcess.running = true
    // A tool that will not launch may never fire onExited: say so now.
    if (!syncProcess.running) syncError = "could not start swapkin"
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
    var span = windowSpanMs(label)
    if (span >= 28 * 24 * 3600 * 1000) return "Monthly"
    if (span >= 7 * 24 * 3600 * 1000) return "Weekly"
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

  // A provider's windows. For any provider with accounts they come from the
  // account being read, not from the shared collector record: right after a
  // switch that record still holds the other account's figures, and showing
  // those is worse than nothing.
  function providerWindows(p, account) {
    // Another account has its own figures or none: the active account's must
    // never show under its name. The active one falls back to the record.
    if (p && (p.accounts || []).length > 0 && account && (!account.active || (account.limits || []).length > 0))
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
    var tier = Models.stripProviderName(p.tierLabel, p.providerName)
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

  // Grouped by family: "Opus" once, with its versions (5, 5.5) listed under it,
  // so a new point release does not look like a different model. A family's
  // header carries the sum; the bars under it compare versions on one scale.
  function modelRows(p, hiddenText) {
    var usageByModel = Models.shownUsage(p ? p.modelUsage : {}, hiddenText)
    var families = {}
    for (var id in usageByModel) {
      var bucket = usageByModel[id] || {}
      var input = Number(bucket.inputTokens || 0)
      var output = Number(bucket.outputTokens || 0)
      var cacheRead = Number(bucket.cacheReadInputTokens || 0)
      var cacheWrite = Number(bucket.cacheCreationInputTokens || 0)
      var name = usage.friendlyModelName(id)
      var parts = name.match(/^(\D*?)\s*([vV]?\d.*)?$/)
      var family = parts && parts[1] ? parts[1] : name
      var version = parts && parts[1] && parts[2] ? parts[2] : ""
      var fam = families[family] || (families[family] = {
        name: family, total: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, versions: {}
      })
      var v = fam.versions[version] || (fam.versions[version] = {
        name: version !== "" ? family + " " + version : family, version: version,
        total: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0
      })
      var total = input + output + cacheRead + cacheWrite
      var sums = [fam, v]
      for (var k = 0; k < 2; k++) {
        sums[k].total += total
        sums[k].input += input
        sums[k].output += output
        sums[k].cacheRead += cacheRead
        sums[k].cacheWrite += cacheWrite
      }
    }
    var list = []
    for (var f in families) list.push(families[f])
    list.sort(function(a, b) { return b.total - a.total })
    list = list.slice(0, 4)
    var rows = []
    for (var i = 0; i < list.length; i++) {
      var versions = []
      for (var key in list[i].versions) versions.push(list[i].versions[key])
      versions.sort(function(a, b) { return parseFloat(a.version) - parseFloat(b.version) })
      var peak = Math.max(1, list[i].total)
      // Bars only compare things: a family with one shown version has nothing
      // to be compared with, so it is one plain line ("Fable 5.1  2.9B").
      if (versions.length === 1) {
        var only = versions[0]
        rows.push({ name: only.version !== "" ? list[i].name + " " + only.version : list[i].name,
                    total: list[i].total, input: list[i].input, output: list[i].output,
                    cacheRead: list[i].cacheRead, cacheWrite: list[i].cacheWrite, header: true, indent: false, peak: peak })
        continue
      }
      rows.push({ name: list[i].name, total: list[i].total, input: list[i].input, output: list[i].output,
                  cacheRead: list[i].cacheRead, cacheWrite: list[i].cacheWrite, header: true, indent: false, peak: peak })
      for (var m = 0; m < versions.length; m++) {
        var ver = versions[m]
        rows.push({ name: ver.name, total: ver.total, input: ver.input, output: ver.output,
                    cacheRead: ver.cacheRead, cacheWrite: ver.cacheWrite, header: false, indent: true, peak: peak })
      }
    }
    return rows
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
    enterTick++
    stripTick++
    cursorActive = false
    candName = ""
    managing = false
    settingsOpen = false
    colourEditing = ""
    paceCursor = -1
    autoCursor = -1
    modelCursor = -1
    setCursor = -1
    renaming = ""; addingAccount = false
    actionError = ""
    if (firstProviderSetting !== "" && providerById(firstProviderSetting)) selectedProviderId = firstProviderSetting
    nowMs = Date.now()
    if (detailFlick) detailFlick.contentY = 0
    // Opening only reads the records on disk. Fetches belong to the timer and Sync.
    reloadAccounts()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  Main {
    id: usage
    settings: root.settings
  }

  // ------------------------------------------------------------- accounts
  // Accounts are saved by the bundled swapkin tool, one adapter per provider.
  // A hot provider (Claude) swaps the login file in place; a cold one only
  // moves the active pointer for new sessions; a never provider needs a
  // fresh sign-in. providerWindows/switchNoteText read provider.mode to tell
  // which applies.
  readonly property string accountTool: Qt.resolvedUrl("bin/swapkin").toString().replace(/^file:\/\//, "")
  readonly property var palette: ["#7fa7d9", "#d97757", "#8fb572", "#d9a54a", "#b98fd9",
                                  "#6fc7c0", "#d98fa8", "#a8a35c", "#7f8fd9", "#c98f6f"]
  // The selected provider's own accounts, straight off swapkin's listing —
  // no separate `list --json` process to keep in sync.
  readonly property var accounts: provider ? (provider.accounts || []) : []
  property bool managing: false
  // The settings view for every provider (weekly pace, models shown). Never
  // open together with manage, which is only the selected provider's.
  property bool settingsOpen: false
  readonly property bool subView: managing || settingsOpen
  property string colourEditing: ""
  readonly property bool hasAccounts: accounts.length > 0
  // Manage stays reachable with no saved accounts, so the first one (the
  // current login) can be saved from here instead of only from a terminal.
  readonly property bool canManage: Models.canManage(provider)
  // A one-login provider (Antigravity) has nothing to switch to.
  readonly property bool canSwitchAccounts: !!provider && provider.mode !== "never"
  readonly property bool canAutoSwitch: Models.canAutoSwitch(provider)
  readonly property var activeAccount: {
    for (var i = 0; i < accounts.length; i++) if (accounts[i].active) return accounts[i]
    return null
  }
  function activeAccountFor(p) {
    var list = p ? (p.accounts || []) : []
    for (var i = 0; i < list.length; i++) if (list[i].active) return list[i]
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

  // A different provider is a different account list; the account and the
  // manage view you were looking at belong to the one you left. Keyed on the
  // provider's own id, not its slot: if the provider at index 0 drops out
  // (a malformed usage.json, say) and another one takes its place, candName
  // must not survive and match a same-named account of the new provider (L9).
  readonly property string providerId: provider ? provider.providerId : ""
  onProviderIdChanged: {
    enterTick++
    candName = ""
    managing = false
    settingsOpen = false
    paceCursor = -1
    autoCursor = -1
    modelCursor = -1
    setCursor = -1
    renaming = ""; addingAccount = false
    readStatusline()
  }

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
    settingsOpen = false
    colourEditing = ""
    renaming = ""; addingAccount = false
    actionError = ""
    setCursor = -1
    paceCursor = -1
    autoCursor = -1
    modelCursor = -1
  }

  function toggleSettings() {
    settingsOpen = !settingsOpen
    managing = false
    colourEditing = ""
    renaming = ""; addingAccount = false
    setCursor = -1
    paceCursor = -1
    autoCursor = -1
    modelCursor = -1
  }

  // ---- Weekly pace, edited from the settings view ----
  // The same four widget settings Omarchy's plugin settings page edits; the
  // write is the one the clock panel uses (the shell rewrites shell.json and
  // hands the entry back). Without that call on this shell the block stays
  // read-only and says where to edit instead.
  readonly property bool canWritePace: !!(bar && bar.shell && typeof bar.shell.updateEntryInline === "function")
  readonly property bool paceWorking: String(setting("budgetSpread", Budget.DEFAULTS.spread)).toLowerCase().indexOf("work") >= 0
  readonly property string paceDaysText: String(setting("budgetDays", Budget.DEFAULTS.days))
  readonly property var paceDays: Budget.config("Working days", paceDaysText, 0, 24).days
  readonly property var paceHours: Budget.stepHour(setting("budgetStartHour", Budget.DEFAULTS.startHour),
                                                   setting("budgetEndHour", Budget.DEFAULTS.endHour), "start", 0)
  // Monday first; the numbers are Budget's day indexes (0 = Sunday).
  readonly property var paceDayOrder: [1, 2, 3, 4, 5, 6, 0]
  readonly property var paceDayNames: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
  // Keyboard cursor over the block: -1 off, 0-1 spread, 2-8 days, 9-12 the
  // two steppers (start -, start +, end -, end +).
  property int paceCursor: -1
  readonly property var paceRows: [[0, 1], [2, 3, 4, 5, 6, 7, 8], [9, 10], [11, 12]]

  // ---- Models shown, edited from the settings view ----
  // Hiding a model only leaves it out of "tokens by model"; the usage itself
  // is never touched. The hidden ids are one comma-separated plugin setting.
  readonly property string modelsHiddenText: String(setting("modelsHidden", ""))
  readonly property var modelChips: Models.chips(provider ? provider.modelUsage : {}, modelsHiddenText,
                                                 function(id) { return usage.friendlyModelName(id) })
  // Keyboard cursor: -1 off, 0..n-1 the chips, n the "Show all" button.
  property int modelCursor: -1

  function modelActivate(i) {
    if (!canWritePace) return
    if (i < modelChips.length) persistSettings({ modelsHidden: Models.toggleHidden(modelsHiddenText, modelChips[i].id) })
    else persistSettings({ modelsHidden: "" })
  }

  function modelMove(delta) {
    var to = modelCursor + delta
    if (to < 0) { modelCursor = -1; return }
    modelCursor = Math.min(modelChips.length, to)
  }

  function persistSettings(values) {
    if (!canWritePace) return
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function paceActivate(i) {
    if (!canWritePace) return
    if (i < 2) {
      persistSettings({ budgetSpread: i === 0 ? "Working days" : "Every day" })
    } else if (i < 9) {
      var next = Budget.toggleDay(paceDaysText, paceDayOrder[i - 2])
      if (next !== null) persistSettings({ budgetDays: next })
    } else {
      var h = Budget.stepHour(paceHours.start, paceHours.end, i < 11 ? "start" : "end", i % 2 === 1 ? -1 : 1)
      persistSettings({ budgetStartHour: h.start, budgetEndHour: h.end })
    }
  }

  function paceMove(dx, dy) {
    var row = 0, col = 0
    for (var r = 0; r < paceRows.length; r++) {
      var at = paceRows[r].indexOf(paceCursor)
      if (at >= 0) { row = r; col = at }
    }
    if (dy !== 0) {
      var to = row + dy
      if (to < 0) { paceCursor = -1; return }
      if (to >= paceRows.length) return
      paceCursor = paceRows[to][Math.min(col, paceRows[to].length - 1)]
    } else {
      paceCursor = paceRows[row][Math.max(0, Math.min(paceRows[row].length - 1, col + dx))]
    }
  }

  // ---- The other settings, edited from the settings view ----
  // Keyboard: up/down pick a row, left/right change it, enter changes it
  // forward (or toggles the provider under provCursor).
  property int setCursor: -1
  property int provCursor: 0
  readonly property var settingRows: ["watch", "warn", "hero", "first", "cost", "motion", "providers"]
  readonly property var heroOptions: [{ id: "tightest", label: "Tightest" }, { id: "weekly", label: "Weekly" }, { id: "session", label: "Session" }]
  readonly property var motionOptions: [{ id: "system", label: "System" }, { id: "reduce", label: "Reduce" }, { id: "full", label: "Full" }]

  function cycle(list, current, dir) {
    var at = 0
    for (var i = 0; i < list.length; i++) if (list[i] === current) at = i
    return list[(at + dir + list.length) % list.length]
  }

  function settingMove(dx, dy) {
    if (dy !== 0) {
      var to = setCursor + dy
      setCursor = Math.max(-1, Math.min(settingRows.length - 1, to))
    } else if (setCursor >= 0) settingChange(settingRows[setCursor], dx)
  }

  function settingChange(row, dir) {
    if (!canWritePace || dir === 0) return
    if (row === "watch") persistSettings({ watchIntervalMin: Models.stepBy(Models.WATCH_STEPS, watchMinutes, dir, 5) })
    else if (row === "warn") persistSettings({ alertAt: Models.stepBy(Models.WARN_STEPS, warnAtPct, dir, 90) })
    else if (row === "hero") persistSettings({ heroRing: cycle(Models.HERO_MODES, heroRingSetting, dir) })
    else if (row === "motion") persistSettings({ motion: cycle(Models.MOTION_MODES, motionSetting, dir) })
    else if (row === "cost") persistSettings({ showCost: !showCost })
    else if (row === "first") {
      var ids = [""]
      for (var i = 0; i < allProviders.length; i++) ids.push(allProviders[i].providerId)
      persistSettings({ firstProvider: cycle(ids, firstProviderSetting, dir) })
    } else if (row === "providers") {
      if (allProviders.length === 0) return
      provCursor = Math.max(0, Math.min(allProviders.length - 1, provCursor + dir))
    }
  }

  function settingActivate() {
    if (setCursor < 0) return
    var row = settingRows[setCursor]
    if (row === "providers") toggleProvider(provCursor)
    else settingChange(row, 1)
  }

  function toggleProvider(i) {
    if (!canWritePace || i < 0 || i >= allProviders.length) return
    var ids = allProviders.map(function(p) { return p.providerId })
    persistSettings({ providersHidden: Models.toggleProviderHidden(providersHiddenText, ids[i], ids) })
  }

  // ---- Manage keys: act on the account in view ----
  function manageKey(t) {
    var a = candidate
    var k = String(t).toLowerCase()
    if (k === "v" && Models.unsavedLogin(provider)) { saveCurrentLogin(); return true }
    if (!a) return false
    if (k === "u") { if (canSwitchAccounts && !a.active) useAccount(a.name); return true }
    if (k === "n") { renaming = a.name; return true }
    if (k === "c") { colourEditing = colourEditing === a.name ? "" : a.name; return true }
    if (k === "f") { if (!a.active) forgetAccount(a.name); return true }
    return false
  }

  // ---- Auto-switch, edited from the manage screen ----
  // Cursor: -1 off; 0/1 the on/off chips, 2/3 the stepper, 4/5 the return on/off chips.
  property int autoCursor: -1
  readonly property var autoRows: [[0, 1], [2, 3], [4, 5]]
  function truthy(v) { return v === true || String(v).toLowerCase() === "true" }
  readonly property bool autoOn: truthy(setting("autoSwitch", false))
  readonly property bool autoReturn: truthy(setting("autoSwitchReturn", false))
  readonly property int autoLeft: Budget.stepLeftPct(setting("autoSwitchLeftPct", 5), 0)

  function autoActivate(i) {
    if (!canWritePace) return
    if (i < 2) persistSettings({ autoSwitch: i === 0 })
    else if (i < 4) persistSettings({ autoSwitchLeftPct: Budget.stepLeftPct(autoLeft, i === 2 ? -1 : 1) })
    else persistSettings({ autoSwitchReturn: i === 4 })
  }

  function autoMove(dx, dy) {
    var row = 0, col = 0
    for (var r = 0; r < autoRows.length; r++) {
      var at = autoRows[r].indexOf(autoCursor)
      if (at >= 0) { row = r; col = at }
    }
    if (dy !== 0) {
      var to = row + dy
      if (to < 0) { autoCursor = -1; return }
      if (to >= autoRows.length) return
      autoCursor = autoRows[to][Math.min(col, autoRows[to].length - 1)]
    } else {
      autoCursor = autoRows[row][Math.max(0, Math.min(autoRows[row].length - 1, col + dx))]
    }
  }

  function peakText(a) {
    var peak = tightest(limitWindows(a))
    return peak ? " · " + Math.round(peak.percent * 100) + "% peak" : ""
  }

  // Who pays for the next message, for the provider being looked at.
  readonly property string payerLabel: Models.payerLine(provider, activeAccount)

  // Open sessions catch up on their own; a switch that needs a fresh sign-in
  // never picks anything up automatically.
  function switchNoteText() {
    if (!candidate) return ""
    if (!candidate.active) {
      var mode = root.provider ? root.provider.mode : ""
      if (mode === "never") return "Signing in again replaces the current login."
      if (mode === "cold") return "New sessions use " + candidate.name + ". Open ones keep "
        + (activeAccount ? activeAccount.name : "the current account") + "."
      return "Open sessions use " + candidate.name + " on their next message."
    }
    if (roomier) return roomier.name + " has " + Math.round((1 - accountWeekly(roomier)) * 100) + "% of its week free."
    if (accounts.length < 2) return "One account. Add another in manage."
    // The provider's own words: only a hot one moves open sessions along.
    return String((root.provider && root.provider.modeWords) || "Open sessions follow a switch on their next message.")
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

  // list defaults to the selected provider's own accounts; a chip drawn for
  // another provider (the payers strip) passes that provider's list instead,
  // so the fallback-by-index colour never borrows another provider's account.
  function accountColour(a, list) {
    if (a && String(a.colour || "") !== "") return a.colour
    var accts = list || accounts
    var index = 0
    for (var i = 0; i < accts.length; i++) if (accts[i] === a) index = i
    return palette[index % palette.length]
  }

  function accountWeekly(a) {
    var value = a ? Number(a.weekly) : NaN
    return isFinite(value) ? value : 0
  }

  // A tool that reports no plan gets just the name, not a dangling dot.
  function nameAndPlan(a) {
    var plan = accountPlan(a)
    return Models.accountLabel(a) + (plan ? " · " + plan : "")
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

  // Open sessions a switch would move: how many, and what to call them. Read
  // straight off swapkin's listing instead of a pgrep of our own.
  function sessionsText(p) {
    if (!p) return ""
    var n = Number(p.sessions || 0)
    if (n <= 0) return ""
    var label = p.providerId === "claude" ? "Claude Code" : p.providerName
    return n + " " + label + (n === 1 ? " session open" : " sessions open")
  }

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
    id: accountActionProcess
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.actionError = exitCode === 0 ? "" : Models.syncReason(actionErr.text, exitCode).replace(/^swapkin: /, "")
      root.reloadAccounts()
    }
  }

  // Is @account shown in Claude Code's status line? Asked of swapkin per provider:
  // the setting, and whether anything (ours or the user's own script) prints it.
  readonly property bool canStatusline: !!provider && provider.statusline === true
  property bool statuslineOn: false
  function setStatusline(on) {
    if (!canStatusline || statuslineSet.running) return
    statuslineOn = on
    statuslineSet.command = [accountTool, "-p", providerId, "statusline", on ? "on" : "off"]
    statuslineSet.running = true
  }
  function readStatusline() {
    if (!canStatusline || statuslineRead.running) return
    statuslineRead.command = [accountTool, "-p", providerId, "statusline", "status"]
    statuslineRead.running = true
  }
  onCanStatuslineChanged: readStatusline()
  Process {
    id: statuslineRead
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.statuslineOn = text.trim() === "on"
    }
  }
  Process {
    id: statuslineSet
    stderr: StdioCollector { id: statuslineErr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) root.actionError = statuslineErr.text.replace(/^swapkin: /, "").trim()
      root.readStatusline()
    }
  }

  Process {
    id: syncProcess
    command: [root.accountTool, "usage"]
    stderr: StdioCollector { id: syncErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.syncEndMs = Date.now()
      root.nowMs = root.syncEndMs
      root.syncError = exitCode === 0 ? "" : Models.syncReason(syncErr.text, exitCode)
      root.reloadAccounts()
    }
  }

  // Reads the records on disk. Never starts a fetch.
  function reloadAccounts() {
    usage.reloadSwapkin()
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
    if (accountActionProcess.running || !root.provider) return
    accountActionProcess.command = [accountTool, "-p", root.provider.providerId].concat(args)
    accountActionProcess.running = true
  }

  // The last account action that failed, said in the manage page.
  property string actionError: ""
  // The account being renamed (its name, not its label); "" when none.
  property string renaming: ""
  function refocusKeys() { keyCatcher.forceActiveFocus() }
  function formatTokens(n) { return usage.formatTokenCount(n) }
  function renameAccount(name, text) {
    renaming = ""; addingAccount = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    runAccountAction(["label", name, text])
  }
  // The CLI's own login, never saved: store it as the first account. No
  // terminal needed, the tool just reads what is already signed in.
  function saveCurrentLogin() { runAccountAction(["add", "main"]) }
  function useAccount(name) { runAccountAction(["use", name]) }
  function recolourAccount(name, colour) { runAccountAction(["colour", name, colour]) }
  // First press asks "sure?", the second within 2s removes the login.
  function forgetAccount(name) {
    if (forgetPending !== name) { forgetPending = name; forgetTimer.restart(); return }
    forgetPending = ""
    forgetTimer.stop()
    runAccountAction(["remove", name])
  }
  Timer { id: forgetTimer; interval: 2000; onTriggered: root.forgetPending = "" }

  // Adding asks for a name inside the panel first (addingAccount); only a
  // valid, free name reaches the terminal, where the sign-in itself happens.
  property bool addingAccount: false
  function nameProblem(name) {
    if (!/^[a-z0-9][a-z0-9_-]{0,31}$/.test(name))
      return "Use a-z, 0-9, - and _ (for example: work, personal)."
    if (name === "providers") return "'providers' is reserved."
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].name === name) return "'" + name + "' already exists."
    return ""
  }
  function freeAccountName() {
    var n = 2
    while (nameProblem("account" + n) !== "") n++
    return "account" + n
  }
  function addAccount() {
    if (!root.provider) return
    addingAccount = true
  }
  // Signing in needs a terminal: the tool opens the provider's own login flow
  // in a throwaway home and imports it once you are done.
  function addAccountNamed(name) {
    if (!root.provider || nameProblem(name) !== "") return
    addingAccount = false
    if (root.bar) root.bar.run("omarchy-launch-floating-terminal-with-presentation "
      + accountTool + " -p " + root.provider.providerId + " add " + name)
    root.close()
  }

  function cycleAccount() {
    for (var i = 0; i < accounts.length; i++)
      if (accounts[i].active) {
        useAccount(accounts[(i + 1) % accounts.length].name)
        return
      }
  }

  Component.onCompleted: {
    var ids = []
    for (var i = 0; i < providers.length; i++) ids.push(providers[i].providerId)
    providerIds = ids
    reloadAccounts()
  }

  // Cheap enough to keep running: it only re-evaluates text bindings, and a
  // stale "resets in 2h" on a panel that is open is worse than a timer.
  Timer {
    interval: 30000
    running: root.opened
    repeat: true
    onTriggered: { root.nowMs = Date.now(); usage.reloadSwapkin() }
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

    // The mark from icons/account-A.svg (viewBox 40): a filled disc in the
    // account in use, and an outline ring in the theme foreground drawn on top
    // of it, in the SVG's own units (disc r10, ring r10 + stroke 4; the ring sits
    // 2 units closer than the SVG). The bar would shrink any drawn item until its
    // long side is Style.bar.iconSize (12), which made the pair small next to the
    // bell. It measures only Rectangle/Text/Image/Shape items, so the art is
    // drawn in a hidden item and shown through a ShaderEffectSource, which it
    // does not measure: the mark keeps the size set here, 18 x 14.4, 1.5x what
    // the bar gave it. Never the urgent colour.
    iconComponent: Component {
      Item {
        anchors.fill: parent

        Item {
          id: art
          visible: false
          width: 30
          height: 24

          Rectangle {
            x: 0
            y: 2
            width: 20
            height: 20
            radius: 10
            color: root.accountColour(root.activeAccount)
          }

          Rectangle {
            x: 6
            y: 0
            width: 24
            height: 24
            radius: 12
            color: "transparent"
            border.width: 4
            border.color: button.foreground
          }
        }

        ShaderEffectSource {
          sourceItem: art
          anchors.centerIn: parent
          width: 18
          height: 14.4
          textureSize: Qt.size(art.width * 8, art.height * 8)
          smooth: true
        }
      }
    }
    Accessible.name: root.provider
      ? Models.barSummary(root.provider.providerName, root.activeAccount ? root.activeAccount.name : "", root.headline ? root.headline.percent : -1) : "Swapkin"

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

    readonly property real bodyHeight: strip.implicitHeight + detailColumn.implicitHeight + Style.space(18)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (root.renaming !== "") return
        if (root.settingsOpen && root.paceCursor < 0 && root.modelCursor < 0 && root.autoCursor < 0) { root.settingMove(dx, dy); return }
        if (root.paceCursor >= 0) { root.paceMove(dx, dy); return }
        if (root.autoCursor >= 0) { root.autoMove(dx, dy); return }
        if (root.modelCursor >= 0) { root.modelMove(dx + dy); return }
        root.cursorActive = true
        if (dy !== 0) root.selectProvider(root.providerIndex + dy)
        if (dx !== 0) root.stepCandidate(dx)
      }
      onActivateRequested: if (root.settingsOpen && root.paceCursor < 0 && root.modelCursor < 0 && root.setCursor >= 0) root.settingActivate(); else if (root.paceCursor >= 0) root.paceActivate(root.paceCursor); else if (root.autoCursor >= 0) root.autoActivate(root.autoCursor); else if (root.modelCursor >= 0) root.modelActivate(root.modelCursor); else root.syncNow()
      onCloseRequested: if (root.setCursor >= 0) root.setCursor = -1; else if (root.colourEditing !== "") root.colourEditing = ""; else if (root.paceCursor >= 0) root.paceCursor = -1; else if (root.autoCursor >= 0) root.autoCursor = -1; else if (root.modelCursor >= 0) root.modelCursor = -1; else root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if ((t === "w" || t === "W") && root.settingsOpen) { root.modelCursor = -1; root.autoCursor = -1; root.paceCursor = root.paceCursor >= 0 ? -1 : (root.paceWorking ? 2 : 0) }
        else if ((t === "s" || t === "S") && root.managing && root.canAutoSwitch) { root.modelCursor = -1; root.paceCursor = -1; root.autoCursor = root.autoCursor >= 0 ? -1 : 0 }
        else if ((t === "o" || t === "O") && root.settingsOpen && root.modelChips.length > 0) { root.paceCursor = -1; root.autoCursor = -1; root.modelCursor = root.modelCursor >= 0 ? -1 : 0 }
        else if (root.managing && t.length === 1 && "uUnNcCfFvV".indexOf(t) >= 0 && root.manageKey(t)) { }
        else if ((t === "t" || t === "T") && !root.settingsOpen && !root.managing && root.canStatusline) root.setStatusline(!root.statuslineOn)
        else if (t === "r" || t === "R") root.syncNow()
        else if ((t === "a" || t === "A") && root.accounts.length > 1) root.switchToCandidate()
        else if ((t === "m" || t === "M") && root.canManage) root.toggleManage()
        else if (t === "," || ((t === "s" || t === "S") && !(root.managing && root.canAutoSwitch))) root.toggleSettings()
      }

      Column {
        anchors.fill: parent
        spacing: Style.space(12)

        // ---------- Header: who am I, and who pays for the next message ----------
        Column {
          id: header
          width: parent.width
          spacing: Style.space(10)

          // ---- Hero gauge: how full the tightest limit is, the first thing seen ----
          Item {
            id: hero
            visible: !!root.provider
            width: parent.width
            height: Style.space(112)

            readonly property real ring: Style.space(92)
            readonly property color hue: root.alarming ? root.urgent : root.accountColour(root.candidate)
            readonly property real pct: root.headline ? root.headline.percent : -1
            property real glowIn: 1
            property real breath: 1
            property real flash: 0
            property real lastPct: -1
            property string lastKey: ""

            Accessible.role: Accessible.ProgressBar
            Accessible.name: root.provider
              ? root.provider.providerName + (root.headline ? ", " + root.headline.title : "")
                + (pct >= 0 ? ", " + Math.round(pct * 100) + " percent used" + (root.alarming ? ", nearly full" : "") : ", no data")
              : ""

            // The open sweep: ring from empty to the value, the number in step,
            // the glow fading in behind it.
            function replay() {
              heroGauge.sweepMs = 0
              heroGauge.shown = 0
              glowIn = 0
              heroGauge.sweepMs = 700
              heroGauge.shown = pct >= 0 ? pct : 0
              if (!root.reduced) glowFade.restart(); else glowIn = 1
            }

            Connections {
              target: root
              function onEnterTickChanged() { hero.replay(); if (hero.breathing) breathAnim.restart() }
            }

            // Pulse when the same account's usage goes up: one soft beat.
            onPctChanged: {
              var key = root.selectedProviderId + "/" + (root.candidate ? root.candidate.name : "")
              if (key === lastKey && lastPct >= 0 && pct > lastPct && !root.reduced && root.opened) pulse.restart()
              lastKey = key
              lastPct = pct
            }

            NumberAnimation { id: glowFade; target: hero; property: "glowIn"; from: 0; to: 1; duration: root.dur(600); easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }

            SequentialAnimation {
              id: pulse
              ParallelAnimation {
                NumberAnimation { target: heroGauge; property: "scale"; to: 1.05; duration: root.dur(180); easing.type: Easing.OutCubic }
                NumberAnimation { target: hero; property: "flash"; to: 1; duration: root.dur(200) }
              }
              ParallelAnimation {
                NumberAnimation { target: heroGauge; property: "scale"; to: 1; duration: root.dur(320); easing.type: Easing.OutBack; easing.overshoot: 2 }
                NumberAnimation { target: hero; property: "flash"; to: 0; duration: root.dur(200) }
              }
            }

            // A slow breath on the glow: three cycles, only for a full limit and
            // only while open. It restarts on open and provider change.
            readonly property bool breathing: root.opened && root.alarming && !root.reduced && hero.visible
            onBreathingChanged: if (breathing) breathAnim.restart(); else { breathAnim.stop(); breath = 1 }
            SequentialAnimation {
              id: breathAnim
              loops: 3
              onFinished: hero.breath = 1
              NumberAnimation { target: hero; property: "breath"; to: 0.7; duration: root.dur(1200); easing.type: Easing.InOutSine }
              NumberAnimation { target: hero; property: "breath"; to: 1; duration: root.dur(1200); easing.type: Easing.InOutSine }
            }

            // Glow in the provider hue: a radial fade, no blur effect.
            Shape {
              x: heroGauge.x + heroGauge.width / 2 - width / 2
              y: heroGauge.y + heroGauge.height / 2 - height / 2
              width: hero.ring * 1.9
              height: width
              opacity: hero.glowIn * hero.breath
              preferredRendererType: Shape.CurveRenderer
              ShapePath {
                strokeColor: "transparent"
                fillGradient: RadialGradient {
                  centerX: hero.ring * 0.95; centerY: hero.ring * 0.95
                  centerRadius: hero.ring * 0.95
                  focalX: centerX; focalY: centerY
                  GradientStop { position: 0.0; color: root.alpha(hero.hue, 0.18) }
                  GradientStop { position: 0.55; color: root.alpha(hero.hue, 0.08) }
                  GradientStop { position: 1.0; color: root.alpha(hero.hue, 0) }
                }
                PathRectangle { x: 0; y: 0; width: hero.ring * 1.9; height: width }
              }
            }

            // Settings for every provider (key , or s).
            Button {
              id: settingsButton
              z: 2
              anchors.right: parent.right
              anchors.top: parent.top
              text: "⚙"
              bordered: root.settingsOpen
              foreground: root.foreground
              fontFamily: root.fontFamily
              fontSize: Style.font.body
              verticalPadding: Style.space(3)
              Accessible.name: root.settingsOpen ? "Close settings" : "Open settings for all providers"
              onClicked: root.toggleSettings()
            }

            Gauge {
              id: heroGauge
              reduced: root.reduced
              x: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              size: hero.ring
              thickness: Math.round(hero.ring * 0.11)
              value: hero.pct
              sweepMs: 450
              settleMs: 450
              alarm: root.alarming
              trackColor: root.alpha(root.foreground, 0.2)
              valueColor: root.accountColour(root.candidate)
              alarmColor: root.urgent

              Row {
                anchors.centerIn: parent
                spacing: 1
                Text {
                  id: heroNumber
                  textFormat: Text.PlainText
                  text: hero.pct >= 0 ? Models.countUp(heroGauge.value, heroGauge.value > 0 ? heroGauge.shown / heroGauge.value : 1) : "–"
                  color: Qt.tint(root.dim, Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, hero.flash))
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(hero.ring * 0.36)
                  font.bold: true
                }
                Text {
                  visible: hero.pct >= 0
                  anchors.baseline: heroNumber.baseline
                  textFormat: Text.PlainText
                  text: "%"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(hero.ring * 0.18)
                }
              }
            }

            Column {
              anchors.left: heroGauge.right
              anchors.leftMargin: Style.space(20)
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(3)

              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.provider ? root.provider.providerName : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.candidate ? root.nameAndPlan(root.candidate) + (root.candidate.active ? "" : " · not active") : root.heroMeta(root.provider)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
              Text {
                visible: !!root.headline
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.headline ? root.headline.title + (root.resetText(root.headline) !== "" ? " · " + root.resetText(root.headline) : "") : ""
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
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
        }

        // ---------- Body: the provider strip, then the chosen one below ----------
        Column {
          visible: root.providers.length > 0
          width: parent.width
          height: parent.height - header.height - keyBar.height - parent.spacing * 2
          spacing: Style.space(8)

          Row {
            id: strip
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: root.providerIds

              ProviderChip {
                required property string modelData
                required property int index

                width: (strip.width - strip.spacing * Math.max(0, root.providerIds.length - 1)) / Math.max(1, root.providerIds.length)
                provider: root.providerById(modelData)
                position: index
                selected: modelData === root.selectedProviderIdOrFirst
                onClicked: {
                  root.cursorActive = true
                  root.selectProvider(index)
                }
              }
            }
          }

          Rectangle {
            width: parent.width
            height: 1
            color: root.alpha(root.foreground, 0.18)
          }

          Flickable {
            id: detailFlick
            width: parent.width
            height: parent.height - strip.height - 1 - parent.spacing * 2
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
                visible: !root.settingsOpen
                width: parent.width
                implicitHeight: Math.max(detailTitle.implicitHeight, manageButton.implicitHeight, syncRow.implicitHeight)

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
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  // Who pays when you use this provider, right where you look.
                  Text {
                    textFormat: Text.PlainText
                    text: root.payerLabel
                    color: root.activeAccount ? root.accountColour(root.activeAccount) : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }

                }

                Row {
                  id: syncRow
                  anchors.right: manageButton.visible ? manageButton.left : parent.right
                  anchors.rightMargin: manageButton.visible ? Style.space(6) : 0
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  // A quarter ring that turns only while syncing, and not at all
                  // with reduced motion (the button then says "Syncing…").
                  Gauge {
                    id: spinner
                    reduced: root.reduced
                    visible: root.syncView.spin
                    anchors.verticalCenter: parent.verticalCenter
                    size: Style.space(14)
                    thickness: Style.space(2)
                    value: 0.28
                    trackColor: root.alpha(root.foreground, 0.2)
                    valueColor: root.foreground
                    RotationAnimator on rotation {
                      from: 0; to: 360; duration: root.dur(900)
                      loops: Animation.Infinite
                      running: spinner.visible && root.opened
                    }
                  }

                  Button {
                    id: syncButton
                    enabled: !root.syncView.disabled
                    opacity: root.syncView.resting ? 0.4 : 1
                    text: root.syncView.label + (root.syncView.disabled ? "" : "  (r)")
                    bordered: true
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    fontSize: Style.font.caption
                    verticalPadding: Style.space(3)
                    Accessible.name: root.syncView.disabled ? "Syncing usage for every account" : "Sync usage for every account"
                    onClicked: root.syncNow()
                  }
                }

                Button {
                  id: manageButton
                  visible: root.canManage
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
                visible: !root.settingsOpen && text !== ""
                width: parent.width
                textFormat: Text.PlainText
                text: Models.syncedLine(root.providers, root.nowMs)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: !root.settingsOpen && root.syncView.resting && root.syncHint !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.syncHint
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: !root.settingsOpen && root.syncView.error !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: "Sync failed: " + root.syncView.error
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: !root.settingsOpen && root.hasAccounts && root.provider && root.provider.reloadPending !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.provider ? "Close Codex to finish the switch: it still uses " + root.provider.reloadPending + "." : ""
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              Text {
                visible: !root.settingsOpen && root.hasAccounts && root.provider && root.provider.sessions > 0
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                text: root.sessionsText(root.provider)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }

              // ---- Manage: every account of this provider, one place, same for all ----
              ManagePage {
                host: root
                visible: root.canManage && root.managing
                width: parent.width
              }

              // ---- Settings for every provider ----
              SettingsPage {
                host: root
                visible: root.settingsOpen
                width: parent.width
              }

              // ---- Accounts: the highlighted one is previewed; a switches to it ----
              Flow {
                visible: root.hasAccounts && !root.subView
                width: parent.width
                spacing: Style.space(8)

                Repeater {
                  model: root.accounts

                  Button {
                    id: tile
                    required property var modelData

                    width: Math.max(Style.space(140), (parent.width - Style.space(8) * (root.accounts.length > 3 ? 2 : root.accounts.length - 1)) / Math.min(root.accounts.length, 3))
                    implicitHeight: tileText.implicitHeight + Style.space(16)
                    selected: !!root.candidate && modelData.name === root.candidate.name
                    bordered: true
                    foreground: root.accountColour(modelData)
                    fontFamily: root.fontFamily
                    Accessible.name: tileName.text + ", " + tileMeta.text
                    onClicked: root.candName = modelData.name

                    // Name and plan on one line; the figure and its age small and dim below.
                    Column {
                      id: tileText
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(10)
                      anchors.rightMargin: Style.space(10)
                      spacing: Style.space(2)
                      Text {
                        id: tileName
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: root.nameAndPlan(tile.modelData) + (tile.modelData.active ? " · active" : "")
                        color: tile.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        font.bold: tile.selected
                      }
                      Text {
                        id: tileMeta
                        width: parent.width
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        text: (root.peakText(tile.modelData) !== "" ? root.peakText(tile.modelData).replace(" · ", "") + " · " : "") + Models.agoText(tile.modelData.age).replace("updated ", "")
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }
                  }
                }
              }

              Item {
                visible: root.hasAccounts && !root.subView
                width: parent.width
                implicitHeight: Math.max(switchButton.visible ? switchButton.implicitHeight : 0, switchNote.implicitHeight)

                Button {
                  id: switchButton
                  visible: !!root.candidate && !root.candidate.active
                  anchors.left: parent.left
                  anchors.verticalCenter: parent.verticalCenter
                  text: (root.provider && root.provider.mode === "never" ? "Sign in as " : "Switch to ")
                    + (root.candidate ? root.candidate.name : "") + "  (a)"
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

              // ---- Account in Claude Code's status line (providers that support it) ----
              Column {
                visible: root.hasAccounts && !root.subView && root.canStatusline
                width: parent.width
                spacing: Style.space(4)

                Item {
                  width: parent.width
                  implicitHeight: Math.max(statuslineLabel.implicitHeight, statuslineChoices.implicitHeight)

                  Text {
                    id: statuslineLabel
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "Show account in status line  (t)"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                  Row {
                    id: statuslineChoices
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)
                    Repeater {
                      model: ["On", "Off"]
                      Button {
                        required property var modelData
                        required property int index
                        text: modelData
                        bordered: true
                        selected: (index === 0) === root.statuslineOn
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        fontSize: Style.font.caption
                        horizontalPadding: Style.space(10)
                        verticalPadding: Style.spacing.controlPaddingY
                        onClicked: root.setStatusline(index === 0)
                      }
                    }
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  text: "Adds @" + (root.activeAccount ? root.activeAccount.name : "account")
                    + " (the account in use) to the bottom line of Claude Code. Off removes it."
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              // ---- Status ----
              BorderSurface {
                visible: !!root.provider && (String(root.provider.usageStatusText || "") !== "" || root.provider.rateLimited === true)
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
                  text: Models.helpLine(root.provider)
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
                visible: limitsSection.visible && !root.subView
                foreground: root.foreground
              }

              Column {
                id: limitsSection
                visible: root.limits.length > 0 && !root.subView
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  // The header doubles as the progress light: a probe takes about
                  // a second, and a silent stale number is worse than saying so.
                  text: (root.hasAccounts && !!root.candidate ? root.nameAndPlan(root.candidate).toUpperCase()
                                           : "LIMITS")
                    + (root.hasAccounts && !!root.candidate && !root.candidate.active ? " · PREVIEW" : "")
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
                    id: limitItem
                    required property var modelData
                    required property int index
                    width: limitsSection.width
                    window: modelData
                    opacity: limitStagger.p
                    transform: Translate { y: (1 - limitStagger.p) * 8 }
                    StaggerIn { id: limitStagger; reduced: root.reduced; index: limitItem.index + 1; tick: root.enterTick }
                  }
                }
              }

              // ---- Counts: tools with no ceiling report a count, never a percent ----
              PanelSeparator {
                visible: countsSection.visible
                foreground: root.foreground
              }

              Column {
                id: countsSection
                readonly property var counts: root.candidate && Array.isArray(root.candidate.counts) ? root.candidate.counts : []
                visible: counts.length > 0 && !root.subView
                width: parent.width
                spacing: Style.space(8)

                PanelSectionHeader {
                  text: "USAGE"
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                }

                Repeater {
                  model: countsSection.counts

                  Item {
                    required property var modelData
                    width: countsSection.width
                    implicitHeight: Math.max(countLabel.implicitHeight, countValue.implicitHeight)

                    Text {
                      id: countLabel
                      textFormat: Text.PlainText
                      text: String(modelData.label || "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      anchors.left: parent.left
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      id: countValue
                      textFormat: Text.PlainText
                      text: String(modelData.value) + (modelData.unit ? " " + modelData.unit : "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }

                CaptionText {
                  visible: root.limits.length === 0
                  text: "No ceiling reported, so no pace."
                }
              }

              // ---- Tokens by day ----
              PanelSeparator {
                visible: usageSection.visible && !root.subView
                foreground: root.foreground
              }

              Column {
                id: usageSection
                visible: !root.subView && !!root.provider && root.provider.recentDays && root.provider.recentDays.length > 0
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

              // Today, in the other unit people think in. Claude only: the
              // estimate is priced from prices.json, which only knows Claude.
              Text {
                visible: !root.subView && root.showCost && root.hasAccounts && root.todayCost >= 0
                  && root.provider && root.provider.providerId === "claude"
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
                visible: !root.subView && root.models.length > 0
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
                    // Bar = this version's share of its family, labelled in %.
                    // A family header draws no bar.
                    share: modelData.header ? 0 : Models.shareOf(modelData.total, modelData.peak)
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
            model: root.paceCursor >= 0
              ? [{ k: "↑ ↓ ← →", l: "move" }, { k: "enter", l: "change" }, { k: "w", l: "back" }]
              : root.autoCursor >= 0
              ? [{ k: "↑ ↓ ← →", l: "move" }, { k: "enter", l: "change" }, { k: "s", l: "back" }]
              : root.modelCursor >= 0
              ? [{ k: "↑ ↓ ← →", l: "move" }, { k: "enter", l: "show/hide" }, { k: "o", l: "back" }]
              : Models.keyHints(root.hasAccounts, root.canManage, root.managing, root.canAutoSwitch, root.settingsOpen, root.canSwitchAccounts, root.canStatusline)

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

  // One provider in the left column: name, account and plan, how full it is.
  // One provider in the strip: a mini gauge and its name. The selected chip
  // lifts 2px, sits on a soft shadow and glows in its account hue.
  component ProviderChip: MouseArea {
    id: chip
    property var provider: null
    property bool selected: false
    property int position: 0

    // Its own active account, never root.activeAccount: that one belongs to
    // whichever provider is selected, and a chip for another provider must
    // never borrow it.
    readonly property var rowActive: root.activeAccountFor(provider)
    readonly property var windows: root.providerWindows(provider, rowActive)
    readonly property var tight: root.tightest(windows)
    readonly property color hue: root.accountColour(rowActive)
    property real lift: selected ? Style.space(2) : 0

    implicitHeight: Style.space(52)
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    activeFocusOnTab: false
    Accessible.role: Accessible.Button
    Accessible.name: chip.provider
      ? Models.barSummary(chip.provider.providerName, chip.rowActive ? chip.rowActive.name : "", chip.tight ? chip.tight.percent : -1)
        + (chip.selected ? ", selected" : "") : ""

    opacity: stagger.p
    transform: Translate { y: (1 - stagger.p) * 8 - chip.lift }
    StaggerIn { id: stagger; reduced: root.reduced; index: chip.position; tick: root.stripTick }

    Behavior on lift { NumberAnimation { duration: root.dur(260); easing.type: Easing.OutBack; easing.overshoot: 1.6 } }
    // Press feedback: the chip gives a little under the finger.
    scale: pressed ? 0.97 : 1
    Behavior on scale { NumberAnimation { duration: root.dur(120); easing.type: Easing.OutCubic } }

    Rectangle {
      visible: chip.selected
      anchors.fill: parent
      anchors.topMargin: Style.space(2)
      radius: Style.cornerRadius
      color: root.alpha("#000000", 0.18)
    }

    Rectangle {
      anchors.fill: parent
      radius: Style.cornerRadius
      color: chip.selected ? root.track
           : chip.containsMouse ? root.alpha(root.foreground, 0.06) : "transparent"
      border.width: chip.selected ? 1 : 0
      border.color: root.alpha(Color.accent, 0.45)
    }

    Row {
      anchors.verticalCenter: parent.verticalCenter
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(8)

      Gauge {
        id: chipGauge
        reduced: root.reduced
        anchors.verticalCenter: parent.verticalCenter
        size: Style.space(30)
        thickness: Style.space(4)
        value: chip.tight ? chip.tight.percent : -1
        alarm: !!chip.tight && chip.tight.percent >= 0.9
        trackColor: root.alpha(root.foreground, 0.2)
        valueColor: chip.hue
        alarmColor: root.urgent
      }

      Column {
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width - chipGauge.width - parent.spacing
        spacing: Style.space(1)

        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          text: chip.provider ? chip.provider.providerName : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          font.bold: true
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          elide: Text.ElideRight
          text: (chip.tight ? Math.round(chip.tight.percent * 100) + "% · " : "")
            + (chip.rowActive ? chip.rowActive.name : root.heroMeta(chip.provider))
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
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
          ? Math.round(limitRow.window.percent * 100) + "%" + (limitRow.alarming ? " !" : "")
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
        visible: !!limitRow.pace && limitRow.pace.state !== "early" && limitRow.window.percent > 0
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
      color: root.foreground
    }

    CaptionText {
      text: limitRow.window ? Budget.forecastLine(limitRow.window.percent, limitRow.pace,
                                                  limitRow.resetMs, root.nowMs) : ""
      color: limitRow.pace && (limitRow.pace.full || limitRow.pace.projected > 1) ? root.urgent : root.foreground
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
    Accessible.role: Accessible.ProgressBar
    Accessible.name: value >= 0 ? Math.round(value * 100) + " percent used" + (alarming ? ", nearly full" : "") : "no data"
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
        NumberAnimation { duration: root.dur(160); easing.type: Easing.OutCubic }
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
        anchors.bottom: parent.bottom
        width: Math.min(parent.width, Style.space(28))
        height: Math.max(Style.space(3), parent.height * root.clamp(dayBar.ratio, 0, 1))
        radius: Style.space(2)
        color: dayBar.today ? root.foreground : root.alpha(root.foreground, 0.55)

        Behavior on height {
          NumberAnimation { duration: root.dur(160); easing.type: Easing.OutCubic }
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
      color: modelRow.row && modelRow.row.header ? "transparent" : root.alpha(root.foreground, 0.05)
    }

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: parent.width * root.clamp(modelRow.share, 0, 1)
      radius: Style.cornerRadius
      color: root.alpha(root.foreground, 0.14)

      Behavior on width {
        NumberAnimation { duration: root.dur(160); easing.type: Easing.OutCubic }
      }
    }

    Text {
      id: modelName
      textFormat: Text.PlainText
      text: modelRow.row ? modelRow.row.name : ""
      color: root.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: modelRow.row ? modelRow.row.header : false
      elide: Text.ElideRight
      anchors.left: parent.left
      anchors.leftMargin: Style.space(modelRow.row && modelRow.row.indent ? 20 : 8)
      anchors.right: modelTokens.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
    }

    Text {
      id: modelTokens
      textFormat: Text.PlainText
      text: !modelRow.row ? ""
        : modelRow.row.header ? usage.formatTokenCount(modelRow.row.total)
        : Models.shareText(modelRow.row.total, modelRow.row.peak) + " · " + usage.formatTokenCount(modelRow.row.total)
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
