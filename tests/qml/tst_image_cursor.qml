// The IMAGE page's row arithmetic.
//
// One keyboard section holding three kinds of row — the controls, then one row per
// saved profile, then the save field — and their positions come from two lists whose
// lengths are decided outside this file: the driver says how many controls exist, the
// user says how many profiles do. So there is no fixed layout to compare against,
// only arithmetic, and the arithmetic is what these tests pin.
//
// The failures worth catching are all silent. An off-by-one puts Enter on the save
// field when the cursor is drawn on the last slider. A row that maps to nothing leaves
// j/k with a dead stop in the middle of the list. `imageProfileAt` answering for a
// control or the save row makes `x` — clear profile — fire on a row that is not a
// profile, which deletes something the user was not pointing at. And saving a profile
// grows the list under the cursor, so the row the cursor sits on has to still exist
// afterwards.
//
// One of these is not hypothetical, and it is why the walk test compares against
// drawn order rather than just counting: the page's first row was once numbered after
// the last control on the theory that j from the bottom should reach it, and on screen
// that made j leap from the last slider to the top and then back down into the
// profiles. Every count still added up. Only drawn order disagreed.
//
// *(reported)* "not sure i love the floating sticky thing" turned this page from a
// sub-page into a tab, which deleted its Back row — the row that bug was about. The
// invariant it left behind is the one still worth holding: rows are numbered in the
// order they are drawn, so j goes down the screen. The page also stopped being half
// the controls: the curated/advanced split existed to keep the old main page short,
// and a page that fits does not need it.
//
// Caveat, the same one tst_preview_pending.qml carries: this file *replicates* the
// members from Panel.qml rather than instantiating the panel, which needs a Bar, a
// Pipewire graph and a real camera to answer. If the panel's copy drifts from the one
// below these still pass.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest

