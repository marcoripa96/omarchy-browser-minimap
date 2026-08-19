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

  // Not `enabled`: Item already defines that, and the redeclaration silently
  // loses to the base property, which left the icon permanently undimmed.
  readonly property bool pluginEnabled: service ? service.enabled : false
  readonly property bool live: service ? service.live : false
  readonly property bool painting: service ? service.painting : false
  readonly property int sessionCount: service ? service.sessionCount : 0

  readonly property string stateText: {
    if (!pluginEnabled) return "Browser minimap: off"
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
    // slotSize and fontSize are deliberately left at BarIconButton's defaults:
    // the neighbouring status icons (network, bluetooth, audio) override
    // neither, and overriding them here made this glyph both smaller and
    // differently slotted, which read as misaligned in the row.
    tooltipText: root.stateText
    // The icon says on or off and nothing else. Tying it to page activity as
    // well made the busiest state the one that looked most like an alarm, and
    // left "off" and "on but idle" separated only by opacity. Activity still
    // shows on the panel's own dot and in the tooltip.
    active: false
    // Off is a deliberate state, not an error: dim rather than hide, so the
    // switch stays where the user left it.
    dimmed: !root.pluginEnabled
    onPressed: (mouseButton) => {
      if (!root.service) return
      if (mouseButton === Qt.MiddleButton) root.service.cycle()
      else root.service.toggle()
    }
  }
}
