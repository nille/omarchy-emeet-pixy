// Microphone helpers in Model.js.
//
// These run in qmltestrunner rather than in the Python suite because Model.js is
// QML JavaScript, and they are worth having because the mic section's correctness
// is almost entirely node *selection*: pick the wrong PipeWire node and every
// control still works, just on the wrong microphone. That failure is invisible
// until someone mutes and is still heard.
//
// No PipeWire here. isPixyMic only reads properties off whatever it is handed, so
// plain objects standing in for PwNode are enough — and are better, because they
// can express the cases a real graph will not reproduce on demand (a PIXY sink, a
// node whose identity lives only in `properties`).
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
//
// Note: /usr/bin/qmltestrunner is Qt5 on Arch and exits silently on these files.
// The Qt6 binary under /usr/lib/qt6/bin is the one that works.
import QtQuick
import QtTest
import "../../Model.js" as Model

Item {
  // The real node on the development machine, kept verbatim: the serial in the
  // middle is the reason isPixyMic matches a substring rather than a full name.
  readonly property string realName: "alsa_input.usb-EMEET_EMEET_PIXY_A260204000408883-02.mono-fallback"

  // A stand-in PwNode. `audio` defaults to an object because that is what an
  // audio node looks like — the cases that matter are the ones that override it
  // to null, which is how the V4L2 camera node presents.
  function node(props) {
    var n = {
      name: "", nickname: "", description: "",
      isSink: false, isStream: false, audio: { volume: 1, muted: false },
      properties: {}
    }
    for (var k in props) n[k] = props[k]
    return n
  }

  TestCase {
    name: "ModelMic"

    // ---- node selection ----

    function test_matches_the_real_pixy_source() {
      verify(Model.isPixyMic(node({ name: realName, nickname: "EMEET PIXY" })))
    }

    function test_matches_on_nickname_alone() {
      // A firmware or PipeWire change could rename the node; the nick is the
      // second chance rather than a single point of failure.
      verify(Model.isPixyMic(node({ name: "alsa_input.usb-1234", nickname: "EMEET PIXY" })))
    }

    function test_falls_back_to_properties_when_the_accessors_are_empty() {
      // Some Quickshell versions leave the plain accessors blank on a
      // partially-bound node, so identity is only in the property map.
      verify(Model.isPixyMic(node({
        properties: {
          "node.name": realName,
          "node.nick": "EMEET PIXY",
          "node.description": "EMEET PIXY Mono"
        }
      })))
    }

    function test_rejects_other_microphones() {
      // The two other sources on the development machine. Muting one of these
      // from a panel titled PIXY is the exact bug this function prevents.
      verify(!Model.isPixyMic(node({
        name: "alsa_input.usb-OWC_Thunderbolt_3_Audio_Device-00.mono-fallback",
        nickname: "OWC Thunderbolt 3 Audio Device"
      })))
      verify(!Model.isPixyMic(node({
        name: "alsa_input.pci-0000_00_1f.3.HiFi__Mic1__source",
        description: "Core Ultra Processors (Series 3) HD Audio Microphones"
      })))
    }

    // The trap this whole function exists for. *(observed)* The PIXY publishes a
    // second node with the same nickname: its V4L2 camera. Values below are the
    // real ones from the development machine.
    //
    // Note the name — `v4l2_input`. Any "is this an input" test based on the name
    // matches it, which is why selection rests on `audio` instead.
    function test_rejects_the_pixy_camera_node() {
      var camera = node({
        name: "v4l2_input.pci-0000_3d_00.0-usb-0_2_1.0",
        nickname: "EMEET PIXY",
        description: "EMEET PIXY (V4L2)",
        audio: null
      })
      verify(!Model.isPixyMic(camera),
             "the V4L2 camera node shares the PIXY nickname and must not be taken for the mic")
    }

    function test_picks_the_mic_even_when_the_camera_node_comes_first() {
      // The regression that matters. Both nodes match on identity, so a selector
      // that only checked the name would return whichever PipeWire enumerated
      // first — the microphone on this machine, by luck. Ordering must not decide.
      var camera = node({
        name: "v4l2_input.pci-0000_3d_00.0-usb-0_2_1.0",
        nickname: "EMEET PIXY",
        description: "EMEET PIXY (V4L2)",
        audio: null
      })
      var microphone = node({ name: realName, nickname: "EMEET PIXY",
                              description: "EMEET PIXY Mono" })
      compare(Model.findPixyMic([camera, microphone]).name, realName,
              "camera node first must still select the microphone")
      compare(Model.findPixyMic([microphone, camera]).name, realName,
              "and the other order must agree")
    }

    function test_rejects_sinks_and_streams() {
      // A PIXY sink would match on identity, so direction has to be checked.
      verify(!Model.isPixyMic(node({ name: realName, isSink: true })))
      // An app's capture stream also carries the device name once it is
      // recording, and adjusting *it* would change one app's gain rather than
      // the microphone.
      verify(!Model.isPixyMic(node({ name: realName, isStream: true })))
    }

    function test_rejects_nothing_gracefully() {
      verify(!Model.isPixyMic(null))
      verify(!Model.isPixyMic(undefined))
    }

    function test_findPixyMic_picks_the_pixy_out_of_a_graph() {
      var graph = [
        node({ name: "alsa_output.pci-0000_00_1f.3.analog-stereo", isSink: true }),
        node({ name: "alsa_input.usb-OWC_Thunderbolt_3-00.mono-fallback" }),
        node({ name: realName, nickname: "EMEET PIXY" }),
        node({ name: "alsa_input.pci-0000_00_1f.3.HiFi__Mic1__source" })
      ]
      compare(Model.findPixyMic(graph).name, realName)
    }

    function test_findPixyMic_returns_null_when_absent() {
      compare(Model.findPixyMic([node({ name: "alsa_input.something-else" })]), null)
      compare(Model.findPixyMic([]), null)
      compare(Model.findPixyMic(null), null)
    }

    function test_rejects_an_unbound_node_rather_than_guessing() {
      // A node whose `audio` has not appeared cannot be confirmed as the
      // microphone. Returning false means the section stays hidden for a moment
      // and then appears, which is better than binding the wrong node and
      // presenting a mute button that does nothing.
      verify(!Model.isPixyMic(node({ name: realName, nickname: "EMEET PIXY", audio: null })))
    }

    // ---- labels ----

    function test_micLabel_prefers_muted_over_the_number() {
      // 40% muted and 0% muted are the same answer to "will they hear me", and
      // showing the percentage there would be technically true and useless.
      compare(Model.micLabel(true, true, 0.4), "Muted")
      compare(Model.micLabel(true, true, 0), "Muted")
    }

    function test_micLabel_rounds_to_whole_percent() {
      compare(Model.micLabel(true, false, 0.55), "55%")
      compare(Model.micLabel(true, false, 1), "100%")
      compare(Model.micLabel(true, false, 0), "0%")
    }

    function test_micLabel_says_when_there_is_no_microphone() {
      compare(Model.micLabel(false, false, 1), "No microphone")
    }

    function test_micIcon_crosses_out_when_muted() {
      compare(Model.micIcon(true), "󰍭")
      compare(Model.micIcon(false), "󰍬")
      verify(Model.micIcon(true) !== Model.micIcon(false))
    }

    // ---- reading a node ----

    function test_micVolume_clamps_over_amplification_to_unity() {
      // PipeWire allows volume above 1.0; the slider does not, because a webcam
      // mic driven past unity is clipping rather than louder. Left unclamped the
      // handle would also sit off the end of its track.
      compare(Model.micVolume({ audio: { volume: 1.4 } }), 1)
      compare(Model.micVolume({ audio: { volume: -0.2 } }), 0)
      compare(Model.micVolume({ audio: { volume: 0.55 } }), 0.55)
    }

    function test_micVolume_and_micMuted_survive_an_unbound_node() {
      // PwNode.audio is null until the node is bound, and the panel renders
      // before PwObjectTracker has finished. Returning 0/false beats a TypeError
      // that would blank the section.
      compare(Model.micVolume({ audio: null }), 0)
      compare(Model.micVolume(null), 0)
      compare(Model.micMuted({ audio: null }), false)
      compare(Model.micMuted(null), false)
    }

    function test_micMuted_reads_the_node() {
      compare(Model.micMuted({ audio: { muted: true } }), true)
      compare(Model.micMuted({ audio: { muted: false } }), false)
    }
  }
}
