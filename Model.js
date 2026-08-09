// Pure helpers for the EMEET PIXY panel. No QML types, no state, no side
// effects — mirrors the Model.js convention every first-party Omarchy panel
// follows, so the logic here stays unit-testable and the Panel stays
// presentation.
.pragma library

// Hardware limits, duplicated from scripts/pixy so the slider bounds match what
// the helper will accept. The helper remains the authority: it re-reads the real
// ranges from the driver and clamps again before anything reaches the wire.
var PAN_MIN = -150
var PAN_MAX = 150
var TILT_MIN = -90
var TILT_MAX = 90
var ZOOM_MIN = 100
var ZOOM_MAX = 150

// Degrees per arrow press / nudge. Five is small enough to frame precisely and
// large enough that holding a direction crosses the range in a few presses.
var PTZ_STEP = 5

var PRESET_SLOTS = [1, 2, 3]

var MODES = ["standard", "tracking", "privacy"]

function clamp(value, low, high) {
  var n = Number(value)
  if (!isFinite(n)) return low
  return Math.max(low, Math.min(high, n))
}

function clampPan(value) { return Math.round(clamp(value, PAN_MIN, PAN_MAX)) }
function clampTilt(value) { return Math.round(clamp(value, TILT_MIN, TILT_MAX)) }
function clampZoom(value) { return Math.round(clamp(value, ZOOM_MIN, ZOOM_MAX)) }

// ---------------------------------------------------------------- parsing

// Parse a helper reply. Anything unexpected yields a shape the panel can render
// without null checks, because a blank widget is worse than an honest
// "no camera" state.
function parseState(raw) {
  var text = String(raw || "").trim()
  if (!text) return absentState("no output")
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return absentState("invalid helper output")
  }
  if (!data || typeof data !== "object") return absentState("invalid helper output")
  if (!data.present) return absentState(data.error === "no-camera" ? "" : String(data.error || ""))

  return {
    ok: data.ok !== false,
    present: true,
    error: data.error ? String(data.error) : "",
    video: String(data.video || ""),
    hidraw: String(data.hidraw || ""),
    card: String(data.card || ""),
    // `streaming` counts only *other* apps. `selfStreaming` is our own preview,
    // kept separate because the two mean opposite things to the UI: one is a
    // reason to yield, the other is the thing being yielded.
    streaming: !!data.streaming,
    selfStreaming: !!data.selfStreaming,
    streamUsers: Array.isArray(data.streamUsers)
      ? data.streamUsers.map(function(u) { return String(u) })
      : [],
    // A mode the camera never confirmed stays null rather than becoming a
    // guess; `modeUnknown` says why so the panel can explain it.
    mode: MODES.indexOf(String(data.mode)) >= 0 ? String(data.mode) : null,
    modeUnknown: String(data.modeUnknown || ""),
    // Privacy is knowable even when the mode is not, so it is carried
    // separately rather than derived from `mode`.
    privacy: data.privacy === true || String(data.mode) === "privacy",
    pan: clampPan(data.pan),
    tilt: clampTilt(data.tilt),
    zoom: clampZoom(data.zoom === undefined ? ZOOM_MIN : data.zoom),
    presets: normalizePresets(data.presets),
    videoError: String(data.videoError || ""),
    hidError: String(data.hidError || "")
  }
}

function absentState(error) {
  return {
    ok: false,
    present: false,
    error: String(error || ""),
    video: "",
    hidraw: "",
    card: "",
    streaming: false,
    selfStreaming: false,
    streamUsers: [],
    mode: null,
    modeUnknown: "",
    privacy: false,
    pan: 0,
    tilt: 0,
    zoom: ZOOM_MIN,
    presets: {},
    videoError: "",
    hidError: ""
  }
}

// Fold a `holders` reply into the state we already have.
//
// `holders` is the cheap subset of `state` — who has the capture stream, and
// nothing else — polled fast while our preview is running so another app does
// not sit there failing for a whole refresh interval. It deliberately carries no
// mode, position, or preset data, so those fields are preserved rather than
// overwritten with defaults, which is why this is a merge and not a parse.
//
// A reply that does not parse, or that reports the camera gone, returns the state
// unchanged: the authority on "is there a camera" is the full `state` call, and a
// transient failure here should not blank the panel.
function mergeHolders(state, raw) {
  if (!state || !state.present) return state
  var data
  try {
    data = JSON.parse(String(raw || "").trim())
  } catch (e) {
    return state
  }
  if (!data || typeof data !== "object" || !data.present) return state

  var next = {}
  for (var key in state) next[key] = state[key]
  next.streaming = !!data.streaming
  next.selfStreaming = !!data.selfStreaming
  next.streamUsers = Array.isArray(data.streamUsers)
    ? data.streamUsers.map(function(u) { return String(u) })
    : []
  return next
}

