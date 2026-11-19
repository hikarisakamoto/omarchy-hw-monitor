import QtQuick
import QtQuick.Shapes
import qs.Commons
import "Model.js" as Model

// A 270-degree circular arc dial based on the SpeedTestOverlay pattern.
// Used in the system panel for CPU, GPU, and RAM readouts.
Item {
  id: root

  property string title: ""
  // How much of the arc to fill, 0..1.
  property real ratio: 0
  property string valueText: ""
  property string subText: ""
  // 0..1 from Model.severity: the arc and figure warm from accent toward hot.
  property real severity: 0
  property color baseColor: Color.foreground
  property color accentColor: Color.accent
  property color hotColor: Color.urgent
  property color valueColor: Model.mixColor(accentColor, hotColor, severity)
  // Title and default sub-text tone.
  readonly property color mutedColor: Qt.darker(baseColor, 1.4)
  property color subTextColor: mutedColor
  property color trackColor: Qt.alpha(baseColor, 0.14)
  property real diameter: Style.space(108)
  property real arcWidth: Math.max(3, Style.space(4))
  property string fontFamily: Style.font.family
  // Colour changes fade only while this is set; a hidden dial just updates.
  property bool animated: true

  // A NaN ratio reads as an empty arc rather than poisoning the sweep angles.
  readonly property real fraction: isFinite(ratio) ? Math.max(0, Math.min(1, ratio)) : 0
  readonly property bool arcVisible: fraction > 0.004

  // 0° is 3 o'clock, increasing clockwise
  readonly property real dialStart: 135
  readonly property real dialSweep: 270
  readonly property real arcRadius: Math.max(1, (diameter / 2) - arcWidth)

  width: diameter
  height: diameter
  implicitWidth: diameter
  implicitHeight: diameter

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    // Track: the full scale background arc
    ShapePath {
      strokeWidth: root.arcWidth
      strokeColor: root.trackColor
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: root.width / 2
        centerY: root.height / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: root.dialStart
        sweepAngle: root.dialSweep
      }
    }

    // Under-glow for the active value arc
    ShapePath {
      strokeWidth: root.arcWidth * 2.5
      strokeColor: root.arcVisible ? Qt.alpha(root.valueColor, 0.18) : "transparent"
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: root.width / 2
        centerY: root.height / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: root.dialStart
        sweepAngle: root.dialSweep * root.fraction
      }
    }

    // Value Arc
    ShapePath {
      strokeWidth: root.arcWidth
      strokeColor: root.arcVisible ? root.valueColor : "transparent"
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: root.width / 2
        centerY: root.height / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: root.dialStart
        sweepAngle: root.dialSweep * root.fraction
      }
    }
  }

  Column {
    anchors.centerIn: parent
    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.title.toUpperCase()
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.1
      color: root.mutedColor
    }

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.valueText !== "" ? root.valueText : Math.round(root.fraction * 100) + "%"
      font.family: root.fontFamily
      font.pixelSize: Style.font.title
      font.bold: true
      color: root.valueColor
      Behavior on color { enabled: root.animated; ColorAnimation { duration: Style.duration(240) } }
    }

    Text {
      visible: root.subText !== ""
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.subText
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      color: root.subTextColor
      Behavior on color { enabled: root.animated; ColorAnimation { duration: Style.duration(240) } }
    }
  }
}
