// The advanced view's row arithmetic.
//
// That page is one keyboard section holding three different kinds of row — Back,
// then the controls, then one row per saved profile, then the save field — and
// their positions are computed from two lists whose lengths come from outside:
// the driver decides how many advanced controls exist, and the user decides how
// many profiles do. So there is no fixed layout to compare against, only
// arithmetic, and the arithmetic is what these tests pin.
//
// The failures worth catching are all silent. An off-by-one puts Enter on Back
// when the cursor is drawn on the last slider. A row that maps to nothing leaves
// j/k with a dead stop in the middle of the list. `advancedProfileAt` answering
// for the Back or Save row makes `x` — clear profile — fire on a row that is not
// a profile, which deletes something the user was not pointing at. And saving a
// profile grows the list under the cursor, so the row the cursor sits on has to
// still exist afterwards.
//
// One of these is not hypothetical: Back was numbered after the last control on
// the theory that j from the bottom should reach it, and on the rendered page
// that made j jump from the last slider to the top and then back down into the
// profiles. Nothing here caught it, because the arithmetic was self-consistent —
// only drawn order disagreed. So the walk test now pins the visited order against
// the order the rows appear on screen, which is the thing that was wrong.
//
// Caveat, the same one tst_preview_pending.qml carries: this file *replicates*
// the members from Panel.qml rather than instantiating the panel, which needs a
// Bar, a Pipewire graph and a real camera to answer. If the panel's copy drifts
// from the one below these still pass. The wiring is covered live instead, by an
// offscreen harness that walks the page against the real device.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest

