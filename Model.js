.pragma library

// Pure parsing and formatting for the hardware readouts. Everything here takes
// raw file text or numbers and returns plain values, so the sampling in
// Service.qml and the drawing in Widget.qml never have to agree on anything
// beyond these shapes.

var KIB_PER_GIB = 1048576
var BYTES_PER_GIB = 1073741824

// Number("") is 0, so an empty or blank value (a failed sysfs read leaves the
// FileView text empty) is treated as missing rather than as a real zero.
function toNumber(value, fallback) {
  var text = String(value).trim()
  var n = text === "" ? NaN : Number(text)
  return isFinite(n) ? n : (fallback === undefined ? 0 : fallback)
}

// Coerce only scalars: String()/Number() on an object whose JSON carried an
// own "toString" key throws "Cannot convert object to primitive value", which
// would take a fail-soft parser down with it. Subprocess output is untrusted,
// so every field of every row goes through this, not toNumber directly.
function toNumberSafe(value, fallback) {
  var t = typeof value
  if (t !== "number" && t !== "string" && t !== "boolean") {
    return fallback === undefined ? 0 : fallback
  }
  return toNumber(value, fallback)
}

// Sensor paths from the probe become blocking FileView reads on the GUI
// thread, so accept only the two sysfs trees hw-probe scans — an hwmon device
// or a DRM card's device — and only clean absolute forms: no '.'/'..'
// traversal, no empty interior segments. sysfs symlinks resolve inside sysfs,
// whereas /proc would let /proc/self/root/... reach any file on disk, so a
// tampered hw-probe cannot point the shell at arbitrary readable files.
// Keep this in step with the paths hw-probe emits: a shape it starts
// producing that is not listed here is silently dropped and shows a dash.
var SENSOR_PATH = /^\/sys\/class\/(hwmon\/hwmon\d+|drm\/card\d+\/device)\/[A-Za-z0-9._:\/-]+$/
function safePath(value) {
  if (typeof value !== "string" || !SENSOR_PATH.test(value)) return undefined
  var parts = value.split("/")
  for (var i = 1; i < parts.length; i++) {
    if (parts[i] === "" || parts[i] === "." || parts[i] === "..") return undefined
  }
  return value
}

