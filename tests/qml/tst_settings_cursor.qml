// The SETTINGS page's row arithmetic.
//
// Same shape of problem as the IMAGE page, and for the same reason: one keyboard
// section holding five different kinds of row — three chip or switch rows, the
// orientation toggles, auto-privacy, the call-automation switches, the snapshot
// button, and the camera's own preset slots — with three of the group lengths coming
// from Model rather than from the layout. So there is no fixed table to compare
// against, only chained arithmetic, and that is what these pin.
//
// The failures are the same silent ones tst_image_cursor.qml describes, plus one this
// page adds: `settingsNativeAt` returning a slot number for a row that is not a slot
// would make `x` — clear slot — erase a preset from a row showing a switch. That is a
// write to the camera's persistent storage from a key the user pressed somewhere else
// entirely, so it gets tests in both directions.
//
// *(reported)* "not sure i love the floating sticky thing" turned this page from a
// sub-page into a tab, which deleted its Back row and shifted every row up by one.
// The rows are otherwise unchanged, which is the point of the change: it was already
// a page holding one list under one cursor.
//
// The formats list at the bottom of the page is deliberately outside the cursor: it is
// read-only text, and a row where Enter does nothing is the dead stop the IMAGE page's
// tests exist to prevent. The last cursor row is therefore the last *slot*, not the
// last thing drawn — pinned below so a later "make the formats keyboard-reachable"
// change has to come here and say so.
//
// Caveat, the same one tst_image_cursor.qml and tst_preview_pending.qml carry: this
// file *replicates* the members from Panel.qml rather than instantiating the panel,
// which needs a Bar, a Pipewire graph and a real camera to answer. If the panel's copy
// drifts from the one below these still pass. The group lengths are the exception and
// are imported from Model, so a fourth orientation toggle or a fourth call action
// shifts the expectations here automatically — which is the half most likely to change.
//
import QtQuick
import QtTest
import "../../Model.js" as Model

