import QtQuick
import QtQuick.Controls
import qs.Commons
import qs.Ui
import "Models.js" as Models

// Manage: one page, the same for every provider. Every account is a card with
// its plan, its limits at a glance, when they were read, and the things you do
// to it: use, rename, recolour, forget. The CLI's own login shows up too, even
// when swapkin has not saved it, with a Save action. A provider that keeps one
// login (Antigravity) gets the same card and says plainly how to change it.
//
// Keys (they act on the account in view, the one ← → picked):
//   u / a use · n rename · c colour · f forget (twice) · v save the login
Column {
  id: page

  // The Panel. Everything here reads its state and calls its actions.
  required property var host

  spacing: Style.space(10)

  // Slides in over the details when manage opens; instant with reduced motion.
  property real slide: 1
  opacity: slide
  transform: Translate { x: (1 - page.slide) * 24 }
  onVisibleChanged: if (visible) {
    if (host.reduced) { slideIn.stop(); slide = 1 } else { slide = 0; slideIn.restart() }
  }
  NumberAnimation { id: slideIn; target: page; property: "slide"; to: 1; duration: host.dur(220); easing.type: Easing.OutCubic }

  readonly property var provider: host.provider
  readonly property bool unsaved: Models.unsavedLogin(provider)
  readonly property bool oneLogin: !!provider && provider.mode === "never"
  readonly property string planText: provider ? Models.stripProviderName(provider.tierLabel, provider.providerName) : ""

  // A small action next to an account; every one is a real button with a
  // 44-ish px hit area once padding is counted, and a press scale from Button.
  component Act: Button {
    bordered: true
    foreground: page.host.foreground
    fontFamily: page.host.fontFamily
    fontSize: Style.font.caption
    horizontalPadding: Style.space(10)
    verticalPadding: Style.space(5)
  }

  // A limit: name and percent on top, a thin bar, the reset line small and dim below.
  component LimitRow: Item {
    id: limit
    required property var win
    required property color tint

    width: parent.width
    implicitHeight: limitCol.implicitHeight
    readonly property real pct: Math.max(0, Math.min(1, win.percent))
    readonly property bool hot: pct >= 0.9

    Column {
      id: limitCol
      width: parent.width
      spacing: Style.space(3)

      Item {
        width: parent.width
        implicitHeight: Math.max(limitTitle.implicitHeight, limitPct.implicitHeight)
        height: implicitHeight

        Text {
          id: limitTitle
          anchors.left: parent.left
          anchors.right: limitPct.left
          anchors.rightMargin: Style.space(8)
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: limit.win.title
          color: page.host.foreground
          font.family: page.host.fontFamily
          font.pixelSize: Style.font.caption
        }

        Text {
          id: limitPct
          anchors.right: parent.right
          textFormat: Text.PlainText
          text: Math.round(limit.pct * 100) + "%"
          color: limit.hot ? page.host.urgent : page.host.foreground
          font.family: page.host.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: limit.hot
        }
      }

      Rectangle {
        width: parent.width
        height: Style.space(5)
        radius: height / 2
        color: page.host.alpha(page.host.foreground, 0.14)

        Rectangle {
          width: Math.max(limit.pct > 0 ? height : 0, parent.width * limit.pct)
          height: parent.height
          radius: height / 2
          color: limit.hot ? page.host.urgent : limit.tint
          Behavior on width { NumberAnimation { duration: page.host.dur(300); easing.type: Easing.OutCubic } }
        }
      }

      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: page.host.resetText(limit.win)
        color: page.host.dim
        font.family: page.host.fontFamily
        font.pixelSize: Style.font.caption - 1
      }
    }
  }

  // ------------------------------------------------------------ accounts ----
  PanelSectionHeader {
    width: parent.width
    text: page.host.hasAccounts ? "ACCOUNT · " + page.host.accounts.length + " SAVED" : "LOGIN"
    foreground: page.host.foreground
    fontFamily: page.host.fontFamily
  }

  Text {
    visible: page.host.actionError !== ""
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: page.host.actionError
    color: page.host.urgent
    font.family: page.host.fontFamily
    font.pixelSize: Style.font.caption
  }

  // Pick the account to manage; ← → and a click on a card of the main view do the same.
  Flow {
    visible: page.host.accounts.length > 1
    width: parent.width
    spacing: Style.space(6)

    Repeater {
      model: page.host.accounts

      Act {
        required property var modelData
        readonly property bool inView: !!page.host.candidate && modelData.name === page.host.candidate.name
        text: "\u25cf  " + Models.accountLabel(modelData) + (modelData.active ? " · active" : "")
        selected: inView
        foreground: inView ? page.host.accountColour(modelData) : page.host.foreground
        Accessible.name: "Manage " + Models.accountLabel(modelData)
        onClicked: page.host.candName = modelData.name
      }
    }
  }

  // Only the account in view gets its detail: its own plan, limits and actions.
  Repeater {
    model: page.host.accounts

    Rectangle {
      id: card
      visible: inView
      required property var modelData

      readonly property var acct: modelData
      readonly property bool inView: !!page.host.candidate && acct.name === page.host.candidate.name
      readonly property bool editing: page.host.colourEditing === acct.name
      readonly property bool renaming: page.host.renaming === acct.name
      readonly property bool confirming: page.host.forgetPending === acct.name
      readonly property color tint: page.host.accountColour(acct)
      readonly property var wins: page.host.limitWindows(acct)

      width: parent.width
      implicitHeight: visible ? body.implicitHeight + Style.space(20) : 0
      radius: Style.cornerRadius
      color: page.host.alpha(page.host.foreground, inView ? 0.07 : 0.03)
      border.width: 1
      border.color: inView ? page.host.alpha(tint, 0.75) : page.host.alpha(page.host.foreground, 0.12)
      Behavior on border.color { ColorAnimation { duration: page.host.dur(160) } }
      Behavior on color { ColorAnimation { duration: page.host.dur(160) } }

      // A click anywhere on the card puts it in view; the buttons above it take their own clicks.
      MouseArea {
        anchors.fill: parent
        onClicked: page.host.candName = card.acct.name
      }

      Column {
        id: body
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Style.space(10)
        spacing: Style.space(8)

        // Name, plan, and when the figures were read.
        Item {
          width: parent.width
          implicitHeight: Math.max(nameCol.implicitHeight, planChip.implicitHeight)

          Rectangle {
            id: dot
            width: Style.space(14)
            height: width
            radius: width / 2
            color: card.tint
            border.width: card.editing ? 2 : 0
            border.color: page.host.foreground
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: nameCol
            anchors.left: dot.right
            anchors.leftMargin: Style.space(10)
            anchors.right: planChip.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(1)

            Row {
              spacing: Style.space(8)
              visible: !card.renaming
              width: parent.width

              Text {
                textFormat: Text.PlainText
                text: Models.accountLabel(card.acct)
                width: Math.min(implicitWidth, parent.width - activePill.width - parent.spacing)
                elide: Text.ElideRight
                color: page.host.foreground
                font.family: page.host.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }
              Rectangle {
                id: activePill
                visible: card.acct.active
                anchors.verticalCenter: parent.verticalCenter
                width: pillText.implicitWidth + Style.space(12)
                height: pillText.implicitHeight + Style.space(4)
                radius: height / 2
                color: page.host.alpha(card.tint, 0.22)
                Text {
                  id: pillText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "active"
                  color: page.host.foreground
                  font.family: page.host.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }

            // Rename in place: Enter saves, Esc leaves it as it was.
            Loader {
              active: card.renaming
              visible: active
              width: parent.width
              sourceComponent: Rectangle {
                height: Style.space(28)
                radius: Style.space(6)
                color: page.host.alpha(page.host.foreground, 0.08)
                border.width: 1
                border.color: page.host.alpha(card.tint, 0.8)

                TextInput {
                  id: nameInput
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  verticalAlignment: TextInput.AlignVCenter
                  maximumLength: 32
                  clip: true
                  text: Models.accountLabel(card.acct)
                  color: page.host.foreground
                  selectionColor: page.host.alpha(card.tint, 0.5)
                  selectedTextColor: page.host.foreground
                  font.family: page.host.fontFamily
                  font.pixelSize: Style.font.body
                  Accessible.name: "New name for " + card.acct.name
                  Component.onCompleted: { forceActiveFocus(); selectAll() }
                  onAccepted: page.host.renameAccount(card.acct.name, text.trim() === card.acct.name ? "" : text)
                  Keys.onEscapePressed: function(event) {
                    event.accepted = true
                    page.host.renaming = ""
                    Qt.callLater(function() { page.host.refocusKeys() })
                  }
                }
              }
            }

            Text {
              width: parent.width
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: (Models.accountLabel(card.acct) !== card.acct.name ? card.acct.name + " · " : "")
                + Models.ageLine(card.acct)
              color: page.host.dim
              font.family: page.host.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Rectangle {
            id: planChip
            visible: page.host.accountPlan(card.acct) !== ""
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: planText.implicitWidth + Style.space(14)
            height: planText.implicitHeight + Style.space(6)
            radius: height / 2
            color: "transparent"
            border.width: 1
            border.color: page.host.alpha(page.host.foreground, 0.28)
            Text {
              id: planText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: page.host.accountPlan(card.acct)
              color: page.host.foreground
              font.family: page.host.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // Limits at a glance: every window the plan has, fullest in red.
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: card.wins.length > 0

          Repeater {
            model: card.wins.slice(0, 4)
            LimitRow { required property var modelData; win: modelData; tint: card.tint }
          }
        }

        Text {
          visible: card.wins.length === 0
          width: parent.width
          textFormat: Text.PlainText
          text: "No limits read yet. Press r to sync."
          color: page.host.dim
          font.family: page.host.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Colours nobody else uses, plus this account's own.
        Flow {
          visible: card.editing
          width: parent.width
          spacing: Style.space(10)

          Repeater {
            model: page.host.coloursFor(card.acct)

            Rectangle {
              required property var modelData
              width: Style.space(16)
              height: width
              radius: width / 2
              color: modelData
              border.width: card.tint === modelData ? 2 : 0
              border.color: page.host.foreground

              MouseArea {
                anchors.fill: parent
                anchors.margins: -Style.space(5)
                cursorShape: Qt.PointingHandCursor
                Accessible.role: Accessible.Button
                Accessible.name: "Colour " + parent.modelData
                onClicked: {
                  page.host.recolourAccount(card.acct.name, parent.modelData)
                  page.host.colourEditing = ""
                }
              }
            }
          }
        }

        // What you can do to it.
        Flow {
          width: parent.width
          spacing: Style.space(6)

          Act {
            visible: page.host.canSwitchAccounts && !card.acct.active
            text: "Use"
            selected: true
            Accessible.name: "Use " + Models.accountLabel(card.acct)
            onClicked: page.host.useAccount(card.acct.name)
          }
          Act {
            text: "Rename"
            Accessible.name: "Rename " + card.acct.name
            onClicked: { page.host.candName = card.acct.name; page.host.renaming = card.renaming ? "" : card.acct.name }
          }
          Act {
            text: "Colour"
            selected: card.editing
            Accessible.name: "Change colour of " + card.acct.name
            onClicked: page.host.colourEditing = card.editing ? "" : card.acct.name
          }
          Act {
            enabled: !card.acct.active
            opacity: card.acct.active ? 0.4 : 1
            text: card.confirming ? "Sure? Forget" : "Forget"
            foreground: card.confirming ? page.host.urgent : page.host.foreground
            Accessible.name: card.acct.active ? "The active account cannot be forgotten" : "Forget " + card.acct.name
            onClicked: page.host.forgetAccount(card.acct.name)
          }
        }
      }
    }
  }

  // ----------------------------------------- the CLI's own, unsaved login ----
  // Also the one login of a provider that keeps only one.
  Rectangle {
    id: loginCard
    visible: !page.host.hasAccounts && !!page.provider
    width: parent.width
    implicitHeight: loginBody.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: page.host.alpha(page.host.foreground, 0.05)
    border.width: 1
    border.color: page.host.alpha(page.host.foreground, 0.18)

    readonly property var wins: page.host.limits

    Column {
      id: loginBody
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      Item {
        width: parent.width
        implicitHeight: Math.max(loginTitle.implicitHeight + loginSub.implicitHeight, loginPlan.implicitHeight)

        Rectangle {
          id: loginDot
          width: Style.space(14)
          height: width
          radius: width / 2
          color: page.unsaved || page.provider && page.provider.signedIn ? page.host.alpha(page.host.foreground, 0.55) : "transparent"
          border.width: 1
          border.color: page.host.alpha(page.host.foreground, 0.55)
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          anchors.left: loginDot.right
          anchors.leftMargin: Style.space(10)
          anchors.right: loginPlan.left
          anchors.rightMargin: Style.space(10)
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(1)

          Text {
            id: loginTitle
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: !page.provider ? "" : page.unsaved ? "Signed in, not saved"
              : page.oneLogin ? (page.provider.signedIn ? "Signed in" : "Not signed in")
              : page.provider.signedIn ? "Signed in, not saved" : "No account yet"
            color: page.host.foreground
            font.family: page.host.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Text {
            id: loginSub
            width: parent.width
            elide: Text.ElideRight
            textFormat: Text.PlainText
            text: page.oneLogin ? "The only login " + page.provider.providerName + " keeps"
              : page.provider && page.provider.signedIn ? "Swapkin has no account for this login yet" : "Add one to start"
            color: page.host.dim
            font.family: page.host.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Rectangle {
          id: loginPlan
          visible: page.planText !== ""
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          width: loginPlanText.implicitWidth + Style.space(14)
          height: loginPlanText.implicitHeight + Style.space(6)
          radius: height / 2
          color: "transparent"
          border.width: 1
          border.color: page.host.alpha(page.host.foreground, 0.28)
          Text {
            id: loginPlanText
            anchors.centerIn: parent
            textFormat: Text.PlainText
            text: page.planText
            color: page.host.foreground
            font.family: page.host.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      Column {
        width: parent.width
        spacing: Style.space(4)
        visible: loginCard.wins.length > 0

        Repeater {
          model: loginCard.wins.slice(0, 4)
          LimitRow { required property var modelData; win: modelData; tint: page.host.foreground }
        }
      }

      Text {
        visible: loginCard.wins.length === 0 && !!page.provider && page.provider.signedIn
        width: parent.width
        textFormat: Text.PlainText
        text: "No limits read yet. Press r to sync."
        color: page.host.dim
        font.family: page.host.fontFamily
        font.pixelSize: Style.font.caption
      }

      Act {
        visible: page.unsaved && !page.oneLogin
        text: "Save this login  (v)"
        selected: true
        Accessible.name: "Save the current " + (page.provider ? page.provider.providerName : "") + " login as an account"
        onClicked: page.host.saveCurrentLogin()
      }
    }
  }

  Text {
    visible: page.oneLogin
    width: parent.width
    wrapMode: Text.WordWrap
    textFormat: Text.PlainText
    text: "One login: sign in again with " + (page.provider ? page.provider.providerId : "the tool") + " to change it."
    color: page.host.foreground
    font.family: page.host.fontFamily
    font.pixelSize: Style.font.bodySmall
  }

  Act {
    visible: page.host.canSwitchAccounts && !page.unsaved
    width: parent.width
    text: "+ add account"
    onClicked: page.host.addAccount()
  }

  // Name first, then the terminal: Enter confirms, Esc cancels.
  Loader {
    active: page.host.addingAccount && page.host.canSwitchAccounts
    visible: active
    width: parent.width
    sourceComponent: Column {
      spacing: Style.space(4)
      Rectangle {
        width: parent.width
        height: Style.space(28)
        radius: Style.space(6)
        color: page.host.alpha(page.host.foreground, 0.08)
        border.width: 1
        border.color: page.host.alpha(page.host.foreground, 0.5)

        TextInput {
          id: addInput
          anchors.fill: parent
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          verticalAlignment: TextInput.AlignVCenter
          maximumLength: 32
          clip: true
          text: page.host.freeAccountName()
          color: page.host.foreground
          selectionColor: page.host.alpha(page.host.foreground, 0.4)
          selectedTextColor: page.host.foreground
          font.family: page.host.fontFamily
          font.pixelSize: Style.font.body
          Accessible.name: "Name for the new account"
          Component.onCompleted: { forceActiveFocus(); selectAll() }
          onAccepted: page.host.addAccountNamed(text.trim())
          Keys.onEscapePressed: function(event) {
            event.accepted = true
            page.host.addingAccount = false
            Qt.callLater(function() { page.host.refocusKeys() })
          }
        }
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: page.host.nameProblem(addInput.text.trim()) || "Enter to sign in, Esc to cancel."
        color: page.host.dim
        font.family: page.host.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }

  Text {
    visible: page.host.canSwitchAccounts && !!page.provider && page.provider.addHint !== ""
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    text: page.provider ? page.provider.addHint : ""
    color: page.host.dim
    font.family: page.host.fontFamily
    font.pixelSize: Style.font.caption
  }

  // --------------------------------------------------------- provider info ----
  PanelSeparator { foreground: page.host.foreground }

  PanelSectionHeader {
    width: parent.width
    text: "PROVIDER · " + (page.provider ? page.provider.providerName.toUpperCase() : "")
    foreground: page.host.foreground
    fontFamily: page.host.fontFamily
  }

  Rectangle {
    width: parent.width
    implicitHeight: info.implicitHeight + Style.space(20)
    radius: Style.cornerRadius
    color: page.host.alpha(page.host.foreground, 0.03)
    border.width: 1
    border.color: page.host.alpha(page.host.foreground, 0.12)

    Column {
      id: info
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.margins: Style.space(10)
      spacing: Style.space(8)

      Repeater {
        model: !page.provider ? [] : [
          { k: "Login lives in", v: page.provider.store },
          { k: "A switch reaches", v: page.provider.modeLabel },
          { k: "Open sessions", v: page.provider.modeWords },
          { k: "Why", v: page.provider.how }
        ].filter(function(r) { return String(r.v || "") !== "" })

        Row {
          required property var modelData
          width: info.width
          spacing: Style.space(10)

          Text {
            width: Style.space(104)
            textFormat: Text.PlainText
            text: parent.modelData.k
            color: page.host.dim
            font.family: page.host.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            width: parent.width - Style.space(104) - parent.spacing
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            text: parent.modelData.v
            color: page.host.foreground
            font.family: page.host.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }
    }
  }

  // ------------------------------------------------- auto-switch (Claude) ----
  PanelSeparator { visible: page.host.canAutoSwitch; foreground: page.host.foreground }

  PanelSectionHeader {
    visible: page.host.canAutoSwitch
    width: parent.width
    text: "AUTO-SWITCH · CLAUDE ONLY"
    foreground: page.host.foreground
    fontFamily: page.host.fontFamily
  }

  // One labelled row of choices or a stepper.
  component Setting: Item {
    id: line
    property string label: ""
    property real fade: 1
    default property alias content: slot.data
    visible: page.host.canAutoSwitch
    width: parent.width
    implicitHeight: Math.max(lineLabel.implicitHeight, slot.implicitHeight)
    opacity: fade
    Text {
      id: lineLabel
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: line.label
      color: page.host.dim
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

  Setting {
    label: "Switch automatically"
    Repeater {
      model: ["On", "Off"]
      Act {
        required property var modelData
        required property int index
        text: modelData
        selected: (index === 0) === page.host.autoOn
        hasCursor: page.host.autoCursor === index
        onClicked: page.host.autoActivate(index)
      }
    }
  }

  Setting {
    label: "Switch when left"
    fade: page.host.autoOn ? 1 : 0.45
    Act { text: "−"; hasCursor: page.host.autoCursor === 2; onClicked: page.host.autoActivate(2) }
    Text {
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(44)
      horizontalAlignment: Text.AlignHCenter
      textFormat: Text.PlainText
      text: page.host.autoLeft + "%"
      color: page.host.foreground
      font.family: page.host.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
    Act { text: "+"; hasCursor: page.host.autoCursor === 3; onClicked: page.host.autoActivate(3) }
  }

  Setting {
    label: "Switch back when recovered"
    fade: page.host.autoOn ? 1 : 0.45
    Repeater {
      model: ["On", "Off"]
      Act {
        required property var modelData
        required property int index
        text: modelData
        selected: (index === 0) === page.host.autoReturn
        hasCursor: page.host.autoCursor === 4 + index
        onClicked: page.host.autoActivate(4 + index)
      }
    }
  }

  Text {
    visible: page.host.canAutoSwitch
    textFormat: Text.PlainText
    width: parent.width
    wrapMode: Text.WordWrap
    text: "Switches when an account has " + page.host.autoLeft + "% left on any limit. It applies at once, like pressing a: open sessions follow on their next message. Press s to use the keys here."
    color: page.host.dim
    font.family: page.host.fontFamily
    font.pixelSize: Style.font.caption
  }
}
