// The pages: which tabs a camera earns, which one is current, and how the bracket
// keys move between them.
//
// *(reported)* "since it is longer than the containing box there is no way to see
// the preview window when adjusting most of the settings", and then, of the floating
// mini-preview that first answered it, "not sure i love the floating sticky thing".
// This file is what replaced both — the panel is four pages that each fit, so the
// preview can be pinned above them and there is no scroll to escape.
//
// It also replaces tst_model_preview_dock.qml, which pinned the arithmetic the dock
// needed: a progress that never reached 1, a docked x computed from the wrong width,
// a divide by zero on an unlaid-out slot. None of it exists now, and the deletion is
// most of the point — a fixed frame has no arithmetic to get wrong.
//
// What is worth pinning here instead is narrower but sharper, because every failure
// in it is a panel you cannot navigate rather than a picture in the wrong place:
//
//   A page that is drawn but not in the tab bar, or in the bar but never drawn.
//   Both come from visiblePages and the panel's `visible:` bindings disagreeing, and
//   the second is a tab that does nothing when clicked.
//
//   A current page that is not in the list. The mic node comes and goes with
//   PipeWire, so this happens on a running system: no tab highlighted, and the
//   bracket keys with no index to step from.
//
//   A step that wraps. Wrapping from SETTINGS to FRAME reads as a jump rather than a
//   move, and it is one comparison away from being written that way.
//
//   MIC's own key on MIC. The hint line is per page precisely so it names no key that
//   does nothing — and `m` is the one key that works everywhere, which makes it the
//   one most likely to be listed twice.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest
import "../../Model.js" as Model

