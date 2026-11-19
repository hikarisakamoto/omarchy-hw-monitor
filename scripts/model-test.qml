// Behaviour checks for Model.js's pure parsers and formatters, run by
// scripts/check.sh as `qml -a core scripts/model-test.qml` (no display needed).
// -a core has no colour provider, so nothing here may touch Qt.rgba: colour
// blending (mixColor) is left to manual testing in a running bar.
// Each mismatch logs a FAIL line to stderr; the exit code is the verdict.
import QtQml
import "../Model.js" as Model

QtObject {
  id: test
  property int fails: 0

  function eq(got, want, what) {
    var g = JSON.stringify(got), w = JSON.stringify(want)
    if (g === w) return
    test.fails++
    console.error("FAIL " + what + ": got " + g + ", want " + w)
  }

  Component.onCompleted: {
    try {
      // Formatting and coercion.
      eq(Model.formatGib(9.94), "9.9", "formatGib below the boundary")
      eq(Model.formatGib(9.96), "10", "formatGib boundary")
      eq(Model.toNumber("", -1), -1, "toNumber blank is missing")
      eq(Model.toNumber(" 42 ", -1), 42, "toNumber trims")
      eq(Model.boolSetting("off", true), false, "boolSetting off")
      eq(Model.intSetting("99", 6, 3, 12), 12, "intSetting clamps")
      eq(Model.enumSetting(" CPU ", ["ram", "cpu"], "ram"), "cpu", "enumSetting normalises")
      eq(Model.enumSetting("gpu", ["ram", "cpu"], "ram"), "ram", "enumSetting falls back")

      // Probe output and GPU choice.
      var gpus = [{ card: "card10", name: "A" }, { card: "card1", name: "B" }]
      eq(Model.pickGpu(gpus, "card1").name, "B", "pickGpu exact card beats substring")
      eq(Model.pickGpu(gpus, "0").name, "A", "pickGpu number is a position")
      eq(Model.pickGpu(Model.parseProbe("").gpus, "card1"), null, "pickGpu with no cards")
      eq(Model.parseProbe("not json").cpu.threads, 0, "parseProbe invalid JSON")
      eq(Model.safePath("/sys/class/hwmon/hwmon3/temp1_input"), "/sys/class/hwmon/hwmon3/temp1_input",
         "safePath accepts an hwmon file")
      eq(Model.safePath("/sys/class/hwmon/hwmon3/../../../etc/passwd"), undefined, "safePath rejects traversal")
      eq(Model.safePath("/proc/self/root/etc/passwd"), undefined, "safePath rejects /proc")

      // CPU load from /proc/stat jiffies.
      var prev = { total: 1000, idle: 800 }
      eq(Model.cpuUsage(prev, { total: 1200, idle: 850 }, 10), 75, "cpuUsage")
      eq(Model.cpuUsage(prev, { total: 1003, idle: 801 }, 10), -1, "cpuUsage window under minDelta")

      // Memory: Cached must not match SwapCached.
      var mem = Model.parseMemory("MemTotal: 1000 kB\nMemFree: 100 kB\nMemAvailable: 400 kB\n"
                                  + "SwapCached: 999 kB\nCached: 200 kB\nSReclaimable: 50 kB\n"
                                  + "SwapTotal: 300 kB\nSwapFree: 100 kB\n")
      eq([mem.usedKib, mem.cachedKib, mem.swapUsedKib, mem.percent], [600, 250, 200, 60], "parseMemory")
      eq(Model.parseMemory(""), null, "parseMemory empty")

      // nvidia-smi CSV.
      eq(Model.parseNvidia("45, 61, 1024, 8192, 120.5, 1800\n"),
         { busy: 45, tempC: 61, vramUsedBytes: 1073741824, vramTotalBytes: 8589934592, watts: 120.5, mhz: 1800 },
         "parseNvidia full line")
      var nv = Model.parseNvidia("[N/A], 50, 1, 2")
      eq([nv.busy, nv.tempC, nv.watts, nv.mhz], [-1, 50, -1, -1], "parseNvidia N/A and short line")
      eq(Model.parseNvidia("garbage"), null, "parseNvidia garbage")

      // proc_top.py JSON: a row with a blank rssKib is dropped, not shown as 0.
      var top = Model.parseProcTop('{"groupedBy": "comm", "procs": [{"pid": 1, "name": "a", "rssKib": 10},'
                                   + ' {"pid": 2, "name": "b", "rssKib": ""}, {"pid": 3, "name": "c", "rssKib": 20}]}')
      eq([top.ok, top.groupedBy, top.rows.map(function (r) { return r.pid })], [true, "comm", [1, 3]],
         "parseProcTop drops a blank rssKib row")
      eq(Model.parseProcTop("nope").ok, false, "parseProcTop invalid JSON")
    } catch (e) {
      test.fails++
      console.error("FAIL uncaught: " + e)
    } finally {
      Qt.exit(test.fails ? 1 : 0)
    }
  }
}
