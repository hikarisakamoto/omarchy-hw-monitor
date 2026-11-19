import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Samples CPU, memory, and GPU telemetry straight out of /proc and /sys.
//
// Discovery runs `hw-probe` once to find out which sysfs files this machine
// exposes. Steady-state bar sampling is blocking reads of virtual files
// measured in microseconds — no fork on a timer, which is why a two-second
// interval is affordable inside the shell process instead of forking a script
// the way a Waybar module would. Two documented exceptions fork helpers:
// `nvidia-smi` on the sample interval (NVIDIA cards expose no sysfs telemetry)
// and `proc_top.py` up to every 3 s, only while the system panel is open and
// its top-processes section is shown.
//
// One instance exists per monitor, since the bar mounts a widget per screen.
// For the virtual-file reads that is cheap enough not to coordinate, but the
// forks are duplicated too: every shown screen runs its own `hw-probe` at
// startup and, on an NVIDIA machine, its own `nvidia-smi` each tick. A screen
// the `monitors` setting hides runs neither.
Item {
  id: root

  property var settings: ({})

  // Set false on a screen this widget is not drawn on: the timers stop and the
  // probe never runs, so a hidden instance costs nothing. Its panel can still
  // be opened (IPC, or the panel hotkey on that screen), and an open panel is
  // sampled like any other: see the sampler Timer and refreshProcTop.
  property bool active: true

  // Resolved from this file's own location rather than spelled out, so a fork
  // that renames the plugin id does not silently lose the helper.
  readonly property string pluginDir: {
    var dir = String(Qt.resolvedUrl("."))
    if (dir.indexOf("file://") === 0) dir = dir.substring(7)
    return dir.replace(/\/$/, "")
  }
  readonly property string probePath: pluginDir + "/hw-probe"

  readonly property int intervalSec: intSetting("refreshIntervalSec", 2, 1, 60)

  // ------------------------------------------------------------- discovery

  property var probe: Model.parseProbe("")
  readonly property var cpuInfo: probe.cpu
  readonly property var gpuInfo: Model.pickGpu(probe.gpus, setting("gpu", "auto"))
  readonly property bool hasGpu: gpuInfo !== null
  readonly property bool gpuIsNvidia: hasGpu && String(gpuInfo.kind) === "nvidia"

  // -------------------------------------------------------------- readings
  //
  // -1 means "this machine does not report it" or "not sampled yet". Every
  // formatter in Model.js renders that as a dash, so a missing sensor degrades
  // to a gap in the readout instead of a zero that looks like real data.

  property real cpuPercent: -1
  property real cpuTempC: -1
  property real cpuMhz: -1
  property var load: null

  property var memory: null
  readonly property real memPercent: memory ? memory.percent : -1

  property real gpuPercent: -1
  property real gpuTempC: -1
  property real gpuWatts: -1
  property real gpuRpm: -1
  property real gpuMhz: -1
  property real gpuVramUsedBytes: -1
  property real gpuVramTotalBytes: -1
  readonly property real gpuVramPercent: gpuVramTotalBytes > 0
    ? Model.clamp(100 * gpuVramUsedBytes / gpuVramTotalBytes, 0, 100) : -1

  // Top processes: sampled only while the panel is open, never in the
  // background. The state lives here and persists with the shell; the worker
  // is spawned per poll and does not outlive it. One guard:
  // procTopProcess.running.
  property var topProcs: []
  property bool procPanelOpen: false
  property string procTopTime: ""
  property bool procTopFailed: false
  property string procGroupedBy: "none"
  readonly property int topProcCount: intSetting("topProcCount", 6, 3, 12)
  readonly property string topProcSort: enumSetting("topProcSort", ["ram", "cpu"], "ram")
  readonly property bool topProcGroup: boolSetting("topProcGroup", true)
  // The panel only hides the section when this is off; gating here as well
  // means proc_top.py is not forked for a list nobody sees.
  readonly property bool showTopProcs: boolSetting("showTopProcs", true)
  readonly property string procTopPath: pluginDir + "/proc_top.py"
  property double _lastProcTopTry: 0
  // Teardown veto: once destruction begins (the hot-reload window) no handler
  // touches state any more. See Component.onDestruction at the bottom.
  property bool _destroyed: false

  // Cumulative jiffies from the previous tick. CPU usage is the ratio between
  // two samples, so there is nothing to show until the second one lands.
  property var _prevJiffies: null

  // CPU load history for the panel's sparkline: {t, v} points pushed by the
  // timed tick only (manual resamples would add irregular, short-window
  // points) and trimmed to the last historyMs. It fills in the background at
  // the cost of one array push per tick and no extra reads, so the chart
  // already spans the last minute when the panel opens. The array is mutated
  // in place; cpuHistoryRev is its change signal, bumped only while the panel
  // is open, so a closed panel re-evaluates nothing.
  readonly property int historyMs: 60000
  property var cpuHistory: []
  property int cpuHistoryRev: 0

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  // Thin wrappers over the shared coercions in Model.js, so a shell.json value
  // means the same thing here as in Widget.qml. setting() is read inside each
  // binding, so a settings change still re-evaluates the property.
  function intSetting(name, fallback, min, max) {
    return Model.intSetting(setting(name, fallback), fallback, min, max)
  }

  function boolSetting(name, fallback) {
    return Model.boolSetting(setting(name, fallback), fallback)
  }

  function enumSetting(name, options, fallback) {
    return Model.enumSetting(setting(name, fallback), options, fallback)
  }

  // Both readers reload their file and return -1 when it has no path (the
  // selected card does not expose that sensor) or the read fails. sample()
  // assigns every reading on every tick, so after a card switch a sensor the
  // new card lacks shows a dash instead of the previous card's value.

  // hwmon reports temperatures in millidegrees, but a handful of drivers
  // report whole degrees. Anything under 200 is already in degrees.
  function readTemp(view) {
    if (view.path === "") return -1
    view.reload()
    var raw = Model.toNumber(view.text(), -1)
    if (!isFinite(raw) || raw <= 0) return -1
    return raw > 200 ? raw / 1000 : raw
  }

  function readNumber(view, divisor) {
    if (view.path === "") return -1
    view.reload()
    var raw = Model.toNumber(view.text(), -1)
    if (!isFinite(raw) || raw < 0) return -1
    return divisor ? raw / divisor : raw
  }

  function refreshProbe() {
    probeProcess.spawn([probePath])
  }

  function sample() {
    statFile.reload()
    var jiffies = Model.parseCpuJiffies(statFile.text())
    if (jiffies) {
      // The shortest window that counts as a reading: ~250 ms of every online
      // CPU's time, counted from /proc/stat itself so it holds even when
      // hw-probe never reported the CPU.
      var usage = Model.cpuUsage(_prevJiffies, jiffies, Math.max(1, jiffies.cpus) * 25)
      if (usage >= 0) cpuPercent = usage
      // A window too short to read keeps its baseline, so the next sample
      // measures the whole span. A reading, a first sample, or a counter that
      // went backwards moves it.
      if (usage >= 0 || !_prevJiffies || jiffies.total < _prevJiffies.total) _prevJiffies = jiffies
    }

    memFile.reload()
    var parsed = Model.parseMemory(memFile.text())
    if (parsed) memory = parsed

    cpuinfoFile.reload()
    var mhz = Model.averageMhz(cpuinfoFile.text())
    cpuMhz = mhz > 0 ? mhz : -1

    loadFile.reload()
    load = Model.parseLoadAverage(loadFile.text())

    cpuTempC = readTemp(cpuTempFile)

    if (gpuIsNvidia) {
      sampleNvidia()
      return
    }

    gpuPercent = readNumber(gpuBusyFile, 0)
    gpuTempC = readTemp(gpuTempFile)
    gpuWatts = readNumber(gpuPowerFile, 1000000)
    gpuRpm = readNumber(gpuFanFile, 0)
    gpuMhz = readNumber(gpuClockFile, 1000000)
    gpuVramUsedBytes = readNumber(gpuVramUsedFile, 0)
    gpuVramTotalBytes = readNumber(gpuVramTotalFile, 0)
  }

  function sampleNvidia() {
    if (_destroyed || nvidiaProcess.running) return
    // hw-probe reports the absolute path it resolved, so the bar never
    // re-resolves nvidia-smi from the session PATH at sample time.
    var bin = gpuInfo && gpuInfo.nvidiaPath ? String(gpuInfo.nvidiaPath) : "nvidia-smi"
    nvidiaProcess.spawn([bin,
                         "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw,clocks.gr",
                         "--format=csv,noheader,nounits",
                         "--id=" + String(gpuInfo.index !== undefined ? gpuInfo.index : 0)])
  }

  // A run that failed, printed an error instead of CSV, or was killed before
  // writing anything blanks the readout instead of freezing the last values
  // as if they were live (driver/library mismatch after an update, "GPU has
  // fallen off the bus" after suspend, a wedged nvidia-smi).
  function applyNvidia(raw) {
    var sample = Model.parseNvidia(raw)
      || { busy: -1, tempC: -1, watts: -1, vramUsedBytes: -1, vramTotalBytes: -1, mhz: -1 }
    gpuPercent = sample.busy
    gpuTempC = sample.tempC
    gpuWatts = sample.watts
    gpuVramUsedBytes = sample.vramUsedBytes
    gpuVramTotalBytes = sample.vramTotalBytes
    gpuMhz = sample.mhz
    // nvidia-smi reports fan speed only as a percentage, not RPM; clear what a
    // sysfs card selected before this one may have left behind.
    gpuRpm = -1
  }

  // Spawns proc_top.py at most every 3 s. Only allowlisted values reach argv
  // (a clamped integer, a validated ram/cpu sort, a bare --group flag): the
  // raw setting string never touches argv. No PATH lookup, no shell.
  function refreshProcTop() {
    if (_destroyed || !procPanelOpen || !showTopProcs || procTopProcess.running) return
    var now = Date.now()
    if (_lastProcTopTry > 0 && now - _lastProcTopTry < 3000) return
    _lastProcTopTry = now
    var cmd = ["/usr/bin/python3", procTopPath, "--top", String(topProcCount), "--sort", topProcSort]
    if (topProcGroup) cmd.push("--group")
    procTopProcess.spawn(cmd)
  }

  // A sort, grouping or visibility change refreshes at once (throttle reset).
  // The guards in refreshProcTop still apply: nothing runs while the panel is
  // closed or the section is off.
  function refreshProcTopNow() {
    _lastProcTopTry = 0
    refreshProcTop()
  }
  onTopProcSortChanged: refreshProcTopNow()
  onTopProcGroupChanged: refreshProcTopNow()
  onShowTopProcsChanged: refreshProcTopNow()

  // ----------------------------------------------------------------- files
  //
  // blockAllReads makes reload() synchronous: without it text() returns the
  // previous tick's contents and every readout lags a full interval. These are
  // kernel-generated files of a few KB, so a blocking read never stalls the UI.

  component SensorFile: FileView {
    blockAllReads: true
    printErrors: false
  }

  // A sensor's FileView path, or "" when the selected card does not expose it.
  function gpuPath(key) {
    return hasGpu && gpuInfo[key] ? String(gpuInfo[key]) : ""
  }

  SensorFile { id: statFile; path: "/proc/stat" }
  SensorFile { id: memFile; path: "/proc/meminfo" }
  SensorFile { id: cpuinfoFile; path: "/proc/cpuinfo" }
  SensorFile { id: loadFile; path: "/proc/loadavg" }
  SensorFile { id: cpuTempFile; path: root.cpuInfo && root.cpuInfo.tempPath ? String(root.cpuInfo.tempPath) : "" }

  // A GPU sensor the card does not expose leaves its path empty, and its
  // reading stays -1 — the widget then renders a dash rather than a fake zero.
  SensorFile { id: gpuBusyFile; path: root.gpuPath("busyPath") }
  SensorFile { id: gpuTempFile; path: root.gpuPath("tempPath") }
  SensorFile { id: gpuPowerFile; path: root.gpuPath("powerPath") }
  SensorFile { id: gpuFanFile; path: root.gpuPath("fanPath") }
  SensorFile { id: gpuClockFile; path: root.gpuPath("clockPath") }
  SensorFile { id: gpuVramUsedFile; path: root.gpuPath("vramUsedPath") }
  SensorFile { id: gpuVramTotalFile; path: root.gpuPath("vramTotalPath") }

  // ------------------------------------------------------------- processes
  //
  // Each helper runs inside a GuardedProcess, which owns its watchdog
  // (SIGTERM), kill timer (SIGKILL) and byte cap. The values below are the
  // only per-helper differences.

  GuardedProcess {
    id: probeProcess
    timeoutMs: 8000
    killMs: 2000
    byteCap: Model.HELPER_MAX_CHARS
    onFinished: function(text) {
      if (root._destroyed) return
      // A re-probe (the widget re-shown) that fails or prints nothing usable
      // keeps the last good discovery instead of dropping every sensor.
      var parsed = Model.parseProbe(text)
      if (parsed.ok || !root.probe.ok) root.probe = parsed
      // Sensor paths only become known here, so take the first real sample
      // once they land instead of waiting out a whole interval.
      root.sample()
    }
    // A killed or crashed probe leaves discovery empty for the whole session
    // otherwise: retry slowly until one run succeeds.
    onExited: if (!root._destroyed && !root.probe.ok) probeRetryTimer.restart()
  }

  GuardedProcess {
    id: nvidiaProcess
    timeoutMs: 10000
    killMs: 2000
    byteCap: Model.HELPER_MAX_CHARS
    onFinished: function(text) { if (!root._destroyed) root.applyNvidia(text) }
  }

  // Top-processes worker: run directly (never sh -c), stdout capped at one
  // JSON line under 16 KB and validated by Model.parseProcTop. It fails soft:
  // the last good list stays and procTopFailed is raised instead of emptying
  // the section. Watchdog kill-before-next-tick: 0.4 s internal read << 2 s
  // watchdog << 3 s throttle.
  GuardedProcess {
    id: procTopProcess
    timeoutMs: 2000
    killMs: 1000
    byteCap: Model.PROC_TOP_MAX_CHARS
    onFinished: function(text) {
      if (root._destroyed) return
      // parseProcTop degrades fail-soft on every shape it documents, but an
      // exotic value type can still throw: catch it so the section flags a
      // failure instead of freezing silently. The watchdog keeps running until
      // the process exits — a helper that closes stdout and then hangs must
      // still be killed.
      var res = null
      try { res = Model.parseProcTop(text, root.topProcCount) } catch (e) { res = null }
      if (res && res.ok) {
        root.topProcs = res.rows
        root.procGroupedBy = res.groupedBy
        root.procTopFailed = false
        // A fixed pattern, so the digits stay ASCII whatever the locale.
        root.procTopTime = Qt.formatTime(new Date(), "HH:mm:ss")
      } else {
        root.procTopFailed = true
      }
    }
    onTimedOut: if (!root._destroyed) root.procTopFailed = true
  }

  // Slow retry for discovery: armed only when a probe run ended without
  // producing a valid payload (killed, crashed, or malformed), restart() so
  // each failed exit resets the 30 s deadline, and never re-armed once a
  // run succeeds (onTriggered checks probe.ok).
  Timer {
    id: probeRetryTimer
    interval: 30000
    repeat: false
    onTriggered: {
      if (root._destroyed || root.probe.ok) return
      refreshProbe()
    }
  }

  // Teardown: raise the veto and stop every worker and watchdog, so no
  // in-flight callback touches state while the object is finalised (reload).
  Component.onDestruction: {
    _destroyed = true
    probeRetryTimer.stop()
    probeProcess.shutdown()
    nvidiaProcess.shutdown()
    procTopProcess.shutdown()
  }

  // -------------------------------------------------------------- lifetime

  // The only periodic sampler. While the system panel is open everything
  // ticks every second; otherwise at refreshIntervalSec. (The panel used to
  // run its own 1 s sample() timer beside this one, and whenever the two
  // landed a few ms apart the CPU figure came from a near-empty window.)
  // Changing the interval restarts the timer, which at most delays one tick.
  // It also runs for an open panel on an inactive (hidden) instance.
  Timer {
    interval: root.procPanelOpen ? 1000 : root.intervalSec * 1000
    running: root.active || root.procPanelOpen
    repeat: true
    onTriggered: root.tick()
  }

  function tick() {
    if (_destroyed) return
    sample()
    if (cpuPercent >= 0) {
      var now = Date.now()
      // A wall clock stepped backwards (NTP correcting a local-time RTC,
      // `date -s`) leaves points stamped in the future: they would never be
      // trimmed and would draw past the chart's right edge. Start over.
      if (cpuHistory.length > 0 && cpuHistory[cpuHistory.length - 1].t > now) cpuHistory = []
      cpuHistory.push({ t: now, v: cpuPercent })
      while (now - cpuHistory[0].t > historyMs) cpuHistory.shift()
      if (procPanelOpen) cpuHistoryRev++
    }
    // Throttled to every 3 s and a no-op unless the panel is open.
    refreshProcTop()
  }

  // CPU usage needs two samples. Take the second one shortly after startup so
  // the widget shows a real number immediately rather than a dash.
  Timer {
    interval: 350
    running: root.active
    repeat: false
    onTriggered: root.sample()
  }

  function start() {
    if (!active || probeProcess.running) return
    sample()
    refreshProbe()
  }

  // A hidden instance keeps no history: when it is shown again the old
  // points would be joined across the gap as if they were recent.
  onActiveChanged: {
    if (active) {
      start()
    } else if (!procPanelOpen) {
      cpuHistory = []
    }
  }
  onProcPanelOpenChanged: if (!procPanelOpen && !active) cpuHistory = []
  Component.onCompleted: start()
}