Item {
  // A camera with everything: image controls read, a mic on the graph, HID open.
  // Each test turns off the one capability it is about.
  function caps(props) {
    var c = { hasImage: true, hasMic: true, hasVendor: true }
    for (var k in props) c[k] = props[k]
    return c
  }

  function keys(pages) {
    var out = []
    for (var i = 0; i < pages.length; i++) out.push(pages[i].key)
    return out
  }

  TestCase {
    name: "ModelPages"

    // ---- which tabs exist ----

    function test_a_full_camera_gets_every_page_in_order() {
      // The order is editorial and it is the tab order, the cursor order and the
      // bracket-key order all at once, so it is worth stating outright: FRAME first
      // because it is what the widget is for, SETTINGS last because it is the page
      // you visit once.
      compare(keys(Model.visiblePages(caps({}))), ["frame", "image", "mic", "settings"])
    }

    function test_frame_survives_a_camera_that_is_not_there() {
      // It is where "No EMEET PIXY found" is explained, so it has to exist before
      // anything about the camera is known — including from the very first binding
      // evaluation, when caps is still an empty object.
      compare(keys(Model.visiblePages({})), ["frame"])
      compare(keys(Model.visiblePages(null)), ["frame"])
      compare(keys(Model.visiblePages(caps({ hasImage: false, hasMic: false,
                                             hasVendor: false }))), ["frame"])
    }

    function test_a_capability_the_camera_lacks_takes_its_tab_with_it() {
      // A tab for an empty page is worse than a missing tab: it is a place to go that
      // says nothing when you get there, and it costs a keypress to find that out.
      compare(keys(Model.visiblePages(caps({ hasMic: false }))),
              ["frame", "image", "settings"])
      compare(keys(Model.visiblePages(caps({ hasImage: false }))),
              ["frame", "mic", "settings"])
      compare(keys(Model.visiblePages(caps({ hasVendor: false }))),
              ["frame", "image", "mic"])
    }

    function test_every_page_carries_a_label_and_a_tooltip() {
      // The label is the chip and the tooltip says what the page holds. A blank
      // either way is a tab you cannot read, and PAGES is the only place both live.
      for (var i = 0; i < Model.PAGES.length; i++) {
        var page = Model.PAGES[i]
        verify(page.key !== "", "page " + i + " has no key")
        verify(page.label !== "", page.key + " has no label")
        verify(page.tooltip !== "", page.key + " has no tooltip")
      }
    }

    // ---- which one is current ----

    function test_a_page_that_exists_is_kept() {
      var pages = Model.visiblePages(caps({}))
      compare(Model.resolvePage("settings", pages), "settings")
      compare(Model.resolvePage("mic", pages), "mic")
    }

    function test_a_page_that_has_gone_falls_back_to_the_first() {
      // The real case: PipeWire restarts while someone is on MIC. Falling back to the
      // first page rather than the nearest neighbour, because the first page is the
      // only one guaranteed to be there.
      var pages = Model.visiblePages(caps({ hasMic: false }))
      compare(Model.resolvePage("mic", pages), "frame")
      compare(Model.resolvePage("nonsense", pages), "frame")
      compare(Model.resolvePage("", pages), "frame")
    }

    function test_no_pages_at_all_resolves_to_nothing_rather_than_guessing() {
      // Cannot happen — FRAME is unconditional — but the panel treats "" as "do not
      // switch", and a fallback of "frame" against an empty list would be a page key
      // that no tab and no section matches.
      compare(Model.resolvePage("frame", []), "")
      compare(Model.resolvePage("frame", null), "")
    }

    // ---- moving between them ----

    function test_the_brackets_step_one_page_at_a_time() {
      var pages = Model.visiblePages(caps({}))
      compare(Model.stepPage("frame", pages, 1), "image")
      compare(Model.stepPage("image", pages, 1), "mic")
      compare(Model.stepPage("mic", pages, -1), "image")
    }

    function test_the_ends_stop_rather_than_wrapping() {
      // A tab bar has a left and a right end. Wrapping SETTINGS → FRAME reads as the
      // panel jumping somewhere rather than moving, which is the opposite of the chip
      // groups — those wrap, because a three-option cycle has no ends to protect.
      var pages = Model.visiblePages(caps({}))
      compare(Model.stepPage("frame", pages, -1), "frame")
      compare(Model.stepPage("settings", pages, 1), "settings")
    }

    function test_stepping_skips_the_pages_this_camera_does_not_have() {
      // The list is the authority, not PAGES: on a camera with no mic, `]` from IMAGE
      // has to reach SETTINGS rather than stopping on a tab that is not drawn.
      var pages = Model.visiblePages(caps({ hasMic: false }))
      compare(Model.stepPage("image", pages, 1), "settings")
      compare(Model.stepPage("settings", pages, -1), "image")
    }

    function test_stepping_from_a_page_that_is_gone_lands_on_the_first() {
      // Belt and braces against the order of two bindings: `pages` can update before
      // the panel has re-resolved `page`, and a bracket press in that window must not
      // return something absent. Index 0 is the treated-as-current fallback, so `]`
      // from nowhere goes to the second page and `[` stays put.
      var pages = Model.visiblePages(caps({ hasMic: false }))
      compare(Model.stepPage("mic", pages, -1), "frame")
      compare(Model.stepPage("mic", pages, 1), "image")
    }

    function test_stepping_with_no_pages_does_not_throw() {
      compare(Model.stepPage("frame", [], 1), "")
      compare(Model.stepPage("frame", null, -1), "")
    }

    // ---- the tab bar's highlight ----

    function test_the_index_is_the_position_in_the_visible_list() {
      // What paints the current chip. Measured against the visible list rather than
      // PAGES, or a camera with no image controls would highlight the tab to the left
      // of the one it is on.
      var pages = Model.visiblePages(caps({ hasImage: false }))
      compare(Model.pageIndex("frame", pages), 0)
      compare(Model.pageIndex("mic", pages), 1)
      compare(Model.pageIndex("settings", pages), 2)
    }

    function test_a_page_not_in_the_list_has_no_index() {
      // -1 rather than 0, which is what the panel passes to ButtonGroup to mean "no
      // chip is current" — 0 would light up FRAME while another page was drawn.
      var pages = Model.visiblePages(caps({ hasMic: false }))
      compare(Model.pageIndex("mic", pages), -1)
      compare(Model.pageIndex("frame", []), -1)
      compare(Model.pageIndex("frame", null), -1)
    }

    // ---- what the hint line says ----

    function test_every_page_names_the_page_key_first() {
      // It is the one key that is new, so it leads on all four. And it is `[/]`
      // rather than Tab: every other panel in the shell binds Tab to switching bar
      // panels, and it is not h/l, which sweeps whatever slider the cursor is on.
      var pages = Model.visiblePages(caps({}))
      for (var i = 0; i < pages.length; i++) {
        var hint = Model.pageHints(pages[i].key, caps({}))
        compare(hint.indexOf("[/] page"), 0, pages[i].key + ": " + hint)
        verify(hint.indexOf("tab ") < 0, pages[i].key + " claims Tab: " + hint)
      }
    }

    function test_every_page_ends_with_refresh_and_close() {
      // Both work everywhere, and Esc closing outright — rather than backing out a
      // level first, as the two sub-pages needed — is the thing this restructure
      // changed about them.
      var pages = Model.visiblePages(caps({}))
      for (var i = 0; i < pages.length; i++) {
        var hint = Model.pageHints(pages[i].key, caps({}))
        verify(hint.indexOf("r refresh") >= 0, pages[i].key + ": " + hint)
        verify(hint.indexOf("esc close") >= 0, pages[i].key + ": " + hint)
        verify(hint.indexOf("esc back") < 0, pages[i].key + " still says back")
      }
    }

    function test_only_the_frame_page_offers_the_framing_keys() {
      // 1-3 recalls a framing preset, and it is deliberately dead elsewhere: IMAGE's
      // profiles are named rather than numbered and SETTINGS' slots are the camera's
      // own, so a hint naming it there would point at a list that is not on screen.
      verify(Model.pageHints("frame", caps({})).indexOf("1-3 recall") >= 0)
      verify(Model.pageHints("image", caps({})).indexOf("1-3") < 0)
      verify(Model.pageHints("settings", caps({})).indexOf("1-3") < 0)
      verify(Model.pageHints("frame", caps({})).indexOf("c recenter") >= 0)
      verify(Model.pageHints("image", caps({})).indexOf("recenter") < 0)
    }

    function test_mute_is_offered_everywhere_but_named_once() {
      // 'm' works on every page, so every page says so — except MIC, which lists it
      // among its own keys. Saying it twice on one line is the failure this catches,
      // and it is the shape a later edit most easily produces.
      var mic = Model.pageHints("mic", caps({}))
      compare(mic.indexOf("m mute"), mic.lastIndexOf("m mute"), mic)
      verify(Model.pageHints("frame", caps({})).indexOf("m mute") >= 0)
      verify(Model.pageHints("settings", caps({})).indexOf("m mute") >= 0)
    }

    function test_a_camera_with_no_microphone_is_not_offered_mute() {
      // The MIC page cannot be reached on such a camera, so this is about the other
      // three: a key that would do nothing, on hardware that has no mic to mute.
      verify(Model.pageHints("frame", caps({ hasMic: false })).indexOf("mute") < 0)
      verify(Model.pageHints("settings", caps({ hasMic: false })).indexOf("mute") < 0)
    }

    function test_an_unknown_page_still_gets_the_keys_that_always_work() {
      // Reachable for one frame while `page` and `pages` disagree. A hint line that
      // came back empty would blink the block out and shift the panel's height.
      var hint = Model.pageHints("nonsense", caps({}))
      verify(hint.indexOf("[/] page") >= 0, hint)
      verify(hint.indexOf("esc close") >= 0, hint)
    }
  }
}