// Presets arrive keyed by slot number as a string. Entries that do not carry a
// full position are dropped rather than half-rendered.
function normalizePresets(raw) {
  var out = {}
  if (!raw || typeof raw !== "object") return out
  for (var i = 0; i < PRESET_SLOTS.length; i++) {
    var slot = PRESET_SLOTS[i]
    var entry = raw[String(slot)]
    if (!entry || typeof entry !== "object") continue
    if (entry.pan === undefined || entry.tilt === undefined || entry.zoom === undefined) continue
    out[slot] = {
      pan: clampPan(entry.pan),
      tilt: clampTilt(entry.tilt),
      zoom: clampZoom(entry.zoom)
    }
  }
  return out
}

function hasPreset(presets, slot) {
  return !!(presets && presets[slot])
}

function presetLabel(presets, slot) {
  var entry = presets ? presets[slot] : null
  if (!entry) return "Empty"
  return positionLabel(entry.pan, entry.tilt) + " · " + zoomLabel(entry.zoom)
}

// ---------------------------------------------------------------- labels

// Bar glyph. Privacy is the one camera state with real consequences if you
// misread it, so it gets the unambiguous crossed-out webcam; everything else is
// a plain one. Deliberately not three glyphs for three modes — the bar is read
// at a glance, and "is the lens closed" is the question being asked.
//
// Codepoints are md-webcam (U+F05A0) and md-webcam_off (U+F1737), verified
// present in the Nerd Font by glyph name rather than by eyeballing the shape.
function barIcon(state) {
  if (!state || !state.present) return "󰖠"
  return state.privacy ? "󱜷" : "󰖠"
}

function modeName(mode) {
  if (mode === "privacy") return "Privacy"
  if (mode === "tracking") return "Tracking"
  if (mode === "standard") return "Standard"
  return "Unknown"
}

// One-line summary for the panel hero and the bar tooltip.
function summary(state) {
  if (!state || !state.present) return "No camera found"
  if (state.privacy) return "Privacy — lens closed"
  if (state.mode) return modeName(state.mode)
  // Standard and Tracking are indistinguishable on an idle camera. Saying so
  // beats picking one: the panel would otherwise claim tracking is off while
  // the camera is following someone around the room.
  if (state.modeUnknown === "needs-stream") return "Ready"
  if (state.modeUnknown === "no-response") return "Not responding"
  if (state.modeUnknown === "no-hid") return "No control interface"
  return "Ready"
}

// Chip label for one mode, prefixed with a filled or hollow radio dot.
//
// The dot exists because the theme's selected fill is a deliberately quiet wash
// — right for "which option did I pick" in a form, too subtle for "is this
// camera following me right now". The dot is a second channel that carries no
// color of its own, so it reads the same under every theme.
//
// A hollow dot on both chips is the correct rendering when the mode is unknown
// (an idle camera cannot distinguish Standard from Tracking) or while privacy is
// on: neither chip is entitled to claim it is the active one.
//
// Two hollow dots on their own read as a bug, though, which is what a report of
// this called it — so the idle case does not rely on them alone. The whole group
// is dimmed and disabled there (see Panel.qml) and modeNote says why, which turns
// "nothing is selected" from a puzzle into a stated condition.
function modeChipLabel(mode, state, privacy) {
  var label = modeName(mode)
  var active = !privacy && state && state.mode === mode
  return (active ? "●  " : "○  ") + label
}

// Whether the camera will accept a Standard/Tracking write at all.
//
// *(observed)* It will not while nothing is capturing: the firmware takes the
// HID report and discards it. Tested both directions — setting Tracking on an
// idle camera and then starting a stream reads back Standard, and setting
// Standard from Tracking the same way reads back Tracking. So the chips are not
// merely unreadable when idle, they are inert, and a chip that looks pressable
// and silently does nothing is worse than one that admits it cannot act.
//
// Privacy is deliberately not gated on this. It is a lens shutter rather than a
// tracking behavior and it writes fine on an idle camera — verified — which is
// what lets the hero switch and the bar's right-click keep working when the
// camera is doing nothing. Same reason its state stays readable while idle.
//
// Keyed on the same fact that makes the mode readable, because it is the same
// firmware condition: something has to be holding the stream. `selfStreaming`
// counts, and it is usually what makes this true — the panel's own preview.
function modeWritable(state) {
  if (!state || !state.present) return false
  return state.streaming === true || state.selfStreaming === true
}

