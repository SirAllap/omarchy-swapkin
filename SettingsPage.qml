import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Budget.js" as Budget
import "Models.js" as Models

// Settings for every provider, in sections with a line of help each. Every row
// here is read by real code: the watchdog (interval, warn-at), the hero ring
// (which limit), the provider strip (hidden, first), the cost line, and motion.
// Auto-switch is Claude's, so it lives in Claude's manage page.
//
// Keys: ↑ ↓ pick a row, ← → change it, enter changes it forward; w pace, o models.
Column {
  id: page

  required property var host

  spacing: Style.space(8)

  property real slide: 1
  opacity: slide
  transform: Translate { x: (1 - page.slide) * 24 }
  onVisibleChanged: if (visible) {
    if (host.reduced) { slideIn.stop(); slide = 1 } else { slide = 0; slideIn.restart() }
  }
  NumberAnimation { id: slideIn; target: page; property: "slide"; to: 1; duration: host.dur(220); easing.type: Easing.OutCubic }

  component Choice: Button {
    bordered: true
    foreground: page.host.foreground
    fontFamily: page.host.fontFamily
    fontSize: Style.font.caption
    horizontalPadding: Style.space(10)
    verticalPadding: Style.spacing.controlPaddingY
  }

  component Help: Text {
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    color: page.host.dim
    font.family: page.host.fontFamily
    font.pixelSize: Style.font.caption
  }

  component Section: Column {
    property string title: ""
    property string help: ""
    width: parent.width
    spacing: Style.space(6)
    PanelSeparator { foreground: page.host.foreground }
    PanelSectionHeader {
      width: parent.width
      text: parent.title
      foreground: page.host.foreground
      fontFamily: page.host.fontFamily
    }
    Help { visible: parent.help !== ""; text: parent.help }
  }

  // A labelled row. `cursor` is its index in the keyboard order.
  component Row2: Item {
    id: line
    property string label: ""
    property int cursor: -1
    default property alias content: slot.data
    width: parent.width
    implicitHeight: Math.max(lineLabel.implicitHeight, slot.implicitHeight) + Style.space(6)

    readonly property bool picked: page.host.setCursor === cursor && cursor >= 0

    Rectangle {
      anchors.fill: parent
      radius: Style.space(6)
      color: line.picked ? page.host.alpha(page.host.foreground, 0.07) : "transparent"
      Behavior on color { ColorAnimation { duration: page.host.dur(120) } }
    }
    Text {
      id: lineLabel
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: line.label
      color: line.picked ? page.host.foreground : page.host.dim
      font.family: page.host.fontFamily
      font.pixelSize: Style.font.caption
    }
    Row {
      id: slot
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(6)
      enabled: page.host.canWritePace
    }
  }

  component Stepper: Row {
    id: stepper
    property string valueText: ""
    signal down()
    signal up()
    spacing: Style.space(6)
    Choice { text: "−"; onClicked: stepper.down() }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(56)
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: stepper.valueText
      color: page.host.foreground
      font.family: page.host.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Choice { text: "+"; onClicked: stepper.up() }
  }

  PanelSectionHeader {
    width: parent.width
    text: "SETTINGS · ALL PROVIDERS"
    foreground: page.host.foreground
    fontFamily: page.host.fontFamily
  }

  Help {
    text: page.host.canWritePace
      ? "Press ↑ ↓ to pick a row and ← → to change it. Auto-switch is Claude's own: it is in Claude's manage page."
      : "This shell cannot save from here. Edit these in Omarchy plugin settings."
  }

  // ------------------------------------------------------------- watching ----
  Section {
    title: "WATCHING"
    help: "While the panel is closed Swapkin keeps an eye on the active Claude account."
  }

  Row2 {
    label: "Check every"
    cursor: 0
    Stepper {
      valueText: page.host.watchMinutes + " min"
      onDown: page.host.settingChange("watch", -1)
      onUp: page.host.settingChange("watch", 1)
    }
  }
  Row2 {
    label: "Warn me at"
    cursor: 1
    Stepper {
      valueText: page.host.warnAtPct + "%"
      onDown: page.host.settingChange("warn", -1)
      onUp: page.host.settingChange("warn", 1)
    }
  }
  Help { text: "Each check refreshes the figures, and warns once when the weekly limit passes the warn-at share." }

  // --------------------------------------------------------------- display ----
  Section {
    title: "DISPLAY"
    help: "What the top of the panel shows, and what it leaves out."
  }

  Row2 {
    label: "Hero ring shows"
    cursor: 2
    Repeater {
      model: page.host.heroOptions
      Choice {
        required property var modelData
        text: modelData.label
        selected: modelData.id === page.host.heroRingSetting
        onClicked: page.host.persistSettings({ heroRing: modelData.id })
      }
    }
  }
  Help { text: "Tightest is the fullest limit. Weekly or Session pick that window; an account without one shows its fullest." }

  Row2 {
    label: "Opens on"
    cursor: 3
    Flow {
      width: Style.space(400)
      spacing: Style.space(6)
      Repeater {
        model: [{ providerId: "", providerName: "Most used" }].concat(page.host.allProviders)
        Choice {
          required property var modelData
          text: modelData.providerName
          selected: modelData.providerId === page.host.firstProviderSetting
          onClicked: page.host.persistSettings({ firstProvider: modelData.providerId })
        }
      }
    }
  }

  Row2 {
    label: "Cost estimate"
    cursor: 4
    Repeater {
      model: ["Show", "Hide"]
      Choice {
        required property var modelData
        required property int index
        text: modelData
        selected: (index === 0) === page.host.showCost
        onClicked: page.host.persistSettings({ showCost: index === 0 })
      }
    }
  }
  Help { text: "Today's tokens priced at API rates, under the details. Claude only; it is an estimate." }

  Row2 {
    label: "Motion"
    cursor: 5
    Repeater {
      model: page.host.motionOptions
      Choice {
        required property var modelData
        text: modelData.label
        selected: modelData.id === page.host.motionSetting
        onClicked: page.host.persistSettings({ motion: modelData.id })
      }
    }
  }
  Help { text: "System follows Omarchy's reduce-motion switch. Reduce and Full override it for Swapkin only. Nothing moves while the panel is idle." }

  // ------------------------------------------------------------- providers ----
  Section {
    title: "PROVIDERS"
    help: "Leave a provider out of the strip. Its accounts and data are untouched; one always stays."
  }

  Flow {
    width: parent.width
    spacing: Style.space(6)
    enabled: page.host.canWritePace

    Repeater {
      model: page.host.allProviders

      Choice {
        required property var modelData
        required property int index
        text: modelData.providerName
        selected: !Models.isHidden(page.host.providersHiddenText, modelData.providerId)
        hasCursor: page.host.setCursor === 6 && page.host.provCursor === index
        Accessible.name: modelData.providerName + (selected ? ", shown" : ", hidden")
        onClicked: { page.host.provCursor = index; page.host.toggleProvider(index) }
      }
    }
  }

  // ----------------------------------------------------------- weekly pace ----
  Section {
    title: "WEEKLY PACE"
    help: "The days and hours that earn weekly budget. Press w for the keys."
  }

  Row {
    width: parent.width
    spacing: Style.space(6)
    enabled: page.host.canWritePace

    Repeater {
      model: ["Working hours", "Every hour"]

      Choice {
        required property var modelData
        required property int index

        width: (parent.width - parent.spacing) / 2
        text: modelData
        selected: (index === 0) === page.host.paceWorking
        hasCursor: page.host.paceCursor === index
        onClicked: page.host.paceActivate(index)
      }
    }
  }

  Row {
    width: parent.width
    spacing: Style.space(4)
    enabled: page.host.canWritePace
    opacity: page.host.paceWorking ? 1 : 0.45

    Repeater {
      model: page.host.paceDayNames

      Choice {
        required property var modelData
        required property int index

        width: (parent.width - parent.spacing * 6) / 7
        text: modelData
        selected: page.host.paceDays[page.host.paceDayOrder[index]]
        hasCursor: page.host.paceCursor === index + 2
        horizontalPadding: Style.space(2)
        onClicked: page.host.paceActivate(index + 2)
      }
    }
  }

  Repeater {
    model: [{ label: "Work starts", value: page.host.paceHours.start, first: 9 },
            { label: "Work ends", value: page.host.paceHours.end, first: 11 }]

    Item {
      id: hourLine
      required property var modelData

      width: parent.width
      implicitHeight: Math.max(hourLabel.implicitHeight, hourStep.implicitHeight)
      opacity: page.host.paceWorking ? 1 : 0.45

      Text {
        id: hourLabel
        anchors.left: parent.left
        anchors.leftMargin: Style.space(6)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: hourLine.modelData.label
        color: page.host.dim
        font.family: page.host.fontFamily
        font.pixelSize: Style.font.caption
      }

      Row {
        id: hourStep
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.space(6)
        enabled: page.host.canWritePace

        Choice {
          text: "−"
          hasCursor: page.host.paceCursor === hourLine.modelData.first
          onClicked: page.host.paceActivate(hourLine.modelData.first)
        }
        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: Style.space(56)
          horizontalAlignment: Text.AlignHCenter
          textFormat: Text.PlainText
          text: Budget.hourText(hourLine.modelData.value)
          color: page.host.foreground
          font.family: page.host.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Choice {
          text: "+"
          hasCursor: page.host.paceCursor === hourLine.modelData.first + 1
          onClicked: page.host.paceActivate(hourLine.modelData.first + 1)
        }
      }
    }
  }

  // ---------------------------------------------------------------- models ----
  Section {
    title: "MODELS SHOWN"
    help: "Hides a model from Tokens by model only; no usage is deleted. Press o for the keys."
  }

  Flow {
    width: parent.width
    spacing: Style.space(6)
    enabled: page.host.canWritePace

    Repeater {
      model: page.host.modelChips

      Choice {
        required property var modelData
        required property int index

        text: modelData.name + " · " + page.host.formatTokens(modelData.total)
        selected: modelData.shown
        hasCursor: page.host.modelCursor === index
        onClicked: page.host.modelActivate(index)
      }
    }

    Choice {
      visible: page.host.modelsHiddenText !== ""
      text: "Show all"
      hasCursor: page.host.modelCursor === page.host.modelChips.length
      onClicked: page.host.modelActivate(page.host.modelChips.length)
    }
  }
}
