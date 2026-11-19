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
// A StdioCollector's text still holds the PREVIOUS run's output until this
// run writes its first byte to that stream (verified on Quickshell 0.3.2, for
// a run that writes nothing and for one killed first). So each stream has a
// per-run fresh flag, set by its dataChanged: the byte guard counts a stream
// only once this run has written to it (otherwise one oversized run, on
// stdout or stderr, would get every later quiet run killed for its size), and
// `finished` hands a run that wrote nothing "" rather than replaying the last
// run's output as if it were new.
Item {
  id: guard

  property int timeoutMs: 2000
  property int killMs: 2000
  property int byteCap: 65536

  readonly property bool running: proc.running

  // Stdout closed; `text` is this run's output, or "" if it wrote none.
  signal finished(string text)
  // The watchdog fired and the run is being terminated.
  signal timedOut()
  // The process exited; its watchdog and kill timer are already disarmed.
  signal exited()

  // Teardown veto: once set, no timer or handler touches anything again.
  property bool _destroyed: false
  // Whether this run has written to stdout / stderr; dataChanged fires only
  // for the current run's bytes.
  property bool _fresh: false
  property bool _errFresh: false

  // Start a run unless one is still in flight. Returns whether it started.
  function spawn(command) {
    if (_destroyed || proc.running) return false
    proc.command = command
    _fresh = false
    _errFresh = false
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
      onDataChanged: guard._fresh = true
      onStreamFinished: if (!guard._destroyed) guard.finished(guard._fresh ? text : "")
    }
    stderr: StdioCollector {
      id: err
      waitForEnd: false
      onDataChanged: guard._errFresh = true
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
      if ((guard._fresh && String(out.text).length > guard.byteCap)
          || (guard._errFresh && String(err.text).length > guard.byteCap)) guard.terminate()
    }
  }
}