// Explains why the mode reads as unknown, for the line under the mode selector.
// Empty when there is nothing worth saying, so the caller can hide the row.
//
// The idle case says what the *chips* are doing, not what the readback is doing.
// It used to report only the readback ("the camera only reports Standard vs
// Tracking while an app is using it"), which was true and still left the panel
// looking broken: two hollow chips and a note explaining a detail the reader had
// not asked about. What they want to know is why neither is lit and why pressing
// one does nothing, and those have a single answer.
function modeNote(state) {
  if (!state || !state.present || state.privacy) return ""
  if (state.modeUnknown === "no-response") return "The camera is not answering control queries."
  if (state.modeUnknown === "no-hid")
    return "The vendor control interface was not found — check the udev rule."
  if (state.hidError) return state.hidError
  if (!modeWritable(state))
    return "The camera only switches between Standard and Tracking while it is in "
      + "use. Turn the preview on, or start a call, to change it."
  if (state.mode) return ""
  if (state.modeUnknown === "needs-stream")
    return "The camera only reports Standard vs Tracking while an app is using it."
  return ""
}

// Who currently holds the video stream. Worth surfacing because it explains
// both why the mode is readable and why a meeting app may be showing the lens.
function streamLabel(state) {
  if (!state || !state.present || !state.streaming) return ""
  var users = state.streamUsers || []
  if (!users.length) return "In use"
  if (users.length === 1) return "In use by " + users[0]
  return "In use by " + users.length + " apps"
}

// ---------------------------------------------------------------- preview
//
// Only one process can hold the V4L2 stream at a time, and that cuts both ways:
// another app streaming makes our preview fail with EBUSY, and *our* preview
// makes the other app fail the same way. The second direction is the one that
// costs something real — a meeting joined while the panel happens to be open
// would get no video — so the preview yields rather than competes.
//
// This is why the preview is worth being able to turn off entirely: pan, tilt,
// zoom, privacy, and tracking all travel the control plane (UVC ioctls and
// vendor HID), which is unaffected by who holds the stream. With the preview
// disabled the widget stays fully functional as a camera controller during a
// call, which is arguably when it is most wanted.

// Why the preview is not showing, or "" when it is (or should be) running.
// Ordered by precedence, most decisive first: a reason that makes the preview
// impossible outranks one that merely makes it unwanted.
function previewBlocker(state, enabled, opened) {
  if (!state || !state.present) return "no-camera"
  if (!enabled) return "disabled"
  if (state.privacy) return "privacy"
  // Another app is on the camera, so we get out of the way.
  //
  // `streaming` counts only other processes, never our own preview, so this does
  // not fight itself: the preview holding the stream does not make the preview
  // think it is blocked.
  //
  // It fires in both directions, which is the point. An app that already has the
  // camera means our capture would fail with EBUSY. An app that opened the node
  // and was refused *because of us* also lands here — it holds an fd while it
  // retries — so we release and it can proceed. That second case is the one that
  // matters: without it a meeting joined while the panel is open silently gets no
  // video, and the fix is worthless if it only handles the easy direction.
  if (state.streaming) return "busy"
  if (!opened) return "closed"
  return ""
}

// The blocker rendered for the placeholder inside the preview frame. Kept short
// — it sits in a small box — and paired with previewHint for the explanation.
function previewNote(state, enabled, opened) {
  var reason = previewBlocker(state, enabled, opened)
  if (reason === "no-camera") return "No camera"
  if (reason === "disabled") return "Preview off"
  if (reason === "privacy") return "Lens closed"
  if (reason === "busy") return streamLabel(state) || "In use"
  return ""
}

// The second line, which says what the note implies. Only where it is not
// obvious: "Lens closed" needs no gloss, but "In use by zoom" does — without it
// a blank preview during a call reads as this widget being broken.
function previewHint(state, enabled, opened) {
  var reason = previewBlocker(state, enabled, opened)
  if (reason === "busy") return "Only one app can capture at a time. Controls still work."
  // Not currently rendered — the panel hides the whole frame when the preview is
  // off rather than leaving a placeholder — but kept correct and kept here so the
  // string does not have to be reinvented if that changes. It used to point at the
  // widget settings dialog, which is now the wrong instruction: the switch is on
  // the FRAMING header, a few lines above where this would appear.
  if (reason === "disabled") return "Turn it back on with the switch above."
  return ""
}

