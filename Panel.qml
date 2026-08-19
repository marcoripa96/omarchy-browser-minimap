import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// The minimap surface. All state and the bridge process live in Service.qml;
// this file is the view, plus the policy for when the view is worth showing.
Item {
  id: root

  readonly property string pluginId: "io.github.marcoripa96.browser-minimap"

  property var shell: null
  property var manifest: null
  // The host assigns this once, in Loader.onLoaded. If the service singleton
  // has not been created by then it assigns null, and being a plain assignment
  // rather than a binding, null is what it stays — leaving the panel inert for
  // the life of the shell. Resolving through the host keeps it a binding, so
  // the panel picks the service up whenever it appears.
  property var service: null
  readonly property var svc: {
    if (root.shell && typeof root.shell.serviceFor === "function") {
      var resolved = root.shell.serviceFor(root.pluginId)
      if (resolved) return resolved
    }
    return root.service
  }

  function setting(key, fallback) {
    return root.svc ? root.svc.setting(key, fallback) : fallback
  }

  readonly property int compactWidth: Style.space(setting("width", 360))
  readonly property int expandedWidth: Style.space(setting("expandedWidth", 720))
  readonly property bool showCaption: setting("showCaption", true) === true
  readonly property bool clickThrough: setting("clickThrough", false) === true
  readonly property string pinnedMonitor: String(setting("monitor", ""))
  readonly property int idleHideSec: Math.max(0, setting("idleHideSec", 8))
  readonly property int maxVisibleSec: Math.max(0, setting("maxVisibleSec", 45))
  readonly property bool debug: setting("debug", false) === true

  readonly property bool live: svc ? svc.live : false
  readonly property bool painting: svc ? svc.painting : false
  readonly property var sessions: svc && svc.sessions ? svc.sessions : []
  readonly property int sessionCount: sessions.length
  readonly property bool showSwitcher: sessionCount > 1

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
  property bool shouldShow: false
  property bool present: false
  property bool expanded: false
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
  readonly property real aspect: svc && svc.viewportW > 0 && svc.viewportH > 0
    ? svc.viewportH / svc.viewportW : 0.625
  readonly property int shotHeight: Math.round(contentWidth * aspect)
  readonly property int pad: Style.space(8)
  readonly property int headerHeight: showCaption
    ? root.pad + Style.font.caption + Style.font.bodySmall + Math.round(root.pad * 0.4) + root.pad
    : 0
  readonly property int switcherHeight: showSwitcher
    ? Math.round(root.pad * 0.75) * 2 + Style.font.caption + Style.space(6)
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
  //   3. Anything that reads as a fresh action — a navigation, a session
  //      switch, or the first change after a quiet spell — starts a new
  //      stretch and brings it back.
  //
  // Right-click dismisses the current stretch by hand; rule 3 still returns it.
  function evaluate() {
    if (!root.live) {
      root.shouldShow = false
      return
    }

    var now = Date.now()
    var changeAt = root.svc ? root.svc.lastChangeAt : 0
    var quietFor = changeAt > 0 ? now - changeAt : 0
    var idle = root.idleHideSec > 0 && changeAt > 0 && quietFor > root.idleHideSec * 1000
    var overstayed = root.maxVisibleSec > 0 && root.shownSince > 0
      && (now - root.shownSince) > root.maxVisibleSec * 1000

    var next = !root.dismissed && !idle && !overstayed
    if (root.debug && next !== root.shouldShow)
      console.log("minimap: show=" + next + " idle=" + idle + " over=" + overstayed
        + " quietFor=" + Math.round(quietFor) + " shownFor=" + Math.round(now - root.shownSince))
    root.shouldShow = next
  }

  // A fresh action: show again, from the top of the clock.
  function beginStretch() {
    if (root.debug) console.log("minimap: beginStretch " + (root.svc ? root.svc.pageUrl : ""))
    root.dismissed = false
    root.shownSince = Date.now()
    evaluate()
  }

  // Driven by this panel's own `live`, not the service's signal. A Connections
  // handler on the service runs before this side's binding has caught up, so
  // it would evaluate against a stale value — and the tick below stops in the
  // same instant, leaving nothing to correct it. That combination kept the
  // window up after the plugin was switched off.
  onLiveChanged: {
    if (live) beginStretch()
    else { shownSince = 0; dismissed = false; evaluate() }
  }

  Timer {
    interval: 500
    // Keeps ticking through the hide transition rather than stopping the
    // instant the session goes away.
    running: root.live || root.present
    repeat: true
    onTriggered: root.evaluate()
  }


  Connections {
    target: root.svc

    // Every visual change the shown session makes.
    function onFramePathChanged() {
      var path = root.svc.framePath
      if (path === "" || path === root.framePath) return
      var gap = root.shownSince > 0 ? Date.now() - root.lastQueuedAt : 0
      root.framePath = path
      root.queueFrame(path)
      if (root.idleHideSec > 0 && root.lastQueuedAt > 0 && gap > root.idleHideSec * 1000)
        root.beginStretch()
      else
        root.evaluate()
      root.lastQueuedAt = Date.now()
    }

    // A navigation, or a deliberate switch to another session, is the clearest
    // "something is happening" signal there is.
    function onPageUrlChanged() { if (root.svc.live) root.beginStretch() }
    function onShownChanged() { if (root.svc.live) root.beginStretch() }
  }

  property double lastQueuedAt: 0

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

  // ------------------------------------------------------------------ view
  PanelWindow {
    id: win
    visible: root.present
    // Follow whichever output Hyprland has focused, so "top right" means the
    // screen being worked on. Pin it by setting `monitor` to an output name.
    screen: root.targetScreen

    anchors { top: true; right: true }
    margins {
      top: Style.space(root.setting("topMargin", 12))
      right: Style.space(root.setting("rightMargin", 12))
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
      height: card.borderTop + root.headerHeight + root.shotHeight + root.switcherHeight + card.borderBottom
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
            text: root.svc && root.svc.pageTitle !== "" ? root.svc.pageTitle : "agent-browser"
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            color: Color.popups.text
            elide: Text.ElideRight
            maximumLineCount: 1
          }
          Text {
            width: parent.width
            text: root.svc ? root.svc.pageUrl : ""
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
        anchors.leftMargin: card.borderLeft
        anchors.rightMargin: card.borderRight
        anchors.topMargin: root.showCaption ? 0 : card.borderTop
        height: root.shotHeight
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

      // One chip per live session, only once there is a choice to make. The
      // shown session is filled in; an outline on it means the bridge picked it
      // automatically and will keep re-picking as sessions get busy.
      Item {
        id: switcher
        visible: root.showSwitcher
        height: root.switcherHeight
        anchors.top: viewport.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: card.borderLeft
        anchors.rightMargin: card.borderRight

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.popups.text, 0.05)
        }

        Row {
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          anchors.leftMargin: root.pad
          anchors.rightMargin: root.pad
          spacing: Math.round(root.pad * 0.5)

          Repeater {
            // No point building chips for a switcher that is not on screen.
            model: root.showSwitcher ? root.sessions : []

            Rectangle {
              id: chip
              required property var modelData
              readonly property bool isShown: root.svc && modelData.name === root.svc.shown
              readonly property bool isPinned: root.svc && modelData.name === root.svc.selected

              height: Style.font.caption + Style.space(6)
              width: Math.min(chipLabel.implicitWidth + chipDot.width + Style.space(14),
                              Math.round(switcher.width / Math.max(1, root.sessionCount)) - root.pad)
              radius: Math.max(2, Style.cornerRadius)
              color: chip.isShown ? Util.alpha(Color.accent, 0.22) : Util.alpha(Color.popups.text, 0.07)
              border.width: chip.isPinned ? Math.max(1, Style.space(1)) : 0
              border.color: Color.accent

              Rectangle {
                id: chipDot
                width: Style.space(5)
                height: width
                radius: width / 2
                anchors.left: parent.left
                anchors.leftMargin: Style.space(5)
                anchors.verticalCenter: parent.verticalCenter
                color: chip.modelData.painting ? Color.accent : Util.alpha(Color.popups.text, 0.3)
                Behavior on color { ColorAnimation { duration: 220 } }
              }

              Text {
                id: chipLabel
                anchors.left: chipDot.right
                anchors.leftMargin: Style.space(4)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(5)
                anchors.verticalCenter: parent.verticalCenter
                text: chip.modelData.name
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: chip.isShown ? Color.popups.text : Util.alpha(Color.popups.text, 0.6)
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              MouseArea {
                anchors.fill: parent
                enabled: !root.clickThrough
                cursorShape: Qt.PointingHandCursor
                // Clicking the session already pinned releases it back to
                // automatic, so one control both pins and unpins.
                onClicked: {
                  if (!root.svc) return
                  if (chip.isPinned) root.svc.clearSelection()
                  else root.svc.select(chip.modelData.name)
                }
              }
            }
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        // Sits under the chips: the switcher's own areas take their clicks
        // first, and everything else toggles size or dismisses.
        z: -1
        enabled: !root.clickThrough
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onClicked: (mouse) => {
          if (mouse.button === Qt.RightButton) { root.dismissed = true; root.evaluate() }
          else if (mouse.button === Qt.MiddleButton) { if (root.svc) root.svc.cycle() }
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
