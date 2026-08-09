// The preview switch's optimistic override: the switch has to move the instant it
// is clicked, but the value it shows lives in shell.json and comes back through a
// round trip via `omarchy-shell`. So `previewPending` covers the gap.
//
// Three ways that can go wrong, and all three are here: the override never clears
// (switch permanently detached from reality), the override clears too eagerly (the
// switch snaps back for a frame mid-write), or the write never lands at all and
// nothing resolves it — `omarchy-shell` missing from PATH leaves the switch showing
// a preview state that is not true, indefinitely.
//
// Caveat worth knowing before trusting these: this file *replicates* the property
// block from Panel.qml rather than instantiating the panel, because the panel needs
// a Bar, a PipeWire graph, and a real shell to answer the write. The tests pin the
// logic, not the wiring — if the panel's version of these five members drifts from
// the copy below, these still pass. The wiring is covered live instead: an IPC
// previewOff followed by reading shell.json back.
import QtQuick
import QtTest

Item {
  id: root
  property bool rawSetting: true

  property var previewPending: null
  readonly property bool previewEnabled: previewPending !== null
    ? previewPending
    : rawSetting

  readonly property bool previewSetting: rawSetting
  onPreviewSettingChanged: {
    if (previewPending === previewSetting) {
      previewPending = null
      previewPendingTimeout.stop()
    }
  }

  function setPreviewEnabled(enabled) {
    if (previewEnabled === enabled) return
    previewPending = enabled
    previewPendingTimeout.restart()
  }

  Timer {
    id: previewPendingTimeout
    interval: 2000
    onTriggered: root.previewPending = null
  }

  TestCase {
    name: "PreviewPending"
    when: windowShown

    function init() {
      root.previewPending = null
      previewPendingTimeout.stop()
      root.rawSetting = true
    }

    function test_the_switch_throws_immediately() {
      root.setPreviewEnabled(false)
      compare(root.previewEnabled, false)
      verify(previewPendingTimeout.running)
    }

    function test_the_override_clears_when_the_setting_agrees() {
      root.setPreviewEnabled(false)
      root.rawSetting = false
      compare(root.previewPending, null)
      compare(root.previewEnabled, false)
      verify(!previewPendingTimeout.running)
    }

    function test_the_override_reverts_when_the_write_never_lands() {
      // The failure this guards: omarchy-shell missing from PATH. Without the
      // timeout the switch would sit where it was clicked forever while the
      // preview stayed as it was.
      root.setPreviewEnabled(false)
      compare(root.previewEnabled, false)
      wait(2300)
      compare(root.previewPending, null)
      compare(root.previewEnabled, true)
    }

    function test_a_redundant_set_is_a_no_op() {
      // No write, no timer — otherwise clicking the switch to the position it is
      // already in would arm a revert against nothing.
      root.setPreviewEnabled(true)
      compare(root.previewPending, null)
      verify(!previewPendingTimeout.running)
    }

    function test_an_external_change_wins_over_a_stale_override() {
      // The settings dialog set it back to true while our false was in flight.
      // The override does not clear (it never agreed), so the timeout is what
      // resolves it — and it resolves to the real setting, not to our guess.
      root.setPreviewEnabled(false)
      root.rawSetting = true
      wait(2300)
      compare(root.previewEnabled, true)
    }
  }
}