// Codepoints are md-eye (U+F0208) and md-eye_off (U+F0209), verified present in
// the Nerd Font by glyph name rather than by eyeballing the shape.
//
// An eye rather than a movie camera: the state being toggled is whether *this
// panel watches*, not whether the camera works. A crossed-out video camera would
// read as "camera disabled", which is what the privacy switch does.
function previewIcon(enabled) {
  return enabled ? "󰈈" : "󰈉"
}

// The command that persists the preview setting.
//
// Written through the shell's own `setBarWidget`, so the panel switch and the
// widget settings dialog are the same value and cannot disagree. A CLI hop rather
// than a direct call because PluginRegistry is not a singleton and a plugin has no
// handle on it; reaching another part of the shell by shelling out to
// `omarchy-shell` is the route the shell's own microphone widget uses.
//
// The value is JSON — `setBarWidget` parses its argument — so it must be the bare
// word true/false, not a quoted string. A quoted "false" is a truthy string and
// would silently leave the preview on.
//
// `{}` is the selector: no selector means the setting applies to every instance of
// this widget, which is right because there is one camera.
function previewSettingArgs(moduleName, enabled) {
  return ["omarchy-shell", "-q", "shell", "setBarWidget",
          moduleName, "preview", enabled ? "true" : "false", "{}"]
}

// ---------------------------------------------------------------- image controls
//
// The panel does not carry its own table of image controls: the helper reads the
// real ranges, types and auto/manual flags off the driver and sends them, so the
// only thing here is presentation. That means a firmware that drops a control, or
// reports a different range, needs no change on this side.
//
// Everything below takes the parsed control list and answers one question about
// it. Nothing mutates, and nothing assumes a control exists.

function parseImage(raw) {
  var text = String(raw || "").trim()
  if (!text) return imageReply("no output")
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return imageReply("invalid helper output")
  }
  if (!data || typeof data !== "object") return imageReply("invalid helper output")

  var controls = []
  var list = Array.isArray(data.controls) ? data.controls : []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (!c || typeof c !== "object" || !c.key) continue
    var lo = Number(c.min), hi = Number(c.max)
    // A control with no range would render as a slider that cannot move. The
    // helper already drops these; this is the second line of defense, because a
    // dead row is the kind of bug that ships.
    if (!isFinite(lo) || !isFinite(hi) || hi <= lo) continue
    controls.push({
      key: String(c.key),
      label: String(c.label || c.key),
      type: String(c.type || "integer"),
      min: lo,
      max: hi,
      step: Math.max(1, Number(c.step) || 1),
      "default": Number(c["default"]),
      value: clamp(c.value, lo, hi),
      inactive: !!c.inactive,
      curated: !!c.curated,
      auto: c.auto ? String(c.auto) : "",
      unit: c.unit ? String(c.unit) : "",
      options: normalizeOptions(c.options)
    })
  }

  return {
    ok: data.ok !== false,
    error: String(data.error || ""),
    controls: controls,
    // Keyed by control, so the panel can mark exactly the row that was refused
    // rather than showing one banner for the whole section.
    failed: normalizeFailures(data.failed)
  }
}

function imageReply(error) {
  return { ok: false, error: String(error || ""), controls: [], failed: {} }
}

// Fold a *profile* reply into the control list the panel is already showing.
//
// Every profile subcommand answers with `profiles`, but only `load` and `save`
// also carry `controls` — `list`, and every failure, do not. Parsing those
// directly would swap the live list for an empty one and blank the whole section
// on a refresh that changed nothing. So the controls survive and only the status
// is taken from the reply.
function mergeImage(previous, raw) {
  var next = parseImage(raw)
  if (next.controls.length) return next
  next.controls = (previous && Array.isArray(previous.controls)) ? previous.controls : []
  return next
}

// Menu options, dropped unless they carry both halves. A chip with no label is
// unclickable-by-confusion, and one with no value writes nothing.
function normalizeOptions(raw) {
  var out = []
  if (!Array.isArray(raw)) return out
  for (var i = 0; i < raw.length; i++) {
    var o = raw[i]
    if (!o || typeof o !== "object") continue
    var value = Number(o.value)
    if (!isFinite(value) || !o.label) continue
    out.push({ value: value, label: String(o.label) })
  }
  return out
}

