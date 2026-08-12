// The mode selector's two questions: can the camera change mode right now, and
// what does the panel say when it cannot.
//
// *(observed)* This exists because of a report that neither Standard nor Tracking
// was highlighted when the panel opened. Both halves of that turned out to be the
// same firmware behavior, and the second half is the one worth pinning: the camera
// discards a Standard/Tracking HID write while nothing is capturing. Tested
// against the hardware in both directions — set Tracking on an idle camera, then
// start a stream, and it reads back Standard; set Standard from Tracking the same
// way and it stays Tracking. So the chips were not merely unlit when idle, they
// were inert, and they still looked pressable.
//
// The failure this guards against is therefore not a wrong pixel. It is a control
// that accepts a click, reports no error, and does nothing — the helper returns
// ok:true because the write was delivered; the firmware simply threw it away.
//
// Privacy is the exception throughout, and it is an exception in both directions:
// entering privacy works on an idle camera and so does leaving it. That asymmetry
// is the thing most likely to be "simplified" away by someone tidying this later,
// so it gets its own tests — gating privacy would lock the lens shut on an idle
// camera, which is strictly worse than the bug being fixed.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest
import "../../Model.js" as Model

Item {
  // Defaulted to an idle camera that is present and healthy, because idle is the
  // case under test — the panel spends most of its life there.
  function cam(props) {
    var s = {
      present: true, mode: null, modeUnknown: "needs-stream", privacy: false,
      streaming: false, selfStreaming: false, streamUsers: [],
      pan: 0, tilt: 0, zoom: 100, video: "/dev/video0", error: "", hidError: ""
    }
    for (var k in props) s[k] = props[k]
    return s
  }

  TestCase {
    name: "ModelMode"

    // ---- when the camera will accept a mode write ----

    function test_an_idle_camera_cannot_change_mode() {
      // The bug. Nothing is capturing, so the write would be discarded.
      verify(!Model.modeWritable(cam({})))
    }

    function test_another_app_streaming_makes_the_mode_writable() {
      // Someone else's call is holding the stream. The control plane is
      // unaffected by *who* holds it — that separation is the whole premise of
      // this widget — so the mode can be changed mid-call.
      verify(Model.modeWritable(cam({ streaming: true, mode: "standard",
                                      modeUnknown: "" })))
    }

    function test_our_own_preview_makes_the_mode_writable() {
      // The common case by far: the panel's own preview is what satisfies the
      // firmware. Counting only *other* apps here would leave the chips dead in
      // exactly the situation where the user is looking at a live picture.
      verify(Model.modeWritable(cam({ selfStreaming: true, mode: "standard",
                                      modeUnknown: "" })))
    }

    function test_an_absent_camera_is_never_writable() {
      verify(!Model.modeWritable(cam({ present: false, streaming: true })))
    }

    function test_a_missing_state_is_not_writable() {
      // Called from a binding that evaluates before the first helper reply.
      verify(!Model.modeWritable(null))
      verify(!Model.modeWritable(undefined))
    }

    function test_writability_does_not_depend_on_the_mode_being_known() {
      // These travel together in practice — both need a stream — but they are
      // different questions, and the note below distinguishes them. A camera that
      // is streaming can be written to even if the readback has not landed yet.
      verify(Model.modeWritable(cam({ streaming: true, mode: null,
                                      modeUnknown: "needs-stream" })))
    }

    // ---- what the panel says about it ----

    function test_the_idle_note_explains_the_dimmed_chips() {
      // The user-facing half of the fix. Two hollow chips and no explanation is
      // what got reported as broken, so the note has to name the condition and
      // say what to do about it.
      var note = Model.modeNote(cam({}))
      verify(note !== "", "an idle camera must explain itself")
      verify(note.indexOf("in use") >= 0, "says what the camera needs: " + note)
      verify(note.indexOf("preview") >= 0, "says how to get there: " + note)
    }

    function test_a_streaming_camera_with_a_known_mode_says_nothing() {
      // Nothing is wrong and nothing is ambiguous, so the row is hidden rather
      // than filled with reassurance.
      compare(Model.modeNote(cam({ streaming: true, mode: "standard",
                                   modeUnknown: "" })), "")
    }

    function test_privacy_suppresses_the_note() {
      // The lens is shut, which the hero switch already states plainly. Adding a
      // paragraph about tracking there buries the thing that matters.
      compare(Model.modeNote(cam({ privacy: true, mode: "privacy" })), "")
    }

    function test_a_real_fault_outranks_the_idle_explanation() {
      // Both are true of an unplugged HID node, and only one is worth reading:
      // "turn the preview on" is useless advice when the control interface is
      // missing, and it would send someone chasing the wrong problem.
      compare(Model.modeNote(cam({ modeUnknown: "no-hid" })),
              "The vendor control interface was not found — check the udev rule.")
      compare(Model.modeNote(cam({ modeUnknown: "no-response" })),
              "The camera is not answering control queries.")
    }

    function test_the_state_parser_preserves_unknown_privacy() {
      var state = Model.parseState(JSON.stringify({
        ok: true, present: true, mode: null, modeUnknown: "no-response"
      }))
      compare(state.privacy, null)
    }

    function test_unknown_privacy_has_distinct_text_and_glyph() {
      var state = cam({ privacy: null, mode: null, modeUnknown: "no-response" })
      verify(Model.summary(state).indexOf("Privacy unknown") === 0)
      verify(Model.barIcon(state) !== Model.barIcon(cam({ privacy: false })))
      verify(Model.barIcon(state) !== Model.barIcon(cam({ privacy: true })))
    }

    function test_confirmed_privacy_values_keep_their_glyphs() {
      compare(Model.barIcon(cam({ privacy: false })), "󰖠")
      compare(Model.barIcon(cam({ privacy: true })), "󱜷")
    }

    function test_the_unknown_glyph_is_a_font_glyph_not_an_ascii_question_mark() {
      // The bar is a run of Nerd Font glyphs. A literal "?" is the shape a
      // missing glyph makes, so it would read as a font problem rather than as a
      // camera state.
      var icon = Model.barIcon(cam({ privacy: null, modeUnknown: "no-hid" }))
      verify(icon !== "?")
      verify(icon.charCodeAt(0) > 0xFF)
    }

    // Unknown privacy must not swallow the reason, which is the actionable half:
    // "no control interface" is what tells someone to check the udev rule. These
    // two strings were unreachable at one point, which is why they are pinned by
    // name here rather than only through modeNote.
    function test_unknown_privacy_still_says_why_it_is_unknown() {
      compare(Model.summary(cam({ privacy: null, mode: null, modeUnknown: "no-hid" })),
              "Privacy unknown — no control interface")
      compare(Model.summary(cam({ privacy: null, mode: null, modeUnknown: "no-response" })),
              "Privacy unknown — not responding")
      compare(Model.summary(cam({ privacy: null, mode: null, modeUnknown: "hid-error" })),
              "Privacy unknown — control interface error")
    }

    function test_a_readable_shutter_keeps_the_plain_diagnostics() {
      // Privacy known, mode not: the old wording, still reachable.
      compare(Model.summary(cam({ privacy: false, mode: null, modeUnknown: "no-response" })),
              "Not responding")
      compare(Model.summary(cam({ privacy: false, mode: null, modeUnknown: "no-hid" })),
              "No control interface")
      compare(Model.summary(cam({ privacy: false, mode: null, modeUnknown: "needs-stream" })),
              "Ready")
    }

    function test_privacy_known_separates_unknown_from_confirmed_open() {
      // null is falsy, so `!state.privacy` would fold these together — the exact
      // bug the tri-state exists to prevent.
      verify(Model.privacyKnown(cam({ privacy: false })))
      verify(Model.privacyKnown(cam({ privacy: true })))
      verify(!Model.privacyKnown(cam({ privacy: null })))
      verify(!Model.privacyKnown(null))
    }

    function test_an_older_helper_reply_still_reads_privacy_from_the_mode() {
      // No `privacy` key at all, as a helper predating the explicit field sends.
      // 0x02 is unambiguous, so mode alone is enough to confirm it.
      var state = Model.parseState(JSON.stringify({
        ok: true, present: true, mode: "privacy" }))
      compare(state.privacy, true)
    }

    function test_an_absent_camera_says_nothing_here() {
      // The panel hides this whole section without a camera; the hero line
      // already says there is none.
      compare(Model.modeNote(cam({ present: false })), "")
    }

    // ---- the chips' selected state ----

    function test_neither_chip_claims_to_be_active_when_idle() {
      // Honest, and now no longer confusing on its own: the group is dimmed and
      // the note says why.
      compare(Model.modeChipLabel("standard", cam({}), false).charAt(0), "○")
      compare(Model.modeChipLabel("tracking", cam({}), false).charAt(0), "○")
    }

    function test_the_live_mode_fills_exactly_one_dot() {
      var state = cam({ streaming: true, mode: "tracking", modeUnknown: "" })
      compare(Model.modeChipLabel("tracking", state, false).charAt(0), "●")
      compare(Model.modeChipLabel("standard", state, false).charAt(0), "○")
    }

    function test_privacy_empties_both_dots() {
      // Whatever the mode was, privacy is what the camera is doing now, and the
      // switch says so.
      var state = cam({ mode: "privacy", privacy: true })
      compare(Model.modeChipLabel("standard", state, true).charAt(0), "○")
      compare(Model.modeChipLabel("tracking", state, true).charAt(0), "○")
    }

    // ---- the summary line ----

    function test_an_idle_camera_summarizes_as_ready() {
      // Not "Unknown". The camera is fine and reachable; it just will not say
      // which of two modes it is in.
      compare(Model.summary(cam({})), "Ready")
    }

    function test_a_streaming_camera_summarizes_as_its_mode() {
      compare(Model.summary(cam({ streaming: true, mode: "tracking",
                                  modeUnknown: "" })), "Tracking")
    }
  }
}