Item {
  id: root

  // The two lists the layout is computed from. Only `key` matters here. Every
  // control the driver reported, not a curated subset — that is what the page holds
  // now.
  property var imageControls: [{ key: "brightness" }, { key: "contrast" },
                               { key: "autoExposure" }, { key: "exposure" }]
  property var imageProfiles: ["Studio", "Warm"]

  property string page: "image"
  property string focusSection: "image"
  property int selectedIndex: 0

  function sectionCount(section) {
    if (section === "image") return imageControls.length + 1 + imageProfiles.length
    return 0
  }

  readonly property int imageControlRow: 0
  readonly property int imageProfileRow: imageControlRow + imageControls.length
  readonly property int imageSaveRow: imageProfileRow + imageProfiles.length

  function imageControlAt(index) {
    var i = index - imageControlRow
    return i >= 0 && i < imageControls.length ? imageControls[i] : null
  }

  function imageProfileAt(index) {
    var i = index - imageProfileRow
    return i >= 0 && i < imageProfiles.length ? imageProfiles[i] : ""
  }

  // One list, one clamp. The two-level walk this replaces existed because the main
  // page had five sections to step between; a page is one section, so j/k is a
  // bounded increment and nothing else.
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

  // The half of publishProfiles that touches the cursor: the list arrives, and the
  // save row it was sitting on has moved.
  function publishProfiles(names) {
    var onSaveRow = focusSection === "image" && selectedIndex === imageSaveRow
    imageProfiles = names
    if (onSaveRow) selectedIndex = imageSaveRow
    clampCursor()
  }

  // What Enter would do on a row, named the way activateCursor dispatches. The order
  // matters and is the order the panel uses.
  function actionAt(index) {
    if (index === imageSaveRow) return "save"
    var name = imageProfileAt(index)
    if (name) return "load:" + name
    var control = imageControlAt(index)
    return control ? "control:" + control.key : "nothing"
  }

  TestCase {
    name: "ImageCursor"

    function init() {
      root.imageControls = [{ key: "brightness" }, { key: "contrast" },
                            { key: "autoExposure" }, { key: "exposure" }]
      root.imageProfiles = ["Studio", "Warm"]
      root.page = "image"
      root.focusSection = "image"
      root.selectedIndex = 0
    }

    // ---- the row count matches the rows that exist ----

    function test_the_count_covers_every_row_once() {
      // 4 controls + 2 profiles + Save. A count that is short leaves the last row
      // unreachable; one that is long gives j a dead stop at the end.
      compare(root.sectionCount("image"), 7)
      compare(root.imageControlRow, 0)
      compare(root.imageProfileRow, 4)
      compare(root.imageSaveRow, 6)
    }

    function test_the_first_control_is_the_first_row() {
      // No Back row any more: the page is a tab, so the way out is `[`/`]` and the
      // top row is the first thing on the page rather than a way off it.
      compare(root.imageControlRow, 0)
      compare(root.actionAt(0), "control:brightness")
    }

    function test_the_save_row_is_the_last_row() {
      // The field is at the bottom of the page, so it has to be the last index —
      // otherwise j stops one short of it or walks past it into nothing.
      compare(root.imageSaveRow, root.sectionCount("image") - 1)
    }

    function test_walking_down_visits_every_row_in_the_order_it_is_drawn() {
      // The order below is the order the rows appear on the page, top to bottom.
      // That is the assertion, not just that every row is reached once.
      var seen = []
      for (var i = 0; i < 20; i++) {
        seen.push(root.actionAt(root.selectedIndex))
        root.moveCursor(1)
      }
      compare(seen.slice(0, 7).join(" "),
              "control:brightness control:contrast control:autoExposure "
              + "control:exposure load:Studio load:Warm save")
      compare(root.selectedIndex, root.imageSaveRow)
    }

    function test_walking_back_up_stops_at_the_top() {
      root.selectedIndex = root.imageSaveRow
      for (var i = 0; i < 20; i++) root.moveCursor(-1)
      compare(root.selectedIndex, 0)
      compare(root.actionAt(0), "control:brightness")
    }

    function test_no_row_maps_to_nothing() {
      // A hole in the middle of the list is a cursor that lands somewhere and does
      // nothing on Enter — indistinguishable from a broken key.
      for (var i = 0; i < root.sectionCount("image"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    // ---- the wrong row must not answer ----

    function test_the_save_row_is_not_a_profile() {
      // `x` clears the profile the cursor sits on. If this answered, pressing it on
      // the save field would delete a profile the user was not pointing at.
      compare(root.imageProfileAt(root.imageSaveRow), "")
    }

    function test_a_control_row_is_not_a_profile_either() {
      for (var i = 0; i < root.imageControls.length; i++)
        compare(root.imageProfileAt(root.imageControlRow + i), "")
    }

    function test_a_profile_or_save_row_is_not_a_control() {
      // h/l on a profile would otherwise sweep the last slider from a row where no
      // slider is drawn.
      compare(root.imageControlAt(root.imageProfileRow), null)
      compare(root.imageControlAt(root.imageSaveRow), null)
      compare(root.imageControlAt(-1), null)
    }

    // ---- the lists change under the cursor ----

    function test_saving_a_profile_keeps_the_cursor_on_the_save_field() {
      // The list grows by one while the cursor sits on Save, which moves Save down a
      // row. clampCursor alone does not catch this — the page got longer, so the old
      // index is still in range — and the cursor would be left on the profile just
      // written, where the next Enter recalls it instead of saving.
      root.selectedIndex = root.imageSaveRow
      root.publishProfiles(["Studio", "Warm", "Cool"])
      compare(root.selectedIndex, root.imageSaveRow)
      compare(root.actionAt(root.selectedIndex), "save")
    }

    function test_clearing_the_last_profile_pulls_the_cursor_back_in_range() {
      // `x` on the bottom profile removes the row the cursor is on, and the page gets
      // shorter than the cursor's index.
      root.selectedIndex = root.imageSaveRow
      root.publishProfiles([])
      compare(root.selectedIndex, root.sectionCount("image") - 1)
      compare(root.actionAt(root.selectedIndex), "save")
    }

    function test_a_list_arriving_while_the_cursor_is_elsewhere_leaves_it_alone() {
      // The periodic refresh republishes the same list constantly. Following the save
      // row must not become a rule that drags the cursor off a slider.
      root.selectedIndex = root.imageControlRow + 1
      root.publishProfiles(["Studio", "Warm", "Cool"])
      compare(root.selectedIndex, root.imageControlRow + 1)
      compare(root.actionAt(root.selectedIndex), "control:contrast")
    }

    function test_a_cursor_on_a_profile_stays_on_its_row_number() {
      // Not on the same profile — the names are sorted, so an insert shifts what is
      // under the cursor. Row-stable is the honest guarantee, and it is enough: the
      // row is drawn where the cursor is and says which profile it holds.
      root.selectedIndex = root.imageProfileRow
      root.publishProfiles(["Cool", "Studio", "Warm"])
      compare(root.selectedIndex, root.imageProfileRow)
      compare(root.actionAt(root.selectedIndex), "load:Cool")
    }

    function test_a_page_with_no_profiles_still_has_a_save_field() {
      // The save row collides with the profile row when the list is empty, which is
      // harmless only because no profile row is drawn — pinned so it stays so.
      root.imageProfiles = []
      compare(root.sectionCount("image"), 5)
      compare(root.imageSaveRow, root.imageProfileRow)
      compare(root.actionAt(root.imageSaveRow), "save")
      for (var i = 0; i < root.sectionCount("image"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    function test_a_camera_reporting_no_controls_still_has_a_save_field() {
      // Not this camera, and the page is hidden entirely in that case — see
      // visiblePages — but the list comes from the driver and the arithmetic must not
      // produce a negative row on the way there.
      root.imageControls = []
      compare(root.imageProfileRow, root.imageControlRow)
      compare(root.sectionCount("image"), 3)
      for (var i = 0; i < root.sectionCount("image"); i++)
        verify(root.actionAt(i) !== "nothing", "row " + i + " does nothing")
    }

    function test_the_rows_are_numbered_in_the_order_they_are_drawn() {
      // The one invariant that ties the arithmetic to the page, held whatever the two
      // list lengths are. Pinned separately from the walk because that is the thing
      // that was wrong once, and it was wrong at one particular pair of lengths.
      var shapes = [[4, 2], [0, 0], [1, 5], [14, 0], [0, 3]]
      for (var i = 0; i < shapes.length; i++) {
        root.imageControls = Array.from({ length: shapes[i][0] }, function(_, n) {
          return { key: "c" + n }
        })
        root.imageProfiles = Array.from({ length: shapes[i][1] }, function(_, n) {
          return "p" + n
        })
        var shape = shapes[i][0] + " controls, " + shapes[i][1] + " profiles"
        compare(root.imageControlRow, 0, shape)
        verify(root.imageControlRow <= root.imageProfileRow, shape)
        verify(root.imageProfileRow <= root.imageSaveRow, shape)
        compare(root.imageSaveRow, root.sectionCount("image") - 1, shape)
      }
    }

    function test_a_shorter_control_list_shifts_every_row_below_it() {
      // A refresh that drops a control — the driver stopped reporting Gain — must not
      // leave the cursor pointing at a profile that has moved up.
      root.selectedIndex = root.imageSaveRow
      root.imageControls = [{ key: "brightness" }]
      root.clampCursor()
      compare(root.selectedIndex, root.imageSaveRow)
      compare(root.actionAt(root.selectedIndex), "save")
      compare(root.actionAt(root.imageProfileRow), "load:Studio")
    }

    // ---- the page is the cursor's authority ----

    function test_a_cursor_left_on_another_page_is_pulled_onto_this_one() {
      // `page` decides, not the cursor: a section string that does not match the
      // drawn page is a ring on rows nobody can see, and h/l reaching controls that
      // are not on screen. The panel resets both on every page change, so this is the
      // guard for the frame where the two disagree.
      root.focusSection = "settings"
      root.selectedIndex = 9
      root.clampCursor()
      compare(root.focusSection, "image")
      compare(root.selectedIndex, 0)
    }
  }
}