function normalizeFailures(raw) {
  var out = {}
  if (!raw || typeof raw !== "object") return out
  for (var key in raw) out[key] = String(raw[key])
  return out
}

// A glyph per control, so a row is identifiable at a glance without reading its
// label. Keyed by control rather than derived from the type, because the point is
// to distinguish five identically-shaped 0..255 sliders from each other.
//
// Deliberately a lookup with a fallback rather than a required entry: the panel
// takes its control list from the helper, so a firmware exposing something this
// table has never heard of must still render. It gets the generic slider glyph.
var CONTROL_GLYPHS = {
  brightness: "󰃠",
  contrast: "󰐩",
  saturation: "󰕣",
  sharpness: "󰉗",
  gamma: "󰕚",
  whiteBalanceAuto: "󰖨",
  whiteBalance: "󰔏",
  hue: "󰒞",
  gain: "󰌳",
  autoExposure: "󰄄",
  exposure: "󱎫",
  focusAuto: "󰽎",
  focus: "󰈐",
  powerLineFrequency: "󰥜",
  backlightCompensation: "󰃡"
}

function controlGlyph(control) {
  if (!control) return ""
  return CONTROL_GLYPHS[control.key] || "󰘮"
}

function findControl(controls, key) {
  if (!Array.isArray(controls)) return null
  for (var i = 0; i < controls.length; i++) {
    if (controls[i].key === key) return controls[i]
  }
  return null
}

// Just the values, keyed by control name — what a script asking the panel for its
// state actually wants. The ranges and menu options a full control list carries
// are `pixy image`'s answer to a different question.
function controlValues(controls) {
  var out = {}
  var list = Array.isArray(controls) ? controls : []
  for (var i = 0; i < list.length; i++) out[list[i].key] = list[i].value
  return out
}

function curatedControls(controls) {
  return (Array.isArray(controls) ? controls : []).filter(function(c) {
    return c.curated
  })
}

function advancedControls(controls) {
  return (Array.isArray(controls) ? controls : []).filter(function(c) {
    return !c.curated
  })
}

// Whether a control's row should be dimmed and its slider inert.
//
// Read from the driver's own flag rather than inferred from the auto switch's
// position, because the two can disagree for a moment: the switch is optimistic
// and the flag is fact. Inferring would flash the slider live before the driver
// agreed, then dim it again on the next refresh.
function isHeld(control) {
  return !!(control && control.inactive)
}

// Why a slider is dimmed, in the words of the switch that is holding it. Empty
// when nothing is holding it, so the caller can use it as both test and text.
function heldNote(controls, control) {
  if (!isHeld(control) || !control.auto) return ""
  var holder = findControl(controls, control.auto)
  return holder ? "Set by " + holder.label.toLowerCase() : "Set automatically"
}

// A copy of a control reading a different value.
//
// This is what lets the panel show an optimistic in-flight value without any of
// the labelling, percentage, nudge or menu helpers knowing that pending writes
// exist: point them at `withValue(control, pending)` and they answer about the
// value the user is dragging rather than the one the driver last reported.
function withValue(control, value) {
  if (!control) return control
  var copy = {}
  for (var key in control) copy[key] = control[key]
  copy.value = clamp(value, control.min, control.max)
  return copy
}

// The one line a row has for saying why it is not behaving normally. Both cases
// go in the same slot because a row has room for one, and a control that was
// refused *and* is held has nothing useful to say twice.
//
// The refusal wins: "held by auto white balance" is a standing condition the
// dimmed row already communicates, while a refused write is news.
function controlNote(controls, control, failed) {
  if (!control) return ""
  if (failed && failed[control.key]) return String(failed[control.key])
  return heldNote(controls, control)
}

// A control's value as a human reads it. Three cases, and the reason they are
// here rather than in the panel is that each is a judgement about meaning:
//
//   - a menu shows its option's label, because "3" is not an exposure mode
//   - anything with a unit shows the unit, because 5000 alone is not a colour
//   - everything else shows a percentage of its range, because the raw 0..255
//     the driver speaks is meaningless to anyone who has not read the UVC spec
function controlValueLabel(control) {
  if (!control) return ""
  if (control.type === "menu") {
    var option = optionFor(control, control.value)
    return option ? option.label : String(control.value)
  }
  if (control.type === "boolean") return control.value ? "On" : "Off"
  if (control.unit) return String(Math.round(control.value)) + " " + control.unit
  return String(controlPercent(control)) + "%"
}

