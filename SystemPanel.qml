import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Shapes
import qs.Ui
import qs.Commons
import "Model.js" as Model

// First-class Omarchy system popup panel displaying visual telemetry for CPU,
// GPU, Memory, and live CPU load history, with an interactive settings drawer.
KeyboardPanel {
  id: root

  required property QtObject hw
  property bool fahrenheit: false
  property int warnPercent: 70
  property int criticalPercent: 90
  property int warnTempC: 75
  property int criticalTempC: 90

  property string mode: "icons"
  property bool showGpu: true
  property bool showCpu: true
  property bool showCpuTemp: true
  property bool showGpuTemp: false
  property bool showRam: true
  property bool showTopProcs: true
  property bool showClocks: false
  property bool showGauges: false
  property string ramFormat: "used/total"
  property string tempFormat: "degree-unit"
  property bool settingsOpen: false

  function persistSetting(key, value) {
    if (root.owner && typeof root.owner.persistSetting === "function") {
      root.owner.persistSetting(key, value)
    }
  }

  readonly property color baseColor: root.bar ? root.bar.foreground : Color.foreground
  readonly property color hotColor: root.bar ? root.bar.urgent : Color.urgent
  // Captions, labels and idle readings.
  readonly property color mutedColor: Qt.darker(baseColor, 1.4)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  // One severity and one warmed colour per load figure, so the dial, the
  // readouts and the meter bar of a metric always agree.
  readonly property real cpuSeverity: Model.severity(hw.cpuPercent, warnPercent, criticalPercent)
  readonly property real memSeverity: Model.severity(hw.memPercent, warnPercent, criticalPercent)
  readonly property real vramSeverity: Model.severity(hw.gpuVramPercent, warnPercent, criticalPercent)
  readonly property color cpuColor: Model.mixColor(baseColor, hotColor, cpuSeverity)
  readonly property color memColor: Model.mixColor(baseColor, hotColor, memSeverity)
  readonly property color vramColor: Model.mixColor(baseColor, hotColor, vramSeverity)

  // parseProbe's stand-in ("CPU", 0 cores, 0 threads) fills cpuInfo until
  // hw-probe answers, and for good if it never does; it is not data.
  readonly property bool cpuKnown: !!hw.cpuInfo && hw.cpuInfo.threads > 0

  // GPU load, or VRAM occupancy on a card that reports no load counter.
  readonly property real gpuMeter: hw.gpuPercent >= 0 ? hw.gpuPercent : hw.gpuVramPercent

  // "used / total GiB (pct%)" for the RAM and VRAM meter headers.
  function usageText(usedGib, totalGib, percent) {
    return Model.formatGib(usedGib) + " / " + Model.formatGib(totalGib) + " GiB (" + Model.formatPercent(percent) + ")"
  }

  // The bar's rule: muted up to warnTempC (and for a missing reading), then
  // the base colour warming to urgent at criticalTempC.
  function tempColor(tempC) {
    var t = Model.severity(tempC, warnTempC, criticalTempC)
    return t > 0 ? Model.mixColor(baseColor, hotColor, t) : mutedColor
  }

  // Ring buffer for the last 60 seconds of CPU samples.
  // Sampled while the panel is open; cleared when closed to avoid background overhead.
  property var cpuHistory: []

  readonly property var sparklinePoints: {
    var list = []
    var n = cpuHistory ? cpuHistory.length : 0
    if (n < 2) return list
    var w = sparklineBox.width - Style.space(8)
    var h = sparklineBox.height - Style.space(8)
    for (var i = 0; i < n; i++) {
      var px = Style.space(4) + (i / (n - 1)) * w
      var v = Math.max(0, Math.min(100, Number(cpuHistory[i]) || 0))
      var py = Style.space(4) + h - (v / 100) * h
      list.push(Qt.point(px, py))
    }
    return list
  }

  readonly property point sparklineFirst: sparklinePoints.length > 0 ? sparklinePoints[0] : Qt.point(0, sparklineBox.height)

  readonly property var sparklineFillPoints: {
    if (sparklinePoints.length < 2) return []
    var list = sparklinePoints.slice()
    var w = sparklineBox.width - Style.space(4)
    var h = sparklineBox.height - Style.space(4)
    list.push(Qt.point(w, h))
    list.push(Qt.point(Style.space(4), h))
    return list
  }

  onOpenChanged: {
    if (open) {
      hw.sample()
      hw.procPanelOpen = true
      hw.refreshProcTop()
      var initial = hw.cpuPercent >= 0 ? hw.cpuPercent : 0
      root.cpuHistory = [initial, initial]
    } else {
      root.cpuHistory = []
      root.settingsOpen = false
      hw.procPanelOpen = false
    }
  }

  focusTarget: keyCatcher
  contentWidth: fittedContentWidth(Style.space(500))
  contentHeight: fittedContentHeight(panelColumn.implicitHeight + Style.space(16), Style.space(1100))

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onCloseRequested: root.close()
    // root.owner is the Panel widget root (Widget.qml sets owner: root),
    // which is what Bar.switchPanelFrom expects.
    onTabRequested: function(direction) {
      if (root.owner && typeof root.owner.switchPanel === "function") {
        root.owner.switchPanel(direction)
      }
    }
    onTextKey: function(t) {
      if (t === "r" || t === "R") {
        hw.sample()
      } else if (t === "c" || t === "C") {
        root.persistSetting("fahrenheit", false)
      } else if (t === "f" || t === "F") {
        root.persistSetting("fahrenheit", true)
      } else if (t === "s" || t === "S") {
        root.settingsOpen = !root.settingsOpen
      }
    }

    Timer {
      id: historyTimer
      interval: 1000
      repeat: true
      running: root.open
      onTriggered: {
        hw.sample()
        hw.refreshProcTop()
        var cur = hw.cpuPercent >= 0 ? hw.cpuPercent : 0
        var arr = root.cpuHistory.slice()
        arr.push(cur)
        if (arr.length > 60) arr.shift()
        root.cpuHistory = arr
      }
    }

    Component.onDestruction: historyTimer.stop()

    Controls.ScrollView {
      id: scrollArea
      anchors.fill: parent
      clip: true
      Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
      Controls.ScrollBar.vertical.policy: panelColumn.implicitHeight > scrollArea.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff

      Binding {
        target: scrollArea.contentItem
        property: "interactive"
        value: panelColumn.implicitHeight > scrollArea.height
      }

      Column {
        id: panelColumn
        width: scrollArea.availableWidth
        spacing: Style.space(12)

        // 1. Header with Processor Name and Settings Gear
        Item {
          width: parent.width
          implicitHeight: Math.max(headerLeft.implicitHeight, settingsButton.implicitHeight)

          Row {
            id: headerLeft
            anchors.left: parent.left
            anchors.right: settingsButton.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)

            Text {
              textFormat: Text.PlainText
              text: ""
              color: Color.accent
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - Style.font.display - Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                textFormat: Text.PlainText
                text: "Hardware"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                width: parent.width
                wrapMode: Text.Wrap
                text: root.cpuKnown ? hw.cpuInfo.model : "System Telemetry"
                color: root.mutedColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }
          }

          // Gear Icon for In-Panel Settings
          ModeChip {
            id: settingsButton
            text: "\uF013"
            selected: root.settingsOpen
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.settingsOpen = !root.settingsOpen
          }
        }

        // Animated Settings Drawer
        Rectangle {
          width: parent.width
          visible: root.settingsOpen || height > 0
          height: root.settingsOpen ? settingsCol.implicitHeight + Style.space(20) : 0
          clip: true
          color: Qt.alpha(root.baseColor, 0.05)
          border.color: Qt.alpha(root.baseColor, 0.14)
          border.width: 1
          radius: Style.cornerRadius

          Behavior on height {
            NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
          }
          opacity: root.settingsOpen ? 1 : 0
          Behavior on opacity {
            NumberAnimation { duration: 180; easing.type: Easing.OutCubic }
          }

          Column {
            id: settingsCol
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: Style.space(10)
            spacing: Style.space(10)

            // Settings Header
            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: "Top Bar Display Settings"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            ChoiceRow {
              label: "Mode"
              key: "mode"
              current: root.mode
              options: [
                { value: "icons", label: "Icons" },
                { value: "compact", label: "Compact" },
                { value: "full", label: "Full" },
                { value: "labels", label: "Labels" }
              ]
            }

            // Each chip toggles one of the bar's shown-item settings.
            SettingRow {
              label: "Show"

              Repeater {
                model: [
                  { key: "showGpu", label: "󰾲 GPU" },
                  { key: "showCpu", label: " CPU" },
                  { key: "showCpuTemp", label: " CPU Temp" },
                  { key: "showGpuTemp", label: "󰔏 GPU Temp" },
                  { key: "showRam", label: " RAM" },
                  { key: "showClocks", label: "󰓅 Clocks" },
                  { key: "showGauges", label: "󰁹 Gauges" }
                ]
                delegate: ModeChip {
                  required property var modelData
                  text: modelData.label
                  selected: root[modelData.key]
                  onClicked: root.persistSetting(modelData.key, !root[modelData.key])
                }
              }
            }

            ChoiceRow {
              label: "RAM"
              key: "ramFormat"
              // "available" is an alias of "free": both show MemAvailable.
              current: root.ramFormat === "available" ? "free" : root.ramFormat
              options: [
                { value: "used/total", label: "Used/Total" },
                { value: "used", label: "Used" },
                { value: "percent", label: "Percent" },
                { value: "free", label: "Free" }
              ]
            }

            ChoiceRow {
              label: "Unit"
              key: "fahrenheit"
              current: root.fahrenheit
              options: [
                { value: false, label: "°C  Celsius" },
                { value: true, label: "°F  Fahrenheit" }
              ]
            }

            ChoiceRow {
              label: "Temp"
              key: "tempFormat"
              current: root.tempFormat
              // Each label previews its format in the current unit.
              options: {
                var unit = root.fahrenheit ? "F" : "C"
                return [
                  { value: "degree-unit", label: "45°" + unit },
                  { value: "degree", label: "45°" },
                  { value: "unit", label: "45" + unit },
                  { value: "unit-lower", label: "45" + unit.toLowerCase() },
                  { value: "bare", label: "45" }
                ]
              }
            }
          }
        }

        // 2. Primary Telemetry Dials (CPU, RAM, GPU)
        Row {
          width: parent.width
          spacing: Style.space(8)

          PanelDial {
            title: "CPU"
            valueText: Model.formatPercent(hw.cpuPercent)
            subText: hw.cpuTempC > 0 ? Model.formatTemp(hw.cpuTempC, root.fahrenheit) : ""
            subTextColor: root.tempColor(hw.cpuTempC)
            ratio: hw.cpuPercent >= 0 ? hw.cpuPercent / 100 : 0
            severity: root.cpuSeverity
          }

          PanelDial {
            title: "RAM"
            valueText: Model.formatPercent(hw.memPercent)
            subText: hw.memory ? Model.formatKib(hw.memory.usedKib) + "/" + Model.formatKib(hw.memory.totalKib) + "G" : ""
            ratio: hw.memPercent >= 0 ? hw.memPercent / 100 : 0
            severity: root.memSeverity
          }

          PanelDial {
            // Says VRAM when the card has no load counter and the figure is VRAM use.
            title: hw.hasGpu && hw.gpuPercent < 0 && hw.gpuVramPercent >= 0 ? "VRAM" : "GPU"
            valueText: hw.hasGpu ? Model.formatPercent(root.gpuMeter) : "N/A"
            subText: hw.hasGpu && hw.gpuTempC > 0 ? Model.formatTemp(hw.gpuTempC, root.fahrenheit) : (hw.hasGpu && hw.gpuWatts >= 0 ? Model.formatWatts(hw.gpuWatts) : "")
            subTextColor: root.tempColor(hw.gpuTempC)
            ratio: hw.hasGpu && root.gpuMeter >= 0 ? root.gpuMeter / 100 : 0
            severity: hw.hasGpu ? Model.severity(root.gpuMeter, root.warnPercent, root.criticalPercent) : 0
          }
        }

        // 3. CPU Load History Sparkline (60s)
        SectionCard {
          spacing: Style.space(8)

          InfoPair {
            label: "CPU Load History (60s)"
            labelColor: root.baseColor
            value: hw.cpuPercent >= 0 ? Model.formatPercent(hw.cpuPercent) + " current" : "–"
            valueColor: root.cpuColor
            valueBold: true
            fontSize: Style.font.caption
          }

          Item {
            id: sparklineBox
            width: parent.width
            height: Style.space(55)

            // Background grid lines
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              y: parent.height * 0.25
              height: 1
              color: Qt.alpha(root.baseColor, 0.08)
            }
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              y: parent.height * 0.50
              height: 1
              color: Qt.alpha(root.baseColor, 0.08)
            }
            Rectangle {
              anchors.left: parent.left
              anchors.right: parent.right
              y: parent.height * 0.75
              height: 1
              color: Qt.alpha(root.baseColor, 0.08)
            }

            // Sparkline fill area
            Shape {
              anchors.fill: parent
              visible: root.sparklinePoints.length >= 2
              layer.enabled: true
              layer.samples: 4

              ShapePath {
                strokeWidth: 0
                strokeColor: "transparent"
                fillColor: Qt.alpha(Color.accent, 0.18)

                startX: root.sparklineFirst.x
                startY: root.sparklineFirst.y

                PathPolyline {
                  path: root.sparklineFillPoints
                }
              }
            }

            // Sparkline stroke line
            Shape {
              anchors.fill: parent
              visible: root.sparklinePoints.length >= 2
              layer.enabled: true
              layer.samples: 4

              ShapePath {
                strokeWidth: Style.space(2)
                strokeColor: Color.accent
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                joinStyle: ShapePath.RoundJoin

                startX: root.sparklineFirst.x
                startY: root.sparklineFirst.y

                PathPolyline {
                  path: root.sparklinePoints
                }
              }
            }
          }
        }

        // 4. Processor Topology & Load Average
        SectionCard {
          icon: ""
          title: "Processor"

          Row {
            width: parent.width
            spacing: Style.space(16)

            HalfColumn {
              InfoPair {
                label: "Cores"
                value: root.cpuKnown ? hw.cpuInfo.cores + "C / " + hw.cpuInfo.threads + "T" : "–"
              }
              InfoPair {
                label: "Avg Clock"
                value: Model.formatGhz(hw.cpuMhz)
              }
            }

            HalfColumn {
              InfoPair {
                label: "Temperature"
                value: Model.formatTemp(hw.cpuTempC, root.fahrenheit)
                valueColor: root.tempColor(hw.cpuTempC)
              }
              InfoPair {
                label: "Load"
                value: Model.formatPercent(hw.cpuPercent)
                valueColor: root.cpuColor
              }
            }
          }

          // Load average 1m, 5m, 15m
          Column {
            width: parent.width
            spacing: Style.space(6)

            Text {
              textFormat: Text.PlainText
              text: "Load Average (1m · 5m · 15m)"
              color: root.mutedColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              LoadMeter { period: "1 min"; value: hw.load ? hw.load.one : 0 }
              LoadMeter { period: "5 min"; value: hw.load ? hw.load.five : 0 }
              LoadMeter { period: "15 min"; value: hw.load ? hw.load.fifteen : 0 }
            }
          }
        }

        // 5. Memory & Swap Breakdown
        SectionCard {
          icon: ""
          title: "Memory & Swap"

          // RAM horizontal split progress
          Column {
            width: parent.width
            spacing: Style.space(4)

            InfoPair {
              label: "RAM Usage"
              value: hw.memory ? root.usageText(Model.gibFromKib(hw.memory.usedKib), Model.gibFromKib(hw.memory.totalKib), hw.memPercent) : "–"
              valueColor: root.memColor
              valueBold: true
              fontSize: Style.font.caption
            }

            MeterBar {
              ratio: hw.memPercent >= 0 ? hw.memPercent / 100 : -1
              fillColor: root.memColor
            }
          }

          // Details
          Row {
            width: parent.width
            spacing: Style.space(16)

            HalfColumn {
              InfoPair {
                label: "Available"
                value: hw.memory ? Model.formatKib(hw.memory.availableKib) + " GiB" : "–"
              }
              InfoPair {
                label: "Page Cache"
                value: hw.memory ? Model.formatKib(hw.memory.cachedKib) + " GiB" : "–"
              }
            }

            HalfColumn {
              InfoPair {
                label: "Swap Used"
                value: !hw.memory ? "–" : hw.memory.swapTotalKib > 0 ? Model.formatKib(hw.memory.swapUsedKib) + " GiB" : "None"
              }
              InfoPair {
                label: "Swap Total"
                value: !hw.memory ? "–" : hw.memory.swapTotalKib > 0 ? Model.formatKib(hw.memory.swapTotalKib) + " GiB" : "None"
              }
            }
          }
        }

        // 5b. Top processes by RAM or CPU (sampled only while the panel is open)
        SectionCard {
          icon: ""
          title: "Top processes"
          spacing: Style.space(8)
          visible: root.showTopProcs
          opacity: hw.procTopFailed && hw.topProcs.length === 0 ? 0.7 : 1

          headerItems: [
            ModeChip {
              text: "RAM"
              selected: hw.topProcSort === "ram"
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.persistSetting("topProcSort", "ram")
            },
            ModeChip {
              text: "CPU"
              selected: hw.topProcSort === "cpu"
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.persistSetting("topProcSort", "cpu")
            },
            ModeChip {
              text: "Group"
              selected: hw.topProcGroup
              anchors.verticalCenter: parent.verticalCenter
              onClicked: root.persistSetting("topProcGroup", !hw.topProcGroup)
            }
          ]

          headerTrailing: Text {
            id: procTopStamp
            textFormat: Text.PlainText
            text: {
              var h = hw
              var metric = h.topProcSort === "cpu" ? "by CPU" : "by RAM"
              // Grouping found no systemd app identity and fell back to
              // process names: say so, the Group chip alone can't.
              if (h.topProcGroup && h.procGroupedBy === "comm") metric += " \u00b7 by name"
              if (h.procTopTime === "") return metric
              return metric + " \u00b7 " + h.procTopTime
            }
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: hw.topProcs.length > 0

            Repeater {
              model: hw.topProcs
              delegate: Column {
                required property var modelData
                required property int index

                width: parent.width
                spacing: Style.space(3)

                readonly property int total: hw.topProcs.length
                readonly property bool sortCpu: hw.topProcSort === "cpu"
                readonly property real topRss: total > 0 ? Math.max(1, hw.topProcs[0].rssKib) : 1
                readonly property real topCpu: total > 0 ? Math.max(0, hw.topProcs[0].cpu) : 0
                readonly property bool useCpuBars: sortCpu && topCpu > 0
                readonly property real metricVal: sortCpu ? modelData.cpu : modelData.memPct
                readonly property real shareD: useCpuBars ? modelData.cpu / Math.max(1, topCpu) : modelData.rssKib / topRss
                readonly property real rankSev: total > 1 ? (1 - index / (total - 1)) : 1
                readonly property real combinedSev: Math.max(0.35 + 0.65 * rankSev,
                  Model.severity(metricVal, root.warnPercent, root.criticalPercent))
                // Rows ramp from the base colour toward the theme accent, never
                // toward urgent: a ranking should read clearly without alarming.
                readonly property color sevColor: Model.mixColor(root.baseColor, Color.accent, combinedSev)

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    id: procRank
                    textFormat: Text.PlainText
                    text: (index + 1) + "."
                    color: sevColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    textFormat: Text.PlainText
                    width: Math.max(40, parent.width - procRank.implicitWidth - procFigs.implicitWidth - parent.spacing * 2)
                    elide: Text.ElideRight
                    text: modelData.count > 1 ? (modelData.name + "  · " + modelData.count + " processes") : (modelData.name + "  (" + modelData.pid + ")")
                    color: root.baseColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: procFigs
                    textFormat: Text.PlainText
                    anchors.verticalCenter: parent.verticalCenter
                    text: Model.formatMemKib(modelData.rssKib) + " · CPU " + Model.formatPercent(modelData.cpu)
                    color: sevColor
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }
                }

                MeterBar {
                  height: Style.space(5)
                  ratio: shareD
                  fillColor: sevColor
                }
              }
            }
          }

          Text {
            textFormat: Text.PlainText
            visible: hw.topProcs.length === 0
            width: parent.width
            wrapMode: Text.Wrap
            text: hw.procTopFailed ? "Process data unavailable (python3 missing or read failed)." : "Collecting process data…"
            color: root.mutedColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        // 6. Graphics Telemetry Section (if GPU present)
        SectionCard {
          icon: "󰾲"
          title: hw.gpuInfo && hw.gpuInfo.name ? hw.gpuInfo.name : "Graphics Adapter"
          visible: hw.hasGpu

          // VRAM Meter
          Column {
            width: parent.width
            spacing: Style.space(4)
            visible: hw.gpuVramTotalBytes > 0

            InfoPair {
              label: "VRAM"
              value: hw.gpuVramTotalBytes > 0 ? root.usageText(Model.gibFromBytes(hw.gpuVramUsedBytes), Model.gibFromBytes(hw.gpuVramTotalBytes), hw.gpuVramPercent) : "–"
              valueColor: root.vramColor
              valueBold: true
              fontSize: Style.font.caption
            }

            MeterBar {
              ratio: hw.gpuVramPercent >= 0 ? hw.gpuVramPercent / 100 : -1
              fillColor: root.vramColor
            }
          }

          Row {
            width: parent.width
            spacing: Style.space(16)

            HalfColumn {
              InfoPair { label: "Load"; value: Model.formatPercent(hw.gpuPercent) }
              InfoPair {
                label: "Temperature"
                value: Model.formatTemp(hw.gpuTempC, root.fahrenheit)
                valueColor: root.tempColor(hw.gpuTempC)
              }
              InfoPair { label: "Power"; value: Model.formatWatts(hw.gpuWatts) }
            }

            HalfColumn {
              InfoPair { label: "Clock"; value: Model.formatGhz(hw.gpuMhz) }
              InfoPair { label: "Fan"; value: Model.formatRpm(hw.gpuRpm) }
              InfoPair { label: "Driver"; value: hw.gpuInfo && hw.gpuInfo.kind ? String(hw.gpuInfo.kind) : "–" }
            }
          }
        }

        // Bottom breathing room spacer to guarantee zero clipping
        Item {
          width: parent.width
          height: Style.space(12)
        }
      }
    }
  }

  // A drawer or header chip. The shell's own Button draws it, so the selected
  // state uses the theme's control tokens and stays legible on every theme;
  // caption text and tight padding keep the drawer compact.
  component ModeChip: Button {
    bordered: true
    foreground: root.baseColor
    fontFamily: root.fontFamily
    fontSize: Style.font.caption
    horizontalPadding: Style.space(6)
    verticalPadding: Style.space(4)
  }

  // A labelled row of drawer chips that wraps when the panel is narrow.
  component SettingRow: Row {
    id: settingRow
    property string label: ""
    default property alias chips: chipFlow.data

    width: parent.width
    spacing: Style.space(8)

    Text {
      id: settingLabel
      width: Style.space(48)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: settingRow.label
      color: root.mutedColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }

    Flow {
      id: chipFlow
      width: parent.width - settingLabel.width - parent.spacing
      spacing: Style.space(4)
    }
  }

  // A setting that takes one of `options` ([{ value, label }]): the chip whose
  // value equals `current` is selected, and picking a chip persists its value.
  component ChoiceRow: SettingRow {
    id: choiceRow
    property string key: ""
    property var options: []
    property var current

    Repeater {
      model: choiceRow.options
      delegate: ModeChip {
        required property var modelData
        text: modelData.label
        selected: choiceRow.current === modelData.value
        onClicked: root.persistSetting(choiceRow.key, modelData.value)
      }
    }
  }

  // A panel section: a tinted card with an icon + title header over a column
  // of content. A card without a title has no header row.
  component SectionCard: Rectangle {
    id: card
    property string icon: ""
    property string title: ""
    // Extra header items: placed after the title, or against the right edge.
    property alias headerItems: titleRow.data
    property alias headerTrailing: trailingRow.data
    property alias spacing: body.spacing
    default property alias content: body.data

    width: parent.width
    implicitHeight: body.implicitHeight + Style.space(24)
    color: Qt.alpha(root.baseColor, 0.04)
    border.color: Qt.alpha(root.baseColor, 0.10)
    border.width: 1
    radius: Style.cornerRadius

    Column {
      id: body
      anchors.fill: parent
      anchors.margins: Style.space(12)
      spacing: Style.space(10)

      Item {
        visible: card.title !== ""
        width: parent.width
        implicitHeight: Math.max(titleRow.implicitHeight, trailingRow.implicitHeight)

        Row {
          id: titleRow
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: card.icon
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            textFormat: Text.PlainText
            text: card.title
            color: root.baseColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        Row {
          id: trailingRow
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(6)
        }
      }
    }
  }

  // A label on the left and its value against the right edge. Defaults suit
  // a detail row; meter headers use the caption size with a bold value.
  component InfoPair: Item {
    id: infoPairRoot
    property string label: ""
    property string value: ""
    property color labelColor: root.mutedColor
    property color valueColor: root.baseColor
    property int fontSize: Style.font.bodySmall
    property bool labelBold: true
    property bool valueBold: false

    width: parent.width
    implicitHeight: Math.max(labelText.implicitHeight, valueText.implicitHeight)

    Text {
      id: labelText
      textFormat: Text.PlainText
      text: infoPairRoot.label
      color: infoPairRoot.labelColor
      font.family: root.fontFamily
      font.pixelSize: infoPairRoot.fontSize
      font.bold: infoPairRoot.labelBold
    }

    Text {
      id: valueText
      anchors.right: parent.right
      textFormat: Text.PlainText
      text: infoPairRoot.value
      color: infoPairRoot.valueColor
      font.family: root.fontFamily
      font.pixelSize: infoPairRoot.fontSize
      font.bold: infoPairRoot.valueBold
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }

  // One column of a two-column block of InfoPairs.
  component HalfColumn: Column {
    width: (parent.width - parent.spacing) / 2
    spacing: Style.spacing.labelGap
  }

  // A track filled to `ratio` (0..1). A negative ratio means there is no
  // reading and leaves the track empty; a reading of zero still shows a dot.
  component MeterBar: Rectangle {
    id: meter
    property real ratio: -1
    property color fillColor: root.baseColor

    width: parent.width
    height: Style.space(6)
    radius: height / 2
    color: Qt.alpha(root.baseColor, 0.12)

    Rectangle {
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      radius: parent.radius
      color: meter.fillColor
      width: meter.ratio >= 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * meter.ratio)) : 0
      Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
    }
  }

  // A Dial taking a third of its row, in the panel's colours.
  component PanelDial: Dial {
    width: (parent.width - parent.spacing * 2) / 3
    baseColor: root.baseColor
    hotColor: root.hotColor
    fontFamily: root.fontFamily
  }

  // One load-average figure, a third of its row, measured against the
  // thread count (8 until the probe reports it).
  component LoadMeter: Column {
    id: meterRoot
    property string period: ""
    property real value: 0
    readonly property real ratio: value / (root.cpuKnown ? hw.cpuInfo.threads : 8)

    width: (parent.width - parent.spacing * 2) / 3
    spacing: Style.space(4)

    InfoPair {
      label: meterRoot.period
      labelBold: false
      value: meterRoot.value.toFixed(2)
      valueBold: true
      fontSize: Style.font.caption
    }

    MeterBar {
      height: Style.space(4)
      ratio: meterRoot.ratio
      fillColor: Model.mixColor(root.baseColor, root.hotColor, meterRoot.ratio)
    }
  }
}
