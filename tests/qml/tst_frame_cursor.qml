// The FRAME page's row arithmetic.
//
// The page the panel opens on, and the only one whose rows are four different kinds of
// thing under one cursor: the mode chips, three sliders, the recenter button, and then
// the three preset slots. Eight rows, one of which is a group whose length comes from
// Model.
//
// Two failures here move hardware, which is what separates this page from the other
// two cursor suites:
//
//   A row that answers to `framePresetAt` when it is not a slot. `x` clears a slot and
//   Enter on an empty one *stores* the current position into it — so a slider row that
//   answered would overwrite a saved framing with wherever the lens happens to be
//   pointing, from a key pressed on a row about something else.
//
//   A slider row that falls through `adjustHorizontal` into the wrong branch. h/l on
//   pan when the cursor is on tilt pans the camera while the user is watching the tilt
//   row — visible, but as the camera doing the wrong thing rather than as a bug.
//
// And one that does not: the mode row answers to *both* Enter and h/l, deliberately, so
// the chips behave like every other chip group in the bar. That is pinned too, because
// "h/l does nothing on this row" is exactly what a later tidy-up would assume.
//
// *(reported)* "not sure i love the floating sticky thing" made this page a tab, and
// gave it the presets — they were on the old main page below the aiming controls, which
// is where they belong, and a preset recalls where the lens points. So this is the one
// page the restructure made longer rather than shorter.
//
// Caveat, the same one tst_image_cursor.qml and tst_settings_cursor.qml carry: this file
// *replicates* the members from Panel.qml rather than instantiating the panel, which
// needs a Bar, a Pipewire graph and a real camera to answer. If the panel's copy drifts
// from the one below these still pass. PRESET_SLOTS is the exception and is imported, so
// a fourth slot shifts the expectations here automatically.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest
import "../../Model.js" as Model

