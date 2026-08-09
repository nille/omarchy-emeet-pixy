import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

// Standalone harness for developing Panel.qml outside a running Omarchy shell.
//
// The real shell injects `bar`, `moduleName`, and `settings` into each widget
// and hosts it in a bar surface. Here a plain window plays that role, with a
// StubBar supplying exactly the properties qs.Ui components read off the host.
// That's enough to compile the panel, instantiate every component, and click
// through it against the real camera.
//
//   tests/harness/run
//
// Launch it through that wrapper rather than calling quickshell directly. The
// `qs.Ui` and `qs.Commons` imports above resolve relative to the root QML file's
// directory, so they only load from a file sitting beside a `qs/` directory —
// which this checkout has no way to provide, and which no QML_IMPORT_PATH can
// substitute for. The wrapper builds that level in a temp directory and sets
// PIXY_DIR, which points the panel's helper at this working tree instead of
// ~/.config/omarchy/plugins/nille.emeet-pixy. Without it the harness drives the
// installed copy, which is rarely what you want while editing.
ShellRoot {
  id: harness

  FloatingWindow {
    id: window
    implicitWidth: 520
    implicitHeight: 220
    color: Color.background
    visible: true

    // Mirrors the subset of Bar's API that qs.Ui components and Panel read.
    // Property names and fallbacks match plugins/bar/Bar.qml.
    QtObject {
      id: stubBar

      property string fontFamily: Style.font.family
      property color themeForeground: Color.bar.text
      property color foreground: themeForeground
      property color barForeground: themeForeground
      property bool foregroundAnimationEnabled: true
      property color background: Color.bar.background
      property color urgent: Color.bar.active
      property bool vertical: false
      property int barSize: Style.bar.sizeHorizontal
      property string position: "top"

      // Popout coordination. KeyboardPanel reads `activePopout` and calls
      // request/release on open and close, so these have to exist and behave —
      // a missing `activePopout` assigns undefined to a bool and warns.
      property var activePopout: null

      function requestPopout(owner) {
        if (activePopout === owner) return
        if (activePopout) {
          if ("closeForPopoutSwitch" in activePopout) activePopout.closeForPopoutSwitch()
          else if ("close" in activePopout) activePopout.close()
        }
        activePopout = owner
      }

      function releasePopout(owner) {
        if (activePopout === owner) activePopout = null
      }

      // Bar owns tooltips and click routing for its widgets; the harness has
      // no bar chrome, so these are no-ops rather than missing methods.
      function showTooltip(item, text) {}
      function hideTooltip(item) {}
      function registerClickTarget(item) {}
      function unregisterClickTarget(item) {}
      function moduleWidgets(name) { return [] }
      function switchPanelFrom(panel, direction) { return false }
    }

    Text {
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.margins: 12
      text: "emeet-pixy harness — click the webcam glyph"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.bodySmall
      opacity: 0.6
    }

    // Stand-in for the bar strip the widget normally sits in, so the panel
    // anchors and opens the way it will in the real bar.
    Rectangle {
      id: barStrip
      anchors.top: parent.top
      anchors.left: parent.left
      anchors.right: parent.right
      height: Style.bar.sizeHorizontal
      color: Color.bar.background

      Loader {
        id: widgetLoader
        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        source: "../../Panel.qml"
        onLoaded: {
          item.bar = stubBar
          item.moduleName = "nille.emeet-pixy"
          // `preview` is set explicitly rather than left to the schema default so
          // this object matches every key the panel reads. Note that the preview
          // switch cannot actually persist here: its write goes out to
          // `omarchy-shell setBarWidget`, which needs a running shell to answer.
          // The switch still throws, because the optimistic override drives it —
          // and then reverts on the 2 s timeout, which is the correct behavior for
          // a write that never lands.
          item.settings = {
            refreshIntervalSec: 10, ptzStep: 5, hideWhenAbsent: false, preview: true
          }
        }
      }
    }
  }
}