function cleanString(value, maxLen) {
  if (typeof value !== "string") return undefined
  var s = value.trim()
  if (s === "") return undefined
  return s.length > maxLen ? s.substring(0, maxLen) : s
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

// ---------------------------------------------------------------- settings
//
// One coercion per setting type, shared by Widget.qml and Service.qml, so a
// value from shell.json means the same thing to every reader. Each returns the
// fallback for a missing or unusable value instead of throwing.

function isScalar(value) {
  var t = typeof value
  return t === "number" || t === "string" || t === "boolean"
}

function boolSetting(value, fallback) {
  if (typeof value === "boolean") return value
  if (!isScalar(value)) return fallback
  var text = String(value).trim().toLowerCase()
  if (["true", "1", "yes", "on"].indexOf(text) !== -1) return true
  if (["false", "0", "no", "off"].indexOf(text) !== -1) return false
  return fallback
}

function intSetting(value, fallback, min, max) {
  var n = isScalar(value) ? parseInt(String(value), 10) : NaN
  if (!isFinite(n)) n = fallback
  return clamp(n, min, max)
}

// `options` lists the accepted lower-case spellings; anything else falls back.
function enumSetting(value, options, fallback) {
  if (!isScalar(value)) return fallback
  var want = String(value).trim().toLowerCase()
  return options.indexOf(want) === -1 ? fallback : want
}

// ------------------------------------------------------------------ colour

// Blend `from` toward `to` by t, clamped to 0..1, keeping from's alpha. Every
// warm-up, temperature, and accent ramp in the bar and panel goes through here.
function mixColor(from, to, t) {
  var k = isFinite(t) ? clamp(t, 0, 1) : 0
  if (k <= 0) return from
  return Qt.rgba(from.r + (to.r - from.r) * k,
                 from.g + (to.g - from.g) * k,
                 from.b + (to.b - from.b) * k,
                 from.a)
}

// ------------------------------------------------------------------- probe

// Probe output is one JSON line from a helper we spawn, but treat it as
// untrusted anyway: keep only known keys with expected types, and accept a
// sensor path only when it has a shape safePath allows.
function parseProbe(raw) {
  // Until a probe lands the CPU is unknown: an empty model lets the tooltip
  // and panel header fall back instead of showing "CPU · 0C/0T".
  var empty = { ok: false, cpu: { model: "", cores: 0, threads: 0 }, gpus: [] }
  var text = String(raw || "").trim()
  if (text === "") return empty
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return empty
    var rawCpu = parsed.cpu && typeof parsed.cpu === "object" ? parsed.cpu : {}
    var cpu = {
      model: cleanString(rawCpu.model, 128) || "CPU",
      cores: Math.max(0, Math.floor(toNumberSafe(rawCpu.cores, 0))),
      threads: Math.max(0, Math.floor(toNumberSafe(rawCpu.threads, 0)))
    }
    var tempPath = safePath(rawCpu.tempPath)
    if (tempPath !== undefined) {
      cpu.tempPath = tempPath
      cpu.tempLabel = cleanString(rawCpu.tempLabel, 64)
    }
    var gpus = []
    var rawGpus = parsed.gpus instanceof Array ? parsed.gpus : []
    var PATH_KEYS = ["busyPath", "vramUsedPath", "vramTotalPath", "tempPath",
                     "powerPath", "fanPath", "clockPath"]
    for (var i = 0; i < rawGpus.length; i++) {
      var g = rawGpus[i]
      if (!g || typeof g !== "object") continue
      var gpu = {}
      var kind = cleanString(g.kind, 64)
      if (kind !== undefined) gpu.kind = kind
      var name = cleanString(g.name, 256)
      if (name !== undefined) gpu.name = name
      var card = cleanString(g.card, 64)
      if (card !== undefined) gpu.card = card
      gpu.index = Math.max(0, Math.floor(toNumberSafe(g.index, 0)))
      // Absolute path of the nvidia-smi the probe resolved: must be a clean
      // absolute path (no relative names, no traversal); the widget falls
      // back to a bare 'nvidia-smi' when it is missing or malformed.
      if (typeof g.nvidiaPath === "string" && /^\/[A-Za-z0-9._\/+-]+$/.test(g.nvidiaPath)
          && g.nvidiaPath.indexOf("..") === -1) {
        gpu.nvidiaPath = g.nvidiaPath
      }
      for (var k = 0; k < PATH_KEYS.length; k++) {
        var path = safePath(g[PATH_KEYS[k]])
        if (path !== undefined) gpu[PATH_KEYS[k]] = path
      }
      gpus.push(gpu)
    }
    return { ok: true, cpu: cpu, gpus: gpus }
  } catch (e) {
    return empty
  }
}

// Pick which discovered card the widget reports on. `auto` means the first,
// which hw-probe has already sorted so a card with a load counter wins.
function pickGpu(gpus, preference) {
  if (!(gpus instanceof Array) || gpus.length === 0) return null
  var want = String(preference === undefined || preference === null ? "auto" : preference).trim().toLowerCase()
  if (want === "" || want === "auto") return gpus[0]

  // A bare number is a position in hw-probe's list, not a DRM card number:
  // the probe lists cards with a load counter first, so "0" need not be card0.
  var index = parseInt(want, 10)
  if (isFinite(index) && index >= 0 && index < gpus.length) return gpus[index]

  // An exact card name wins before the substring scan, so "card1" never
  // lands on card10 just because that card is listed first.
  for (var c = 0; c < gpus.length; c++) {
    var card = gpus[c].card
    if (typeof card === "string" && card.toLowerCase() === want) return gpus[c]
  }

  // Otherwise treat it as a substring match on card, kind, or name — so
  // "card1", "amdgpu", and "9070" all select the same GPU.
  for (var i = 0; i < gpus.length; i++) {
    var gpu = gpus[i]
    var haystack = [gpu.card, gpu.kind, gpu.name].join(" ").toLowerCase()
    if (haystack.indexOf(want) !== -1) return gpu
  }
  return gpus[0]
}

// --------------------------------------------------------------------- cpu

