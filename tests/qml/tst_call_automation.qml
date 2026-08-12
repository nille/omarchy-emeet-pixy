// Call automation: the edge detector, the plan a call start produces, and whether
// the end of the call puts everything back.
//
// This is the only feature here that changes the camera without anyone touching
// the panel, which sets the bar for what has to be pinned. Two failures matter
// more than the rest:
//
//   The mic that was deliberately left on. `unmute` is supposed to be a one-way
//   favour — unmute for the call, mute again *only if it was muted to begin with*.
//   A restore that fires unconditionally would mute someone mid-sentence at the end
//   of every call, and it would look like the camera did it on its own.
//
//   The round trip. `restore` records only what was actually changed, so the
//   invariant is that state → start → end → state is the identity. Tested as a
//   round trip rather than field by field, because the bug would be a field that
//   goes missing between the two halves and each half looks right alone.
//
// A call plan maps to at most one absolute mode command. The helper's command
// contract test covers the integration boundary: `mode tracking` itself puts
// Standard and then Tracking on the wire when leaving Privacy. The tests here pin
// the QML half so it cannot regress to dispatching those as competing processes.
// planIsEmpty and callActionLabel are covered because they are what stop the panel
// announcing a call it did nothing about.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
import QtQuick
import QtTest
import "../../Model.js" as Model
import "../.." as Pixy