// Position in the range as a percentage. Note this is *not* the value: a control
// spanning 2300..7500 sits at 0% when it reads 2300, not at 31%.
function controlPercent(control) {
  if (!control || control.max <= control.min) return 0
  var span = control.max - control.min
  return Math.round(((clamp(control.value, control.min, control.max) - control.min) / span) * 100)
}

// Turn a 0..1 slider position back into a value the driver will accept, landing
// on a step boundary so the readback agrees with where the handle was left.
function controlValueAt(control, fraction) {
  if (!control) return 0
  var raw = control.min + clamp(fraction, 0, 1) * (control.max - control.min)
  return snapControl(control, raw)
}

function snapControl(control, value) {
  if (!control) return 0
  var step = Math.max(1, control.step)
  var clamped = clamp(value, control.min, control.max)
  var snapped = control.min + Math.round((clamped - control.min) / step) * step
  return Math.round(clamp(snapped, control.min, control.max))
}

// One step along, for an arrow key or a wheel notch.
//
// The step the driver reports is 1 on every control this camera has, which would
// make an arrow press move a 0..255 slider by 0.4% — forty presses to cross a
// quarter of the range. So the nudge is a percentage of the span, rounded up to
// at least one step, and only the driver's step for ranges small enough that a
// percentage would round to nothing.
function controlNudge(control, direction) {
  if (!control) return 0
  var span = control.max - control.min
  var size = Math.max(control.step, Math.round(span * 0.04))
  return snapControl(control, control.value + (direction < 0 ? -size : size))
}

// The next option in a menu, wrapping. Menus here have two or three options, so
// cycling is the whole interaction — there is no case where a dropdown would
// earn its extra click.
function nextOption(control, direction) {
  if (!control || !control.options.length) return null
  var index = -1
  for (var i = 0; i < control.options.length; i++) {
    if (control.options[i].value === control.value) { index = i; break }
  }
  // An unrecognized current value starts from the beginning rather than from
  // nowhere: the camera reports 3 for Aperture Priority even where index 2 does
  // not exist, so "not in the list" is a real state, not a corrupt one.
  if (index < 0) return control.options[0]
  var next = (index + (direction < 0 ? -1 : 1) + control.options.length) % control.options.length
  return control.options[next]
}

function optionFor(control, value) {
  if (!control) return null
  for (var i = 0; i < control.options.length; i++) {
    if (control.options[i].value === value) return control.options[i]
  }
  return null
}

// Whether anything differs from the driver's defaults — what the Reset button
// keys its enabled state off.
//
// Power line frequency is excluded to match the helper's RESET_EXCLUDE: it is a
// property of the room's mains, not of the picture, so a camera that differs
// only there is already as neutral as Reset can make it. Held controls are
// excluded too, since their value is not in effect.
function imageIsDefault(controls) {
  var list = Array.isArray(controls) ? controls : []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (c.key === "powerLineFrequency") continue
    if (isHeld(c)) continue
    if (!isFinite(c["default"])) continue
    if (c.value !== c["default"]) return false
  }
  return true
}

// A one-line summary for the IMAGE header, so the section says something without
// being opened. Names what is off-default rather than counting it: "Brightness,
// contrast" tells you where to look, "2 adjusted" does not.
//
// Held controls are skipped for the same reason as in imageIsDefault, and the
// hardware makes this one easy to get wrong: the firmware keeps the last manual
// value in a control after its auto is switched back on, so an untouched camera
// reports whiteBalance 3200 against a default of 5000 with inactive:true. Reading
// that as an adjustment claims the picture was changed when nothing is in effect.
function imageSummary(controls) {
  var list = Array.isArray(controls) ? controls : []
  if (!list.length) return "Unavailable"
  var changed = []
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (c.key === "powerLineFrequency" || !isFinite(c["default"])) continue
    if (isHeld(c)) continue
    if (c.value !== c["default"]) changed.push(c.label)
  }
  if (!changed.length) return "Default"
  if (changed.length === 1) return changed[0] + " adjusted"
  if (changed.length === 2) return changed[0] + ", " + changed[1].toLowerCase()
  return changed.length + " adjusted"
}

