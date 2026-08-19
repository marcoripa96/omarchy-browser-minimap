import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// A live mirror of whatever agent-browser is looking at, pinned under the bar
// on the focused output. The panel owns no polling of its own: a node bridge
// watches the agent-browser runtime directory and this file only reacts to the
// state lines it prints.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // ------------------------------------------------------------- settings
  // Defaults ship in the manifest; overrides live in this plugin's entry in
  // shell.json. Reading both inside pick() is what makes the bindings below
  // re-evaluate when either side changes.
  readonly property var defaults: manifest && manifest.panel && manifest.panel.defaults ? manifest.panel.defaults : ({})
  readonly property var overrides: {
    var cfg = root.shell ? root.shell.shellConfig : null
    var list = cfg && Array.isArray(cfg.plugins) ? cfg.plugins : []
    for (var i = 0; i < list.length; i++)
      if (list[i] && list[i].id === "io.github.marcoripa96.browser-minimap") return list[i]
    return ({})
  }
  function pick(key, fallback) {
    if (overrides[key] !== undefined) return overrides[key]
    if (defaults[key] !== undefined) return defaults[key]
    return fallback
  }

  readonly property int fps: Math.max(1, Math.min(30, pick("fps", 4)))
  readonly property int compactWidth: Style.space(pick("width", 360))
  readonly property int expandedWidth: Style.space(pick("expandedWidth", 720))
  readonly property bool showCaption: pick("showCaption", true) === true
  readonly property bool clickThrough: pick("clickThrough", false) === true
  readonly property string pinnedMonitor: String(pick("monitor", ""))
  readonly property int idleHideSec: Math.max(0, pick("idleHideSec", 8))
  readonly property int maxVisibleSec: Math.max(0, pick("maxVisibleSec", 45))
  readonly property bool debug: pick("debug", false) === true
  readonly property string onlySession: String(pick("session", ""))

  // Qt hands a QML file its own directory as a file:// URL; the bridge needs a
  // plain path to exec.
  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    if (u.indexOf("file://") === 0) u = u.substring(7)
    while (u.length > 1 && u.charAt(u.length - 1) === "/") u = u.substring(0, u.length - 1)
    return u
  }

  readonly property var targetScreen: {
    var wanted = root.pinnedMonitor
    if (wanted === "") {
      var focused = Hyprland.focusedMonitor
      wanted = focused ? String(focused.name || "") : ""
    }
    var list = Quickshell.screens
    for (var i = 0; i < list.length; i++)
      if (list[i] && String(list[i].name) === wanted) return list[i]
    return list.length > 0 ? list[0] : null
  }

  // ---------------------------------------------------------------- state
  property bool live: false          // a browser session exists and has a tab
  property bool shouldShow: false    // ...and it is worth looking at right now
  property bool present: false       // window mounted (outlives shouldShow by one fade)
  property bool expanded: false
  property bool painting: false      // the page changed in the last moment

  property string pageUrl: ""
  property string pageTitle: ""
  property int sessionCount: 0
  property int viewportW: 1440
  property int viewportH: 900

  property double lastChangeAt: 0    // last time the page actually looked different
  property double shownSince: 0
  property bool dismissed: false

  // Frames are double-buffered. A single Image with cache:false blanks itself
  // while decoding the next file, which at 4fps reads as a flicker; instead the
  // back buffer loads off-screen and only becomes the front once it is Ready.
  property string framePath: ""
  property string pendingPath: ""
  property int frontIndex: 0
  property bool loadingFrame: false
  property bool hasPainted: false

  readonly property int contentWidth: expanded ? expandedWidth : compactWidth
  readonly property real aspect: viewportW > 0 && viewportH > 0 ? viewportH / viewportW : 0.625
  readonly property int shotHeight: Math.round(contentWidth * aspect)
  readonly property int pad: Style.space(8)
  readonly property int headerHeight: showCaption
    ? root.pad + Style.font.caption + Style.font.bodySmall + Math.round(root.pad * 0.4) + root.pad
    : 0

  // ------------------------------------------------------------- presence
  //
  // Dismissal is the hard part of an ambient panel, and there is no single
  // clean signal for "the agent is done". Three rules cover it between them:
  //
  //   1. A page that stops changing is finished being interesting, so the
  //      minimap steps aside after `idleHideSec` of a still viewport. Most
  //      pages go completely quiet — CDP stops sending frames outright — so
  //      this is the rule that fires almost every time.
  //   2. A page that animates forever (a chat console, a spinner, a live
  //      clock) would otherwise pin the minimap up permanently, so
  //      `maxVisibleSec` caps one stretch of visibility regardless.
  //   3. Anything that reads as a fresh action — a navigation, or the first
  //      change after a quiet spell — starts a new stretch and brings it back.
  //
  // Right-click dismisses the current stretch by hand; rule 3 still returns it.
  function evaluate() {
    var now = Date.now()

    if (!root.live) {
      root.shouldShow = false
      return
    }

    var quietFor = root.lastChangeAt > 0 ? now - root.lastChangeAt : 0
    var idle = root.idleHideSec > 0 && root.lastChangeAt > 0 && quietFor > root.idleHideSec * 1000
    var overstayed = root.maxVisibleSec > 0 && root.shownSince > 0
      && (now - root.shownSince) > root.maxVisibleSec * 1000

    root.painting = root.lastChangeAt > 0 && quietFor < 1500
    var next = !root.dismissed && !idle && !overstayed
    if (root.debug && next !== root.shouldShow)
      console.log("minimap: show=" + next + " idle=" + idle + " over=" + overstayed
        + " quietFor=" + Math.round(quietFor) + " shownFor=" + Math.round(now - root.shownSince)
        + " maxVisibleSec=" + root.maxVisibleSec + " idleHideSec=" + root.idleHideSec)
    root.shouldShow = next
  }

  // A fresh action: show again, from the top of the clock.
  function beginStretch() {
    if (root.debug) console.log("minimap: beginStretch " + root.pageUrl)
    root.dismissed = false
    root.shownSince = Date.now()
    evaluate()
  }

  Timer {
    id: tick
    interval: 500
    running: root.live
    repeat: true
    onTriggered: root.evaluate()
  }

  onShouldShowChanged: {
    if (shouldShow) { hideTimer.stop(); present = true }
    else hideTimer.restart()
  }

  Timer {
    id: hideTimer
    interval: 260
    onTriggered: {
      root.present = false
      root.expanded = false
      root.framePath = ""
      root.pendingPath = ""
      root.loadingFrame = false
      root.hasPainted = false
      bufA.source = ""
      bufB.source = ""
    }
  }

  // ---------------------------------------------------------- frame queue
  function queueFrame(pathname) {
    if (pathname === "") return
    if (root.loadingFrame) { root.pendingPath = pathname; return }
    root.loadingFrame = true
    loadWatchdog.restart()
    var back = root.frontIndex === 0 ? bufB : bufA
    // Clearing first guarantees a status transition even when the bridge hands
    // this buffer the same file name it already holds. The back buffer is
    // invisible, so blanking it costs nothing on screen.
    back.source = ""
    back.source = Util.fileUrl(pathname)
  }

  function bufferSettled(index, ok) {
    loadWatchdog.stop()
    root.loadingFrame = false
    if (ok) {
      root.frontIndex = index
      root.hasPainted = true
    }
    if (root.pendingPath !== "") {
      var next = root.pendingPath
      root.pendingPath = ""
      queueFrame(next)
    }
  }

  // A frame file can vanish under a reader if the bridge restarts mid-load.
  // Without this the queue would wedge on loadingFrame forever.
  Timer {
    id: loadWatchdog
    interval: 2000
    onTriggered: root.bufferSettled(root.frontIndex, false)
  }

  // ------------------------------------------------------------ the bridge
  function handleLine(line) {
    var msg
    try { msg = JSON.parse(line) } catch (e) { return }
    if (msg.type !== "state") return

    if (!msg.live) {
      root.live = false
      root.lastChangeAt = 0
      root.shownSince = 0
      root.dismissed = false
      evaluate()
      return
    }

    var wasLive = root.live
    var navigated = msg.url !== undefined && msg.url !== "" && msg.url !== root.pageUrl

    root.pageUrl = msg.url || ""
    root.pageTitle = msg.title || ""
    root.sessionCount = msg.sessions || 1
    if (msg.vw > 0) root.viewportW = msg.vw
    if (msg.vh > 0) root.viewportH = msg.vh
    root.live = true

    if (msg.frame && msg.frame !== root.framePath) {
      // The bridge only sends a frame when the pixels actually differ, so this
      // branch is the page changing, not merely the screencast ticking over.
      var gap = root.lastChangeAt > 0 ? Date.now() - root.lastChangeAt : 0
      var resumed = root.idleHideSec > 0 && gap > root.idleHideSec * 1000
      root.lastChangeAt = Date.now()
      root.framePath = msg.frame
      queueFrame(msg.frame)
      if (!wasLive || resumed) beginStretch()
    }

    if (navigated || !wasLive) beginStretch()
    else evaluate()
  }

  Process {
    id: bridge
    running: true
    command: root.onlySession === ""
      ? [root.pluginDir + "/bridge.sh", root.pluginDir + "/bridge.mjs", "--fps", String(root.fps)]
      : [root.pluginDir + "/bridge.sh", root.pluginDir + "/bridge.mjs", "--fps", String(root.fps),
         "--session", root.onlySession]
    stdout: SplitParser { onRead: line => root.handleLine(line) }
  }

  // Restarting on an fps change is cheaper than teaching the bridge a control
  // channel it would otherwise never use.
  onFpsChanged: restartBridge()
  onOnlySessionChanged: restartBridge()
  function restartBridge() {
    if (!bridge.running) return
    bridge.running = false
    bridge.running = true
  }

  // ------------------------------------------------------------------ view
  PanelWindow {
    id: win
    visible: root.present
    // Follow whichever output Hyprland has focused, so "top right" means the
    // screen being worked on. Pin it by setting `monitor` to an output name.
    screen: root.targetScreen

    anchors { top: true; right: true }
    margins {
      top: Style.space(root.pick("topMargin", 12))
      right: Style.space(root.pick("rightMargin", 12))
    }
    implicitWidth: card.width
    implicitHeight: card.height
    color: "transparent"

    WlrLayershell.namespace: "omarchy-browser-minimap"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Reserve nothing, but sit below anything that does — the bar keeps its
    // strip and the minimap tucks underneath it.
    exclusionMode: ExclusionMode.Normal
    exclusiveZone: 0

    BorderSurface {
      id: card
      width: card.borderLeft + root.contentWidth + card.borderRight
      height: card.borderTop + root.headerHeight + root.shotHeight + card.borderBottom
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      clip: true

      opacity: root.shouldShow ? 1 : 0
      scale: root.shouldShow ? 1 : 0.96
      Behavior on opacity { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
      Behavior on height { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

      Item {
        id: header
        visible: root.showCaption
        height: root.headerHeight
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.borderTop
        anchors.leftMargin: card.borderLeft
        anchors.rightMargin: card.borderRight

        Rectangle {
          id: dot
          width: Style.space(7)
          height: width
          radius: width / 2
          x: root.pad
          y: root.pad + Math.round((Style.font.caption - height) / 2)
          color: root.painting ? Color.accent : Util.alpha(Color.popups.text, 0.35)
          Behavior on color { ColorAnimation { duration: 220 } }
        }

        Column {
          anchors.left: dot.right
          anchors.leftMargin: root.pad
          anchors.right: parent.right
          anchors.rightMargin: root.pad
          anchors.top: parent.top
          anchors.topMargin: root.pad
          spacing: Math.round(root.pad * 0.4)

          Text {
            width: parent.width
            text: root.pageTitle !== "" ? root.pageTitle : "agent-browser"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.popups.text
            elide: Text.ElideRight
            maximumLineCount: 1
          }
          Text {
            width: parent.width
            text: root.sessionCount > 1
              ? root.pageUrl + "  ·  " + root.sessionCount + " sessions"
              : root.pageUrl
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: Util.alpha(Color.popups.text, 0.55)
            // Elide from the left so the tail of a long path — the part that
            // actually says where the agent went — survives.
            elide: Text.ElideLeft
            maximumLineCount: 1
          }
        }
      }

      Item {
        id: viewport
        anchors.top: root.showCaption ? header.bottom : parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: card.borderLeft
        anchors.rightMargin: card.borderRight
        anchors.bottomMargin: card.borderBottom
        anchors.topMargin: root.showCaption ? 0 : card.borderTop
        clip: true

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.popups.text, 0.06)
        }

        // The two halves of the double buffer. Neither caches: the bridge
        // rewrites both file names in place, and a cached decode would freeze
        // the minimap on whichever frame it saw first.
        Image {
          id: bufA
          anchors.fill: parent
          cache: false
          asynchronous: true
          fillMode: Image.PreserveAspectFit
          smooth: true
          mipmap: true
          opacity: root.frontIndex === 0 ? 1 : 0
          onStatusChanged: {
            if (status === Image.Ready) root.bufferSettled(0, true)
            else if (status === Image.Error) root.bufferSettled(root.frontIndex, false)
          }
        }

        Image {
          id: bufB
          anchors.fill: parent
          cache: false
          asynchronous: true
          fillMode: Image.PreserveAspectFit
          smooth: true
          mipmap: true
          opacity: root.frontIndex === 1 ? 1 : 0
          onStatusChanged: {
            if (status === Image.Ready) root.bufferSettled(1, true)
            else if (status === Image.Error) root.bufferSettled(root.frontIndex, false)
          }
        }

        Text {
          anchors.centerIn: parent
          // Only before the very first frame lands. Tying this to live image
          // status would put a label back on screen between every frame.
          visible: !root.hasPainted
          text: "waiting for a frame"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: Util.alpha(Color.popups.text, 0.5)
        }
      }

      MouseArea {
        anchors.fill: parent
        enabled: !root.clickThrough
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: (mouse) => {
          if (mouse.button === Qt.RightButton) { root.dismissed = true; root.evaluate() }
          else root.expanded = !root.expanded
        }
      }
    }

    // A click-through minimap is purely ambient: an empty input region means
    // the compositor routes every pointer event to whatever is underneath.
    mask: root.clickThrough ? emptyRegion : null

    Region { id: emptyRegion }
  }
}
