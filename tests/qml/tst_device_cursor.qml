// The device page's row arithmetic.
//
// Same shape of problem as the advanced page, and for the same reason: one
// keyboard section holding six different kinds of row — Back, three chip or switch
// rows, the orientation toggles, auto-privacy, the call-automation switches, the
// snapshot button, and the camera's own preset slots — with three of the group
// lengths coming from Model rather than from the layout. So there is no fixed
// table to compare against, only chained arithmetic, and that is what these pin.
//
// The failures are the same silent ones tst_advanced_cursor.qml describes, plus
// one this page adds: `deviceNativeAt` returning a slot number for a row that is
// not a slot would make `x` — clear slot — erase a preset from a row showing a
// switch. That is a write to the camera's persistent storage from a key the user
// pressed somewhere else entirely, so it gets tests in both directions.
//
// The formats list at the bottom of the page is deliberately outside the cursor:
// it is read-only text, and a row where Enter does nothing is the dead stop the
// advanced page's tests exist to prevent. The last cursor row is therefore the
// last *slot*, not the last thing drawn — pinned below so a later "make the
// formats keyboard-reachable" change has to come here and say so.
//
// Caveat, the same one tst_advanced_cursor.qml and tst_preview_pending.qml carry:
// this file *replicates* the members from Panel.qml rather than instantiating the
// panel, which needs a Bar, a Pipewire graph and a real camera to answer. If the
// panel's copy drifts from the one below these still pass. The group lengths are
// the exception and are imported from Model, so a fourth orientation toggle or a
// fourth call action shifts the expectations here automatically — which is the
// half most likely to change.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest
import "../../Model.js" as Model

