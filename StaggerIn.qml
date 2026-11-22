import QtQuick
import qs.Commons

// Fade-and-rise entry, 40 ms apart, 220 ms each, capped at 8 items. Bind
// `opacity: stagger.p` and `transform: Translate { y: (1 - stagger.p) * 8 }`
// on the item. It plays only when `tick` changes (the panel opening, a new
// provider); at rest nothing runs. Reduced motion: no animation at all.
Item {
  id: stagger
  property int index: 0
  property int tick: 0
  property real p: 1
  property bool reduced: Style.reduceMotion
  visible: false
  width: 0
  height: 0

  onTickChanged: if (stagger.reduced) { anim.stop(); p = 1 } else { p = 0; anim.restart() }

  SequentialAnimation {
    id: anim
    PauseAnimation { duration: (stagger.reduced ? 0 : Math.min(stagger.index, 8) * 40) }
    NumberAnimation { target: stagger; property: "p"; to: 1; duration: stagger.reduced ? 0 : 220; easing.type: Easing.BezierSpline; easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1] }
  }
}