function imageArgs(helper, assignments) {
  var argv = [helper, "image"]
  for (var key in assignments) {
    argv.push("--set", key + "=" + String(Math.round(Number(assignments[key]) || 0)))
  }
  return argv
}

function imageReadArgs(helper) {
  return [helper, "image"]
}

function imageResetArgs(helper) {
  return [helper, "image", "--reset"]
}

function profileArgs(helper, action, name) {
  var argv = [helper, "profile", String(action)]
  if (name) argv.push(String(name))
  return argv
}

// Profile names, sorted, from any reply that carries a `profiles` object — which
// every profile subcommand does, including the failures, so one parser covers
// save, load, clear and list.
function parseProfiles(raw) {
  var data
  try {
    data = JSON.parse(String(raw || "").trim())
  } catch (e) {
    return []
  }
  if (!data || typeof data !== "object" || !data.profiles) return []
  var names = []
  for (var name in data.profiles) {
    if (name) names.push(String(name))
  }
  return names.sort()
}

// Whether a typed profile name can be saved.
//
// The helper refuses a blank name and would happily overwrite an existing one, so
// this is what lets the panel disable the button rather than fire a write that
// comes back as an error — and what makes the button say "Overwrite" when that is
// what pressing it does. Comparison is exact, matching the helper's dict keys:
// "Warm" and "warm" really are two profiles down there.
function profileNameState(names, name) {
  var trimmed = String(name || "").trim()
  if (!trimmed) return "blank"
  var list = Array.isArray(names) ? names : []
  for (var i = 0; i < list.length; i++) {
    if (list[i] === trimmed) return "exists"
  }
  return "new"
}

// A default name for a new profile that does not collide with an existing one.
// Numbered rather than timestamped, because the panel has no clock worth showing
// and "Profile 2" is easier to say out loud than a date.
function nextProfileName(names) {
  var taken = {}
  var list = Array.isArray(names) ? names : []
  for (var i = 0; i < list.length; i++) taken[list[i]] = true
  for (var n = 1; n <= list.length + 1; n++) {
    var candidate = "Profile " + n
    if (!taken[candidate]) return candidate
  }
  return "Profile " + (list.length + 1)
}

// ---------------------------------------------------------------- microphone
//
// The PIXY's microphone is a plain PipeWire source — no vendor protocol, no
// helper involvement. So the mic section is entirely `Quickshell.Services.Pipewire`
// and these functions only pick the right node and label it.
//
// It has to be *this camera's* node, not `Pipewire.defaultAudioSource`. A webcam
// is rarely the system default, and a widget whose mic control silently drives a
// laptop's built-in array instead of the device named in its title is worse than
// having no mic control: muting it would look like it worked.

// Whether a PipeWire node is the PIXY's own microphone.
//
// Matched on identity strings rather than on the ALSA card number or the node id,
// both of which change across replug and reboot. `node.nick` is "EMEET PIXY" and
// `node.name` is `alsa_input.usb-EMEET_EMEET_PIXY_<serial>-02.mono-fallback` on
// this device; the serial rules out matching a full name, so it is a substring.
//
// **The `audio` check is the load-bearing half, not a formality.** *(observed)*
// The PIXY publishes two nodes with the nickname "EMEET PIXY": the ALSA source and
// the V4L2 *camera* (`v4l2_input.pci-…`, media.class Video/Source). Identity alone
// matches both, and so does any test for "input" or "source" in the name — the
// camera node is called `v4l2_input`. Only `node.audio` separates them: it is
// non-null on the microphone and null on the camera, it is a constant property
// rather than one that fills in later, and it reads correctly before
// PwObjectTracker has bound anything (verified at 100 ms from startup).
//
// Without it this function returns whichever of the two PipeWire enumerated first.
// It happens to be the microphone on this machine, which is precisely what makes
// the bug worth a comment: it would work until it silently did not.
//
// `properties` is read only as a fallback, and last. PwNode.properties is invalid
// until the node is bound, and the shell's own audio panel documents that touching
// it while capture streams are appearing can destabilize the Pipewire service, so
// the plain `name`/`nickname`/`description` accessors are tried first.
function isPixyMic(node) {
  if (!node || node.isSink || node.isStream) return false
  // An audio node, not the camera that shares its name.
  if (!node.audio) return false
  var haystack = [node.name, node.nickname, node.description].join(" ")
  if (/EMEET|PIXY/i.test(haystack)) return true
  var props = node.properties || {}
  haystack = [props["node.name"], props["node.nick"], props["node.description"]].join(" ")
  return /EMEET|PIXY/i.test(haystack)
}