Item {
  id: root

  property string page: "settings"
  property string focusSection: "settings"
  property int selectedIndex: 0

  function sectionCount(section) {
    if (section === "settings") return settingsNativeRow + Model.PRESET_SLOTS.length
    return 0
  }

  readonly property int settingsAudioRow: 0
  readonly property int settingsGestureRow: 1
  readonly property int settingsFocusRow: 2
  readonly property int settingsFeatureRow: 3
  readonly property int settingsAutoPrivacyRow: settingsFeatureRow + Model.FEATURE_TOGGLES.length
  readonly property int settingsCallRow: settingsAutoPrivacyRow + 1
  readonly property int settingsSnapshotRow: settingsCallRow + Model.CALL_ACTION_META.length
  readonly property int settingsNativeRow: settingsSnapshotRow + 1

  function settingsFeatureAt(index) {
    var i = index - settingsFeatureRow
    return i >= 0 && i < Model.FEATURE_TOGGLES.length ? Model.FEATURE_TOGGLES[i] : null
  }

  function settingsCallAt(index) {
    var i = index - settingsCallRow
    return i >= 0 && i < Model.CALL_ACTION_META.length ? Model.CALL_ACTION_META[i] : null
  }

  function settingsNativeAt(index) {
    var i = index - settingsNativeRow
    return i >= 0 && i < Model.PRESET_SLOTS.length ? Model.PRESET_SLOTS[i] : 0
  }

  function moveCursor(delta) {
    var max = sectionCount(focusSection) - 1
    if (max < 0) return
    if (focusSection === "header" || selectedIndex < 0) { selectedIndex = 0; return }
    selectedIndex = Math.max(0, Math.min(max, selectedIndex + (delta > 0 ? 1 : -1)))
  }

  function clampCursor() {
    if (focusSection !== page) { focusSection = page; selectedIndex = 0; return }
    var count = sectionCount(focusSection)
    if (count === 0) { selectedIndex = -1; return }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // What Enter would do on a row, in the order activateSettingsRow dispatches — the
  // named rows first, then the three group lookups. The order is load-bearing: a
  // group lookup that answered for a named row would shadow it.
  function actionAt(index) {
    if (index === settingsAudioRow) return "audio"
    if (index === settingsGestureRow) return "gesture"
    if (index === settingsFocusRow) return "focus"
    if (index === settingsAutoPrivacyRow) return "autoPrivacy"
    if (index === settingsSnapshotRow) return "snapshot"
    var feature = settingsFeatureAt(index)
    if (feature) return "feature:" + feature.key
    var call = settingsCallAt(index)
    if (call) return "call:" + call.key
    var slot = settingsNativeAt(index)
    if (slot) return "clear:" + slot
    return "nothing"
  }

  // Which rows h/l reaches, from adjustSettingsRow. Not every row has a direction —
  // the snapshot button does not — and that is the point: it must not fall through
  // into a group lookup.
  function adjustAt(index) {
    if (index === settingsAudioRow) return "cycleAudio"
    if (index === settingsFocusRow) return "cycleFocus"
    if (index === settingsAutoPrivacyRow) return "cycleAutoPrivacy"
    if (index === settingsGestureRow) return "setGesture"
    var feature = settingsFeatureAt(index)
    if (feature) return "feature:" + feature.key
    var call = settingsCallAt(index)
    if (call) return "call:" + call.key
    return ""
  }

  TestCase {
    name: "SettingsCursor"

    function init() {
      root.page = "settings"
      root.focusSection = "settings"
      root.selectedIndex = 0
    }

    // ---- the row count covers the rows that exist ----

    function test_the_count_reaches_the_last_slot_and_stops() {
      // Audio + gesture + focus + 3 features + auto-privacy + 3 call switches +
      // snapshot + 3 slots. Written out once, against the real list lengths, so a
      // count that drifts from the chain shows up here. Fourteen rather than the
      // fifteen it was: the Back row went with the page becoming a tab.
      compare(Model.FEATURE_TOGGLES.length, 3)
      compare(Model.CALL_ACTION_META.length, 3)
      compare(Model.PRESET_SLOTS.length, 3)
      compare(root.sectionCount("settings"), 14)
      compare(root.settingsNativeRow, 11)
    }

    function test_the_first_setting_is_the_first_row() {
      // No Back row: the page is a tab, so the way out is `[`/`]` and the top row is
      // the first setting rather than a way off the page.
      compare(root.settingsAudioRow, 0)
      compare(root.actionAt(0), "audio")
    }

    function test_the_last_slot_is_the_last_row() {
      // The formats list is drawn after it but is not a cursor row, so the last
      // slot has to be the final index — otherwise j either stops one short of it
      // or walks into the read-only text where Enter does nothing.
      var last = root.sectionCount("settings") - 1
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
      compare(seen.slice(0, 14).join(" "),
              "audio gesture focus "
              + "feature:flipHorizontal feature:flipVertical feature:autoRotate "
              + "autoPrivacy call:openLens call:tracking call:unmute "
              + "snapshot clear:1 clear:2 clear:3")
      compare(root.selectedIndex, root.sectionCount("settings") - 1)
    }

    function test_walking_back_up_stops_at_the_top() {
      root.selectedIndex = root.sectionCount("settings") - 1
      for (var i = 0; i < 30; i++) root.moveCursor(-1)
      compare(root.selectedIndex, 0)
      compare(root.actionAt(root.selectedIndex), "audio")
    }

    function test_no_row_maps_to_nothing() {
      // A hole in the middle is a cursor that lands somewhere and does nothing on
      // Enter, which is indistinguishable from a broken key.
      for (var i = 0; i < root.sectionCount("settings"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    function test_every_row_is_reached_exactly_once() {
      var seen = {}
      for (var i = 0; i < root.sectionCount("settings"); i++) {
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
      for (var i = 0; i < root.settingsNativeRow; i++)
        compare(root.settingsNativeAt(i), 0, "row " + i + " answered as a slot")
      compare(root.settingsNativeAt(-1), 0)
      compare(root.settingsNativeAt(root.sectionCount("settings")), 0)
    }

    function test_zero_is_what_a_non_slot_row_returns() {
      // Panel.qml's clearNativePreset guards on `!slot`, so the sentinel has to be
      // falsy — a -1 or a null would pass a truthiness check and reach the helper.
      verify(!root.settingsNativeAt(root.settingsAudioRow))
      verify(!root.settingsNativeAt(root.settingsSnapshotRow))
      verify(root.settingsNativeAt(root.settingsNativeRow))
    }

    function test_the_named_rows_are_not_features_or_call_actions() {
      // The three group lookups run after the named rows in activateSettingsRow, so
      // one of them answering for a named row would only show up as h/l adjusting
      // the wrong thing — adjustSettingsRow checks the groups too.
      var named = [root.settingsAudioRow, root.settingsGestureRow, root.settingsFocusRow,
                   root.settingsAutoPrivacyRow, root.settingsSnapshotRow]
      for (var i = 0; i < named.length; i++) {
        compare(root.settingsFeatureAt(named[i]), null, "row " + named[i] + " is a feature")
        compare(root.settingsCallAt(named[i]), null, "row " + named[i] + " is a call action")
      }
    }

    function test_a_feature_row_is_not_a_call_action_and_the_reverse() {
      // The two groups are adjacent with only auto-privacy between them, so an
      // off-by-one here would put a mirror toggle on a call switch's row.
      for (var f = 0; f < Model.FEATURE_TOGGLES.length; f++)
        compare(root.settingsCallAt(root.settingsFeatureRow + f), null)
      for (var c = 0; c < Model.CALL_ACTION_META.length; c++)
        compare(root.settingsFeatureAt(root.settingsCallRow + c), null)
    }

    function test_the_groups_are_in_their_declared_order() {
      // The walk pins the labels; this pins that the lookups agree with Model's own
      // ordering rather than happening to match it.
      for (var f = 0; f < Model.FEATURE_TOGGLES.length; f++)
        compare(root.settingsFeatureAt(root.settingsFeatureRow + f).key,
                Model.FEATURE_TOGGLES[f].key)
      for (var c = 0; c < Model.CALL_ACTION_META.length; c++)
        compare(root.settingsCallAt(root.settingsCallRow + c).key, Model.CALL_ACTION_META[c].key)
      for (var s = 0; s < Model.PRESET_SLOTS.length; s++)
        compare(root.settingsNativeAt(root.settingsNativeRow + s), Model.PRESET_SLOTS[s])
    }

    // ---- h/l ----

    function test_the_snapshot_row_has_no_horizontal_action() {
      // A single action, so h/l on it must do nothing rather than fall into a
      // neighbouring group. Enter is its key.
      compare(root.adjustAt(root.settingsSnapshotRow), "")
    }

    function test_every_other_row_answers_to_h_and_l() {
      // The switches included: l turns one on and h off, which is how the image
      // page treats booleans. A switch with no horizontal action would read as a
      // dead key on a row where the neighbours all respond.
      for (var i = 0; i < root.sectionCount("settings"); i++) {
        if (i === root.settingsSnapshotRow) continue
        if (i >= root.settingsNativeRow) continue
        verify(root.adjustAt(i) !== "", "row " + i + " ignores h/l")
      }
    }

    function test_a_slot_row_ignores_h_and_l() {
      // A slot holds pan and tilt; there is no "more" or "less" of one. Its only
      // keyboard action is Enter or x, both of which clear it.
      for (var s = 0; s < Model.PRESET_SLOTS.length; s++)
        compare(root.adjustAt(root.settingsNativeRow + s), "")
    }

    // ---- the page's shape is fixed, unlike the IMAGE page's ----

    function test_the_row_order_is_monotonic() {
      // Rows are numbered in the order they appear so j goes down the screen. The
      // groups chain off each other, so this holds whatever their lengths become.
      compare(root.settingsAudioRow, 0)
      verify(root.settingsAudioRow < root.settingsGestureRow)
      verify(root.settingsGestureRow < root.settingsFocusRow)
      verify(root.settingsFocusRow < root.settingsFeatureRow)
      verify(root.settingsFeatureRow < root.settingsAutoPrivacyRow)
      verify(root.settingsAutoPrivacyRow < root.settingsCallRow)
      verify(root.settingsCallRow < root.settingsSnapshotRow)
      verify(root.settingsSnapshotRow < root.settingsNativeRow)
      verify(root.settingsNativeRow < root.sectionCount("settings"))
    }

    function test_the_count_does_not_depend_on_what_the_camera_reported() {
      // Unlike the IMAGE page, whose rows come from the driver, every row here is
      // always drawn — a setting the camera did not answer for shows "not reported"
      // rather than disappearing. So the cursor cannot be left pointing past the
      // end by a failed read, and clamping is a no-op.
      root.selectedIndex = root.sectionCount("settings") - 1
      root.clampCursor()
      compare(root.selectedIndex, root.sectionCount("settings") - 1)
    }

    function test_a_cursor_left_past_the_end_comes_back_in_range() {
      // showPage resets the cursor on arrival, so this is the guard for a list that
      // shrinks under a cursor already on the page rather than for a stale index
      // carried in from another one — that case is the next test.
      root.selectedIndex = 99
      root.clampCursor()
      compare(root.selectedIndex, root.sectionCount("settings") - 1)
      verify(root.actionAt(root.selectedIndex) !== "nothing")
    }

    function test_a_cursor_left_on_another_page_is_pulled_onto_this_one() {
      // `page` decides, not the cursor: a section string that does not match the
      // drawn page is a ring on rows nobody can see, and — on this page — an `x` that
      // could reach a slot from a row belonging to a different list entirely.
      root.focusSection = "image"
      root.selectedIndex = 6
      root.clampCursor()
      compare(root.focusSection, "settings")
      compare(root.selectedIndex, 0)
    }
  }
}