Item {
  id: root

  property string focusSection: "device"
  property int selectedIndex: 0

  readonly property var visibleSections: ["device"]

  function sectionCount(section) {
    if (section === "device") return deviceNativeRow + Model.PRESET_SLOTS.length
    return 0
  }

  readonly property int deviceBackRow: 0
  readonly property int deviceAudioRow: 1
  readonly property int deviceGestureRow: 2
  readonly property int deviceFocusRow: 3
  readonly property int deviceFeatureRow: 4
  readonly property int deviceAutoPrivacyRow: deviceFeatureRow + Model.FEATURE_TOGGLES.length
  readonly property int deviceCallRow: deviceAutoPrivacyRow + 1
  readonly property int deviceSnapshotRow: deviceCallRow + Model.CALL_ACTION_META.length
  readonly property int deviceNativeRow: deviceSnapshotRow + 1

  function deviceFeatureAt(index) {
    var i = index - deviceFeatureRow
    return i >= 0 && i < Model.FEATURE_TOGGLES.length ? Model.FEATURE_TOGGLES[i] : null
  }

  function deviceCallAt(index) {
    var i = index - deviceCallRow
    return i >= 0 && i < Model.CALL_ACTION_META.length ? Model.CALL_ACTION_META[i] : null
  }

  function deviceNativeAt(index) {
    var i = index - deviceNativeRow
    return i >= 0 && i < Model.PRESET_SLOTS.length ? Model.PRESET_SLOTS[i] : 0
  }

  function moveCursor(delta) {
    var max = sectionCount(focusSection) - 1
    if (delta > 0) { if (selectedIndex < max) selectedIndex = selectedIndex + 1 }
    else { if (selectedIndex > 0) selectedIndex = selectedIndex - 1 }
  }

  function clampCursor() {
    var count = sectionCount(focusSection)
    if (count === 0) { selectedIndex = -1; return }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // What Enter would do on a row, in the order activateDeviceRow dispatches — the
  // named rows first, then the three group lookups. The order is load-bearing: a
  // group lookup that answered for a named row would shadow it.
  function actionAt(index) {
    if (index === deviceBackRow) return "back"
    if (index === deviceAudioRow) return "audio"
    if (index === deviceGestureRow) return "gesture"
    if (index === deviceFocusRow) return "focus"
    if (index === deviceAutoPrivacyRow) return "autoPrivacy"
    if (index === deviceSnapshotRow) return "snapshot"
    var feature = deviceFeatureAt(index)
    if (feature) return "feature:" + feature.key
    var call = deviceCallAt(index)
    if (call) return "call:" + call.key
    var slot = deviceNativeAt(index)
    if (slot) return "clear:" + slot
    return "nothing"
  }

  // Which rows h/l reaches, from adjustDeviceRow. Not every row has a direction —
  // the snapshot button and Back do not — and that is the point: those two must not
  // fall through into a group lookup.
  function adjustAt(index) {
    if (index === deviceAudioRow) return "cycleAudio"
    if (index === deviceFocusRow) return "cycleFocus"
    if (index === deviceAutoPrivacyRow) return "cycleAutoPrivacy"
    if (index === deviceGestureRow) return "setGesture"
    var feature = deviceFeatureAt(index)
    if (feature) return "feature:" + feature.key
    var call = deviceCallAt(index)
    if (call) return "call:" + call.key
    return ""
  }

  TestCase {
    name: "DeviceCursor"

    function init() {
      root.focusSection = "device"
      root.selectedIndex = 0
    }

    // ---- the row count covers the rows that exist ----

    function test_the_count_reaches_the_last_slot_and_stops() {
      // Back + audio + gesture + focus + 3 features + auto-privacy + 3 call
      // switches + snapshot + 3 slots. Written out once, against the real list
      // lengths, so a count that drifts from the chain shows up here.
      compare(Model.FEATURE_TOGGLES.length, 3)
      compare(Model.CALL_ACTION_META.length, 3)
      compare(Model.PRESET_SLOTS.length, 3)
      compare(root.sectionCount("device"), 15)
      compare(root.deviceNativeRow, 12)
    }

    function test_the_last_slot_is_the_last_row() {
      // The formats list is drawn after it but is not a cursor row, so the last
      // slot has to be the final index — otherwise j either stops one short of it
      // or walks into the read-only text where Enter does nothing.
      var last = root.sectionCount("device") - 1
      compare(root.actionAt(last), "clear:" + Model.PRESET_SLOTS[Model.PRESET_SLOTS.length - 1])
    }

    function test_walking_down_visits_every_row_in_the_order_it_is_drawn() {
      // The order below is the order the rows appear on the page, top to bottom.
      // That is the assertion, not merely that each row is reached once: the bug
      // this pattern caught on the advanced page had the arithmetic self-consistent
      // and only the drawn order disagreeing.
      var seen = []
      for (var i = 0; i < 30; i++) {
        seen.push(root.actionAt(root.selectedIndex))
        root.moveCursor(1)
      }
      compare(seen.slice(0, 15).join(" "),
              "back audio gesture focus "
              + "feature:flipHorizontal feature:flipVertical feature:autoRotate "
              + "autoPrivacy call:openLens call:tracking call:unmute "
              + "snapshot clear:1 clear:2 clear:3")
      compare(root.selectedIndex, root.sectionCount("device") - 1)
    }

    function test_walking_back_up_returns_to_back() {
      root.selectedIndex = root.sectionCount("device") - 1
      for (var i = 0; i < 30; i++) root.moveCursor(-1)
      compare(root.selectedIndex, root.deviceBackRow)
      compare(root.actionAt(root.selectedIndex), "back")
    }

    function test_no_row_maps_to_nothing() {
      // A hole in the middle is a cursor that lands somewhere and does nothing on
      // Enter, which is indistinguishable from a broken key.
      for (var i = 0; i < root.sectionCount("device"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    function test_every_row_is_reached_exactly_once() {
      var seen = {}
      for (var i = 0; i < root.sectionCount("device"); i++) {
        var action = root.actionAt(i)
        verify(seen[action] === undefined, action + " appears twice")
        seen[action] = i
      }
    }

    // ---- the wrong row must not answer ----

    function test_only_slot_rows_are_slots() {
      // `x` clears the slot the cursor sits on, which is a write to the camera's
      // persistent storage. Any other row answering here would erase a preset from
      // a row that is showing a switch — the worst version of an off-by-one on this
      // page, because it is not undoable and not visible where it happened.
      for (var i = 0; i < root.deviceNativeRow; i++)
        compare(root.deviceNativeAt(i), 0, "row " + i + " answered as a slot")
      compare(root.deviceNativeAt(-1), 0)
      compare(root.deviceNativeAt(root.sectionCount("device")), 0)
    }

    function test_zero_is_what_a_non_slot_row_returns() {
      // Panel.qml's clearNativePreset guards on `!slot`, so the sentinel has to be
      // falsy — a -1 or a null would pass a truthiness check and reach the helper.
      verify(!root.deviceNativeAt(root.deviceBackRow))
      verify(!root.deviceNativeAt(root.deviceSnapshotRow))
      verify(root.deviceNativeAt(root.deviceNativeRow))
    }

    function test_the_named_rows_are_not_features_or_call_actions() {
      // The three group lookups run after the named rows in activateDeviceRow, so
      // one of them answering for a named row would only show up as h/l adjusting
      // the wrong thing — adjustDeviceRow checks the groups too.
      var named = [root.deviceBackRow, root.deviceAudioRow, root.deviceGestureRow,
                   root.deviceFocusRow, root.deviceAutoPrivacyRow, root.deviceSnapshotRow]
      for (var i = 0; i < named.length; i++) {
        compare(root.deviceFeatureAt(named[i]), null, "row " + named[i] + " is a feature")
        compare(root.deviceCallAt(named[i]), null, "row " + named[i] + " is a call action")
      }
    }

    function test_a_feature_row_is_not_a_call_action_and_the_reverse() {
      // The two groups are adjacent with only auto-privacy between them, so an
      // off-by-one here would put a mirror toggle on a call switch's row.
      for (var f = 0; f < Model.FEATURE_TOGGLES.length; f++)
        compare(root.deviceCallAt(root.deviceFeatureRow + f), null)
      for (var c = 0; c < Model.CALL_ACTION_META.length; c++)
        compare(root.deviceFeatureAt(root.deviceCallRow + c), null)
    }

    function test_the_groups_are_in_their_declared_order() {
      // The walk pins the labels; this pins that the lookups agree with Model's own
      // ordering rather than happening to match it.
      for (var f = 0; f < Model.FEATURE_TOGGLES.length; f++)
        compare(root.deviceFeatureAt(root.deviceFeatureRow + f).key,
                Model.FEATURE_TOGGLES[f].key)
      for (var c = 0; c < Model.CALL_ACTION_META.length; c++)
        compare(root.deviceCallAt(root.deviceCallRow + c).key, Model.CALL_ACTION_META[c].key)
      for (var s = 0; s < Model.PRESET_SLOTS.length; s++)
        compare(root.deviceNativeAt(root.deviceNativeRow + s), Model.PRESET_SLOTS[s])
    }

    // ---- h/l ----

    function test_back_and_snapshot_have_no_horizontal_action() {
      // Both are single actions, so h/l on them must do nothing rather than fall
      // into a neighbouring group. Enter is their key.
      compare(root.adjustAt(root.deviceBackRow), "")
      compare(root.adjustAt(root.deviceSnapshotRow), "")
    }

    function test_every_other_row_answers_to_h_and_l() {
      // The switches included: l turns one on and h off, which is how the image
      // page treats booleans. A switch with no horizontal action would read as a
      // dead key on a row where the neighbours all respond.
      for (var i = 0; i < root.sectionCount("device"); i++) {
        if (i === root.deviceBackRow || i === root.deviceSnapshotRow) continue
        if (i >= root.deviceNativeRow) continue
        verify(root.adjustAt(i) !== "", "row " + i + " ignores h/l")
      }
    }

    function test_a_slot_row_ignores_h_and_l() {
      // A slot holds pan and tilt; there is no "more" or "less" of one. Its only
      // keyboard action is Enter or x, both of which clear it.
      for (var s = 0; s < Model.PRESET_SLOTS.length; s++)
        compare(root.adjustAt(root.deviceNativeRow + s), "")
    }

    // ---- the page's shape is fixed, unlike the advanced page's ----

    function test_the_row_order_is_monotonic() {
      // Rows are numbered in the order they appear so j goes down the screen. The
      // groups chain off each other, so this holds whatever their lengths become.
      verify(root.deviceBackRow < root.deviceAudioRow)
      verify(root.deviceAudioRow < root.deviceGestureRow)
      verify(root.deviceGestureRow < root.deviceFocusRow)
      verify(root.deviceFocusRow < root.deviceFeatureRow)
      verify(root.deviceFeatureRow < root.deviceAutoPrivacyRow)
      verify(root.deviceAutoPrivacyRow < root.deviceCallRow)
      verify(root.deviceCallRow < root.deviceSnapshotRow)
      verify(root.deviceSnapshotRow < root.deviceNativeRow)
      verify(root.deviceNativeRow < root.sectionCount("device"))
    }

    function test_the_count_does_not_depend_on_what_the_camera_reported() {
      // Unlike the image page, whose rows come from the driver, every row here is
      // always drawn — a setting the camera did not answer for shows "not reported"
      // rather than disappearing. So the cursor cannot be left pointing past the
      // end by a failed read, and clamping is a no-op.
      root.selectedIndex = root.sectionCount("device") - 1
      root.clampCursor()
      compare(root.selectedIndex, root.sectionCount("device") - 1)
    }

    function test_a_cursor_left_past_the_end_comes_back_in_range() {
      // The page opens on Back, but the cursor is shared with the main page, whose
      // sections are longer — so clampCursor is what stops a stale index from
      // pointing at a row that does not exist here.
      root.selectedIndex = 99
      root.clampCursor()
      compare(root.selectedIndex, root.sectionCount("device") - 1)
      verify(root.actionAt(root.selectedIndex) !== "nothing")
    }
  }
}