Item {
  id: root

  property string page: "frame"
  property string focusSection: "frame"
  property int selectedIndex: 0

  function sectionCount(section) {
    if (section === "header") return 0
    if (section === "frame") return framePresetRow + Model.PRESET_SLOTS.length
    return 0
  }

  // The two pinned switches, replicated with the rows they are deliberately not.
  readonly property int headerPrivacyIndex: -1
  readonly property int headerPreviewIndex: -2

  // activateCursor's header branch.
  function headerActionAt(index) {
    return index === headerPreviewIndex ? "preview" : "privacy"
  }

  readonly property int frameModeRow: 0
  readonly property int framePanRow: 1
  readonly property int frameTiltRow: 2
  readonly property int frameZoomRow: 3
  readonly property int frameHomeRow: 4
  readonly property int framePresetRow: 5

  function framePresetAt(index) {
    var i = index - framePresetRow
    return i >= 0 && i < Model.PRESET_SLOTS.length ? Model.PRESET_SLOTS[i] : 0
  }

  function moveCursor(delta) {
    var max = sectionCount(focusSection) - 1
    if (max < 0) return
    if (focusSection === "header" || selectedIndex < 0) { selectedIndex = 0; return }
    selectedIndex = Math.max(0, Math.min(max, selectedIndex + (delta > 0 ? 1 : -1)))
  }

  function clampCursor() {
    if (focusSection === "header") return
    if (focusSection !== page) { focusSection = page; selectedIndex = 0; return }
    var count = sectionCount(focusSection)
    if (count === 0) { selectedIndex = -1; return }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // What Enter does on a row, in activateCursor's order. "store:N" and "recall:N" are
  // the same key on the same row — which of the two depends on whether the slot holds
  // anything — so the preset rows answer as one or the other depending on this list.
  property var savedSlots: [1]

  function actionAt(index) {
    if (index === frameModeRow) return "mode"
    if (index === frameHomeRow) return "recenter"
    var slot = framePresetAt(index)
    if (slot) return (savedSlots.indexOf(slot) >= 0 ? "recall:" : "store:") + slot
    if (index === framePanRow || index === frameTiltRow || index === frameZoomRow)
      return "slider"
    return "nothing"
  }

  // What h/l does, in adjustHorizontal's order. "" means the row has no horizontal
  // action — which is correct for recenter and the slots.
  function adjustAt(index) {
    if (index === frameModeRow) return "mode"
    if (index === framePanRow) return "pan"
    if (index === frameTiltRow) return "tilt"
    if (index === frameZoomRow) return "zoom"
    return ""
  }

  TestCase {
    name: "FrameCursor"

    function init() {
      root.page = "frame"
      root.focusSection = "frame"
      root.selectedIndex = 0
      root.savedSlots = [1]
    }

    // ---- the row count matches the rows that exist ----

    function test_the_count_reaches_the_last_slot_and_stops() {
      // Mode, pan, tilt, zoom, recenter, then a row per slot. Written out against
      // the real slot count so a fourth slot has to come through here.
      compare(Model.PRESET_SLOTS.length, 3)
      compare(root.sectionCount("frame"), 8)
      compare(root.framePresetRow, 5)
    }

    function test_the_mode_row_is_the_first_row() {
      // The page the panel opens on, so this is the row the cursor appears on when
      // someone presses j for the first time. Mode is the right thing to land on:
      // tracking-versus-manual is the decision the rest of the page depends on.
      compare(root.frameModeRow, 0)
      compare(root.actionAt(0), "mode")
    }

    function test_the_last_slot_is_the_last_row() {
      compare(root.framePresetAt(root.sectionCount("frame") - 1),
              Model.PRESET_SLOTS[Model.PRESET_SLOTS.length - 1])
    }

    function test_walking_down_visits_every_row_in_the_order_it_is_drawn() {
      // Drawn order, not just coverage: this is the invariant that was once wrong on
      // the IMAGE page, where every count added up and only the screen disagreed.
      var seen = []
      for (var i = 0; i < 20; i++) {
        seen.push(root.actionAt(root.selectedIndex))
        root.moveCursor(1)
      }
      compare(seen.slice(0, 8).join(" "),
              "mode slider slider slider recenter recall:1 store:2 store:3")
      compare(root.selectedIndex, root.sectionCount("frame") - 1)
    }

    function test_walking_back_up_stops_at_the_top() {
      root.selectedIndex = root.sectionCount("frame") - 1
      for (var i = 0; i < 20; i++) root.moveCursor(-1)
      compare(root.selectedIndex, 0)
      compare(root.actionAt(0), "mode")
    }

    function test_no_row_maps_to_nothing() {
      // A hole in the middle of the list is a cursor that lands somewhere and does
      // nothing on Enter — indistinguishable from a broken key.
      for (var i = 0; i < root.sectionCount("frame"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    // ---- the wrong row must not answer ----

    function test_only_slot_rows_are_slots() {
      // The one that writes to the camera: Enter on an empty slot *stores* the current
      // position, so a slider row answering here would overwrite a saved framing from
      // a row about something else — and `x` on it would erase one.
      for (var i = 0; i < root.framePresetRow; i++)
        compare(root.framePresetAt(i), 0, "row " + i + " answered as a slot")
      compare(root.framePresetAt(-1), 0)
      compare(root.framePresetAt(root.sectionCount("frame")), 0)
    }

    function test_zero_is_what_a_non_slot_row_returns() {
      // Every caller guards on falsiness rather than comparing to null, so a slot
      // lookup that returned undefined would still be safe but one that returned a
      // number for a non-slot row would not. Slot numbers start at 1 for this reason.
      verify(!root.framePresetAt(root.frameModeRow))
      verify(!root.framePresetAt(root.frameHomeRow))
      verify(root.framePresetAt(root.framePresetRow))
      verify(Model.PRESET_SLOTS.indexOf(0) < 0)
    }

    function test_the_sliders_answer_to_h_and_l_and_to_nothing_else() {
      // Each slider's own axis and no other. h/l on tilt that panned would move the
      // camera in the wrong plane while the user watched the tilt row — the camera
      // doing something visibly wrong, which reads as broken hardware.
      compare(root.adjustAt(root.framePanRow), "pan")
      compare(root.adjustAt(root.frameTiltRow), "tilt")
      compare(root.adjustAt(root.frameZoomRow), "zoom")
    }

    function test_recenter_has_no_horizontal_action() {
      // A single action with Enter as its key — plus `c`. h/l on it must do nothing
      // rather than fall into a neighbouring slider, which is what a chain of
      // else-ifs produces when a case is dropped.
      compare(root.adjustAt(root.frameHomeRow), "")
    }

    function test_the_slots_ignore_h_and_l() {
      // Recall, save and clear are Enter, `s` and `x`. There is nothing to sweep, and
      // a slot that answered would be reachable by the key held down to pan.
      for (var i = 0; i < Model.PRESET_SLOTS.length; i++)
        compare(root.adjustAt(root.framePresetRow + i), "",
                "slot row " + i + " answered to h/l")
    }

    function test_the_mode_row_answers_to_both_enter_and_h_and_l() {
      // Deliberate, and the exception to the rule above: the chips are a group, and
      // every chip group in the bar sweeps under h/l. A later tidy-up reading "chips
      // are boolean, so h/l has nothing to do" would take this away.
      compare(root.actionAt(root.frameModeRow), "mode")
      compare(root.adjustAt(root.frameModeRow), "mode")
    }

    // ---- what the slots hold changes under the cursor ----

    function test_a_slot_that_gains_a_preset_switches_from_store_to_recall() {
      // One key, two meanings, decided by whether the slot holds anything — so the
      // second press on the same row must not store again over what the first saved.
      root.selectedIndex = root.framePresetRow + 1
      compare(root.actionAt(root.selectedIndex), "store:2")
      root.savedSlots = [1, 2]
      compare(root.actionAt(root.selectedIndex), "recall:2")
      compare(root.selectedIndex, root.framePresetRow + 1)
    }

    function test_clearing_a_slot_leaves_the_row_where_it_was() {
      // Unlike the IMAGE page's profiles, the slots are a fixed list: clearing one
      // empties it rather than removing its row, so the cursor cannot be left past the
      // end and the row goes back to offering "store".
      root.savedSlots = [1, 2, 3]
      root.selectedIndex = root.sectionCount("frame") - 1
      root.savedSlots = [1, 2]
      root.clampCursor()
      compare(root.selectedIndex, root.sectionCount("frame") - 1)
      compare(root.actionAt(root.selectedIndex), "store:3")
    }

    // ---- the page is the cursor's authority ----

    function test_the_row_count_does_not_depend_on_the_camera() {
      // Every row is drawn whatever the camera reported — an unread pan shows its
      // slider disabled rather than vanishing — so unlike IMAGE there is no shape here
      // for a failed read to change. Pinned so a "hide what we could not read" change
      // has to come through the cursor arithmetic too.
      compare(root.sectionCount("frame"), 8)
      root.savedSlots = []
      compare(root.sectionCount("frame"), 8)
      for (var i = 0; i < root.sectionCount("frame"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    function test_a_cursor_left_on_another_page_is_pulled_onto_this_one() {
      // `page` decides, not the cursor: a section string that does not match the drawn
      // page is a ring on rows nobody can see — and on this page, an Enter that could
      // reach a slot from a row belonging to a different list entirely.
      root.focusSection = "settings"
      root.selectedIndex = 11
      root.clampCursor()
      compare(root.focusSection, "frame")
      compare(root.selectedIndex, 0)
    }

    // *(reported)* "the button to control preview is too far from the preview window"
    // took the preview switch off this page and pinned it over the picture, next to
    // the privacy switch. So there are two off-page switches now, and they are told
    // apart by index below zero — which is the same value moveCursor already read as
    // "not on a row".
    function test_the_two_pinned_switches_are_not_rows_and_j_comes_onto_the_page() {
      // Neither switch is a row on any page, so j from either has to land on row 0
      // rather than on row 1 — and clampCursor must leave them alone, or a refresh
      // would knock the cursor off a switch every time state republished.
      var pinned = [root.headerPrivacyIndex, root.headerPreviewIndex]
      for (var i = 0; i < pinned.length; i++) {
        verify(pinned[i] < 0, "pinned switch " + i + " is a row index")
        root.focusSection = "header"
        root.selectedIndex = pinned[i]
        root.clampCursor()
        compare(root.focusSection, "header")
        compare(root.selectedIndex, pinned[i])
        root.focusSection = "frame"
        root.moveCursor(1)
        compare(root.selectedIndex, 0)
      }
      // Distinct, or hovering one would draw the ring on both and Enter would reach
      // the wrong switch.
      verify(root.headerPrivacyIndex !== root.headerPreviewIndex)
    }

    function test_enter_on_a_pinned_switch_reaches_that_switch_and_no_row() {
      // activateCursor's header branch is a two-way choice on the index, with privacy
      // as the fallback: an unrecognised negative index must not fall through into the
      // page's rows, where Enter stores a preset.
      compare(root.headerActionAt(root.headerPrivacyIndex), "privacy")
      compare(root.headerActionAt(root.headerPreviewIndex), "preview")
      compare(root.headerActionAt(-99), "privacy")
    }
  }
}
