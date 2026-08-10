// Where the preview is drawn: in its slot in FRAMING, or shrunk into the corner of
// the viewport once that slot has scrolled away.
//
// *(reported)* "since it is longer than the containing box there is no way to see
// the preview window when adjusting most of the settings". Mirroring, focus,
// brightness and the image sliders are all judged by looking at the picture, and the
// picture was at the top of a panel two pages taller than its box.
//
// The arithmetic is worth pinning because every failure in it looks like a rendering
// bug rather than a maths one: a progress that never reaches 1 leaves the picture
// half-shrunk and half-off the top edge; one that reaches 1 too early makes it jump;
// a docked x computed from the slot width rather than the current width sends the
// thumbnail past the right edge while it shrinks. All of those are invisible in
// review and obvious — but unattributable — on screen.
//
// The invariant behind most of the tests below: at progress 0 the result must equal
// the slot exactly, and at progress 1 it must equal the corner exactly. Anything in
// between only has to be monotonic, because that is all the eye asks of it.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest
import "../../Model.js" as Model

Item {
  // A 360-wide viewport with a 336-wide slot in it, which is the real panel: the
  // slot is the column width less its horizontal margin. miniWidth is the real one
  // too — two thirds of the panel, after *(reported)* "the preview window is too
  // small" retired the original third.
  function view(props) {
    var v = { width: 360, height: 620, inset: 10, miniWidth: 240, corner: "top",
              compactBelow: 200 }
    for (var k in props) v[k] = props[k]
    return v
  }

  function slot(props) {
    var s = { y: 0, height: 189, width: 336, available: true }
    for (var k in props) s[k] = props[k]
    return s
  }

  TestCase {
    name: "ModelPreviewDock"

    // ---- the two ends ----

    function test_a_slot_at_the_top_of_the_viewport_is_not_docked() {
      var dock = Model.previewDock(slot({ y: 0 }), view({}))
      compare(dock.progress, 0)
      compare(dock.docked, false)
      compare(dock.compact, false)
      compare(dock.width, 336)
      compare(dock.y, 0)
    }

    function test_in_place_the_picture_is_exactly_the_slot() {
      // The slot is a real hole in the layout, so a picture that is not exactly its
      // size and place leaves a visible seam — and the whole point of the slot is
      // that the panel is the same height it was before any of this.
      var s = slot({ y: 140 })
      var dock = Model.previewDock(s, view({}))
      compare(dock.width, s.width)
      compare(dock.height, Math.round(s.width * Model.PREVIEW_ASPECT))
      compare(dock.y, s.y)
      // Centred horizontally, as the slot is.
      compare(dock.x, Math.round((360 - s.width) / 2))
    }

    function test_a_slot_scrolled_a_full_height_past_the_top_is_fully_docked() {
      // The travel is the slot's own height, so the shrink finishes exactly as the
      // slot finishes leaving. Any other distance and the two look unrelated.
      var dock = Model.previewDock(slot({ y: -189 }), view({}))
      compare(dock.progress, 1)
      compare(dock.docked, true)
      compare(dock.width, 240)
      compare(dock.height, Math.round(240 * Model.PREVIEW_ASPECT))
    }

    function test_the_docked_corner_is_inset_from_the_top_right() {
      var dock = Model.previewDock(slot({ y: -400 }), view({}))
      compare(dock.x, 360 - 10 - dock.width)
      compare(dock.y, 10)
      // Fully on screen, which is the thing an x computed from the wrong width
      // would break.
      verify(dock.x >= 0)
      verify(dock.x + dock.width <= 360)
    }

    function test_the_bottom_corner_is_measured_from_the_bottom_edge() {
      // Not used today — the top corner is what the mockup chose — but the option
      // exists, and a corner that is off by the frame's own height is the kind of
      // thing that only shows up when someone switches it.
      var dock = Model.previewDock(slot({ y: -400 }), view({ corner: "bottom" }))
      compare(dock.y, 620 - 10 - dock.height)
      verify(dock.y + dock.height <= 620)
    }

    // ---- in between ----

    function test_progress_is_monotonic_and_the_picture_only_shrinks() {
      // The eye asks for exactly this much: no reversal on either count while
      // scrolling one way. A non-monotonic width would read as the picture pulsing.
      var last = null
      for (var y = 40; y >= -260; y -= 10) {
        var dock = Model.previewDock(slot({ y: y }), view({}))
        if (last) {
          verify(dock.progress >= last.progress, "progress reversed at y=" + y)
          verify(dock.width <= last.width, "width grew at y=" + y)
        }
        last = dock
      }
      compare(last.progress, 1)
    }

    function test_the_picture_keeps_its_shape_at_every_point() {
      // 16:9 throughout, in its frame and docked alike, so the image never distorts
      // as it moves — the one property a viewer notices instantly.
      for (var y = 40; y >= -260; y -= 7) {
        var dock = Model.previewDock(slot({ y: y }), view({}))
        compare(dock.height, Math.round(dock.width * Model.PREVIEW_ASPECT),
                "wrong aspect at y=" + y)
      }
    }

    function test_the_picture_stays_inside_the_viewport_while_it_moves() {
      // The two ends are both inside it, but a corner interpolated at the wrong
      // width overshoots the right edge in the middle — visible as the thumbnail
      // clipping against the panel border on the way in.
      for (var y = 40; y >= -260; y -= 7) {
        var dock = Model.previewDock(slot({ y: y }), view({}))
        verify(dock.x >= 0, "off the left at y=" + y)
        verify(dock.x + dock.width <= 360, "off the right at y=" + y)
      }
    }

    function test_docked_is_true_the_moment_it_starts_moving() {
      // The border changes with `docked`, and it is what separates the floating
      // picture from the rows underneath it. A threshold in the middle would leave
      // it borderless while it is half over the content.
      var dock = Model.previewDock(slot({ y: -1 }), view({}))
      verify(dock.docked)
      verify(!dock.compact)
    }

    function test_compact_follows_the_width_not_the_progress() {
      // `compact` drops the placeholder's explanatory sentence, and the question it
      // answers is "does a line of text fit" — so it is measured against the width.
      //
      // The distinction is the whole point of this test: at the real docked size the
      // frame is 240 wide and fully docked, so a progress-based threshold — which is
      // what this was before *(reported)* "the preview window is too small" — would
      // hide a sentence that fits perfectly well.
      var full = Model.previewDock(slot({ y: -189 }), view({}))
      compare(full.progress, 1)
      compare(full.width, 240)
      verify(!full.compact, "a 240-wide frame has room for the note")

      // And it does switch, when the frame really is too narrow.
      var small = Model.previewDock(slot({ y: -189 }), view({ miniWidth: 120 }))
      compare(small.width, 120)
      verify(small.compact)
    }

    function test_compact_switches_at_the_threshold_it_is_given() {
      // Either side of it, at a width the caller picked, so the comparison is the
      // stated one rather than an inequality that happens to hold.
      verify(Model.previewDock(slot({ y: -189 }), view({ miniWidth: 199 })).compact)
      verify(!Model.previewDock(slot({ y: -189 }), view({ miniWidth: 200 })).compact)
    }

    function test_no_threshold_means_nothing_is_compact() {
      // The visible failure of a missing threshold should be a clipped line, not a
      // silently hidden explanation at every size — an omitted `compactBelow` must
      // not read as "compact always".
      var v = view({})
      delete v.compactBelow
      verify(!Model.previewDock(slot({ y: -189 }), v).compact)
      verify(!Model.previewDock(slot({ y: 0 }), v).compact)
    }

    function test_the_picture_in_its_slot_is_never_compact() {
      // It is wider there than anywhere else, so this is really a guard against the
      // comparison being written the wrong way round.
      verify(!Model.previewDock(slot({ y: 0 }), view({})).compact)
      verify(!Model.previewDock(slot({ y: -40 }), view({})).compact)
    }

    // ---- no slot at all ----

    function test_no_slot_on_screen_means_docked_outright() {
      // The sub-pages replace the panel body, so there is no frame to sit in. The
      // panel hides the layer there today, but the arithmetic must not answer
      // "in place" for a slot that does not exist — that would draw the picture at
      // full width over the device page.
      var dock = Model.previewDock(slot({ available: false, y: 0 }), view({}))
      compare(dock.progress, 1)
      verify(dock.docked)
      compare(dock.width, 240)
    }

    function test_a_missing_slot_or_view_does_not_throw() {
      // Both are read off items that exist before they have been laid out, so the
      // first evaluation of this binding runs on zeroes.
      var dock = Model.previewDock(null, null)
      compare(dock.progress, 1)
      verify(isFinite(dock.x))
      verify(isFinite(dock.y))
      verify(isFinite(dock.width))
      compare(dock.width, 0)
      compare(dock.height, 0)
    }

    function test_a_slot_with_no_height_does_not_divide_by_zero() {
      // The slot's height is 0 while the preview setting is off, and the panel can
      // evaluate this a frame before the layer's own visibility catches up.
      var dock = Model.previewDock(slot({ height: 0, y: -5 }), view({}))
      verify(isFinite(dock.progress))
      verify(dock.progress >= 0 && dock.progress <= 1)
    }

    function test_a_slot_below_the_viewport_is_still_in_place() {
      // Scrolled *up* past the slot — which cannot happen from FRAMING, since it is
      // near the top, but a positive y must not read as progress either way. Only
      // the top edge docks it.
      var dock = Model.previewDock(slot({ y: 500 }), view({}))
      compare(dock.progress, 0)
      compare(dock.y, 500)
    }
  }
}
