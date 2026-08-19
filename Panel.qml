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
  readonly property bool showActions: setting("showActions", true) === true
  readonly property int actionTtlSec: Math.max(1, setting("actionTtlSec", 4))
  readonly property int maxActions: Math.max(1, setting("maxActions", 4))
  readonly property bool showPointer: setting("showPointer", true) === true
  readonly property int trailMs: Math.max(120, setting("pointerTrailMs", 700))
  readonly property int glideMs: Math.max(0, setting("pointerGlideMs", 380))
  // Deliberately not the theme accent. The marker sits on top of arbitrary web
  // pages rather than on the shell's own surfaces, so it wants a colour that
  // stays legible over a white page and a dark one alike, and that no site is
  // likely to be using for its own chrome.
  readonly property color pointerColor: setting("pointerColor", "#ffc83d")

  // The host and the route are two different questions — which site is this,
  // and where in it — so they get separate places rather than one long string
  // where both are buried.
  readonly property string pageHost: {
    var url = root.svc ? root.svc.pageUrl : ""
    var rest = url.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "")
    var cut = rest.search(/[\/?#]/)
    return cut === -1 ? rest : rest.substring(0, cut)
  }
  readonly property string pagePath: {
    var url = root.svc ? root.svc.pageUrl : ""
    // No page means no route; a bare "/" under an empty title reads as a bug.
    if (url === "") return ""
    var rest = url.replace(/^[a-z][a-z0-9+.-]*:\/\//i, "")
    var cut = rest.search(/[\/?#]/)
    if (cut === -1) return "/"
    var tail = rest.substring(cut)
    return tail === "" ? "/" : tail
  }

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
  readonly property bool expanded: svc ? svc.expanded : false
  property double shownSince: 0
  property bool dismissed: false

  // Frames are double-buffered. A single Image with cache:false blanks itself
  // while decoding the next file, which at 4fps reads as a flicker; instead the
  // back buffer loads off-screen and only becomes the front once it is Ready.
  // Drives the age-out of the action feed. Updated by the same tick that
  // evaluates presence rather than a timer of its own.
  property double nowTick: 0

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
  readonly property int headerGap: Math.round(root.pad * 0.4)
  // Measured from the fonts, not guessed from their pixel sizes. A rendered
  // line box is several pixels taller than the size it was asked for, and
  // reserving the smaller number let the two lines grow into the bottom
  // padding until the route sat flush against the mirror.
  readonly property int headerHeight: showCaption
    ? root.pad + Math.ceil(titleMetrics.height) + root.headerGap
      + Math.ceil(routeMetrics.height) + root.pad
    : 0

  FontMetrics {
    id: titleMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.caption
  }
  FontMetrics {
    id: routeMetrics
    font.family: Style.font.family
    font.pixelSize: Style.font.bodySmall
  }
  // The rail is extra width rather than a slice out of the mirror: the whole
  // point of the panel is the page, so it keeps the size it was asked for and
  // the card grows to hold the list.
  readonly property int railWidth: showSwitcher ? Style.space(setting("railWidth", 132)) : 0
  readonly property int rowHeight: Style.font.caption + Style.space(11)

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
    onTriggered: {
      root.nowTick = Date.now()
      root.pruneActions()
      root.evaluate()
    }
  }


  Connections {
    target: root.svc

    // Every visual change the shown session makes.
    function onFramePathChanged() {
      var path = root.svc.framePath
      // Empty means the shown session has never painted: show nothing rather
      // than leave the previous session's page under this one's title.
      if (path === "") {
        root.framePath = ""
        root.pendingPath = ""
        root.hasPainted = false
        root.frontIndex = 0
        bufA.source = ""
        bufB.source = ""
        return
      }
      if (path === root.framePath) return
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
    function onShownChanged() {
      // No blanking here. The bridge rewrites the incoming session's picture
      // before announcing the switch, so the mirror changes over in one step;
      // clearing on every shown change would blink the panel every time the
      // automatic pick moved between two busy sessions.
      actionModel.clear()
      if (root.svc.live) root.beginStretch()
    }
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
      if (root.svc) root.svc.expanded = false
      root.framePath = ""
      root.pendingPath = ""
      root.loadingFrame = false
      root.hasPainted = false
      actionModel.clear()
      bufA.source = ""
      bufB.source = ""
    }
  }

  // ------------------------------------------------------------ action feed
  ListModel { id: actionModel }

  Connections {
    target: root.svc

    function onPointerMoved(x, y) {
      if (root.showPointer) pointerLayer.moveTo(x, y)
    }

    function onActionOccurred(action, label, x, y, hasPoint) {
      // The shutter fires whether or not the feed is switched on: it is the
      // one action with a natural visual, and it says the agent took something
      // away with it.
      if (action === "screenshot" || action === "pdf") shutter.fire()
      if (!root.showActions) return
      root.nowTick = Date.now()
      actionModel.append({ label: label, born: root.nowTick })
      while (actionModel.count > root.maxActions) actionModel.remove(0)
      // Acting on a page is the clearest statement that the agent is working,
      // and it can happen before the page repaints — a click that opens a menu
      // three frames later would otherwise miss the panel entirely.
      root.beginStretch()
    }
  }

  function pruneActions() {
    var cutoff = root.nowTick - (root.actionTtlSec * 1000 + 400)
    while (actionModel.count > 0 && actionModel.get(0).born < cutoff) actionModel.remove(0)
  }

  // ---------------------------------------------------------- frame queue

  // Adopt whatever the service is already holding. The handlers below only
  // fire on change, so a panel that attaches after the frame arrived — on a
  // hot reload, or when the service outlives a panel reload — would otherwise
  // sit on "waiting for a frame" until the page next repainted, which for a
  // static page is never. The same applies when the panel comes back after
  // hiding, since hiding drops the decoded buffers.
  function syncFromService() {
    if (!root.svc) return
    var path = root.svc.framePath
    if (path !== "" && path !== root.framePath) {
      root.framePath = path
      queueFrame(path)
    }
    evaluate()
  }

  onSvcChanged: syncFromService()
  onPresentChanged: if (present) syncFromService()
  Component.onCompleted: syncFromService()

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
    // Sized to the largest the card can get, and left there. Binding the
    // surface to the animating card resized the Wayland surface on every
    // frame, and Hyprland animates layer resizes itself (layersIn/layersOut),
    // so each of those frames started its own compositor animation. The result
    // was two animation systems fighting over one rectangle. The surface now
    // changes size only when the geometry genuinely changes — a rail
    // appearing, a different viewport aspect — and the expand/collapse happens
    // entirely inside it, on the scene graph, where it is smooth.
    implicitWidth: card.borderLeft + root.railWidth + root.expandedWidth + card.borderRight
    implicitHeight: card.borderTop + root.headerHeight
      + Math.round(root.expandedWidth * root.aspect) + card.borderBottom
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
      // The panel is anchored to the top right, so the card grows down and to
      // the left out of that corner rather than from its own centre.
      anchors.top: parent.top
      anchors.right: parent.right
      transformOrigin: Item.TopRight
      width: card.borderLeft + root.railWidth + root.contentWidth + card.borderRight
      height: card.borderTop + root.headerHeight + root.shotHeight + card.borderBottom
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      clip: true

      opacity: root.shouldShow ? 1 : 0
      scale: root.shouldShow ? 1 : 0.97
      Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }
      Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutQuint } }
      // Width and height must share a curve and a duration, or the box skews
      // its way to the new size instead of growing.
      Behavior on width { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }
      Behavior on height { NumberAnimation { duration: 260; easing.type: Easing.OutQuint } }

      Item {
        id: header
        visible: root.showCaption
        height: root.headerHeight
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.topMargin: card.borderTop
        anchors.leftMargin: card.borderLeft + root.railWidth
        anchors.rightMargin: card.borderRight

        // A recording light: red and breathing while the page is changing,
        // dark and still when it is not.
        Rectangle {
          id: dot
          width: Style.space(8)
          height: width
          radius: width / 2
          x: root.pad
          // Centred on the title's rendered line box, not on the font's pixel
          // size — a line box is taller than its glyphs, so measuring against
          // pixelSize parks the light above the text it belongs to. Anchors
          // cannot reach across into the Column, but a binding can.
          y: headerText.y + titleRow.y + titleLine.y + Math.round((titleLine.height - height) / 2)
          color: root.painting ? Color.urgent : Util.alpha(Color.popups.text, 0.3)
          Behavior on color { ColorAnimation { duration: 220 } }

          SequentialAnimation {
            running: root.painting
            loops: Animation.Infinite
            NumberAnimation { target: dot; property: "opacity"; to: 0.35; duration: 850; easing.type: Easing.InOutSine }
            NumberAnimation { target: dot; property: "opacity"; to: 1.0; duration: 850; easing.type: Easing.InOutSine }
            // The animation owns opacity while it runs, so hand it back rather
            // than leaving the light stuck at whatever point it stopped on.
            onStopped: dot.opacity = 1
          }
        }

        Column {
          id: headerText
          anchors.left: dot.right
          anchors.leftMargin: root.pad
          anchors.right: parent.right
          anchors.rightMargin: root.pad
          anchors.top: parent.top
          anchors.topMargin: root.pad
          spacing: root.headerGap

          Item {
            id: titleRow
            width: parent.width
            height: titleLine.height

            // The host is short and identifying, so it keeps its width and the
            // title yields — but it is capped, because a long subdomain should
            // not eat the whole line either.
            Text {
              id: domainLine
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, titleRow.width * 0.5)
              text: root.pageHost
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: Util.alpha(Color.popups.text, 0.7)
              horizontalAlignment: Text.AlignRight
              elide: Text.ElideRight
              maximumLineCount: 1
            }

            Text {
              id: titleLine
              anchors.left: parent.left
              anchors.right: domainLine.left
              anchors.rightMargin: root.pageHost === "" ? 0 : Style.space(8)
              text: root.svc && root.svc.pageTitle !== "" ? root.svc.pageTitle : "agent-browser"
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              color: Color.popups.text
              elide: Text.ElideRight
              maximumLineCount: 1
            }
          }

          Text {
            width: parent.width
            text: root.pagePath
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            color: Util.alpha(Color.popups.text, 0.55)
            // Elide from the left so the tail of a long route — the part that
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
        anchors.leftMargin: card.borderLeft + root.railWidth
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

        // A screenshot leaves no trace in the frames themselves — the page
        // looks identical before and after — so it gets the one visual the
        // action deserves.
        Rectangle {
          id: shutter
          anchors.fill: parent
          color: "white"
          opacity: 0
          visible: opacity > 0

          function fire() { shutterFlash.restart() }

          SequentialAnimation {
            id: shutterFlash
            // Fast in, slow out: the shape of a real shutter, and it reads as
            // a flash rather than a flicker.
            NumberAnimation { target: shutter; property: "opacity"; from: 0; to: 0.72; duration: 55; easing.type: Easing.OutQuad }
            NumberAnimation { target: shutter; property: "opacity"; to: 0; duration: 340; easing.type: Easing.OutCubic }
          }
        }

        // Where the agent is working. agent-browser reports the target of an
        // action, not a path to it, so the movement between two points is
        // drawn rather than observed: the marker is simply told where to be
        // next and glides there, and the trail is where it has just been. What
        // is real is the endpoints; the line between them is an animation.
        Item {
          id: pointerLayer
          anchors.fill: parent
          visible: root.showPointer

          readonly property real scaleToView: root.svc && root.svc.viewportW > 0
            ? viewport.width / root.svc.viewportW : 1

          function moveTo(pageX, pageY) {
            var cx = pageX * pointerLayer.scaleToView
            var cy = pageY * pointerLayer.scaleToView
            // The first point of a burst appears where it happened instead of
            // flying in from wherever the marker was left last time.
            if (!marker.visible) {
              marker.gliding = false
              trail.points = []
            }
            marker.x = cx - marker.width / 2
            marker.y = cy - marker.height / 2
            marker.visible = true
            marker.gliding = true
            pointerIdle.restart()
            sampler.start()
          }

          Canvas {
            id: trail
            anchors.fill: parent
            property var points: []

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              if (points.length < 2) return
              var now = Date.now()
              ctx.lineCap = "round"
              ctx.lineJoin = "round"
              for (var i = 1; i < points.length; i++) {
                var age = now - points[i].t
                var life = 1 - age / root.trailMs
                if (life <= 0) continue
                ctx.beginPath()
                ctx.moveTo(points[i - 1].x, points[i - 1].y)
                ctx.lineTo(points[i].x, points[i].y)
                ctx.lineWidth = Math.max(1, Style.space(3) * life)
                ctx.strokeStyle = Qt.rgba(root.pointerColor.r, root.pointerColor.g,
                                          root.pointerColor.b, life * 0.85)
                ctx.stroke()
              }
            }
          }

          Item {
            id: marker
            width: Style.space(13)
            height: width
            visible: false
            // Turned off for the first point of a burst so the marker appears
            // rather than travels.
            property bool gliding: true

            Behavior on x {
              enabled: marker.gliding
              NumberAnimation { duration: root.glideMs; easing.type: Easing.InOutCubic }
            }
            Behavior on y {
              enabled: marker.gliding
              NumberAnimation {
                duration: root.glideMs
                easing.type: Easing.InOutCubic
                onFinished: pulse.restart()
              }
            }

            Rectangle {
              anchors.fill: parent
              radius: width / 2
              color: Util.alpha(root.pointerColor, 0.28)
              border.width: Math.max(1, Style.space(2))
              border.color: root.pointerColor
            }

            // Lands on the target the way a click would.
            SequentialAnimation {
              id: pulse
              ParallelAnimation {
                NumberAnimation { target: halo; property: "opacity"; from: 0.9; to: 0; duration: 480; easing.type: Easing.OutCubic }
                NumberAnimation { target: halo; property: "scale"; from: 0.7; to: 2.1; duration: 480; easing.type: Easing.OutCubic }
              }
            }

            Rectangle {
              id: halo
              anchors.centerIn: parent
              width: parent.width
              height: parent.height
              radius: width / 2
              color: "transparent"
              border.width: Math.max(1, Style.space(2))
              border.color: root.pointerColor
              opacity: 0
            }
          }

          // Samples the marker while it travels, so the trail follows the
          // animation rather than jumping between the two endpoints.
          Timer {
            id: sampler
            interval: 24
            repeat: true
            running: false
            onTriggered: {
              var now = Date.now()
              if (marker.visible) {
                trail.points.push({
                  x: marker.x + marker.width / 2,
                  y: marker.y + marker.height / 2,
                  t: now,
                })
              }
              while (trail.points.length > 0 && now - trail.points[0].t > root.trailMs)
                trail.points.shift()
              trail.requestPaint()
              if (trail.points.length === 0 && !marker.visible) sampler.stop()
            }
          }

          Timer {
            id: pointerIdle
            interval: 2600
            onTriggered: marker.visible = false
          }
        }

        // What the agent just did, newest at the bottom, tucked into the
        // corner so it covers as little of the page as possible.
        Column {
          id: feed
          visible: root.showActions && actionModel.count > 0
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.rightMargin: Style.space(6)
          anchors.bottomMargin: Style.space(6)
          width: Math.min(viewport.width - Style.space(12), Style.space(240))
          spacing: Math.max(1, Style.space(2))

          Repeater {
            model: actionModel

            Rectangle {
              required property string label
              required property double born

              anchors.right: parent.right
              width: Math.min(feed.width, actionLabel.implicitWidth + Style.space(14))
              height: Style.font.caption + Style.space(9)
              radius: Math.max(2, Style.cornerRadius)
              color: Util.alpha(Color.background, 0.84)
              border.width: Math.max(1, Style.space(1))
              border.color: Util.alpha(Color.popups.text, 0.16)

              // Each entry ages out on its own clock, so a burst of actions
              // does not reset the ones already fading.
              opacity: (root.nowTick - born) < root.actionTtlSec * 1000 ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }

              Text {
                id: actionLabel
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(7)
                anchors.rightMargin: Style.space(7)
                anchors.verticalCenter: parent.verticalCenter
                text: parent.label
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: Color.popups.text
                elide: Text.ElideRight
                maximumLineCount: 1
              }
            }
          }
        }
      }

      // One row per live session, down the left edge. Only appears once there
      // is a choice to make, so the single-session case stays a plain mirror.
      // The filled row is the one being shown; the accent marker down its left
      // edge means it is pinned there by hand rather than picked automatically.
      Item {
        id: rail
        visible: root.showSwitcher
        width: root.railWidth
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.topMargin: card.borderTop
        anchors.bottomMargin: card.borderBottom
        anchors.leftMargin: card.borderLeft
        clip: true

        Rectangle {
          anchors.fill: parent
          color: Util.alpha(Color.popups.text, 0.05)
        }

        // Hairline against the mirror, so the page never looks like it bleeds
        // into the list.
        Rectangle {
          width: Math.max(1, Style.space(1))
          height: parent.height
          anchors.right: parent.right
          color: Util.alpha(Color.popups.text, 0.12)
        }

        Column {
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.topMargin: Math.round(root.pad * 0.6)
          spacing: Math.max(1, Style.space(1))

          Repeater {
            model: root.showSwitcher ? root.sessions : []

            Item {
              id: row
              required property var modelData
              readonly property bool isShown: root.svc && modelData.name === root.svc.shown
              // The page is what you recognise a session by; the session name
              // is an agent-browser implementation detail.
              readonly property string label: modelData.title !== "" ? modelData.title : modelData.name

              width: rail.width
              height: root.rowHeight

              Rectangle {
                anchors.fill: parent
                color: row.isShown ? Util.alpha(Color.accent, 0.18)
                  : (rowMouse.containsMouse ? Util.alpha(Color.popups.text, 0.07) : "transparent")
                Behavior on color { ColorAnimation { duration: 120 } }
              }

              Rectangle {
                width: Math.max(2, Style.space(2))
                height: parent.height
                anchors.left: parent.left
                visible: row.isShown
                color: Color.accent
              }

              Rectangle {
                id: rowDot
                width: Style.space(5)
                height: width
                radius: width / 2
                anchors.left: parent.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                color: row.modelData.painting ? Color.urgent : Util.alpha(Color.popups.text, 0.3)
                Behavior on color { ColorAnimation { duration: 220 } }
              }

              Text {
                anchors.left: rowDot.right
                anchors.leftMargin: Style.space(5)
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: row.label
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                color: row.isShown ? Color.popups.text : Util.alpha(Color.popups.text, 0.65)
                // The rail is a fixed width, so a long title is cut with an
                // ellipsis rather than wrapping or stretching the card.
                elide: Text.ElideRight
                maximumLineCount: 1
              }

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                enabled: !root.clickThrough
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                // Picking a session is the whole interaction: no modes, no
                // way to land somewhere you did not choose. Following the
                // busiest session automatically is what happens until you
                // pick, and `auto` over IPC returns to it.
                onClicked: if (root.svc) root.svc.select(row.modelData.name)
              }
            }
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        // Sits under the rail: its rows take their own clicks first, and
        // everything else toggles size or dismisses.
        z: -1
        enabled: !root.clickThrough
        acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
        cursorShape: Qt.PointingHandCursor
        onClicked: (mouse) => {
          if (mouse.button === Qt.RightButton) { root.dismissed = true; root.evaluate() }
          else if (mouse.button === Qt.MiddleButton) { if (root.svc) root.svc.cycle() }
          else if (root.svc) root.svc.toggleExpanded()
        }
      }
    }

    // The surface is now bigger than the card, so the input region has to
    // follow the card itself — otherwise the transparent margin would swallow
    // clicks meant for whatever is behind it. A click-through minimap is
    // purely ambient and takes no input at all.
    mask: root.clickThrough ? emptyRegion : cardRegion

    Region { id: emptyRegion }
    Region { id: cardRegion; item: card; radius: Style.cornerRadius }
  }
}