// The aggregate line of /proc/stat holds cumulative jiffies since boot:
// cpu user nice system idle iowait irq softirq steal guest guest_nice
// The per-CPU lines after it (cpu0, cpu1, ...) list only online CPUs, so their
// count is how fast the total grows: USER_HZ = 100 jiffies per CPU-second.
function parseCpuJiffies(raw) {
  var text = String(raw || "")
  var end = text.indexOf("\n")
  var line = end === -1 ? text : text.substring(0, end)
  var parts = line.replace(/\s+/g, " ").split(" ")
  if (parts.length < 5 || parts[0] !== "cpu") return null

  var total = 0
  // Fields past `steal` are already counted inside user/nice, so stop at 8.
  for (var i = 1; i < parts.length && i <= 8; i++) total += toNumber(parts[i])
  // iowait is time with nothing to run, so it belongs with idle rather than
  // being charged to a process — this matches what top and btop report.
  var idle = toNumber(parts[4]) + toNumber(parts[5])
  var perCpu = text.match(/^cpu\d+\s/gm)
  return { total: total, idle: idle, cpus: perCpu ? perCpu.length : 0 }
}

// Usage is a ratio of jiffie deltas, not of wall-clock time, so an uneven
// sampling interval cannot skew it. A window under minDelta jiffies (an
// off-cycle resample landing just after a tick) holds too few ticks to be a
// reading — a handful of jiffies quantise to 0/50/100% — and returns -1 like
// a missing sample.
function cpuUsage(previous, current, minDelta) {
  if (!previous || !current) return -1
  var totalDelta = current.total - previous.total
  var idleDelta = current.idle - previous.idle
  if (totalDelta <= 0 || totalDelta < (minDelta || 0)) return -1
  return clamp(100 * (1 - idleDelta / totalDelta), 0, 100)
}

// Average current clock across every thread. /proc/cpuinfo is the one place
// that reports it without globbing 32 cpufreq directories.
function averageMhz(raw) {
  var matches = String(raw || "").match(/^cpu MHz\s*:\s*([\d.]+)/gm)
  if (!matches || matches.length === 0) return 0
  var sum = 0
  for (var i = 0; i < matches.length; i++) sum += toNumber(matches[i].split(":")[1])
  return sum / matches.length
}

function parseLoadAverage(raw) {
  var parts = String(raw || "").trim().split(/\s+/)
  if (parts.length < 3) return null
  return { one: toNumber(parts[0]), five: toNumber(parts[1]), fifteen: toNumber(parts[2]) }
}

// ------------------------------------------------------------------ memory

// MemAvailable is the kernel's own estimate of what a new allocation can get
// without swapping, which is what "used" should be measured against — total
// minus free counts reclaimable page cache as used and always reads ~90%.
// GPUReclaim is the DRM/TTM page pool: idle pages the GPU driver keeps for
// reuse, which a shrinker frees under memory pressure. The kernel leaves it
// out of MemAvailable, so it is added to available and clamped to total.
// Checked on 7.2.15 by rebuilding si_mem_available() from /proc/vmstat and
// /proc/zoneinfo with no GPU term: it matched MemAvailable exactly while the
// pool held ~3 GiB. Re-run that check after a kernel update; a kernel that
// folds the pool into MemAvailable would make this count it twice.
// Each key is anchored at line start so Cached never matches SwapCached. No
// `g` flag: these are shared by every widget instance, and a global regex
// would carry lastIndex from one call into the next.
var MEMINFO = {
  MemTotal: /^MemTotal:\s+(\d+)/m,
  MemAvailable: /^MemAvailable:\s+(\d+)/m,
  MemFree: /^MemFree:\s+(\d+)/m,
  Buffers: /^Buffers:\s+(\d+)/m,
  Cached: /^Cached:\s+(\d+)/m,
  SReclaimable: /^SReclaimable:\s+(\d+)/m,
  GPUReclaim: /^GPUReclaim:\s+(\d+)/m,
  SwapTotal: /^SwapTotal:\s+(\d+)/m,
  SwapFree: /^SwapFree:\s+(\d+)/m
}

function parseMemory(raw) {
  var text = String(raw || "")
  function field(key) {
    var match = text.match(MEMINFO[key])
    return match ? toNumber(match[1]) : 0
  }

  var total = field("MemTotal")
  if (total <= 0) return null
  var available = field("MemAvailable")
  var cached = field("Cached")
  if (available <= 0) available = field("MemFree") + field("Buffers") + cached
  available = Math.min(total, available + field("GPUReclaim"))

  var swapTotal = field("SwapTotal")
  return {
    totalKib: total,
    availableKib: available,
    usedKib: Math.max(0, total - available),
    cachedKib: cached + field("SReclaimable"),
    swapTotalKib: swapTotal,
    swapUsedKib: Math.max(0, swapTotal - field("SwapFree")),
    percent: clamp(100 * (total - available) / total, 0, 100)
  }
}