Item {
  id: root

  // The two lists the layout is computed from. Only `key` matters here.
  property var advancedImage: [{ key: "hue" }, { key: "gain" },
                               { key: "autoExposure" }, { key: "exposure" }]
  property var imageProfiles: ["Studio", "Warm"]

  property string focusSection: "advanced"
  property int selectedIndex: 0

  readonly property var visibleSections: ["advanced"]

  function sectionCount(section) {
    if (section === "advanced") return advancedImage.length + 2 + imageProfiles.length
    return 0
  }

  readonly property int advancedBackRow: 0
  readonly property int advancedControlRow: 1
  readonly property int advancedProfileRow: advancedControlRow + advancedImage.length
  readonly property int advancedSaveRow: advancedProfileRow + imageProfiles.length

  function advancedControlAt(index) {
    var i = index - advancedControlRow
    return i >= 0 && i < advancedImage.length ? advancedImage[i] : null
  }

  function advancedProfileAt(index) {
    var i = index - advancedProfileRow
    return i >= 0 && i < imageProfiles.length ? imageProfiles[i] : ""
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections.length) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionCount(focusSection) ? 0 : -1
      return
    }
    var max = sectionCount(focusSection) - 1

    if (delta > 0) {
      if (selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionCount(focusSection) ? 0 : -1
      }
    } else {
      if (selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        var prevMax = sectionCount(prev) - 1
        selectedIndex = prevMax >= 0 ? prevMax : -1
      }
    }
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections.length) return
    if (focusSection === "header") return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionCount(focusSection) ? 0 : -1
      return
    }
    var count = sectionCount(focusSection)
    if (count === 0) { selectedIndex = -1; return }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // The half of publishProfiles that touches the cursor: the list arrives, and
  // the save row it was sitting on has moved.
  function publishProfiles(names) {
    var onSaveRow = focusSection === "advanced" && selectedIndex === advancedSaveRow
    imageProfiles = names
    if (onSaveRow) selectedIndex = advancedSaveRow
    clampCursor()
  }

  // What Enter would do on a row, named the way activateCursor dispatches. The
  // order matters and is the order the panel uses.
  function actionAt(index) {
    if (index === advancedBackRow) return "back"
    if (index === advancedSaveRow) return "save"
    var name = advancedProfileAt(index)
    if (name) return "load:" + name
    var control = advancedControlAt(index)
    return control ? "control:" + control.key : "nothing"
  }

  TestCase {
    name: "AdvancedCursor"

    function init() {
      root.advancedImage = [{ key: "hue" }, { key: "gain" },
                            { key: "autoExposure" }, { key: "exposure" }]
      root.imageProfiles = ["Studio", "Warm"]
      root.focusSection = "advanced"
      root.selectedIndex = 0
    }

    // ---- the row count matches the rows that exist ----

    function test_the_count_covers_every_row_once() {
      // Back + 4 controls + 2 profiles + Save. A count that is short leaves the
      // last row unreachable; one that is long gives j a dead stop at the end.
      compare(root.sectionCount("advanced"), 8)
      compare(root.advancedBackRow, 0)
      compare(root.advancedControlRow, 1)
      compare(root.advancedProfileRow, 5)
      compare(root.advancedSaveRow, 7)
    }

    function test_the_save_row_is_the_last_row() {
      // The field is at the bottom of the page, so it has to be the last index —
      // otherwise j stops one short of it or walks past it into nothing.
      compare(root.advancedSaveRow, root.sectionCount("advanced") - 1)
    }

    function test_walking_down_visits_every_row_in_the_order_it_is_drawn() {
      // The order below is the order the rows appear on the page, top to bottom.
      // That is the assertion, not just that every row is reached once: the bug
      // this replaced had j leaping from the last slider up to Back and then back
      // down into the profiles, and every count here still added up.
      var seen = []
      for (var i = 0; i < 20; i++) {
        seen.push(root.actionAt(root.selectedIndex))
        root.moveCursor(1)
      }
      compare(seen.slice(0, 8).join(" "),
              "back control:hue control:gain control:autoExposure control:exposure "
              + "load:Studio load:Warm save")
      compare(root.selectedIndex, root.advancedSaveRow)
    }

    function test_walking_back_up_returns_to_back() {
      root.selectedIndex = root.advancedSaveRow
      for (var i = 0; i < 20; i++) root.moveCursor(-1)
      compare(root.selectedIndex, root.advancedBackRow)
      compare(root.actionAt(0), "back")
    }

    function test_no_row_maps_to_nothing() {
      // A hole in the middle of the list is a cursor that lands somewhere and
      // does nothing on Enter — indistinguishable from a broken key.
      for (var i = 0; i < root.sectionCount("advanced"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    // ---- the wrong row must not answer ----

    function test_the_back_and_save_rows_are_not_profiles() {
      // `x` clears the profile the cursor sits on. If these answered, pressing it
      // on Back or Save would delete a profile the user was not pointing at.
      compare(root.advancedProfileAt(root.advancedBackRow), "")
      compare(root.advancedProfileAt(root.advancedSaveRow), "")
    }

    function test_a_control_row_is_not_a_profile_either() {
      for (var i = 0; i < root.advancedImage.length; i++)
        compare(root.advancedProfileAt(root.advancedControlRow + i), "")
    }

    function test_the_back_row_is_not_a_control() {
      // h/l on Back would otherwise adjust the last slider from a row where no
      // slider is drawn.
      compare(root.advancedControlAt(root.advancedBackRow), null)
      compare(root.advancedControlAt(root.advancedSaveRow), null)
      compare(root.advancedControlAt(-1), null)
    }

    // ---- the lists change under the cursor ----

    function test_saving_a_profile_keeps_the_cursor_on_the_save_field() {
      // The list grows by one while the cursor sits on Save, which moves Save
      // down a row. clampCursor alone does not catch this — the page got longer,
      // so the old index is still in range — and the cursor would be left on the
      // profile just written, where the next Enter recalls it instead of saving.
      root.selectedIndex = root.advancedSaveRow
      root.publishProfiles(["Studio", "Warm", "Cool"])
      compare(root.selectedIndex, root.advancedSaveRow)
      compare(root.actionAt(root.selectedIndex), "save")
    }

    function test_clearing_the_last_profile_pulls_the_cursor_back_in_range() {
      // `x` on the bottom profile removes the row the cursor is on, and the page
      // gets shorter than the cursor's index.
      root.selectedIndex = root.advancedSaveRow
      root.publishProfiles([])
      compare(root.selectedIndex, root.sectionCount("advanced") - 1)
      compare(root.actionAt(root.selectedIndex), "save")
    }

    function test_a_list_arriving_while_the_cursor_is_elsewhere_leaves_it_alone() {
      // The periodic refresh republishes the same list constantly. Following the
      // save row must not become a rule that drags the cursor off a slider.
      root.selectedIndex = root.advancedControlRow + 1
      root.publishProfiles(["Studio", "Warm", "Cool"])
      compare(root.selectedIndex, root.advancedControlRow + 1)
      compare(root.actionAt(root.selectedIndex), "control:gain")
    }

    function test_a_cursor_on_a_profile_stays_on_its_row_number() {
      // Not on the same profile — the names are sorted, so an insert shifts what
      // is under the cursor. Row-stable is the honest guarantee, and it is enough:
      // the row is drawn where the cursor is and says which profile it holds.
      root.selectedIndex = root.advancedProfileRow
      root.publishProfiles(["Cool", "Studio", "Warm"])
      compare(root.selectedIndex, root.advancedProfileRow)
      compare(root.actionAt(root.selectedIndex), "load:Cool")
    }

    function test_a_page_with_no_profiles_still_has_back_and_save() {
      // The save row collides with the profile row when the list is empty, which
      // is harmless only because no profile row is drawn — pinned so it stays so.
      root.imageProfiles = []
      compare(root.sectionCount("advanced"), 6)
      compare(root.advancedSaveRow, root.advancedProfileRow)
      compare(root.actionAt(root.advancedBackRow), "back")
      compare(root.actionAt(root.advancedSaveRow), "save")
      for (var i = 0; i < root.sectionCount("advanced"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    function test_a_camera_reporting_no_advanced_controls_still_has_a_page() {
      // Not this camera, but the list comes from the driver. Back must stay
      // reachable or the page becomes a trap with no way out but Escape.
      root.advancedImage = []
      compare(root.actionAt(root.advancedBackRow), "back")
      compare(root.advancedProfileRow, root.advancedControlRow)
      compare(root.sectionCount("advanced"), 4)
      for (var i = 0; i < root.sectionCount("advanced"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    function test_back_is_the_first_row_because_it_is_drawn_first() {
      // The one invariant that ties the arithmetic to the page: rows are numbered
      // in the order they appear, so j goes down the screen. Pinned separately
      // from the walk because it holds whatever the two list lengths are, and it
      // is the thing that was wrong.
      var shapes = [[4, 2], [0, 0], [1, 5], [8, 0], [0, 3]]
      for (var i = 0; i < shapes.length; i++) {
        root.advancedImage = Array.from({ length: shapes[i][0] }, function(_, n) {
          return { key: "c" + n }
        })
        root.imageProfiles = Array.from({ length: shapes[i][1] }, function(_, n) {
          return "p" + n
        })
        var shape = shapes[i][0] + " controls, " + shapes[i][1] + " profiles"
        compare(root.advancedBackRow, 0, shape)
        verify(root.advancedBackRow < root.advancedControlRow, shape)
        verify(root.advancedControlRow <= root.advancedProfileRow, shape)
        verify(root.advancedProfileRow <= root.advancedSaveRow, shape)
        compare(root.advancedSaveRow, root.sectionCount("advanced") - 1, shape)
      }
    }

    function test_a_shorter_control_list_shifts_every_row_below_it() {
      // A refresh that drops a control — the driver stopped reporting Gain — must
      // not leave the cursor pointing at a profile that has moved up.
      root.selectedIndex = root.advancedSaveRow
      root.advancedImage = [{ key: "hue" }]
      root.clampCursor()
      compare(root.selectedIndex, root.advancedSaveRow)
      compare(root.actionAt(root.selectedIndex), "save")
      compare(root.actionAt(root.advancedProfileRow), "load:Studio")
    }
  }
}
