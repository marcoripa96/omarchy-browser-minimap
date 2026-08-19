import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

// Headless singleton that owns the bridge process and everything derived from
// it. The panel renders this; the bar widget toggles and reflects it. Keeping
// the process here means one bridge per shell no matter how many surfaces are
// looking at it, and it stops dead when the widget turns the plugin off.
QtObject {
  id: root

  readonly property string pluginId: "io.github.marcoripa96.browser-minimap"

  property var shell: null
  property var manifest: null

  // ------------------------------------------------------------- settings
  // Defaults ship in the manifest. Overrides live in the plugin's bar-layout
  // entry when the widget is on the bar, and in its `plugins[]` entry
  // otherwise — the same precedence shell.updateEntryInline writes with, so a
  // setting is always read back from where it was saved.
  // barWidget.defaults is canonical — it is the block the bar settings UI
  // reads — with the panel block as the fallback when the widget is not on the
  // bar at all.
  readonly property var defaults: {
    if (manifest && manifest.barWidget && manifest.barWidget.defaults) return manifest.barWidget.defaults
    if (manifest && manifest.panel && manifest.panel.defaults) return manifest.panel.defaults
    return ({})
  }

  readonly property var overrides: {
    var cfg = root.shell ? root.shell.shellConfig : null
    if (!cfg) return ({})

    var layout = cfg.bar && cfg.bar.layout ? cfg.bar.layout : null
    var sections = ["left", "center", "right"]
    for (var s = 0; s < sections.length; s++) {
      var list = layout && Array.isArray(layout[sections[s]]) ? layout[sections[s]] : []
      for (var i = 0; i < list.length; i++)
        if (list[i] && list[i].id === root.pluginId) return list[i]
    }

    var plugins = Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var p = 0; p < plugins.length; p++)
      if (plugins[p] && plugins[p].id === root.pluginId) return plugins[p]

    return ({})
  }

  function setting(key, fallback) {
    if (overrides[key] !== undefined && overrides[key] !== null) return overrides[key]
    if (defaults[key] !== undefined && defaults[key] !== null) return defaults[key]
    return fallback
  }

  function persist(key, value) {
    if (!root.shell || typeof root.shell.updateEntryInline !== "function") return
    var next = ({})
    for (var k in overrides) next[k] = overrides[k]
    next[key] = value
    root.shell.updateEntryInline(root.pluginId, next)
  }

  readonly property bool enabled: setting("enabled", true) === true
  readonly property int fps: Math.max(1, Math.min(30, setting("fps", 4)))
  readonly property string onlySession: String(setting("session", ""))
  readonly property bool trackPointer: setting("showPointer", true) === true

  function setEnabled(value) { persist("enabled", value === true) }
  function toggle() { setEnabled(!root.enabled) }

  // ---------------------------------------------------------------- state
  property bool live: false
  property string shown: ""
  property bool auto: true
  property var sessions: []
  // The bridge reports the session list on every frame. Reassigning it each
  // time would rebuild the panel's chip delegates several times a second for
  // no reason, so only a real change propagates.
  property string sessionsSignature: ""
  property string pageUrl: ""
  property string pageTitle: ""
  property string framePath: ""
  property int seq: 0
  property int viewportW: 1440
  property int viewportH: 900
  property double lastChangeAt: 0
  property bool painting: false

  readonly property int sessionCount: sessions ? sessions.length : 0

  // Which size the card is at. Lives here rather than in the panel so it can
  // be driven from a keybinding as well as a click.
  property bool expanded: false
  function toggleExpanded() { root.expanded = !root.expanded }

  // Selection is deliberately not persisted: pinning a session by hand is a
  // "look at this one now" gesture, and a session name from an hour ago is
  // meaningless after a restart. `session` in settings is the durable pin.
  property string selected: ""

  function select(name) {
    var next = String(name || "")
    if (next === root.selected) return
    root.selected = next
    sendSelection()
  }

  function clearSelection() { select("") }

  function cycle() {
    if (root.sessionCount < 2) return
    // Walk names in the order the bridge reports them, then wrap around to
    // automatic rather than looping the pins forever — otherwise there is no
    // way back to "follow whatever is busy" without opening the panel.
    var names = []
    for (var i = 0; i < root.sessionCount; i++) names.push(root.sessions[i].name)
    if (root.selected === "") { select(names[0]); return }
    var at = names.indexOf(root.selected)
    if (at === -1 || at === names.length - 1) select("")
    else select(names[at + 1])
  }

  function sendSelection() {
    if (!bridge.running) return
    try { bridge.write(JSON.stringify({ select: root.selected }) + "\n") } catch (e) {}
  }

  // One agent action. `action` is the raw command name, so surfaces can react
  // to particular ones; `label` is the human phrasing. `x`/`y` are viewport
  // pixels and only present for raw pointer commands, and hasPoint says
  // whether they mean anything.
  signal actionOccurred(string action, string label, real x, real y, bool hasPoint)

  // Where on the page the agent just acted, in viewport pixels. Raw pointer
  // commands carry this; for everything else the bridge resolves the target's
  // box, when it can.
  signal pointerMoved(real x, real y)

  function handleLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }

    if (msg.type === "point") {
      if (msg.session !== root.shown) return
      pointerMoved(msg.x, msg.y)
      return
    }

    if (msg.type === "action") {
      // Actions from a session you are not watching would be unreadable
      // without saying which session they came from, and the rail already
      // shows those sessions are busy.
      if (msg.session !== root.shown) return
      var hasPoint = msg.x !== undefined && msg.y !== undefined
      actionOccurred(msg.action || "", msg.label || msg.action, hasPoint ? msg.x : 0, hasPoint ? msg.y : 0, hasPoint)
      return
    }

    if (msg.type !== "state") return

    var incoming = Array.isArray(msg.sessions) ? msg.sessions : []
    var signature = JSON.stringify(incoming)
    if (signature !== root.sessionsSignature) {
      root.sessionsSignature = signature
      root.sessions = incoming
    }
    root.auto = msg.auto !== false

    if (!msg.live) {
      root.live = false
      root.shown = ""
      root.lastChangeAt = 0
      root.painting = false
      return
    }

    root.shown = msg.shown || ""
    root.pageUrl = msg.url || ""
    root.pageTitle = msg.title || ""
    if (msg.vw > 0) root.viewportW = msg.vw
    if (msg.vh > 0) root.viewportH = msg.vh

    if (msg.frame && msg.frame !== root.framePath) {
      root.framePath = msg.frame
      root.seq = msg.seq || 0
      root.lastChangeAt = Date.now()
    }

    // A pinned session that went away silently falls back to automatic, so the
    // panel never sits blank waiting for a browser that is gone.
    if (root.selected !== "" && msg.pinnedMissing === true) root.selected = ""

    root.live = true
  }

  property Timer paintTick: Timer {
    interval: 500
    running: root.live
    repeat: true
    onTriggered: root.painting = root.lastChangeAt > 0 && (Date.now() - root.lastChangeAt) < 1500
  }

  // Bindable from hyprland.conf, e.g.
  //   bind = SUPER, B, exec, omarchy-shell io.github.marcoripa96.browser-minimap toggle
  property IpcHandler ipc: IpcHandler {
    target: "io.github.marcoripa96.browser-minimap"

    function toggle(): string { root.toggle(); return root.enabled ? "on" : "off" }
    function enable(): string { root.setEnabled(true); return "on" }
    function disable(): string { root.setEnabled(false); return "off" }
    function cycle(): string { root.cycle(); return root.selected === "" ? "auto" : root.selected }
    function select(name: string): string {
      root.select(name)
      return root.selected === "" ? "auto" : root.selected
    }
    function auto(): string { root.clearSelection(); return "auto" }
    function expand(): string { root.expanded = true; return "expanded" }
    function collapse(): string { root.expanded = false; return "compact" }
    function size(): string { root.toggleExpanded(); return root.expanded ? "expanded" : "compact" }
    function status(): string {
      var names = []
      for (var i = 0; i < root.sessionCount; i++) names.push(root.sessions[i].name)
      return JSON.stringify({
        enabled: root.enabled,
        live: root.live,
        shown: root.shown,
        pinned: root.selected,
        painting: root.painting,
        sessions: names,
      })
    }
  }

  // Qt hands a QML file its own directory as a file:// URL; the bridge needs a
  // plain path to exec.
  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    if (u.indexOf("file://") === 0) u = u.substring(7)
    while (u.length > 1 && u.charAt(u.length - 1) === "/") u = u.substring(0, u.length - 1)
    return u
  }

  // Blinked by restartBridge(). Restarting must go through a binding
  // dependency, never a write to bridge.running: an imperative assignment
  // would sever the running binding for good, leaving the process deaf to
  // `enabled` from the first settings change onward.
  property bool bridgeRestarting: false

  property Process bridge: Process {
    id: bridgeProc
    // Off means off: the node process exits, its WebSocket connections close,
    // and agent-browser stops encoding frames for a client that is not there.
    // Waiting for the host to arrive avoids spawning a bridge against default
    // settings and killing it a frame later once the real config lands.
    running: !root.bridgeRestarting && root.enabled && root.shell !== null
    stdinEnabled: true
    command: {
      var argv = [root.pluginDir + "/bridge.sh", root.pluginDir + "/bridge.mjs", "--fps", String(root.fps)]
      if (root.onlySession !== "") argv.push("--session", root.onlySession)
      if (root.trackPointer) argv.push("--track")
      return argv
    }
    stdout: SplitParser { onRead: line => root.handleLine(line) }
    onRunningChanged: {
      if (running) root.sendSelection()
      else {
        root.live = false
        root.sessions = []
        root.sessionsSignature = ""
        root.shown = ""
        root.framePath = ""
        root.painting = false
        root.lastChangeAt = 0
      }
    }
  }

  // Restarting on a settings change is cheaper than teaching the bridge a
  // control channel for values it reads once at startup.
  onFpsChanged: restartBridge()
  onOnlySessionChanged: restartBridge()
  onTrackPointerChanged: restartBridge()
  function restartBridge() {
    if (!bridge.running) return
    // Each assignment re-evaluates the running binding synchronously, so this
    // is stop-then-start with the binding still intact afterwards.
    root.bridgeRestarting = true
    root.bridgeRestarting = false
  }
}
