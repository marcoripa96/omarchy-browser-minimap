import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// The bar's switch for the minimap. Turning it off stops the bridge process
// outright, so a disabled plugin costs nothing but this icon.
BarWidget {
  id: root
  moduleName: "io.github.marcoripa96.browser-minimap"

  // Bar widgets are handed `bar` and `settings`, not `service`, so the shared
  // singleton is fetched off the host by id.
  readonly property var service: bar && bar.shell && typeof bar.shell.serviceFor === "function"
    ? bar.shell.serviceFor(root.moduleName) : null

  readonly property bool enabled: service ? service.enabled : false
  readonly property bool live: service ? service.live : false
  readonly property bool painting: service ? service.painting : false
  readonly property int sessionCount: service ? service.sessionCount : 0

  readonly property string stateText: {
    if (!enabled) return "Browser minimap: off"
    if (!live) return "Browser minimap: no browser session"
    var where = service && service.pageUrl !== "" ? service.pageUrl : (service ? service.shown : "")
    if (sessionCount > 1) {
      var mode = service && service.selected !== "" ? "pinned" : "auto"
      return "Browser minimap: " + where + "\n" + sessionCount + " sessions (" + mode
        + ") · middle-click to switch"
    }
    return "Browser minimap: " + where
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A globe reads as "the agent is out on the web" at bar size, where a
    // browser-chrome glyph turns to mush.
    text: ""
    slotSize: Style.bar.statusSlot
    fontSize: Style.font.caption
    tooltipText: root.stateText
    // Lit while the page is actually changing, so the bar carries the same
    // signal as the minimap's own dot even when the panel has stepped aside.
    active: root.enabled && root.painting
    activeColor: Color.bar.active
    // Off is a deliberate state, not an error: dim rather than hide, so the
    // switch stays where the user left it.
    dimmed: !root.enabled
    onPressed: (mouseButton) => {
      if (!root.service) return
      if (mouseButton === Qt.MiddleButton) root.service.cycle()
      else root.service.toggle()
    }
  }
}
