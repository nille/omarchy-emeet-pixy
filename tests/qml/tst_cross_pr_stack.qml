// The seams between the five fixes, which each of their own suites is blind to.
//
// Issues 1-5 were fixed on separate branches, and every one of them passed alone.
// The behaviour a user actually meets is the composition, and three of these
// fixes only work because of a property another one provides:
//
//   The privacy guard is inert without the tri-state parser. Refusing to plan
//   Tracking when the shutter is unreadable is written as `privacy === false`,
//   which is only different from `!privacy` once the parser stops coercing an
//   unknown shutter to `false`. Landed alone it is dead code that looks alive.
//
//   Tracking is inert without a fresh snapshot. A call plan needs a known mode,
//   and the state left behind by the startup read has `mode: null`, because an
//   idle camera will not say which of Standard or Tracking it is in. Planning
//   from that stale read produces an empty plan and automation silently does
//   nothing — the original bug, with all the new code in place.
//
//   One mode write has to satisfy two intentions. Opening the shutter *and*
//   enabling Tracking is a single `mode tracking`, which works only because the
//   helper puts Standard on the wire first. Nothing in the QML can see that.
//
// So the case worth pinning is the whole path at once: a call starts while the
// panel is closed, on a camera whose shutter is shut. That is the scenario the
// reports described, and it crosses all four QML-side fixes in one go.
//
// These are deliberately written against the real CallSession and the real
// parser rather than hand-built state objects. A hand-built `{privacy: null}`
// proves nothing about whether the parser can still produce it.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest
import "../../Model.js" as Model
import "../.." as Pixy

Item {
  Pixy.CallSession { id: session }

  SignalSpy {
    id: snapshotSpy
    target: session
    signalName: "snapshotRequested"
  }

  SignalSpy {
    id: planSpy
    target: session
    signalName: "planReady"
  }

  // A helper reply as the process actually prints it, so the parser is in the
  // loop rather than bypassed.
  function reply(props) {
    var data = { ok: true, present: true, streaming: true, modeUnknown: "" }
    for (var k in props) data[k] = props[k]
    return Model.parseState(JSON.stringify(data))
  }

  function holders(streaming) {
    return JSON.stringify({
      present: true, streaming: !!streaming, selfStreaming: false,
      streamUsers: streaming ? ["zoom"] : []
    })
  }

  TestCase {
    name: "CrossPrStack"

    function init() {
      session.enabled = false
      session.present = false
      session.actions = ({})
      session.hasMic = false
      session.muted = false
      session.streaming = false
      session.generation = 0
      session.pendingToken = 0
      session.restore = null
      snapshotSpy.clear()
      planSpy.clear()
    }

    // Arms automation and takes the start edge, returning the snapshot token the
    // session is waiting on.
    function arm(acts) {
      session.enabled = true
      session.present = true
      session.actions = acts
      session.observeStreaming(true)
      compare(snapshotSpy.count, 1)
      return snapshotSpy.signalArguments[0][0]
    }

    // The headline case, and the one no single branch demonstrates: everything
    // enabled, panel closed, shutter shut. The lens opens, Tracking engages, the
    // mic unmutes, and the whole start is one mode command.
    function test_a_closed_panel_call_on_a_shuttered_camera_opens_tracks_and_unmutes() {
      var token = arm({ openLens: true, tracking: true, unmute: true })
      session.hasMic = true
      session.muted = true

      var snap = reply({ mode: "privacy", privacy: true })
      verify(Model.privacyKnown(snap), "a confirmed shutter is not the unknown case")
      verify(session.acceptSnapshot(token, snap))

      compare(planSpy.count, 1)
      var plan = planSpy.signalArguments[0][0]
      compare(plan.privacy, false)
      compare(plan.mode, "tracking")
      compare(plan.muted, false)

      // The part that used to be a queue of competing processes. Leaving privacy
      // for tracking is one command, because the helper sequences it internally.
      compare(Model.callModeTarget(plan), "tracking")

      // And the end is a single command back the other way.
      session.observeStreaming(false)
      compare(planSpy.count, 2)
      var end = planSpy.signalArguments[1][0]
      compare(end.privacy, true)
      compare(end.muted, true)
      compare(Model.callModeTarget(end), "privacy")
    }

    // The guard and the parser together. Landed apart, one is dead and the other
    // is only a UI change; together they are what stops automation opening a
    // shutter it cannot see.
    function test_an_unreadable_shutter_is_never_treated_as_an_open_one() {
      var token = arm({ openLens: false, tracking: true, unmute: false })

      var snap = reply({ mode: "standard", modeUnknown: "", privacy: null })
      compare(snap.privacy, null, "the parser must not coerce this to false")
      verify(!Model.privacyKnown(snap))

      session.acceptSnapshot(token, snap)
      if (planSpy.count > 0)
        verify(Model.planIsEmpty(planSpy.signalArguments[0][0]),
               "tracking must not be planned from an unreadable shutter")
      compare(session.restore, null, "and nothing may be recorded to restore")
    }

    // A confirmed-open shutter still gets Tracking. Without this the guard above
    // could be satisfied by refusing everything, which would disable the feature
    // rather than make it safe.
    function test_a_confirmed_open_shutter_still_gets_tracking() {
      var token = arm({ openLens: false, tracking: true, unmute: false })
      verify(session.acceptSnapshot(token, reply({ mode: "standard", privacy: false })))
      compare(planSpy.signalArguments[0][0].mode, "tracking")
    }

    // The cancellation path, which is the one that can outlive the call. A read
    // abandoned by the timeout still completes its collector with an empty
    // string, and parsing that as an absent camera is a trap the cheap holders
    // poll cannot climb out of.
    function test_a_timed_out_snapshot_leaves_presence_and_later_edges_intact() {
      var token = arm({ openLens: true, tracking: true, unmute: false })
      var camera = reply({ mode: "standard", privacy: false })

      compare(Model.parseStateReply("", true), null,
              "a cancelled read is not a device answer")
      session.rejectSnapshot(token)

      // Presence survives, so holders keeps working and still sees the call.
      camera = Model.mergeHolders(camera, holders(true))
      compare(camera.present, true)
      compare(camera.streaming, true)
      compare(planSpy.count, 0, "and no end edge is invented mid-call")

      // The real end is still the end, and the next call is still detected.
      session.observeStreaming(false)
      compare(planSpy.count, 1)
      compare(planSpy.signalArguments[0][1], "end")
      session.observeStreaming(true)
      compare(snapshotSpy.count, 2)
    }

    // Closing the shutter outranks restoring the mode, and it has to be checked
    // first rather than incidentally. A camera that was shuttered *and* in
    // Standard restores as `{mode: "standard", privacy: true}`, and answering
    // that with `standard` would end the call with the lens open — the failure
    // this whole set of fixes exists to prevent. The privacy-only restore looks
    // correct under either ordering, so it cannot be the only case pinned.
    function test_closing_the_shutter_outranks_restoring_the_mode() {
      compare(Model.callModeTarget({ mode: "standard", privacy: true }), "privacy")
      compare(Model.callModeTarget({ mode: "tracking", privacy: true }), "privacy")

      // And with the shutter staying open, the mode is what gets written.
      compare(Model.callModeTarget({ mode: "standard", privacy: false }), "standard")
    }

    // An empty read we did *not* cancel is still a fault worth reporting, so the
    // filter above cannot be a blanket one.
    function test_an_uncancelled_empty_read_is_still_an_error() {
      var parsed = Model.parseStateReply("", false)
      compare(parsed.present, false)
      compare(parsed.error, "no output")
    }
  }
}
