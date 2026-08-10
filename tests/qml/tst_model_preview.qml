// Preview helpers in Model.js: which state blocks the preview, what the frame
// says about it, and the command that persists the switch.
//
// The blocker precedence is worth pinning because the states overlap constantly —
// a camera can be absent *and* the preview disabled, or privacy-closed *and* held
// by another app — and the panel shows exactly one reason. Get the order wrong and
// the frame confidently explains the wrong thing.
//
// previewSettingArgs gets tests for one reason above all: its value argument is
// parsed as JSON by the shell, so "false" (a quoted string) is truthy and would
// silently leave the preview running. That failure is invisible in review and
// invisible at runtime — the switch moves, the setting persists, the preview stays.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
//
// Note: /usr/bin/qmltestrunner is Qt5 on Arch and exits silently on these files.
// The Qt6 binary under /usr/lib/qt6/bin is the one that works.
import QtQuick
import QtTest
import "../../Model.js" as Model

Item {
  // A parsed state object, defaulted to the everything-fine case so each test can
  // override only the field it is about.
  //
  // Named `cam` rather than `state` because `state` is a QML Item property and
  // shadowing it makes every call fail with "not a function".
  function cam(props) {
    var s = {
      present: true, mode: "standard", privacy: false, streaming: null,
      pan: 0, tilt: 0, zoom: 100, video: "/dev/video0", error: ""
    }
    for (var k in props) s[k] = props[k]
    return s
  }

  TestCase {
    name: "ModelPreview"

    // ---- blocker precedence ----

    function test_nothing_blocks_an_open_panel_with_a_healthy_camera() {
      compare(Model.previewBlocker(cam({}), true, true), "")
    }

    function test_a_closed_panel_blocks_last() {
      // Not a fault, just "no one is looking" — and it is what stops the shell
      // from holding the camera open all day.
      compare(Model.previewBlocker(cam({}), true, false), "closed")
    }

    function test_no_camera_outranks_everything() {
      // Absent hardware is the only honest answer even when three other
      // conditions also apply, so it is checked first.
      compare(Model.previewBlocker(cam({ present: false, privacy: true, streaming: true }),
                                   false, false), "no-camera")
    }

    function test_disabled_outranks_privacy_and_busy() {
      // The setting is a decision the user made; the others are circumstances.
      // Reporting "lens closed" to someone who turned the preview off would
      // suggest reopening the lens would bring it back, and it would not.
      compare(Model.previewBlocker(cam({ privacy: true, streaming: true }), false, true),
              "disabled")
    }

    function test_privacy_outranks_busy() {
      compare(Model.previewBlocker(cam({ privacy: true, streaming: true }), true, true),
              "privacy")
    }

    function test_busy_outranks_a_closed_panel() {
      // Both are true while another app streams and the panel is shut, and
      // "closed" would be the useless one to surface if the panel then opened.
      compare(Model.previewBlocker(cam({ streaming: true }), true, false), "busy")
    }

    // ---- our own snapshot ----
    //
    // A still needs the stream the preview is holding, so `capturing` is the one
    // blocker the panel imposes on itself. Its precedence is the interesting part:
    // second only to a missing camera, because the user just asked for it.

    function test_capturing_blocks_the_preview() {
      compare(Model.previewBlocker(cam({}), true, true, true), "capturing")
    }

    function test_capturing_outranks_disabled_privacy_and_busy() {
      // All three would be true of a camera in privacy that someone else holds with
      // the preview switched off — and none of them is why the frame went dark. The
      // snapshot is, and it is the only one that is about to end on its own.
      compare(Model.previewBlocker(cam({ privacy: true, streaming: true }),
                                   false, true, true), "capturing")
    }

    function test_no_camera_still_outranks_capturing() {
      // `snapshotRunning` is set before the helper is asked, so a still requested
      // on an unplugged camera passes through here. Absent hardware is the honest
      // answer; "taking a snapshot" would be a promise nothing can keep.
      compare(Model.previewBlocker(cam({ present: false }), true, true, true), "no-camera")
    }

    function test_an_omitted_capturing_argument_does_not_block() {
      // Every call site passes it, but the default has to be "not capturing" —
      // undefined reading as truthy would put the panel in a permanent snapshot.
      compare(Model.previewBlocker(cam({}), true, true), "")
      compare(Model.previewNote(cam({}), true, true), "")
    }

    function test_the_capturing_note_and_hint_say_it_is_temporary() {
      // Both, because the note alone ("Taking a snapshot") reads like a state the
      // preview is stuck in rather than a moment it is yielding.
      compare(Model.previewNote(cam({}), true, true, true), "Taking a snapshot")
      verify(Model.previewHint(cam({}), true, true, true) !== "")
    }

    function test_a_missing_state_object_is_no_camera_rather_than_a_crash() {
      // The panel renders before the first helper read returns.
      compare(Model.previewBlocker(null, true, true), "no-camera")
      compare(Model.previewBlocker(undefined, true, true), "no-camera")
    }

    // ---- what the frame says ----

    function test_the_note_names_the_blocker() {
      compare(Model.previewNote(cam({ present: false }), true, true), "No camera")
      compare(Model.previewNote(cam({}), false, true), "Preview off")
      compare(Model.previewNote(cam({ privacy: true }), true, true), "Lens closed")
    }

    function test_the_note_is_empty_when_the_preview_is_showing() {
      // Emptiness is load-bearing: it is what hides the placeholder behind the
      // live image rather than drawing text over video.
      compare(Model.previewNote(cam({}), true, true), "")
    }

    function test_the_busy_note_names_the_app_when_it_can() {
      // "In use by zoom" is actionable; "In use" is only a shrug, so the app name
      // is used whenever the helper managed to find one. `streaming` says whether
      // anyone holds the stream; `streamUsers` says who, and can be empty when
      // /proc did not give up an owning process.
      compare(Model.previewNote(cam({ streaming: true, streamUsers: ["zoom"] }), true, true),
              "In use by zoom")
      compare(Model.previewNote(cam({ streaming: true, streamUsers: [] }), true, true), "In use")
      compare(Model.previewNote(cam({ streaming: true, streamUsers: ["zoom", "obs"] }),
                                true, true), "In use by 2 apps")
    }

    function test_only_the_confusing_blockers_get_a_hint() {
      // A blank preview during a call is the case that reads as a broken widget,
      // so it is the case that gets a sentence. "Lens closed" explains itself.
      verify(Model.previewHint(cam({ streaming: true }), true, true) !== "")
      compare(Model.previewHint(cam({ privacy: true }), true, true), "")
      compare(Model.previewHint(cam({ present: false }), true, true), "")
      compare(Model.previewHint(cam({}), true, true), "")
    }

    function test_the_disabled_hint_points_at_the_switch_not_at_settings() {
      // There is a switch on the FRAMING header now. Sending someone to the widget
      // settings dialog while a control sits a few lines above would be actively
      // misleading, so this asserts the old instruction is gone.
      var hint = Model.previewHint(cam({}), false, true)
      verify(hint.indexOf("switch") >= 0)
      verify(hint.indexOf("settings") < 0)
    }

    // ---- the switch's glyph ----

    function test_previewIcon_is_an_eye_that_closes() {
      // md-eye and md-eye_off, verified present in the Nerd Font by glyph name.
      compare(Model.previewIcon(true), "\u{F0208}")
      compare(Model.previewIcon(false), "\u{F0209}")
      verify(Model.previewIcon(true) !== Model.previewIcon(false))
    }

    // ---- persisting the switch ----

    function test_previewSettingArgs_writes_bare_json_booleans() {
      // The whole reason this function is tested. `setBarWidget` JSON-parses its
      // value argument, so a quoted "false" would arrive as a truthy string and
      // the preview would stay on with the switch showing off.
      var off = Model.previewSettingArgs("nille.emeet-pixy", false)
      compare(off[off.length - 2], "false")
      var on = Model.previewSettingArgs("nille.emeet-pixy", true)
      compare(on[on.length - 2], "true")
      verify(off.indexOf("\"false\"") < 0)
    }

    function test_previewSettingArgs_targets_the_shell_and_the_given_module() {
      // argv, not a shell string: the caller uses Quickshell.execDetached, so a
      // stray quote here would be a literal argument rather than a syntax error.
      var argv = Model.previewSettingArgs("nille.emeet-pixy", false)
      compare(argv[0], "omarchy-shell")
      compare(argv.indexOf("shell") >= 0, true)
      compare(argv.indexOf("setBarWidget") >= 0, true)
      compare(argv.indexOf("nille.emeet-pixy") >= 0, true)
      compare(argv.indexOf("preview") >= 0, true)
      // Empty selector, so the write applies to every instance of the widget.
      compare(argv[argv.length - 1], "{}")
    }

    function test_previewSettingArgs_takes_the_module_id_rather_than_assuming_it() {
      // The panel passes its own moduleName. Hardcoding the id here would break
      // silently for anyone who renamed or vendored the plugin: the write would
      // land on a widget that is not this one.
      var argv = Model.previewSettingArgs("someone.else", true)
      compare(argv.indexOf("someone.else") >= 0, true)
      compare(argv.indexOf("nille.emeet-pixy") < 0, true)
    }
  }
}