// ------------------------------------------------------------------ nvidia
//
// nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,
// memory.total,power.draw,clocks.gr --format=csv,noheader,nounits
// Unsupported fields come back as "[N/A]". New fields go at the end, so a
// shorter line from an older query still parses. There is no fan RPM:
// nvidia-smi only reports fan.speed as a percentage of maximum.

function parseNvidia(raw) {
  var line = String(raw || "").trim().split("\n")[0]
  if (!line) return null
  var parts = line.split(",")
  if (parts.length < 4) return null

  function value(index) {
    var text = String(parts[index] || "").trim()
    if (text === "" || text.indexOf("N/A") !== -1) return -1
    // No sensor exceeds 1e9 in its own unit; anything larger (or Infinity
    // after the MiB multiplication) is a malformed reading, not data.
    var n = toNumber(text, -1)
    return isFinite(n) && n <= 1e9 ? n : -1
  }

  return {
    busy: value(0),
    tempC: value(1),
    vramUsedBytes: value(2) >= 0 ? value(2) * 1048576 : -1,
    vramTotalBytes: value(3) >= 0 ? value(3) * 1048576 : -1,
    watts: parts.length > 4 ? value(4) : -1,
    mhz: parts.length > 5 ? value(5) : -1
  }
}

// -------------------------------------------------------------- formatting

function gibFromKib(kib) {
  return kib / KIB_PER_GIB
}

function gibFromBytes(bytes) {
  return bytes / BYTES_PER_GIB
}

// One decimal below 10 GiB, none above: "9.4G" and "62G" both stay narrow,
// and the bar never reflows as memory crosses a rounding boundary. The cut is
// at 9.95, not 10, because toFixed(1) rounds anything above it up to "10.0".
function formatGib(gib) {
  if (!isFinite(gib) || gib < 0) return "–"
  if (gib === 0) return "0"
  if (gib < 9.95) return gib.toFixed(1)
  return String(Math.round(gib))
}

// One decimal always, for the label mode where the figure is the whole point
// and the column is wide enough to carry it.
function formatGibPrecise(gib) {
  if (!isFinite(gib) || gib < 0) return "–"
  return gib.toFixed(1)
}

// formatGib for a figure the kernel reports in KiB.
function formatKib(kib) {
  return formatGib(gibFromKib(kib))
}

// A process's resident memory, with its unit: whole MiB below 1 GiB, where
// one-decimal GiB would print most daemons as "0.0", and GiB above.
function formatMemKib(kib) {
  if (!isFinite(kib) || kib < 0) return "–"
  var mib = Math.round(kib / 1024)
  if (mib < 1024) return mib + " MiB"
  return gibFromKib(kib).toFixed(1) + " GiB"
}

function formatPercent(value) {
  if (!isFinite(value) || value < 0) return "–"
  return Math.round(value) + "%"
}

// Just the figure, for callers that want to choose their own unit marker.
function tempNumber(celsius, fahrenheit) {
  if (!isFinite(celsius) || celsius <= 0) return "–"
  return String(Math.round(fahrenheit ? celsius * 9 / 5 + 32 : celsius))
}

function formatTemp(celsius, fahrenheit) {
  var n = tempNumber(celsius, fahrenheit)
  return n === "–" ? n : n + "°" + (fahrenheit ? "F" : "C")
}

// Just the number, for a bar row where an icon already says what it measures.
// 0 is a real reading: a clock-gated idle GPU reports 0 Hz. Only a missing
// clock (-1) is a dash.
function formatGhzShort(mhz) {
  if (!isFinite(mhz) || mhz < 0) return "–"
  return (mhz / 1000).toFixed(1)
}

function formatGhz(mhz) {
  var n = formatGhzShort(mhz)
  return n === "–" ? n : n + " GHz"
}

function formatWatts(watts) {
  if (!isFinite(watts) || watts < 0) return "–"
  return Math.round(watts) + " W"
}

function formatRpm(rpm) {
  if (!isFinite(rpm) || rpm < 0) return "–"
  return rpm === 0 ? "idle" : Math.round(rpm) + " rpm"
}

