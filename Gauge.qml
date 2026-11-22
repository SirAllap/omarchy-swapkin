import QtQuick
import QtQuick.Shapes
import qs.Commons
import "Models.js" as Models

// A ring gauge: a track and a value arc, two Shape paths with round caps on
// the curve renderer. No Canvas, no shader. `value` is 0..1, or negative for
// no data. The arc eases to a new value only when the value changes; at rest
// nothing runs. Colours come in from the caller, which takes them from the
// Omarchy theme.
Item {
  id: gauge

  property real value: -1
  property real size: 32
  property real thickness: 4
  property color trackColor: "#33ffffff"
  property color valueColor: "white"
  property color alarmColor: "red"
  property bool alarm: false
  // The panel hands over its own motion choice (follow system / reduce / full).
  property bool reduced: Style.reduceMotion
  // 0 = follow `value` at once (the bar has no animation at all).
  property int sweepMs: 0
  // If > 0, sweepMs drops to this once a sweep ends (the open sweep is slower).
  property int settleMs: 0
  // Shown arc, 0..1. A new `value` eases it there; the caller may also set it
  // to 0 with sweepMs at 0 and then back, to replay the sweep.
  property real shown: value >= 0 ? value : 0
  onValueChanged: shown = value >= 0 ? value : 0

  property color arcColor: alarm ? alarmColor : valueColor

  implicitWidth: size
  implicitHeight: size

  Behavior on shown {
    enabled: gauge.sweepMs > 0
    NumberAnimation {
      duration: (gauge.reduced ? 0 : gauge.sweepMs)
      easing.type: Easing.BezierSpline
      easing.bezierCurve: [0.23, 1, 0.32, 1, 1, 1]
      onRunningChanged: if (!running && gauge.settleMs > 0) gauge.sweepMs = gauge.settleMs
    }
  }
  Behavior on arcColor {
    enabled: gauge.sweepMs > 0
    ColorAnimation { duration: (gauge.reduced ? 0 : 250) }
  }

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    antialiasing: true

    ShapePath {
      fillColor: "transparent"
      strokeColor: gauge.trackColor
      strokeWidth: gauge.thickness
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: gauge.width / 2; centerY: gauge.height / 2
        radiusX: (gauge.width - gauge.thickness) / 2; radiusY: radiusX
        startAngle: -90; sweepAngle: 360
      }
    }

    ShapePath {
      fillColor: "transparent"
      strokeColor: gauge.shown > 0 ? gauge.arcColor : "transparent"
      strokeWidth: gauge.thickness
      capStyle: ShapePath.RoundCap
      PathAngleArc {
        centerX: gauge.width / 2; centerY: gauge.height / 2
        radiusX: (gauge.width - gauge.thickness) / 2; radiusY: radiusX
        startAngle: -90; sweepAngle: Math.min(359.9, Models.arcSweep(gauge.shown))
      }
    }
  }
}
