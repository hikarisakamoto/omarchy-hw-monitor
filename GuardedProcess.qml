import QtQuick
import Quickshell.Io

// One helper process plus the guards every helper Service.qml spawns needs:
//
// - a watchdog that sends SIGTERM once a run outlives timeoutMs;
// - a kill timer that escalates to SIGKILL killMs after the first SIGTERM,
//   for a helper that ignores it. It stays armed until the process exits, so
//   a helper that finishes its output and then hangs is still killed;
// - a byte guard that ends a run once its stdout or stderr passes byteCap.
//   StdioCollector never emits the parser's read signal, so the cap is
//   enforced by polling the collected length from a short repeat Timer
//   (verified on Quickshell 0.3.1: a 64 MB spewer is stopped within one
//   polling interval). Untampered output is one line of at most a few KB, so
//   crossing the cap always means a runaway or tampered helper.
//
// StdioCollector.text still holds the PREVIOUS run's output until this run
// writes its first byte, so the byte guard measures stdout against the length
// recorded at spawn: without that baseline a slow-first-byte run would be
// killed for the last run's size. stderr counts toward the cap too.
Item {
  id: guard

  property int timeoutMs: 2000
  property int killMs: 2000
  property int byteCap: 65536

  readonly property bool running: proc.running

  // Stdout closed; `text` is what the collector holds.
  signal finished(string text)
  // The watchdog fired and the run is being terminated.
  signal timedOut()
  // The process exited; its watchdog and kill timer are already disarmed.
  signal exited()

  // Teardown veto: once set, no timer or handler touches anything again.
  property bool _destroyed: false
  property int _base: 0

  // Start a run unless one is still in flight. Returns whether it started.
  function spawn(command) {
    if (_destroyed || proc.running) return false
    proc.command = command
    _base = String(out.text).length
    watchdog.restart()
    proc.running = true
    return true
  }

  // SIGTERM now; SIGKILL killMs after the FIRST request if it is still alive.
  // `running` stays true until the process actually exits, so the byte guard
  // asks again every poll: restarting the kill timer each time would push
  // SIGKILL back forever for a spewer that ignores SIGTERM.
  function terminate() {
    if (proc.running) proc.running = false
    if (!killTimer.running) killTimer.start()
  }

  // Raise the veto and stop the run. The owner calls this from its own
  // Component.onDestruction so no in-flight callback runs during teardown.
  function shutdown() {
    _destroyed = true
    watchdog.stop()
    killTimer.stop()
    if (proc.running) proc.running = false
  }

  Component.onDestruction: shutdown()

  Process {
    id: proc
    stdout: StdioCollector {
      id: out
      waitForEnd: false
      onStreamFinished: if (!guard._destroyed) guard.finished(text)
    }
    stderr: StdioCollector {
      id: err
      waitForEnd: false
    }
    onExited: {
      if (guard._destroyed) return
      watchdog.stop()
      killTimer.stop()
      guard.exited()
    }
  }

  Timer {
    id: watchdog
    interval: guard.timeoutMs
    repeat: false
    onTriggered: {
      if (guard._destroyed) return
      guard.terminate()
      guard.timedOut()
    }
  }

  Timer {
    id: killTimer
    interval: guard.killMs
    repeat: false
    onTriggered: {
      if (guard._destroyed) return
      if (proc.running) proc.signal(9)
    }
  }

  // The running binding stops the guard when the process ends, so a guard
  // never outlives its run.
  Timer {
    interval: 100
    repeat: true
    running: proc.running
    onTriggered: {
      if (guard._destroyed) return
      var len = String(out.text).length
      var errLen = String(err.text).length
      if ((len !== guard._base && len > guard.byteCap) || errLen > guard.byteCap) guard.terminate()
    }
  }
}
