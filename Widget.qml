import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Telemetry readouts for GPU, CPU, Temperatures, and Memory in the Omarchy bar
// with rich per-item data selection, ordering, and formatting controls.
//
// Left click opens the Omarchy system panel popup (or runs clickCommand if set).
// Right click walks the display modes and remembers the choice; middle click resamples.
Panel {
  id: root
  moduleName: "meviusisback.hw-monitor"
  // The host replaces moduleName with the entry id at load, so IPC answers on
  // whatever id the manifest declares. The base handler is off because the
  // IpcHandler below adds methods of its own.
  ipcTarget: moduleName
  manageIpc: false

  readonly property bool vertical: bar ? bar.vertical : false

  function broadcast(method) {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i][method] === "function") items[i][method]()
    }
  }

  // Four states, cycled by right click:
  //   icons    Sleek component glyphs + live figures (Noctalia-style readout, default)
  //   compact  glyphs + gauges
  //   full     glyphs + gauges + temperatures
  //   labels   Waybar-style text readout — GPU 0% · 52°C  CPU 34% · 46°C  RAM 11.2/23G
  readonly property var modes: ["icons", "compact", "full", "labels"]
  readonly property string mode: enumSetting("mode", modes, "icons")

  readonly property string nextMode: modes[(modes.indexOf(mode) + 1) % modes.length]
  readonly property bool labelled: mode === "labels" && !vertical
  readonly property bool showTemps: mode !== "compact" && !vertical
  readonly property bool showValues: (labelled || mode === "icons" || boolSetting("showValues", false)) && !vertical
  readonly property bool showGauges: boolSetting("showGauges", mode !== "icons" && mode !== "labels")
  readonly property bool showClocks: boolSetting("showClocks", false) && !vertical

  readonly property var monitors: {
    var raw = setting("monitors", [])
    if (raw === undefined || raw === null) return []
    if (raw instanceof Array) return raw.map(String)
    var text = String(raw).trim()
    return text === "" ? [] : text.split(/[,\s]+/)
  }

  readonly property string screenName: {
    var window = root.QsWindow ? root.QsWindow.window : null
    return window && window.screen ? String(window.screen.name) : ""
  }

  readonly property bool onThisScreen: monitors.length === 0 || screenName === ""
    || monitors.indexOf(screenName) !== -1

  // -------------------------------------------------------- data selection

  readonly property bool showGpu: boolSetting("showGpu", true)
  readonly property bool showCpu: boolSetting("showCpu", true)
  readonly property bool showCpuTemp: boolSetting("showCpuTemp", true)
  readonly property bool showGpuTemp: boolSetting("showGpuTemp", false)
  readonly property bool showRam: boolSetting("showRam", true)
  readonly property bool showTopProcs: boolSetting("showTopProcs", true)

  readonly property var defaultItemOrder: ["gpu", "cpu", "cpu-temp", "ram"]
  readonly property var itemOrder: {
    var raw = setting("itemsOrder", defaultItemOrder)
    if (raw instanceof Array) return raw.map(function(s) { return String(s).trim().toLowerCase() })
    var text = String(raw || "").trim().toLowerCase()
    return text === "" ? defaultItemOrder : text.split(/[,\s]+/)
  }

  // ------------------------------------------------------------ formatting

  readonly property bool fahrenheit: boolSetting("fahrenheit", false)
  // "free" is MemAvailable, what a new program can get without swapping;
  // "available" is accepted as another name for it.
  readonly property string ramFormat: {
    var want = enumSetting("ramFormat", ["used/total", "used", "percent", "free", "available"], "used/total")
    return want === "available" ? "free" : want
  }

  readonly property string tempFormat: enumSetting("tempFormat",
    ["degree-unit", "degree", "unit", "unit-lower", "bare"], "degree-unit")

  // The unit marker after a temperature figure. tempText() draws it and the
  // temperature slot is measured with it, so the two cannot disagree.
  readonly property string tempSuffix: {
    var unit = fahrenheit ? "F" : "C"
    if (tempFormat === "degree-unit") return "°" + unit
    if (tempFormat === "degree") return "°"
    if (tempFormat === "unit") return unit
    if (tempFormat === "unit-lower") return unit.toLowerCase()
    return ""
  }

  // Entries without the key keep the dimmed leading zero the label-bearing
  // modes have always drawn; icons mode draws the bare figure. "trail" (first
  // shipped as "space") reserved a trailing slot, which every figure cell now
  // does on its own, so both legacy spellings read as "none".
  readonly property string percentPad: {
    var want = enumSetting("percentPad", ["none", "zero", "lead", "trail", "space"],
                           mode === "icons" ? "none" : "zero")
    return want === "trail" || want === "space" ? "none" : want
  }

  readonly property real padOpacity: {
    var n = Number(setting("padOpacity", 0.3))
    return isFinite(n) ? Model.clamp(n, 0, 1) : 0.3
  }

  readonly property int iconSizeSetting: intSetting("iconSize", 0, 0, 48)
  readonly property int iconSize: iconSizeSetting > 0 ? iconSizeSetting : Style.bar.iconFont
  readonly property int valueSize: Math.max(9, Math.round(iconSize * 0.92))

  readonly property int warnPercent: intSetting("warnPercent", 70, 1, 100)
  readonly property int criticalPercent: intSetting("criticalPercent", 90, 1, 100)
  readonly property int warnTempC: intSetting("warnTempC", 75, 1, 150)
  readonly property int criticalTempC: intSetting("criticalTempC", 90, 1, 150)

  readonly property string clickCommand: String(setting("clickCommand", ""))

  // ----------------------------------------------------------------- glyphs

  readonly property string gpuIcon: String(setting("gpuIcon", "󰾲"))
  readonly property string cpuIcon: String(setting("cpuIcon", ""))
  readonly property string tempIcon: String(setting("tempIcon", ""))
  readonly property string gpuTempIcon: String(setting("gpuTempIcon", "󰔏"))
  readonly property string ramIcon: String(setting("ramIcon", ""))
  readonly property string clockIcon: String(setting("clockIcon", "󰓅"))

  readonly property int gpuIconRotation: intSetting("gpuIconRotation", 0, -360, 360)
  readonly property int cpuIconRotation: intSetting("cpuIconRotation", 0, -360, 360)
  readonly property int tempIconRotation: intSetting("tempIconRotation", 0, -360, 360)
  readonly property int gpuTempIconRotation: intSetting("gpuTempIconRotation", 0, -360, 360)
  readonly property int ramIconRotation: intSetting("ramIconRotation", 0, -360, 360)

  // Readers for this entry's settings. The coercion lives in Model.js, so
  // Service.qml reads the same spellings the same way.
  function boolSetting(name, fallback) {
    return Model.boolSetting(setting(name, fallback), fallback)
  }

  function intSetting(name, fallback, min, max) {
    return Model.intSetting(setting(name, fallback), fallback, min, max)
  }

  function enumSetting(name, options, fallback) {
    return Model.enumSetting(setting(name, fallback), options, fallback)
  }

  // ------------------------------------------------------------------ color

  readonly property color base: bar ? bar.barForeground : Color.foreground
  readonly property color hot: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(base, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Dim up to warnTempC, then from the plain foreground toward urgent as the
  // reading climbs to criticalTempC.
  function tempColor(tempC) {
    if (!(tempC > warnTempC)) return dim
    return Model.mixColor(base, hot, Model.severity(tempC, warnTempC, criticalTempC))
  }

  readonly property int percentSlot: Math.ceil(percentMetrics.advanceWidth)
  readonly property int tempSlot: Math.ceil(tempMetrics.advanceWidth)
  readonly property int ramSlot: Math.ceil(ramMetrics.advanceWidth)

  TextMetrics {
    id: percentMetrics
    font.family: root.fontFamily
    font.pixelSize: root.valueSize
    text: "100%"
  }

  TextMetrics {
    id: tempMetrics
    font.family: root.fontFamily
    font.pixelSize: root.valueSize
    text: "100" + root.tempSuffix
  }

  // Representative widest figure per RAM format; the cell never shrinks below
  // this, so neighbours stop dancing when a digit comes or goes. Wider values
  // still grow naturally instead of clipping.
  TextMetrics {
    id: ramMetrics
    font.family: root.fontFamily
    font.pixelSize: root.valueSize
    text: root.ramFormat === "percent" ? "100%" : (root.ramFormat === "used/total" ? "00.0/00G" : "00.0G")
  }

  // --------------------------------------------------------------- readings

  Service {
    id: hw
    settings: root.settings
    active: root.onThisScreen
  }

  function percentPadFor(value) {
    if (percentPad !== "zero") return ""
    if (!isFinite(value) || value < 0) return ""
    return Math.round(value) < 10 ? "0" : ""
  }

  function percentText(value) {
    if (percentPad === "lead") return Model.padLeft(Model.formatPercent(value), 3)
    return Model.formatPercent(value)
  }

  function tempText(celsius) {
    var figure = Model.tempNumber(celsius, fahrenheit)
    if (figure === "–") return Model.padLeft(figure, 3)

    var text = figure + tempSuffix
    return (labelled || percentPad === "lead") ? Model.padLeft(text, 3) : text
  }

  function ramText() {
    if (ramFormat === "percent") return percentText(hw.memPercent)
    if (!hw.memory) return "–"

    var usedGib = Model.gibFromKib(hw.memory.usedKib)
    var totalGib = Model.gibFromKib(hw.memory.totalKib)
    var availGib = Model.gibFromKib(hw.memory.availableKib)

    if (ramFormat === "used") {
      return Model.formatGibPrecise(usedGib) + "G"
    }

    if (ramFormat === "free") {
      return Model.formatGibPrecise(availGib) + "G"
    }

    if (labelled) {
      return Model.formatGibPrecise(usedGib) + "/" + Model.formatGib(totalGib) + "G"
    }

    if (mode === "icons") {
      return Model.formatGib(usedGib) + "/" + Model.formatGib(totalGib) + "G"
    }

    var used = Model.formatGib(usedGib)
    var total = Model.formatGib(totalGib)
    return Model.padLeft(used, 3) + "/" + total
  }

  // ------------------------------------------------------------- cell output

  // Which sensors this machine reports. Plain bools, so the cell list below
  // re-evaluates only when one flips, not on every sample.
  readonly property bool hasCpuTemp: hw.cpuTempC > 0
  readonly property bool hasGpuTemp: hw.hasGpu && hw.gpuTempC > 0

  // The enabled cells' keys: itemsOrder first, then any enabled key it leaves
  // out. This is the Repeater model, and it changes only with settings or
  // sensor presence, so a new sample updates the existing cell items in
  // place (letting their colour and fill animations run) instead of
  // rebuilding every cell each tick.
  readonly property var cellKeys: {
    var enabled = {
      "gpu": showGpu && hw.hasGpu,
      "cpu": showCpu,
      "cpu-temp": showCpuTemp && hasCpuTemp && showTemps && mode === "icons",
      "gpu-temp": showGpuTemp && hasGpuTemp && showTemps && mode === "icons",
      "ram": showRam
    }
    var order = itemOrder.concat(Object.keys(enabled))
    var out = []
    for (var i = 0; i < order.length; i++) {
      if (enabled[order[i]] === true && out.indexOf(order[i]) === -1) out.push(order[i])
    }
    return out
  }

  // What one cell draws, from the current readings. Each cell binds to its
  // own record, so it re-evaluates when one of its readings changes.
  function cellInfo(key) {
    if (key === "gpu") {
      var busy = hw.gpuPercent
      var gpu = loadCell("GPU", gpuIcon, gpuIconRotation,
                         busy >= 0 ? busy : hw.gpuVramPercent, hw.gpuTempC, hw.gpuMhz)
      // A card without a load counter fills its gauge from VRAM, but only
      // real load warms it.
      gpu.severity = Model.severity(busy, warnPercent, criticalPercent)
      return gpu
    }
    if (key === "cpu") {
      return loadCell("CPU", cpuIcon, cpuIconRotation, hw.cpuPercent, hw.cpuTempC, hw.cpuMhz)
    }
    if (key === "cpu-temp") return tempCell("TEMP", tempIcon, tempIconRotation, hw.cpuTempC)
    if (key === "gpu-temp") return tempCell("GPU°", gpuTempIcon, gpuTempIconRotation, hw.gpuTempC)
    return {
      label: "RAM", icon: ramIcon, iconRotation: ramIconRotation,
      value: ramText(), pad: "", temp: "", tempC: -1, clock: "",
      ratio: hw.memPercent >= 0 ? hw.memPercent / 100 : 0,
      severity: Model.severity(hw.memPercent, warnPercent, criticalPercent)
    }
  }

  // A load percentage, with the component's temperature after a dot in the
  // full and labels modes.
  function loadCell(label, icon, rotation, percent, tempC, mhz) {
    return {
      label: label, icon: icon, iconRotation: rotation,
      value: percentText(percent), pad: percentPadFor(percent),
      temp: (mode === "full" || mode === "labels") && tempC > 0 ? tempText(tempC) : "",
      tempC: tempC, clock: Model.formatGhzShort(mhz),
      ratio: percent >= 0 ? percent / 100 : 0,
      severity: Model.severity(percent, warnPercent, criticalPercent)
    }
  }

  // A standalone temperature (icons mode). Its gauge spans 30 °C to criticalTempC.
  // label is never drawn: only labels mode draws labels, and it has no such cell.
  function tempCell(label, icon, rotation, tempC) {
    return {
      label: label, icon: icon, iconRotation: rotation,
      value: tempText(tempC), pad: "", temp: "", tempC: tempC, clock: "",
      ratio: Model.clamp((tempC - 30) / Math.max(1, criticalTempC - 30), 0, 1),
      severity: Model.severity(tempC, warnTempC, criticalTempC)
    }
  }

  // ---------------------------------------------------------------- tooltip

  readonly property string monitorName: {
    var parts = clickCommand.split(/\s+/)
    var last = String(parts[parts.length - 1] || "")
    return last.substring(last.lastIndexOf("/") + 1)
  }

  readonly property string hint: "Click for " + (clickCommand === "" ? "panel" : monitorName)
    + " · right click for " + nextMode + " · middle click resamples"

  function detail() {
    var lines = []

    var cpu = "CPU  " + Model.formatPercent(hw.cpuPercent)
    if (hw.cpuTempC > 0) cpu += "  ·  " + Model.formatTemp(hw.cpuTempC, fahrenheit)
    if (hw.cpuMhz > 0) cpu += "  ·  " + Model.formatGhz(hw.cpuMhz)
    lines.push(cpu)
    if (hw.cpuInfo && hw.cpuInfo.model) {
      lines.push(hw.cpuInfo.model + " · " + hw.cpuInfo.cores + "C/" + hw.cpuInfo.threads + "T")
    }
    if (hw.load) {
      lines.push("Load " + hw.load.one.toFixed(2) + "  " + hw.load.five.toFixed(2) + "  " + hw.load.fifteen.toFixed(2))
    }

    if (hw.hasGpu) {
      lines.push("")
      var gpu = "GPU  " + Model.formatPercent(hw.gpuPercent)
      if (hw.gpuWatts >= 0) gpu += "  ·  " + Model.formatWatts(hw.gpuWatts)
      lines.push(gpu)
      // The probe's name is optional; fall back as the panel does.
      lines.push(hw.gpuInfo.name ? String(hw.gpuInfo.name) : String(hw.gpuInfo.kind || "GPU"))
      if (hw.gpuVramTotalBytes > 0) {
        lines.push("VRAM " + Model.formatGib(Model.gibFromBytes(hw.gpuVramUsedBytes)) + " / "
                   + Model.formatGib(Model.gibFromBytes(hw.gpuVramTotalBytes)) + " GiB  ·  "
                   + Model.formatPercent(hw.gpuVramPercent))
      }
      var extras = []
      if (hw.gpuRpm >= 0) extras.push("Fan " + Model.formatRpm(hw.gpuRpm))
      if (hw.gpuMhz > 0) extras.push(Model.formatGhz(hw.gpuMhz))
      if (extras.length > 0) lines.push(extras.join("  ·  "))
    }

    if (hw.memory) {
      lines.push("")
      lines.push("RAM  " + Model.formatGib(Model.gibFromKib(hw.memory.usedKib)) + " / "
                 + Model.formatGib(Model.gibFromKib(hw.memory.totalKib)) + " GiB  ·  "
                 + Model.formatPercent(hw.memory.percent))
      lines.push("Cache " + Model.formatGib(Model.gibFromKib(hw.memory.cachedKib)) + " GiB"
                 + (hw.memory.swapTotalKib > 0
                    ? "  ·  Swap " + Model.formatGib(Model.gibFromKib(hw.memory.swapUsedKib)) + " / "
                      + Model.formatGib(Model.gibFromKib(hw.memory.swapTotalKib)) + " GiB"
                    : ""))
    }

    return lines.join("\n")
  }

  // ----------------------------------------------------------------- actions

  // Middle click and IPC both reach every placement through broadcast();
  // one hidden by `monitors` keeps costing nothing.
  function refresh() {
    if (hw.active) hw.sample()
  }

  // Save one key into this widget's shell.json entry, keeping its other keys.
  // The host's updateEntryInline is keyed by widget id, so if the widget is
  // placed more than once, every placement receives this instance's entry.
  function persistSetting(key, value) {
    var live = root.settings || {}
    var entry = { id: root.moduleName }
    for (var k in live) if (k !== "id") entry[k] = live[k]
    entry[key] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  function cycleMode() {
    persistSetting("mode", nextMode)
  }

  function toggleFahrenheit() {
    persistSetting("fahrenheit", !fahrenheit)
  }

  function launchMonitor() {
    if (clickCommand === "") {
      root.toggle()
      return
    }
    if (root.bar) root.bar.run(clickCommand)
    else Quickshell.execDetached(["bash", "-lc", clickCommand])
  }

  IpcHandler {
    target: root.ipcTarget

    function open(): void { root.open() }
    function close(): void { root.close() }
    // show/hide are the stock Omarchy panel verbs (Ui/Panel's own handler).
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleFahrenheit(): void { root.toggleFahrenheit() }
    function refresh(): void { root.broadcast("refresh") }
    function cycleMode(): void { root.cycleMode() }
    function status(): string { return root.detail() }
  }

  // ------------------------------------------------------------------ layout

  readonly property int glyphBox: Math.max(Style.bar.iconCanvas, iconSize + Style.space(2))
  readonly property int contentHeight: Math.max(glyphBox, Style.space(15))
  readonly property int gaugeWidth: Math.max(6, Math.round(iconSize * 0.45))
  readonly property int gaugeHeight: Math.max(11, Math.round(iconSize * 0.9))

  visible: onThisScreen
  implicitWidth: onThisScreen ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.cellKeys.length > 0
    tooltipText: root.hint
    horizontalMargin: 6
    fixedWidth: root.vertical ? -1 : Math.ceil(horizontalCells.implicitWidth + button.scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.ceil(verticalCells.implicitHeight + Style.space(8)) : -1

    onPressed: function(pressedButton) {
      if (pressedButton === Qt.RightButton) root.cycleMode()
      else if (pressedButton === Qt.MiddleButton) root.broadcast("refresh")
      else root.launchMonitor()
    }

    // Only the orientation on screen gets cells; a Repeater instantiates its
    // delegates whether or not its parent is visible.
    Row {
      id: horizontalCells
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(root.mode === "icons" ? 14 : 8)

      Repeater {
        model: root.vertical ? [] : root.cellKeys
        delegate: cell
      }
    }

    Column {
      id: verticalCells
      visible: root.vertical
      anchors.centerIn: parent
      spacing: Style.space(5)

      Repeater {
        model: root.vertical ? root.cellKeys : []
        delegate: cell
      }
    }
  }

  SystemPanel {
    id: systemPanel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    hw: hw
    mode: root.mode
    showGpu: root.showGpu
    showCpu: root.showCpu
    showCpuTemp: root.showCpuTemp
    showGpuTemp: root.showGpuTemp
    showRam: root.showRam
    showTopProcs: root.showTopProcs
    showClocks: root.showClocks
    showGauges: root.showGauges
    ramFormat: root.ramFormat
    tempFormat: root.tempFormat
    fahrenheit: root.fahrenheit
    warnPercent: root.warnPercent
    criticalPercent: root.criticalPercent
    warnTempC: root.warnTempC
    criticalTempC: root.criticalTempC
  }

  // The shared look of every figure in a cell.
  component CellText: Text {
    height: root.contentHeight
    textFormat: Text.PlainText
    font.family: root.fontFamily
    font.pixelSize: root.valueSize
    verticalAlignment: Text.AlignVCenter
    renderType: Text.NativeRendering
    Behavior on color { ColorAnimation { duration: 240 } }
  }

  // A component group: glyph + figure (+ temp). modelData is the cell's key.
  Component {
    id: cell

    Row {
      id: group
      required property string modelData
      readonly property var info: root.cellInfo(modelData)
      readonly property bool isTempCell: modelData === "cpu-temp" || modelData === "gpu-temp"
      // Temperatures follow their own ramp; load figures warm with severity.
      readonly property color tone: isTempCell
        ? root.tempColor(info.tempC)
        : Model.mixColor(root.base, root.hot, info.severity)
      readonly property color dimTone: Model.mixColor(root.dim, root.hot, info.severity)
      spacing: Style.space(4)

      // Every figure cell reserves its slot width: a single-digit value keeps
      // an invisible trailing gap instead of pulling its neighbours around.
      readonly property int figureSlot: isTempCell ? root.tempSlot
        : (modelData === "ram" ? root.ramSlot : root.percentSlot)
      readonly property real slack: root.showValues
        ? Math.max(0, figureSlot - valueText.implicitWidth - spacing)
        : 0

      TextMetrics {
        id: glyphMetrics
        font.family: root.fontFamily
        font.pixelSize: root.iconSize
        text: group.info.icon
      }

      Item {
        readonly property bool turned: Math.abs(group.info.iconRotation % 180) === 90
        readonly property real inkWidth: turned
          ? glyphMetrics.tightBoundingRect.height
          : glyphMetrics.tightBoundingRect.width

        visible: !root.labelled
        width: visible ? Math.max(1, Math.ceil(inkWidth)) : 0
        height: root.contentHeight

        OpticalGlyph {
          anchors.fill: parent
          visible: group.info.iconRotation === 0
          text: group.info.icon
          fontFamily: root.fontFamily
          fontSize: root.iconSize
          color: group.tone
          Behavior on color { ColorAnimation { duration: 240 } }
        }

        Text {
          anchors.centerIn: parent
          visible: group.info.iconRotation !== 0
          rotation: group.info.iconRotation
          textFormat: Text.PlainText
          text: group.info.icon
          color: group.tone
          font.family: root.fontFamily
          font.pixelSize: root.iconSize
          renderType: Text.NativeRendering
          Behavior on color { ColorAnimation { duration: 240 } }
        }
      }

      Gauge {
        visible: root.showGauges && !root.labelled
        height: root.contentHeight
        bodyWidth: root.gaugeWidth
        bodyHeight: root.gaugeHeight
        ratio: group.info.ratio
        fillColor: group.tone
        trackColor: Qt.rgba(root.base.r, root.base.g, root.base.b, 0.14)
        borderColor: Qt.rgba(root.base.r, root.base.g, root.base.b, 0.4)
        glow: group.info.severity >= 1
      }

      CellText {
        visible: root.labelled
        text: group.info.label
        color: root.dim
        font.bold: true
      }

      Row {
        visible: root.showValues
        height: root.contentHeight
        spacing: 0

        CellText {
          visible: group.info.pad !== ""
          text: group.info.pad
          color: group.tone
          opacity: root.padOpacity
        }

        CellText {
          id: valueText
          text: group.info.value
          color: group.tone
          font.bold: !group.isTempCell
        }
      }

      Row {
        visible: root.showClocks && group.info.clock !== ""
        height: root.contentHeight
        spacing: Style.space(2)

        CellText {
          visible: root.clockIcon !== ""
          leftPadding: Style.space(2)
          text: root.clockIcon
          color: group.dimTone
        }

        CellText {
          text: group.info.clock
          color: group.dimTone
        }
      }

      Row {
        visible: root.showTemps && group.info.temp !== ""
        height: root.contentHeight
        spacing: Style.space(3)

        CellText {
          text: "·"
          color: Qt.darker(root.base, 1.8)
        }

        CellText {
          width: Math.max(implicitWidth, root.tempSlot)
          text: group.info.temp
          color: root.tempColor(group.info.tempC)
        }
      }

      Item {
        visible: group.slack > 0
        width: visible ? group.slack : 0
        height: 1
      }
    }
  }
}
