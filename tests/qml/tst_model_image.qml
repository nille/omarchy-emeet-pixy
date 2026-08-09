// Image-control helpers in Model.js: parsing the helper's payload, labelling
// values, deciding what is held by an auto, and building argv.
//
// The parsing tests carry most of the weight, and the reason is that this payload
// is the only place the panel learns what controls exist. It does not keep its own
// table — a firmware that drops Hue or reports a different white-balance range
// needs no change on this side — so a parser that lets a degenerate control
// through renders a slider that cannot move, and one that drops a good control
// renders nothing at all. Both look like hardware faults from the outside.
//
// The label tests pin judgements rather than formatting: a menu shows its option's
// name because "3" is not an exposure mode, a unit-bearing control shows its unit
// because 5000 alone is not a colour, and everything else shows a percentage of
// its range because the raw 0..255 the driver speaks means nothing to anyone who
// has not read the UVC spec.
//
//   QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
//
// Note: /usr/bin/qmltestrunner is Qt5 on Arch and exits silently on these files.
import QtQuick
import QtTest
import "../../Model.js" as Model

Item {
  // The helper's reply for a healthy camera, as JSON text, because that is what
  // the panel actually receives. Tests that need a variation edit the object
  // before it is stringified rather than hand-writing JSON.
  function payload(overrides) {
    var reply = {
      ok: true,
      controls: [
        { key: "brightness", label: "Brightness", type: "integer", min: 0, max: 255,
          step: 1, "default": 128, value: 128, inactive: false, curated: true },
        { key: "whiteBalanceAuto", label: "Auto white balance", type: "boolean",
          min: 0, max: 1, step: 1, "default": 1, value: 1, inactive: false,
          curated: true },
        { key: "whiteBalance", label: "White balance", type: "integer", min: 2300,
          max: 7500, step: 1, "default": 5000, value: 5000, inactive: true,
          curated: true, auto: "whiteBalanceAuto", unit: "K" },
        { key: "autoExposure", label: "Auto exposure", type: "menu", min: 0, max: 3,
          step: 1, "default": 3, value: 3, inactive: false, curated: false,
          options: [{ value: 1, label: "Manual Mode" },
                    { value: 3, label: "Aperture Priority Mode" }] }
      ]
    }
    for (var k in overrides) reply[k] = overrides[k]
    return JSON.stringify(reply)
  }

  function parsed(overrides) {
    return Model.parseImage(payload(overrides))
  }

  // A single control, defaulted to a plain 0..255 integer.
  function control(props) {
    var c = { key: "brightness", label: "Brightness", type: "integer", min: 0,
              max: 255, step: 1, "default": 128, value: 128, inactive: false,
              curated: true, auto: "", unit: "", options: [] }
    for (var k in props) c[k] = props[k]
    return c
  }

  TestCase {
    name: "ModelImage"

    // ---- parsing ----

    function test_a_healthy_reply_parses_every_control() {
      var reply = parsed({})
      compare(reply.ok, true)
      compare(reply.controls.length, 4)
      compare(reply.controls[0].key, "brightness")
    }

    function test_order_is_preserved() {
      // The panel stacks the sliders in payload order, and the helper's order is
      // editorial — an auto switch below the slider it gates reads backwards.
      var keys = parsed({}).controls.map(function(c) { return c.key })
      compare(keys.join(","),
              "brightness,whiteBalanceAuto,whiteBalance,autoExposure")
    }

    function test_empty_output_is_not_ok_but_is_still_renderable() {
      // A blank widget is worse than an honest failure, so the shape holds.
      var reply = Model.parseImage("")
      compare(reply.ok, false)
      compare(reply.controls.length, 0)
      compare(reply.failed !== undefined, true)
    }

    function test_garbage_output_is_not_ok() {
      compare(Model.parseImage("not json").ok, false)
      compare(Model.parseImage("[1,2,3]").controls.length, 0)
      compare(Model.parseImage(null).ok, false)
    }

    function test_a_missing_controls_array_yields_no_controls() {
      compare(Model.parseImage('{"ok":true}').controls.length, 0)
    }

    function test_degenerate_controls_are_dropped() {
      // The `Zoom, Continuous` shape: min === max. The helper drops these too;
      // this is the second line of defense, because a dead slider ships quietly.
      var reply = parsed({ controls: [
        { key: "gain", label: "Gain", type: "integer", min: 0, max: 0, step: 1,
          "default": 0, value: 0 },
        { key: "brightness", label: "Brightness", type: "integer", min: 0,
          max: 255, step: 1, "default": 128, value: 128 }
      ] })
      compare(reply.controls.length, 1)
      compare(reply.controls[0].key, "brightness")
    }

    function test_controls_without_a_key_are_dropped() {
      var reply = parsed({ controls: [{ label: "Mystery", min: 0, max: 10 }] })
      compare(reply.controls.length, 0)
    }

    function test_non_numeric_ranges_are_dropped() {
      var reply = parsed({ controls: [
        { key: "brightness", min: "low", max: "high", value: 1 }
      ] })
      compare(reply.controls.length, 0)
    }

    function test_a_value_outside_the_range_is_clamped() {
      var reply = parsed({ controls: [
        { key: "brightness", label: "B", type: "integer", min: 0, max: 255,
          step: 1, "default": 128, value: 9999 }
      ] })
      compare(reply.controls[0].value, 255)
    }

    function test_a_zero_step_becomes_one() {
      // A zero step would make snapControl divide by zero and the slider inert.
      var reply = parsed({ controls: [
        { key: "brightness", label: "B", type: "integer", min: 0, max: 255,
          step: 0, "default": 128, value: 128 }
      ] })
      compare(reply.controls[0].step, 1)
    }

    function test_a_missing_label_falls_back_to_the_key() {
      var reply = parsed({ controls: [
        { key: "brightness", type: "integer", min: 0, max: 255, value: 10 }
      ] })
      compare(reply.controls[0].label, "brightness")
    }

    function test_menu_options_survive_and_malformed_ones_do_not() {
      var reply = parsed({ controls: [
        { key: "autoExposure", label: "Auto exposure", type: "menu", min: 0,
          max: 3, step: 1, "default": 3, value: 3,
          options: [{ value: 1, label: "Manual Mode" },
                    { value: 2 },                       // no label
                    { label: "Nameless" },              // no value
                    { value: 3, label: "Aperture Priority Mode" }] }
      ] })
      compare(reply.controls[0].options.length, 2)
      compare(reply.controls[0].options[1].label, "Aperture Priority Mode")
    }

    function test_non_menu_controls_get_an_empty_options_array() {
      // Not undefined: the panel iterates it without checking.
      compare(parsed({}).controls[0].options.length, 0)
    }

    function test_per_control_failures_are_carried() {
      // Keyed by control so the panel marks the row that was refused rather than
      // showing one banner over the whole section.
      var reply = parsed({ ok: false,
                           failed: { whiteBalance: "held by auto white balance" } })
      compare(reply.ok, false)
      compare(reply.failed.whiteBalance, "held by auto white balance")
    }

    function test_a_reply_with_no_failures_still_has_a_failed_object() {
      compare(Object.keys(parsed({}).failed).length, 0)
    }

    // ---- folding a profile reply into a live list ----

    function test_a_profile_reply_carrying_controls_replaces_the_list() {
      // `load` and `save` answer with the readback, and that readback is the whole
      // point: it is how the panel learns where the sliders ended up.
      var previous = parsed({})
      var next = Model.mergeImage(previous, payload({}))
      compare(next.controls.length, 4)
      compare(next.ok, true)
    }

    function test_a_profile_reply_with_no_controls_keeps_the_ones_on_screen() {
      // `list` and every failure omit `controls`. Parsing one of those directly
      // would blank the entire IMAGE section on a refresh that changed nothing.
      var previous = parsed({})
      var next = Model.mergeImage(previous, '{"ok":true,"profiles":{"warm":{}}}')
      compare(next.controls.length, 4)
      compare(next.controls[0].key, "brightness")
    }

    function test_a_failed_profile_reply_keeps_the_controls_but_not_the_status() {
      // The rows stay, and the error comes through — the section reports the
      // refusal without losing the state it was showing.
      var previous = parsed({})
      var next = Model.mergeImage(previous, '{"ok":false,"error":"no such profile"}')
      compare(next.controls.length, 4)
      compare(next.ok, false)
      compare(next.error, "no such profile")
    }

    function test_merging_into_nothing_is_still_renderable() {
      // The first reply of the session, before anything has been read.
      compare(Model.mergeImage(null, '{"ok":true}').controls.length, 0)
      compare(Model.mergeImage(undefined, "").controls.length, 0)
    }

    // ---- lookup and splitting ----

    function test_find_control_by_key() {
      var reply = parsed({})
      compare(Model.findControl(reply.controls, "whiteBalance").label, "White balance")
      compare(Model.findControl(reply.controls, "nope"), null)
      compare(Model.findControl(null, "brightness"), null)
    }

    function test_curated_and_advanced_partition_the_list() {
      var reply = parsed({})
      var curated = Model.curatedControls(reply.controls)
      var advanced = Model.advancedControls(reply.controls)
      compare(curated.length + advanced.length, reply.controls.length)
      compare(advanced.length, 1)
      compare(advanced[0].key, "autoExposure")
    }

    function test_values_come_out_keyed_by_control() {
      // What a script asking the panel for its state wants: the ranges and menu
      // options a full control list carries answer a different question.
      var values = Model.controlValues(parsed({}).controls)
      compare(values.brightness, 128)
      compare(values.whiteBalance, 5000)
      compare(Object.keys(values).length, 4)
      compare(Object.keys(Model.controlValues(null)).length, 0)
    }

    // ---- glyphs ----

    function test_every_control_has_its_own_glyph() {
      // The point of the table is distinguishing five identically-shaped 0..255
      // sliders, so two of them sharing a glyph defeats it.
      var keys = ["brightness", "contrast", "saturation", "sharpness", "gamma",
                  "whiteBalanceAuto", "whiteBalance", "hue", "gain", "autoExposure",
                  "exposure", "focusAuto", "focus", "powerLineFrequency",
                  "backlightCompensation"]
      var seen = {}
      for (var i = 0; i < keys.length; i++) {
        var glyph = Model.controlGlyph(control({ key: keys[i] }))
        verify(glyph !== "")
        compare(seen[glyph] === undefined, true, keys[i] + " reuses a glyph")
        seen[glyph] = keys[i]
      }
    }

    function test_an_unknown_control_still_gets_a_glyph() {
      // The list comes from the helper, so a firmware exposing something this
      // table has never heard of must still render a row.
      verify(Model.controlGlyph(control({ key: "chromaGain" })) !== "")
      compare(Model.controlGlyph(null), "")
    }

    // ---- held by an auto ----

    function test_a_control_the_driver_marks_inactive_is_held() {
      compare(Model.isHeld(control({ inactive: true })), true)
      compare(Model.isHeld(control({ inactive: false })), false)
      compare(Model.isHeld(null), false)
    }

    function test_the_held_note_names_the_switch_holding_it() {
      var reply = parsed({})
      var wb = Model.findControl(reply.controls, "whiteBalance")
      compare(Model.heldNote(reply.controls, wb), "Set by auto white balance")
    }

    function test_an_unheld_control_has_no_note() {
      var reply = parsed({})
      compare(Model.heldNote(reply.controls, reply.controls[0]), "")
    }

    function test_a_held_control_whose_holder_is_absent_still_explains_itself() {
      // The curated payload omits Auto Exposure, so Exposure's holder is not in
      // the list. A blank note there would leave a dimmed slider unexplained.
      var exposure = control({ key: "exposure", inactive: true, auto: "autoExposure" })
      compare(Model.heldNote([exposure], exposure), "Set automatically")
    }

    // ---- the row's one note ----

    function test_the_note_falls_back_to_the_held_explanation() {
      var reply = parsed({})
      var wb = Model.findControl(reply.controls, "whiteBalance")
      compare(Model.controlNote(reply.controls, wb, {}), "Set by auto white balance")
      compare(Model.controlNote(reply.controls, reply.controls[0], {}), "")
    }

    function test_a_refusal_wins_over_the_held_explanation() {
      // A row has room for one line. "Set by auto white balance" is a standing
      // condition the dimmed row already communicates; a refused write is news.
      var reply = parsed({})
      var wb = Model.findControl(reply.controls, "whiteBalance")
      compare(Model.controlNote(reply.controls, wb, { whiteBalance: "write refused" }),
              "write refused")
    }

    function test_a_refusal_on_another_control_does_not_leak_across_rows() {
      var reply = parsed({})
      compare(Model.controlNote(reply.controls, reply.controls[0],
                                { whiteBalance: "write refused" }), "")
    }

    function test_a_missing_control_or_failure_map_yields_no_note() {
      compare(Model.controlNote([], null, { brightness: "x" }), "")
      compare(Model.controlNote([], control({}), null), "")
    }

    // ---- value labels ----

    function test_a_plain_control_reads_as_a_percentage_of_its_range() {
      // Raw 0..255 means nothing to anyone who has not read the UVC spec.
      compare(Model.controlValueLabel(control({ value: 128 })), "50%")
      compare(Model.controlValueLabel(control({ value: 0 })), "0%")
      compare(Model.controlValueLabel(control({ value: 255 })), "100%")
    }

    function test_a_unit_bearing_control_shows_the_unit() {
      var wb = control({ key: "whiteBalance", min: 2300, max: 7500, value: 5000,
                         unit: "K" })
      compare(Model.controlValueLabel(wb), "5000 K")
    }

    function test_a_menu_shows_its_options_name() {
      var reply = parsed({})
      var ae = Model.findControl(reply.controls, "autoExposure")
      compare(Model.controlValueLabel(ae), "Aperture Priority Mode")
    }

    function test_a_menu_with_an_unlisted_value_shows_the_number() {
      // Better a bare number than a confident wrong label.
      var ae = control({ type: "menu", value: 7, min: 0, max: 9,
                         options: [{ value: 1, label: "Manual Mode" }] })
      compare(Model.controlValueLabel(ae), "7")
    }

    function test_a_boolean_reads_on_or_off() {
      compare(Model.controlValueLabel(control({ type: "boolean", min: 0, max: 1,
                                               value: 1 })), "On")
      compare(Model.controlValueLabel(control({ type: "boolean", min: 0, max: 1,
                                               value: 0 })), "Off")
    }

    function test_percent_is_position_in_the_range_not_the_value() {
      // A 2300..7500 control at 2300 sits at 0%, not at 31%.
      var wb = control({ min: 2300, max: 7500, value: 2300 })
      compare(Model.controlPercent(wb), 0)
      compare(Model.controlPercent(control({ min: 2300, max: 7500, value: 4900 })), 50)
    }

    function test_percent_of_a_degenerate_control_is_zero_not_a_division_by_zero() {
      compare(Model.controlPercent(control({ min: 5, max: 5, value: 5 })), 0)
      compare(Model.controlPercent(null), 0)
    }

    // ---- the optimistic value ----

    function test_a_copy_reads_the_pending_value() {
      // The whole trick: every label, percentage and nudge helper can be pointed
      // at the value being dragged without knowing pending writes exist.
      var c = control({ value: 128 })
      var pending = Model.withValue(c, 200)
      compare(pending.value, 200)
      compare(Model.controlValueLabel(pending), "78%")
      compare(Model.controlNudge(pending, 1) > 200, true)
    }

    function test_the_original_is_not_touched() {
      // It is the driver's last word, and the next refresh compares against it.
      var c = control({ value: 128 })
      Model.withValue(c, 200)
      compare(c.value, 128)
    }

    function test_a_copy_carries_everything_else_across() {
      // Not just min/max: a copy that lost `options` would make a menu label read
      // as a bare number mid-write, and one that lost `inactive` would un-dim a
      // held row.
      var wb = control({ key: "whiteBalance", min: 2300, max: 7500, value: 5000,
                         unit: "K", inactive: true, auto: "whiteBalanceAuto" })
      var pending = Model.withValue(wb, 3200)
      compare(Model.controlValueLabel(pending), "3200 K")
      compare(Model.isHeld(pending), true)
      compare(pending.auto, "whiteBalanceAuto")
      var ae = control({ type: "menu", value: 3,
                         options: [{ value: 1, label: "Manual Mode" },
                                   { value: 3, label: "Aperture Priority Mode" }] })
      compare(Model.controlValueLabel(Model.withValue(ae, 1)), "Manual Mode")
    }

    function test_a_pending_value_outside_the_range_is_clamped() {
      compare(Model.withValue(control({}), 9999).value, 255)
      compare(Model.withValue(control({}), -5).value, 0)
      compare(Model.withValue(null, 5), null)
    }

    // ---- writing values back ----

    function test_a_slider_fraction_becomes_a_value_in_range() {
      var c = control({})
      compare(Model.controlValueAt(c, 0), 0)
      compare(Model.controlValueAt(c, 1), 255)
      compare(Model.controlValueAt(c, 0.5), 128)
    }

    function test_a_fraction_outside_zero_to_one_is_clamped() {
      var c = control({})
      compare(Model.controlValueAt(c, -3), 0)
      compare(Model.controlValueAt(c, 42), 255)
    }

    function test_values_land_on_a_step_boundary() {
      // An unsnapped write is rounded by the driver, so the readback disagrees
      // with the slider and the handle jumps on the next refresh.
      var c = control({ min: 0, max: 100, step: 10 })
      compare(Model.snapControl(c, 47), 50)
      compare(Model.snapControl(c, 43), 40)
    }

    function test_snapping_stays_inside_the_range() {
      var c = control({ min: 1, max: 95, step: 10 })
      compare(Model.snapControl(c, 999) <= 95, true)
      compare(Model.snapControl(c, -999) >= 1, true)
    }

    function test_a_nudge_moves_a_visible_amount_on_a_wide_range() {
      // The driver reports step 1 on every control here, so a step-sized nudge
      // would move a 0..255 slider by 0.4% — 250 presses end to end.
      var c = control({ value: 128 })
      var up = Model.controlNudge(c, 1)
      compare(up > 128, true)
      compare(up - 128 >= 10, true)
    }

    function test_a_nudge_down_moves_down() {
      compare(Model.controlNudge(control({ value: 128 }), -1) < 128, true)
    }

    function test_a_nudge_on_a_narrow_range_still_moves_one_step() {
      // Backlight compensation is [1..2]: 4% of the span rounds to zero, and a
      // nudge that moves nothing is a key that appears broken.
      var c = control({ min: 1, max: 2, step: 1, value: 1 })
      compare(Model.controlNudge(c, 1), 2)
    }

    function test_a_nudge_at_the_end_of_the_range_stays_put() {
      compare(Model.controlNudge(control({ value: 255 }), 1), 255)
      compare(Model.controlNudge(control({ value: 0 }), -1), 0)
    }

    // ---- menu cycling ----

    function test_the_next_option_wraps() {
      var reply = parsed({})
      var ae = Model.findControl(reply.controls, "autoExposure")
      compare(Model.nextOption(ae, 1).value, 1)   // 3 is last, wraps to first
      ae.value = 1
      compare(Model.nextOption(ae, 1).value, 3)
    }

    function test_the_previous_option_wraps_the_other_way() {
      var reply = parsed({})
      var ae = Model.findControl(reply.controls, "autoExposure")
      ae.value = 1
      compare(Model.nextOption(ae, -1).value, 3)
    }

    function test_an_unlisted_current_value_starts_from_the_first_option() {
      // A real state, not a corrupt one: the camera reports values whose menu
      // index it declines to enumerate.
      var ae = control({ type: "menu", value: 7,
                         options: [{ value: 1, label: "Manual Mode" },
                                   { value: 3, label: "Aperture Priority Mode" }] })
      compare(Model.nextOption(ae, 1).value, 1)
    }

    function test_a_menu_with_no_options_yields_nothing_rather_than_throwing() {
      compare(Model.nextOption(control({ type: "menu" }), 1), null)
      compare(Model.nextOption(null, 1), null)
    }

    // ---- section summary ----

    function test_an_untouched_camera_reads_as_default() {
      compare(Model.imageIsDefault(parsed({}).controls), true)
      compare(Model.imageSummary(parsed({}).controls), "Default")
    }

    function test_one_adjusted_control_is_named() {
      // Naming beats counting: it tells you where to look.
      var reply = parsed({})
      reply.controls[0].value = 200
      compare(Model.imageIsDefault(reply.controls), false)
      compare(Model.imageSummary(reply.controls), "Brightness adjusted")
    }

    function test_two_adjusted_controls_are_both_named() {
      // Both of these are in effect. The fixture's white balance is held by its
      // auto, so adjusting *that* is deliberately not what this tests — see
      // test_a_held_controls_stale_value_does_not_count_as_adjusted.
      var reply = parsed({})
      reply.controls[0].value = 200   // brightness
      reply.controls[3].value = 1     // auto exposure -> Manual Mode
      compare(Model.imageSummary(reply.controls), "Brightness, auto exposure")
    }

    function test_three_or_more_adjusted_controls_are_counted() {
      var reply = parsed({})
      reply.controls[0].value = 200   // brightness
      reply.controls[1].value = 0     // auto white balance off — an adjustment itself
      reply.controls[3].value = 1     // auto exposure
      compare(Model.imageSummary(reply.controls), "3 adjusted")
    }

    function test_power_line_frequency_does_not_count_as_adjusted() {
      // It matches the helper's RESET_EXCLUDE: the right value is a property of
      // the room's mains, so a camera differing only there is already neutral
      // and Reset would have nothing to do.
      var reply = parsed({ controls: [
        { key: "powerLineFrequency", label: "Power line frequency", type: "menu",
          min: 0, max: 2, step: 1, "default": 2, value: 1,
          options: [{ value: 1, label: "50 Hz" }, { value: 2, label: "60 Hz" }] }
      ] })
      compare(Model.imageIsDefault(reply.controls), true)
      compare(Model.imageSummary(reply.controls), "Default")
    }

    function test_a_held_controls_stale_value_does_not_count_as_adjusted() {
      // *(observed)* The firmware keeps the last manual value in a control after
      // its auto switch is turned back on: set white balance to 3200 by hand, then
      // re-enable auto white balance, and the camera still reports 3200 against a
      // default of 5000 — with inactive:true, because the value is no longer in
      // effect. Reading that as an adjustment made the header say "White balance
      // adjusted" and kept Reset enabled on a camera that was fully neutral, with
      // no way to make either of them stop short of an actual Reset.
      //
      // The dimmed row already tells the user this value is not in charge. The
      // summary has to agree with the row.
      var reply = parsed({})
      var wb = Model.findControl(reply.controls, "whiteBalance")
      wb.value = 3200
      wb.inactive = true
      compare(Model.imageIsDefault(reply.controls), true)
      compare(Model.imageSummary(reply.controls), "Default")
      // Still counted the moment the user takes manual control of it again,
      // otherwise a genuinely adjusted white balance would go unreported.
      wb.inactive = false
      compare(Model.imageIsDefault(reply.controls), false)
      compare(Model.imageSummary(reply.controls), "White balance adjusted")
    }

    function test_no_controls_reads_as_unavailable_not_as_default() {
      // An empty payload means the camera did not answer; saying "Default" there
      // would claim knowledge the panel does not have.
      compare(Model.imageSummary([]), "Unavailable")
      compare(Model.imageSummary(null), "Unavailable")
    }

    // ---- argv ----

    function test_read_and_reset_argv() {
      compare(Model.imageReadArgs("/p/pixy").join(" "), "/p/pixy image")
      compare(Model.imageResetArgs("/p/pixy").join(" "), "/p/pixy image --reset")
    }

    function test_set_argv_uses_key_equals_value() {
      var argv = Model.imageArgs("/p/pixy", { brightness: 160 })
      compare(argv.join(" "), "/p/pixy image --set brightness=160")
    }

    function test_set_argv_carries_several_assignments_in_one_call() {
      // One call, because the helper orders an auto and its partner correctly
      // within a batch — two calls would race the interlock.
      var argv = Model.imageArgs("/p/pixy", { whiteBalanceAuto: 0, whiteBalance: 3200 })
      compare(argv.filter(function(a) { return a === "--set" }).length, 2)
      compare(argv.indexOf("whiteBalanceAuto=0") > 0, true)
      compare(argv.indexOf("whiteBalance=3200") > 0, true)
    }

    function test_set_argv_rounds_fractional_values() {
      // The helper accepts floats, but a slider's 127.6 should reach the driver
      // as the integer the readback will report.
      var argv = Model.imageArgs("/p/pixy", { brightness: 127.6 })
      compare(argv.indexOf("brightness=128") > 0, true)
    }

    function test_profile_argv() {
      compare(Model.profileArgs("/p/pixy", "save", "Warm").join(" "),
              "/p/pixy profile save Warm")
      compare(Model.profileArgs("/p/pixy", "list").join(" "),
              "/p/pixy profile list")
    }

    // ---- profiles ----

    function test_profile_names_are_parsed_and_sorted() {
      var names = Model.parseProfiles('{"ok":true,"profiles":{"warm":{},"cool":{}}}')
      compare(names.join(","), "cool,warm")
    }

    function test_profile_names_come_out_of_a_failure_reply_too() {
      // Every profile subcommand carries `profiles`, including the failures, so
      // a refused load still refreshes the list rather than blanking it.
      var names = Model.parseProfiles('{"ok":false,"error":"no such profile","profiles":{"warm":{}}}')
      compare(names.join(","), "warm")
    }

    function test_garbage_yields_no_profiles() {
      compare(Model.parseProfiles("not json").length, 0)
      compare(Model.parseProfiles("").length, 0)
      compare(Model.parseProfiles('{"ok":true}').length, 0)
    }

    function test_a_typed_name_is_new_taken_or_blank() {
      // What lets the panel disable the Save button rather than fire a write that
      // comes back as an error, and what makes it say "Overwrite" when it will.
      var names = ["Warm", "Studio"]
      compare(Model.profileNameState(names, "Cool"), "new")
      compare(Model.profileNameState(names, "Warm"), "exists")
      compare(Model.profileNameState(names, ""), "blank")
      compare(Model.profileNameState(names, "   "), "blank")
      compare(Model.profileNameState(names, null), "blank")
      compare(Model.profileNameState(null, "Cool"), "new")
    }

    function test_surrounding_space_does_not_make_a_second_profile() {
      // The panel trims before writing, so " Warm " must report as the overwrite
      // it is — otherwise the button says Save and then replaces something.
      compare(Model.profileNameState(["Warm"], "  Warm  "), "exists")
    }

    function test_case_is_significant_because_it_is_to_the_helper() {
      // The helper keys a dict, so "Warm" and "warm" really are two profiles.
      // Folding case here would show one Overwrite that creates a second entry.
      compare(Model.profileNameState(["Warm"], "warm"), "new")
    }

    function test_the_next_profile_name_avoids_collisions() {
      compare(Model.nextProfileName([]), "Profile 1")
      compare(Model.nextProfileName(["Profile 1"]), "Profile 2")
      compare(Model.nextProfileName(["Profile 1", "Profile 2"]), "Profile 3")
      // A gap gets filled rather than skipped past.
      compare(Model.nextProfileName(["Profile 2"]), "Profile 1")
      compare(Model.nextProfileName(null), "Profile 1")
    }
  }
}