Item {
  Pixy.CallSession {
    id: session
  }

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

  // Everything enabled, since the actions are independent and each test turns off
  // what it is not about.
  function actions(props) {
    var a = { openLens: true, tracking: true, unmute: true }
    for (var k in props) a[k] = props[k]
    return a
  }

  // The camera as a call starts: lens closed, not tracking, mic muted — the state
  // where all three actions have something to do.
  function now(props) {
    var s = { privacy: true, mode: "standard", muted: true }
    for (var k in props) s[k] = props[k]
    return s
  }

  // start → end, as the panel runs it: the plan's `restore` is what the end reads.
  function roundTrip(enabled, state) {
    var start = Model.callStartPlan(enabled, state)
    return { start: start, end: Model.callEndPlan(start.restore) }
  }

  TestCase {
    name: "CallAutomation"

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

    // ---- the edge ----

    function test_the_edge_fires_once_in_each_direction() {
      compare(Model.callEdge(false, true), "start")
      compare(Model.callEdge(true, false), "end")
    }

    function test_no_edge_when_nothing_changed() {
      // Both the full state read and the fast holders poll republish `camera`, so
      // this is asked several times a second while a call runs. An edge on every
      // republish would reapply the plan — and overwrite `restore` with the state
      // the automation itself just created, which is how the original state gets
      // lost forever.
      compare(Model.callEdge(false, false), "")
      compare(Model.callEdge(true, true), "")
    }

    function test_a_closed_panel_polls_when_call_automation_is_enabled() {
      verify(Model.shouldPollHolders(false, false, true, false))
    }

    function test_a_pending_restore_keeps_polling_after_automation_is_disabled() {
      verify(Model.shouldPollHolders(false, false, false, true))
    }

    function test_a_closed_panel_with_no_automation_does_not_poll() {
      verify(!Model.shouldPollHolders(false, false, false, false))
    }

    function test_an_open_preview_still_polls_without_automation() {
      verify(Model.shouldPollHolders(true, true, false, false))
      verify(!Model.shouldPollHolders(true, false, false, false))
    }

    function test_a_closed_panel_start_waits_for_fresh_state_then_applies_once() {
      session.enabled = true
      session.present = true
      session.actions = actions({})
      session.hasMic = true
      session.muted = true

      // No panel-open event is involved: the holders observation is the edge.
      session.observeStreaming(true)
      compare(snapshotSpy.count, 1)
      compare(planSpy.count, 0)

      var token = snapshotSpy.signalArguments[0][0]
      verify(session.acceptSnapshot(token, {
        present: true, streaming: true, privacy: true, mode: "standard"
      }))
      compare(planSpy.count, 1)
      var plan = planSpy.signalArguments[0][0]
      compare(plan.privacy, false)
      compare(plan.mode, "tracking")
      compare(plan.muted, false)

      // Republishing the same stream state cannot consume the edge twice.
      session.observeStreaming(true)
      compare(snapshotSpy.count, 1)
      compare(planSpy.count, 1)
    }

    function test_a_closed_panel_end_restores_only_the_recorded_changes() {
      session.enabled = true
      session.present = true
      session.actions = actions({ tracking: false, unmute: false })

      session.observeStreaming(true)
      var token = snapshotSpy.signalArguments[0][0]
      verify(session.acceptSnapshot(token, {
        present: true, streaming: true, privacy: true, mode: "privacy"
      }))
      compare(planSpy.count, 1)

      session.observeStreaming(false)
      compare(planSpy.count, 2)
      var end = planSpy.signalArguments[1][0]
      compare(end.privacy, true)
      compare(end.mode, undefined)
      compare(end.muted, undefined)
      compare(session.restore, null)
    }

    function test_a_snapshot_returning_after_the_call_ended_is_ignored() {
      session.enabled = true
      session.present = true
      session.actions = actions({})

      session.observeStreaming(true)
      var token = snapshotSpy.signalArguments[0][0]
      session.observeStreaming(false)
      verify(!session.acceptSnapshot(token, {
        present: true, streaming: true, privacy: true, mode: "standard"
      }))
      compare(planSpy.count, 1) // the empty end plan only
      verify(Model.planIsEmpty(planSpy.signalArguments[0][0]))
      compare(session.restore, null)
    }

    function test_a_fresh_snapshot_that_says_the_call_ended_is_consumed() {
      session.enabled = true
      session.present = true
      session.actions = actions({})

      session.observeStreaming(true)
      var token = snapshotSpy.signalArguments[0][0]
      verify(!session.acceptSnapshot(token, {
        present: true, streaming: false, privacy: true, mode: "standard"
      }))
      compare(session.pendingToken, 0)
      compare(planSpy.count, 0)
      compare(session.restore, null)
    }

    function test_disabling_automation_invalidates_a_pending_snapshot() {
      session.enabled = true
      session.present = true
      session.actions = actions({})

      session.observeStreaming(true)
      var token = snapshotSpy.signalArguments[0][0]
      session.enabled = false
      compare(session.pendingToken, 0)
      verify(!session.acceptSnapshot(token, {
        present: true, streaming: true, privacy: true, mode: "standard"
      }))
      compare(planSpy.count, 0)
    }

    function test_cancelled_snapshot_output_preserves_presence_and_future_edges() {
      session.enabled = true
      session.present = true
      session.actions = actions({})

      session.observeStreaming(true)
      var token = snapshotSpy.signalArguments[0][0]
      var camera = Model.parseState(JSON.stringify({
        ok: true, present: true, streaming: true,
        privacy: true, mode: "standard"
      }))

      // Quickshell completes a cancelled Process collector with an empty
      // string. Filtering that result is what keeps the camera out of the
      // absent-state trap in mergeHolders().
      var reply = Model.parseStateReply("", true)
      compare(reply, null)
      session.rejectSnapshot(token)
      compare(camera.present, true)
      compare(camera.streaming, true)
      compare(session.streaming, true)
      compare(planSpy.count, 0)

      // The real end remains the end edge, and the next call is detected.
      session.observeStreaming(false)
      compare(planSpy.count, 1)
      verify(Model.planIsEmpty(planSpy.signalArguments[0][0]))
      session.observeStreaming(true)
      compare(snapshotSpy.count, 2)
    }

    function test_uncancelled_empty_state_output_is_still_an_error() {
      var reply = Model.parseStateReply("", false)
      compare(reply.present, false)
      compare(reply.error, "no output")
    }

    // ---- what a call start plans ----

    function test_all_three_actions_on_a_camera_that_needs_all_three() {
      var plan = Model.callStartPlan(actions({}), now({}))
      compare(plan.privacy, false)
      compare(plan.mode, "tracking")
      compare(plan.muted, false)
    }

    function test_a_disabled_action_plans_nothing() {
      var plan = Model.callStartPlan(actions({ tracking: false, unmute: false }), now({}))
      compare(plan.privacy, false)
      compare(plan.mode, undefined)
      compare(plan.muted, undefined)
    }

    function test_nothing_enabled_is_an_empty_plan() {
      // What stops the panel writing to the camera, and showing a note about it,
      // every time someone opens a meeting app with the feature switched off.
      var plan = Model.callStartPlan(actions({ openLens: false, tracking: false,
                                              unmute: false }), now({}))
      verify(Model.planIsEmpty(plan))
    }

    function test_an_open_lens_is_left_alone() {
      var plan = Model.callStartPlan(actions({}), now({ privacy: false }))
      compare(plan.privacy, undefined)
      compare(plan.restore.privacy, undefined)
    }

    function test_a_camera_already_tracking_is_left_alone() {
      var plan = Model.callStartPlan(actions({}), now({ mode: "tracking" }))
      compare(plan.mode, undefined)
      compare(plan.restore.mode, undefined)
    }

    function test_an_unmuted_mic_is_left_alone() {
      // The important half of `unmute`: with nothing recorded, the end of the call
      // has nothing to replay, and a mic the user chose to leave on stays on.
      var plan = Model.callStartPlan(actions({}), now({ muted: false }))
      compare(plan.muted, undefined)
      compare(plan.restore.muted, undefined)
    }

    function test_a_camera_with_no_microphone_is_not_a_muted_one() {
      // The panel passes `undefined` when the mic node is not on the graph. A test
      // for `!== false` would read that as muted and plan an unmute for a device
      // that does not exist.
      var plan = Model.callStartPlan(actions({}), now({ muted: undefined }))
      compare(plan.muted, undefined)
      compare(plan.restore.muted, undefined)
    }

    function test_tracking_is_skipped_when_the_mode_is_unknown() {
      // The 0x03 ambiguity: the camera will not always say which mode it is in, and
      // restoring to a guess at the end of the call is worse than not touching it.
      // Skipped at the start rather than fudged at the end, so nothing is recorded.
      var plan = Model.callStartPlan(actions({}), now({ mode: null }))
      compare(plan.mode, undefined)
      compare(plan.restore.mode, undefined)
      // The other two still apply — one unreadable field must not disable the rest.
      compare(plan.privacy, false)
      compare(plan.muted, false)
    }

    function test_tracking_alone_never_opens_a_private_camera() {
      var plan = Model.callStartPlan(
        actions({ openLens: false, tracking: true, unmute: false }),
        now({ privacy: true, mode: "privacy", muted: false }))
      verify(Model.planIsEmpty(plan))
      compare(plan.privacy, undefined)
      compare(plan.mode, undefined)
    }

    function test_tracking_can_follow_an_explicit_lens_open() {
      var plan = Model.callStartPlan(
        actions({ openLens: true, tracking: true, unmute: false }),
        now({ privacy: true, mode: "privacy", muted: false }))
      compare(plan.privacy, false)
      compare(plan.mode, "tracking")
      compare(plan.restore.privacy, true)
    }

    function test_tracking_does_not_treat_unknown_privacy_as_open() {
      var plan = Model.callStartPlan(
        actions({ openLens: false, tracking: true, unmute: false }),
        now({ privacy: null, mode: "standard", muted: false }))
      verify(Model.planIsEmpty(plan))
      compare(plan.mode, undefined)
    }

    function test_an_absent_state_object_plans_nothing_rather_than_crashing() {
      // The first `camera` publish can land before anything is known.
      verify(Model.planIsEmpty(Model.callStartPlan(actions({}), null)))
      verify(Model.planIsEmpty(Model.callStartPlan(null, now({}))))
    }

    // ---- the round trip ----

    function test_the_end_of_the_call_puts_back_exactly_what_the_start_changed() {
      var trip = roundTrip(actions({}), now({}))
      compare(trip.end.privacy, true)
      compare(trip.end.mode, "standard")
      compare(trip.end.muted, true)
    }

    function test_the_end_restores_the_mode_that_was_there_not_a_default() {
      // "standard" is the common case, so a restore hardcoded to it would pass
      // every other test in this file.
      var trip = roundTrip(actions({}), now({ mode: "privacy" }))
      compare(trip.end.mode, "privacy")
    }

    function test_opening_privacy_and_enabling_tracking_is_one_absolute_write() {
      compare(Model.callModeTarget({ privacy: false, mode: "tracking" }),
              "tracking")
    }

    function test_restoring_privacy_collapses_a_redundant_saved_mode() {
      compare(Model.callModeTarget({ mode: "privacy", privacy: true }),
              "privacy")
    }

    function test_lens_open_only_maps_to_standard() {
      compare(Model.callModeTarget({ privacy: false }), "standard")
    }

    function test_explicit_modes_are_the_single_target() {
      compare(Model.callModeTarget({ mode: "standard" }), "standard")
      compare(Model.callModeTarget({ mode: "tracking" }), "tracking")
    }

    function test_a_plan_without_a_camera_change_has_no_mode_write() {
      compare(Model.callModeTarget({ muted: false }), "")
    }

    function test_a_camera_that_needed_nothing_needs_nothing_undone() {
      // Lens open, already tracking, mic on — the state a regular user is in when a
      // second call starts. Both halves have to be empty, or the end of the call
      // would close a lens the user opened by hand.
      var trip = roundTrip(actions({}), now({ privacy: false, mode: "tracking", muted: false }))
      verify(Model.planIsEmpty(trip.start))
      verify(Model.planIsEmpty(trip.end))
    }

    function test_only_the_changed_fields_come_back() {
      var trip = roundTrip(actions({}), now({ privacy: false, muted: false }))
      compare(trip.end.privacy, undefined)
      compare(trip.end.muted, undefined)
      compare(trip.end.mode, "standard")
    }

    function test_the_round_trip_is_the_identity_for_every_starting_state() {
      // The invariant, over all eight combinations of the three fields: whatever the
      // camera was, it is that again afterwards. This is the test that would catch a
      // field recorded at the start and dropped at the end — each half reads fine
      // alone, and only the pair is wrong.
      var modes = ["standard", "tracking"]
      for (var p = 0; p < 2; p++)
        for (var m = 0; m < 2; m++)
          for (var u = 0; u < 2; u++) {
            var before = { privacy: p === 1, mode: modes[m], muted: u === 1 }
            var trip = roundTrip(actions({}), before)
            var after = {
              privacy: trip.end.privacy === undefined
                ? (trip.start.privacy === undefined ? before.privacy : trip.start.privacy)
                : trip.end.privacy,
              mode: trip.end.mode === undefined
                ? (trip.start.mode === undefined ? before.mode : trip.start.mode)
                : trip.end.mode,
              muted: trip.end.muted === undefined
                ? (trip.start.muted === undefined ? before.muted : trip.start.muted)
                : trip.end.muted
            }
            var shape = JSON.stringify(before)
            compare(after.privacy, before.privacy, shape)
            compare(after.mode, before.mode, shape)
            compare(after.muted, before.muted, shape)
          }
    }

    function test_a_call_that_ended_with_nothing_recorded_is_a_no_op() {
      // `callRestore` is null when no call was in progress — including after a shell
      // restart mid-call, which is why it is session-only. An end plan built from
      // null must ask for nothing rather than defaulting the camera to something.
      verify(Model.planIsEmpty(Model.callEndPlan(null)))
      verify(Model.planIsEmpty(Model.callEndPlan(undefined)))
      verify(Model.planIsEmpty(Model.callEndPlan({})))
    }

    // ---- planIsEmpty ----

    function test_planIsEmpty_ignores_the_restore_key() {
      // `restore` is bookkeeping, not a change. A plan carrying only a restore —
      // which cannot happen today, but is one edit away — would otherwise be
      // treated as work to do and announced.
      verify(Model.planIsEmpty({ restore: { mode: "standard" } }))
      verify(!Model.planIsEmpty({ restore: {}, mode: "tracking" }))
    }

    function test_planIsEmpty_counts_a_false_value_as_a_change() {
      // Every one of these actions plans a *false*: privacy off, muted off. A
      // truthiness check would call the whole feature empty and do nothing at all.
      verify(!Model.planIsEmpty({ privacy: false }))
      verify(!Model.planIsEmpty({ muted: false }))
    }

    // ---- what the panel says about it ----

    function test_the_label_names_each_action_in_plain_words() {
      var plan = Model.callStartPlan(actions({}), now({}))
      var label = Model.callActionLabel(plan)
      verify(label.indexOf("opened the lens") >= 0, label)
      verify(label.indexOf("tracking on") >= 0, label)
      verify(label.indexOf("unmuted") >= 0, label)
    }

    function test_the_label_describes_the_undo_in_the_other_direction() {
      // The same function renders both halves, so "closed the lens" and "muted" have
      // to be distinct from their opposites rather than sharing a string.
      var trip = roundTrip(actions({}), now({}))
      var label = Model.callActionLabel(trip.end)
      verify(label.indexOf("closed the lens") >= 0, label)
      verify(label.indexOf("muted") >= 0, label)
      verify(label.indexOf("unmuted") < 0, label)
      verify(label.indexOf("standard") >= 0, label)
    }

    function test_an_empty_plan_says_nothing() {
      // The note is what makes automation visible instead of spooky — but a note
      // about a call that changed nothing is noise, and it would appear on every
      // call for anyone whose camera is already set up the way they want it.
      compare(Model.callActionLabel({}), "")
      compare(Model.callActionLabel(null), "")
      compare(Model.callActionLabel({ restore: { mode: "standard" } }), "")
    }

    // ---- the settings the switches write ----

    function test_every_action_has_a_switch_and_a_setting() {
      // CALL_ACTION_META drives both the device page's rows and the widget settings
      // dialog. A key here that the plan does not know is a switch that does
      // nothing; a setting key that manifest.json does not declare is a switch that
      // does not persist.
      compare(Model.CALL_ACTION_META.length, Model.CALL_ACTIONS.length)
      for (var i = 0; i < Model.CALL_ACTION_META.length; i++) {
        var meta = Model.CALL_ACTION_META[i]
        verify(Model.CALL_ACTIONS.indexOf(meta.key) >= 0, meta.key + " is not a plan action")
        verify(meta.setting.indexOf("call") === 0, meta.setting)
        verify(meta.label !== "" && meta.note !== "", meta.key)
      }
    }

    function test_the_lens_is_the_first_action_drawn() {
      // It is the one that decides whether the call has video at all, so it is
      // applied first and listed first. The plan's own ordering is separate — see
      // CALL_ACTIONS — which is exactly why this is worth pinning.
      compare(Model.CALL_ACTION_META[0].key, "openLens")
    }

    function test_the_settings_write_bare_json_booleans() {
      // Same trap previewSettingArgs documents: `setBarWidget` JSON-parses its
      // value, so a quoted "false" is a truthy string and the switch would move
      // while the automation stayed on.
      for (var i = 0; i < Model.CALL_ACTION_META.length; i++) {
        var key = Model.CALL_ACTION_META[i].setting
        var off = Model.boolSettingArgs("nille.emeet-pixy", key, false)
        compare(off[off.length - 2], "false")
        compare(off[off.length - 1], "{}")
        verify(off.indexOf(key) >= 0)
        var on = Model.boolSettingArgs("nille.emeet-pixy", key, true)
        compare(on[on.length - 2], "true")
      }
    }
  }
}