// The PIXY's mic out of a node list, or null. First match wins; two PIXYs on one
// machine is not a case worth a disambiguation UI.
function findPixyMic(nodes) {
  if (!nodes) return null
  for (var i = 0; i < nodes.length; i++)
    if (isPixyMic(nodes[i])) return nodes[i]
  return null
}

// Bar and panel glyph for the mic. Muted gets the crossed-out microphone, for the
// same reason privacy gets the crossed-out webcam: a strike-through is unambiguous
// where a color shift is a guess.
//
// Codepoints are md-microphone (U+F036C) and md-microphone_off (U+F036D), verified
// present in the Nerd Font by glyph name rather than by eyeballing the shape.
function micIcon(muted) {
  return muted ? "󰍭" : "󰍬"
}

// Volume as a percentage string, or "Muted". One label rather than a percentage
// plus a separate mute indicator: at 0% muted and 40% muted, the number is not
// the answer to "will they hear me".
function micLabel(available, muted, volume) {
  if (!available) return "No microphone"
  if (muted) return "Muted"
  return Math.round(clamp(volume, 0, 1) * 100) + "%"
}

// Volume for a slider, clamped into 0..1. PipeWire allows over-amplification
// above 1.0; the slider deliberately does not, because a webcam mic driven past
// unity is clipping rather than louder.
function micVolume(node) {
  if (!node || !node.audio) return 0
  return clamp(node.audio.volume, 0, 1)
}

function micMuted(node) {
  return !!(node && node.audio && node.audio.muted)
}

function positionLabel(pan, tilt) {
  var p = clampPan(pan), t = clampTilt(tilt)
  if (p === 0 && t === 0) return "Centered"
  return degreeLabel(p) + ", " + degreeLabel(t)
}

// Signed degrees, with an explicit + so a positive value cannot be misread as
// an absolute one.
function degreeLabel(value) {
  var n = Math.round(Number(value) || 0)
  return (n > 0 ? "+" : "") + n + "°"
}

function zoomLabel(zoom) {
  // The wire units are 100..150; showing them as a multiplier is what the
  // official app displays and is what the number actually means.
  return (clampZoom(zoom) / 100).toFixed(2).replace(/0$/, "") + "×"
}

// Whether Recenter would do anything. Pan and tilt only, matching what
// `ptz --home` actually writes — zoom has no center to return to, and counting
// it here would report "not centered" for a camera that is.
function isCentered(state) {
  return !!state && state.pan === 0 && state.tilt === 0
}

// ---------------------------------------------------------------- helper argv

// Build the helper's argument list. Centralized so the Panel never assembles
// argv inline and every call site inherits the same flag spelling.

function stateArgs(helper) {
  return [helper, "state"]
}

function holdersArgs(helper) {
  return [helper, "holders"]
}

function modeArgs(helper, mode) {
  return [helper, "mode", String(mode)]
}

function privacyArgs(helper) {
  return [helper, "privacy"]
}

function ptzArgs(helper, pan, tilt) {
  return [helper, "ptz", "--pan", String(clampPan(pan)), "--tilt", String(clampTilt(tilt))]
}

function nudgeArgs(helper, direction, step) {
  var argv = [helper, "ptz", "--nudge", String(direction)]
  var size = Math.max(1, Math.round(Number(step) || PTZ_STEP))
  argv.push("--step", String(size))
  return argv
}

function homeArgs(helper) {
  return [helper, "ptz", "--home"]
}

function zoomArgs(helper, value) {
  return [helper, "zoom", String(clampZoom(value))]
}

function presetArgs(helper, action, slot) {
  return [helper, "preset", String(action), String(slot)]
}

// Nudge direction for an arrow key or a pad button, as the helper spells it.
//
// `dy` is in *tilt degrees*, not screen pixels: positive is up, matching both
// TILT_ABSOLUTE and the caller's own optimistic `shownTilt + dy * step`. Screen
// coordinates would be the other way round, and getting it backwards here is
// not a simple inversion — the pad's arrows and its slider then move opposite
// ways on the same press, so the handle jumps back on the next readback.
function nudgeFor(dx, dy) {
  if (dx < 0) return "left"
  if (dx > 0) return "right"
  if (dy > 0) return "up"
  if (dy < 0) return "down"
  return ""
}