// ------------------------------------------------------------ top processes

// Defence in depth: proc_top.py already sanitises everything, but a
// subprocess's stdout is untrusted input, so it is validated again here.
// Always returns {ok, rows, groupedBy}: ok is true only when the payload
// parsed and `procs` was an array (an empty or fully filtered list is still
// ok); any other shape returns ok false and no rows. Keeps at most maxN rows,
// cuts names to 48 chars and clamps numbers to their ranges. The collector's
// order (by the chosen metric) is preserved.
var PROC_TOP_MAX = 12 // proc_top.py TOP_MAX
var PROC_NAME_MAX = 48
var PROC_COUNT_MAX = 16384 // proc_top.py PID_CAP: no group can hold more
var PROC_GROUPEDS = ["none", "scope", "comm"]

// Output caps for the helpers Service.qml spawns, each a GuardedProcess
// byteCap: a run whose stdout or stderr passes its cap is stopped and hands
// its parser no text, so parseProbe, parseNvidia and parseProcTop never see
// more than this. parseProcTop re-checks PROC_TOP_MAX_CHARS itself as well.
// Counted in UTF-16 code units (String.length), not bytes. Untampered output
// is one line of a few KB.
var PROC_TOP_MAX_CHARS = 16384
var HELPER_MAX_CHARS = 65536

function parseProcTop(raw, maxN) {
  var out = { ok: false, rows: [], groupedBy: "none" }
  var limit = maxN === undefined ? PROC_TOP_MAX : Math.max(1, Math.min(PROC_TOP_MAX, toNumber(maxN, PROC_TOP_MAX)))
  var text = String(raw || "").trim()
  if (text === "" || text.length > PROC_TOP_MAX_CHARS) return out
  var parsed = null
  try {
    parsed = JSON.parse(text)
  } catch (e) {
    return out
  }
  if (!parsed || !(parsed.procs instanceof Array)) return out
  out.ok = true
  var rawGroupedBy = parsed.groupedBy
  var groupedBy = (typeof rawGroupedBy === "string" || typeof rawGroupedBy === "number")
    ? String(rawGroupedBy) : "none"
  out.groupedBy = PROC_GROUPEDS.indexOf(groupedBy) === -1 ? "none" : groupedBy
  for (var i = 0; i < parsed.procs.length && out.rows.length < limit; i++) {
    var p = parsed.procs[i]
    if (!p || typeof p !== "object") continue
    var pid = Math.floor(toNumberSafe(p.pid, -1))
    if (pid <= 0 || pid > 4194304) continue
    var rawName = typeof p.name === "string" || typeof p.name === "number"
      ? String(p.name) : ""
    var name = cleanString(rawName.replace(/[\r\n\t]/g, " "), PROC_NAME_MAX)
    if (name === undefined) name = "?"
    var count = Math.floor(toNumberSafe(p.count, 1))
    if (!isFinite(count) || count < 1) count = 1
    if (count > PROC_COUNT_MAX) count = PROC_COUNT_MAX
    var rssKib = Math.floor(toNumberSafe(p.rssKib, -1))
    if (rssKib < 0 || rssKib > 68719476736) continue
    out.rows.push({
      pid: pid,
      name: name,
      count: count,
      cpu: clamp(toNumberSafe(p.cpu, 0), 0, 100),
      rssKib: rssKib,
      memPct: clamp(toNumberSafe(p.memPct, 0), 0, 100)
    })
  }
  return out
}

// ------------------------------------------------------------------ severity
//
// 0 while a reading is unremarkable, ramping to 1 as it crosses from `warn` to
// `critical`. Widget.qml mixes the theme foreground toward urgent by this
// amount, so a busy machine warms up gradually instead of flipping to red.

function severity(value, warn, critical) {
  if (!isFinite(value) || value < 0) return 0
  if (value <= warn) return 0
  return clamp((value - warn) / Math.max(1, critical - warn), 0, 1)
}

// Monospace digits are all the same width, so left-padding a reading to the
// width of its widest realistic value keeps the bar from reflowing every time
// a number gains or loses a digit. Values past that width still render — they
// just push the widget wider, which for 100% or 100°C is rare enough to accept.
function padLeft(text, width) {
  var out = String(text)
  while (out.length < width) out = " " + out
  return out
}
