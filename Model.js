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

// ---------------------------------------------------------------- call automation
//
// "A call started" and "a call ended" are already known here: the panel polls who
// holds the capture stream so it can yield its own preview, and an app holding the
// stream *is* a call. So automation needs no new detection mechanism, no window
// title matching, and no list of meeting apps to keep up to date — a browser tab,
// a native client, and OBS all count identically, which is the right answer.
//
// The whole feature is therefore two pure functions plus a Panel property that
// remembers what it changed. Everything reversible is reversed on the way out;
// anything that was already in the wanted state is left alone, so ending a call
// cannot undo something the user set by hand.

var CALL_ACTIONS = ["tracking", "unmute", "openLens"]

// The same three actions as the panel draws them: in the order they are applied,
// each with the settings key that persists it. Separate from CALL_ACTIONS because
// that list is the plan's vocabulary and this is presentation — and because the
// order differs on purpose, openLens first for the reason callStartPlan gives.
var CALL_ACTION_META = [
  { key: "openLens", setting: "callOpenLens", label: "Open the lens",
    note: "Uncovers the camera when a call starts, and closes it again after." },
  { key: "tracking", setting: "callTracking", label: "Turn tracking on",
    note: "Follows you during the call, then restores the previous mode." },
  { key: "unmute", setting: "callUnmute", label: "Unmute the microphone",
    note: "Only if it was muted — a mic left on is left alone." }
]

// Is this transition a call starting or ending?
//
// `selfStreaming` is excluded deliberately: the panel's own preview holds the
// stream, so counting it would fire automation every time the popout opened. Only
// `streaming` — other apps — is a call.
function callEdge(wasStreaming, isStreaming) {
  if (!wasStreaming && isStreaming) return "start"
  if (wasStreaming && !isStreaming) return "end"
  return ""
}

// What to do about a call starting, given which actions are enabled and what the
// camera is currently doing.
//
// Returns an object of the changes to make, and — the part that matters — a
// `restore` object recording only what was actually changed. Ending the call
// replays `restore`, so a camera that was already unmuted and already tracking
// comes out of the call exactly as it went in. Without that bookkeeping, "end of
// call" would mute a mic the user had deliberately left on.
//
// `actions` is the enabled set as {tracking, unmute, openLens}. `now` is
// {privacy, mode, muted} — the live camera and mic state.
function callStartPlan(actions, now) {
  var opts = actions || {}
  var state = now || {}
  var plan = { restore: {} }

  // Opening the lens comes first and is its own action, because it is the one
  // that makes the difference between "my camera did not work" and everything
  // else on this list. A call joined with the lens closed shows a black frame.
  if (opts.openLens && state.privacy) {
    plan.privacy = false
    plan.restore.privacy = true
  }

  // Tracking only when the mode is known. An unknown mode means the camera would
  // not say whether it is already tracking, and restoring to a guess at the end
  // of the call is worse than not touching it — see the 0x03 ambiguity.
  if (opts.tracking && state.mode && state.mode !== "tracking") {
    plan.mode = "tracking"
    plan.restore.mode = state.mode
  }

  if (opts.unmute && state.muted === true) {
    plan.muted = false
    plan.restore.muted = true
  }

  return plan
}

// The inverse: what to undo when the call ends, from the `restore` recorded at
// the start. Only keys that were changed appear, so this is a no-op for anything
// the user had already set the way the call wanted it.
//
// Privacy is restored *last* in the caller's ordering for the same reason it is
// applied first: closing the lens while also writing a mode makes the mode write
// land on a camera that is going into privacy, and the firmware ignores
// Standard/Tracking writes made from privacy.
function callEndPlan(restore) {
  var saved = restore || {}
  var plan = {}
  if (saved.mode !== undefined) plan.mode = saved.mode
  if (saved.muted !== undefined) plan.muted = saved.muted
  if (saved.privacy !== undefined) plan.privacy = saved.privacy
  return plan
}

// Whether a plan asks for anything at all, so the caller can skip the work and
// the log line rather than writing an empty change.
function planIsEmpty(plan) {
  if (!plan) return true
  for (var key in plan) {
    if (key === "restore") continue
    return false
  }
  return true
}

// One line describing what automation did, for the panel's status area. Written
// here rather than in the Panel so the wording is testable and so the panel does
// not assemble prose inline.
function callActionLabel(plan) {
  if (planIsEmpty(plan)) return ""
  var parts = []
  if (plan.privacy === false) parts.push("opened the lens")
  if (plan.privacy === true) parts.push("closed the lens")
  if (plan.mode === "tracking") parts.push("tracking on")
  else if (plan.mode) parts.push(plan.mode)
  if (plan.muted === false) parts.push("unmuted")
  if (plan.muted === true) parts.push("muted")
  return parts.join(", ")
}

// ---------------------------------------------------------------- pages
//
// *(reported)* "since it is longer than the containing box there is no way to see
// the preview window when adjusting most of the settings", and then of the floating
// mini-preview that first answered it: "not sure i love the floating sticky thing".
//
// Both reports are the same underlying fact — the panel had grown to roughly two
// and a half screens, so anything below the fold was reached by scrolling the
// picture away. The floating dock treated the symptom by making the picture escape
// the scroll. This treats the cause: the body is split into pages that each fit,
// the preview is pinned above them where nothing can scroll it, and there is no
// scrolling to survive in the first place.
//
// Consequences worth stating, because they are what make it cheap:
//
//   The two sub-pages stop being special. "Advanced image" and "Camera settings"
//   were already body-replacing pages reached by their own keys with their own Back
//   rows; they are now two more tabs. That deletes both Back rows, both open/close
//   pairs, and the `onMainPage` gate that eight sections carried.
//
//   Every page is one cursor section. That was already true of the sub-pages, and
//   it is what keeps j/k honest: one list, no jumping between groups.
//
// FRAME is first because it is what the widget is for. SETTINGS is last because it
// is the page you visit once. MIC sits between IMAGE and SAVED rather than at the
// end, so the two "adjust a level" pages are neighbours.
//
// `value` rather than `key`, because this list is handed straight to
// `Ui/ButtonGroup` as its `options` and ButtonGroup reads `value` — a chip whose
// option object has no `value` gets `String(undefined)`, so every tab reports
// `"undefined"` on click and `resolvePage` falls the whole bar back to FRAME. Which
// is exactly what happened: *(reported)* "the buttons for settings, mic etc do not
// work". Naming the field what the consumer reads is the fix that cannot come back —
// there is no mapping step left to forget.
var PAGES = [
  { value: "frame", label: "FRAME", tooltip: "Aim the camera, mode, presets" },
  { value: "image", label: "IMAGE", tooltip: "Brightness, contrast, and the rest" },
  { value: "mic", label: "MIC", tooltip: "The camera's microphone" },
  { value: "settings", label: "SETTINGS", tooltip: "The camera's own firmware settings" }
]

// Which pages to draw, given what this camera turned out to have.
//
// A tab for a page with nothing on it is worse than a missing tab: it is a place to
// go that says nothing when you get there, and it costs a keypress to discover
// that. So MIC needs a microphone on the graph and IMAGE needs controls the driver
// answered for — the same conditions those sections already hid themselves under.
//
// FRAME is unconditional. It is where "no camera found" is explained, so it has to
// exist before anything is known.
function visiblePages(caps) {
  var c = caps || {}
  var out = []
  for (var i = 0; i < PAGES.length; i++) {
    var page = PAGES[i]
    if (page.value === "image" && !c.hasImage) continue
    if (page.value === "mic" && !c.hasMic) continue
    // Every settings row is a vendor HID write, so without the HID interface the
    // page is a list of controls that cannot do anything.
    if (page.value === "settings" && !c.hasVendor) continue
    out.push(page)
  }
  return out
}

// The page to land on when the list changes under the current one.
//
// A camera whose mic node disappears — unplugged, or PipeWire restarting — takes
// the MIC page with it, and the panel would otherwise be showing a page that is no
// longer in the tab bar: no tab highlighted, and h/l with nowhere to start from.
// Falling back to the first page rather than the nearest neighbour, because the
// first page is the only one guaranteed to exist.
function resolvePage(wanted, pages) {
  var list = (pages && pages.length) ? pages : []
  if (!list.length) return ""
  for (var i = 0; i < list.length; i++)
    if (list[i].value === wanted) return wanted
  return list[0].value
}

// Step to the next or previous page, stopping at the ends.
//
// Stopping rather than wrapping, unlike the chip groups: a tab bar is a row of
// places with a left and a right end, and wrapping from SETTINGS back to FRAME
// reads as the panel having jumped somewhere rather than moved. The chips wrap
// because a three-option cycle has no ends to speak of.
//
// `[` and `]` drive this, not Tab — Tab belongs to the bar, which uses it to move
// between panels, and not h/l, which sweeps whatever slider the cursor is on.
function stepPage(current, pages, direction) {
  var list = (pages && pages.length) ? pages : []
  if (!list.length) return ""
  var at = 0
  for (var i = 0; i < list.length; i++)
    if (list[i].value === current) at = i
  var next = at + (direction > 0 ? 1 : -1)
  if (next < 0 || next >= list.length) return list[at].value
  return list[next].value
}

function pageIndex(key, pages) {
  var list = (pages && pages.length) ? pages : []
  for (var i = 0; i < list.length; i++)
    if (list[i].value === key) return i
  return -1
}

// The hint line under each page. Per page because the keys differ, and a hint
// naming a key that does nothing here is worse than no hint: it sends someone
// pressing `s` on a page with nothing to save.
//
// `[`/`]` is named on every page because it is the one key that is new. It is not
// h/l, which adjusts whatever the cursor is on — the panel's main gesture — and it is
// not Tab: every other panel in the shell binds Tab to switching *bar* panels, and a
// plugin that quietly means something else by it is worse than a less obvious key.
function pageHints(page, caps) {
  var c = caps || {}
  var keys = ["[/] page"]
  if (page === "frame") {
    keys.push("j/k move", "h/l adjust", "1-3 recall", "s save", "x clear",
              "p privacy", "t tracking", "c recenter", "v preview")
  } else if (page === "image") {
    keys.push("j/k move", "h/l adjust", "enter toggle", "s name", "x clear")
  } else if (page === "mic") {
    keys.push("h/l level", "m mute")
  } else if (page === "settings") {
    keys.push("j/k move", "h/l change", "enter toggle", "x clear slot")
  }
  if (c.hasMic && page !== "mic") keys.push("m mute")
  keys.push("r refresh", "esc close")
  return keys.join(" · ")
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
//
// `capturing` is our own snapshot: taking a still needs the stream the preview is
// holding, so the preview yields to it exactly as it yields to another app. It
// outranks everything but the camera being absent, because it is the one blocker
// the user just asked for.
function previewBlocker(state, enabled, opened, capturing) {
  if (!state || !state.present) return "no-camera"
  if (capturing) return "capturing"
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
function previewNote(state, enabled, opened, capturing) {
  var reason = previewBlocker(state, enabled, opened, capturing)
  if (reason === "no-camera") return "No camera"
  if (reason === "capturing") return "Taking a snapshot"
  if (reason === "disabled") return "Preview off"
  if (reason === "privacy") return "Lens closed"
  if (reason === "busy") return streamLabel(state) || "In use"
  return ""
}

// The second line, which says what the note implies. Only where it is not
// obvious: "Lens closed" needs no gloss, but "In use by zoom" does — without it
// a blank preview during a call reads as this widget being broken.
function previewHint(state, enabled, opened, capturing) {
  var reason = previewBlocker(state, enabled, opened, capturing)
  if (reason === "capturing") return "The preview yields the camera for a moment."
  if (reason === "busy") return "Only one app can capture at a time. Controls still work."
  // Not currently rendered — the panel hides the whole frame when the preview is
  // off rather than leaving a placeholder — but kept correct and kept here so the
  // string does not have to be reinvented if that changes. It names the switch on
  // the FRAMING header rather than the widget settings dialog it used to point at,
  // and names the page rather than a direction: the switch is on FRAME and the
  // preview is pinned above every page, so "above" is only true on one of them.
  if (reason === "disabled") return "Turn it back on with the switch on FRAME."
  return ""
}

// 16:9, the only shape the preview is ever drawn in.
//
// It used to float: it sat in a slot among the framing rows and shrank into the
// corner of the viewport once that slot scrolled away, which is what previewDock
// computed. Pinned above the pages there is no scroll under it to track, so a fixed
// aspect is the whole of the sizing.
var PREVIEW_ASPECT = 9 / 16

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
  return boolSettingArgs(moduleName, "preview", enabled)
}

// The same write for any boolean setting the panel owns a switch for — the three
// call-automation actions. Shares previewSettingArgs' contract, including the
// bare-word JSON: a quoted "false" is a truthy string and would silently leave
// the setting on.
function boolSettingArgs(moduleName, key, enabled) {
  return ["omarchy-shell", "-q", "shell", "setBarWidget",
          moduleName, String(key), enabled ? "true" : "false", "{}"]
}

// An on/off word from the IPC, where every argument arrives as a string. Only the
// off words are listed, and anything else — including an omitted argument, which
// arrives as "" — means on. That asymmetry is on purpose: `pixy-ipc gesture` with
// nothing after it reads as "turn gestures on", and a typo that turned something
// *off* would be the surprising direction to fail in.
//
// Deliberately no "toggle": the panel would have to know the current value, and
// these settings are read on demand rather than polled — so a keybinding bound to
// a toggle would flip whatever the last read said, which may be nothing at all.
function boolArg(word) {
  var text = String(word === undefined || word === null ? "" : word).trim().toLowerCase()
  return !(text === "off" || text === "false" || text === "0" || text === "no")
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

// ---------------------------------------------------------------- vendor features
//
// The settings that live in the camera's own firmware rather than in V4L2: the
// microphone's DSP chain, gesture control, the image-orientation flips, what the
// autofocus aims at, and the idle shutter timeout. All of them are vendor HID
// reports, all of them survive a reboot and a different host, and none of them is
// reachable through any standard interface — which is the whole reason they are
// worth carrying here rather than leaving to the vendor app.
//
// They are read in one call (`pixy vendor`) and shown on their own page, for one
// reason: each is a separate HID query with its own retry budget, so folding them
// into `state` would multiply the cost of the panel's most frequent call for
// values that one page ever shows.
//
// A feature the camera did not answer for stays null rather than becoming false.
// "Off" and "could not read" are different things, and rendering the second as
// the first is how a panel ends up lying about hardware.

// Microphone DSP chain. Three named processing modes, and the only microphone
// control the firmware exposes — level and mute are PipeWire, further up.
var AUDIO_MODES = [
  { value: "noise-cancel", label: "Noise cancelling" },
  { value: "live", label: "Live" },
  { value: "original", label: "Original" }
]

// What the autofocus aims at. Independent of the UVC focus controls, which choose
// auto versus manual rather than *where*.
var FOCUS_TARGETS = [
  { value: "center", label: "Center" },
  { value: "face", label: "Face" },
  { value: "area", label: "Spot" }
]

// The selected-area grid, origin top left. Mirrors METERING_MAX in the helper,
// which clamps again before anything reaches the wire.
var METERING_MAX = 127

// Idle shutter timeout, in seconds, as choices rather than a free number. The
// firmware takes any 32-bit value, but a spinner for "how long before the lens
// closes itself" invites a number nobody wants — the useful answers are a handful
// of durations and off.
var AUTO_PRIVACY_CHOICES = [
  { seconds: 0, label: "Off" },
  { seconds: 60, label: "1 min" },
  { seconds: 300, label: "5 min" },
  { seconds: 900, label: "15 min" }
]

// The orientation toggles, in the order they are drawn. Manual 90° rotation is
// deliberately absent: EMEET Studio's rotate buttons produce no USB traffic at
// all, so rotation there is a host-side transform of its own preview rather than
// a camera setting, and there is nothing to write.
var FEATURE_TOGGLES = [
  { key: "flipHorizontal", label: "Mirror horizontally",
    note: "Flips the image left to right, in the camera." },
  { key: "flipVertical", label: "Mirror vertically",
    note: "Flips the image top to bottom, in the camera." },
  { key: "autoRotate", label: "Auto-rotate",
    note: "Lets the camera correct the image when it is mounted sideways." }
]

function parseVendor(raw) {
  var text = String(raw || "").trim()
  if (!text) return vendorReply("no output")
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return vendorReply("invalid helper output")
  }
  if (!data || typeof data !== "object") return vendorReply("invalid helper output")

  var features = {}
  var raw_features = (data.features && typeof data.features === "object") ? data.features : {}
  for (var i = 0; i < FEATURE_TOGGLES.length; i++) {
    var key = FEATURE_TOGGLES[i].key
    var value = raw_features[key]
    features[key] = (value === true || value === false) ? value : null
  }

  var metering = null
  if (data.metering && typeof data.metering === "object") {
    metering = {
      mode: FOCUS_TARGETS.some(function(t) { return t.value === data.metering.mode })
        ? String(data.metering.mode) : null,
      x: clamp(data.metering.x, 0, METERING_MAX),
      y: clamp(data.metering.y, 0, METERING_MAX)
    }
  }

  var native = {}
  var slots = (data.nativePresets && typeof data.nativePresets === "object")
    ? data.nativePresets : {}
  for (var s = 0; s < PRESET_SLOTS.length; s++) {
    var slot = PRESET_SLOTS[s]
    var entry = slots[String(slot)]
    native[slot] = (entry && typeof entry === "object") ? { saved: entry.saved === true } : null
  }

  return {
    ok: data.ok !== false,
    // `present: false` is the helper's way of saying there is no vendor HID node
    // at all, which is the ordinary state of a camera whose udev rule is missing —
    // a different thing from a failed read, and the only one worth instructions.
    present: data.present !== false,
    error: String(data.error || ""),
    audio: AUDIO_MODES.some(function(m) { return m.value === data.audio })
      ? String(data.audio) : null,
    gesture: (data.gesture === true || data.gesture === false) ? data.gesture : null,
    features: features,
    metering: metering,
    autoPrivacy: isFinite(Number(data.autoPrivacy)) && data.autoPrivacy !== null
      ? Math.max(0, Math.round(Number(data.autoPrivacy))) : null,
    nativePresets: native
  }
}

function vendorReply(error) {
  var features = {}
  for (var i = 0; i < FEATURE_TOGGLES.length; i++) features[FEATURE_TOGGLES[i].key] = null
  var native = {}
  for (var s = 0; s < PRESET_SLOTS.length; s++) native[PRESET_SLOTS[s]] = null
  return {
    ok: false, present: true, error: String(error || ""),
    audio: null, gesture: null, features: features,
    metering: null, autoPrivacy: null, nativePresets: native
  }
}

// Overlay the optimistic values a write is waiting on.
//
// Same reasoning as `imagePending` and the PTZ sliders: a vendor write costs a
// round trip through HID with a retry budget, and a switch that stays put for
// half a second after being clicked reads as broken. Keys are the ones the panel
// writes — "audio", "gesture", "autoPrivacy", "focus", and any feature key.
//
// A copy, never a mutation: a `var` property assigned in place notifies nothing,
// so the rows would keep showing the old value until something else changed.
function applyVendorPending(vendor, pending) {
  if (!vendor) return vendor
  var next = {}
  for (var key in vendor) next[key] = vendor[key]
  var waiting = pending || {}
  if (waiting.audio !== undefined) next.audio = waiting.audio
  if (waiting.gesture !== undefined) next.gesture = waiting.gesture
  if (waiting.autoPrivacy !== undefined) next.autoPrivacy = waiting.autoPrivacy
  if (waiting.focus !== undefined) {
    // The spot survives a mode change, because the camera keeps the last picked
    // point in those bytes — so an optimistic switch to Face must not blank the
    // coordinates the next switch back to Spot will still be using.
    var previous = vendor.metering || { x: 0, y: 0 }
    next.metering = {
      mode: waiting.focus.mode,
      x: waiting.focus.x === undefined ? previous.x : waiting.focus.x,
      y: waiting.focus.y === undefined ? previous.y : waiting.focus.y
    }
  }
  var features = {}
  for (var f in vendor.features) features[f] = vendor.features[f]
  for (var i = 0; i < FEATURE_TOGGLES.length; i++) {
    var name = FEATURE_TOGGLES[i].key
    if (waiting[name] !== undefined) features[name] = waiting[name]
  }
  next.features = features
  return next
}

// Whether anything at all was read. The page shows its own "no control interface"
// state rather than a column of rows that cannot say what they hold.
function vendorReadable(vendor) {
  if (!vendor) return false
  return vendor.audio !== null || vendor.gesture !== null || vendor.metering !== null
    || vendor.autoPrivacy !== null
}

// Why the page has nothing to show. Empty when it does.
function vendorNote(vendor) {
  if (!vendor) return ""
  if (vendor.present === false)
    return "The camera's control interface was not found. Install the udev rule — see the README."
  if (!vendorReadable(vendor))
    return vendor.error
      ? vendor.error
      : "The camera did not answer. Try again, or replug it."
  return ""
}

function audioLabel(mode) {
  for (var i = 0; i < AUDIO_MODES.length; i++)
    if (AUDIO_MODES[i].value === mode) return AUDIO_MODES[i].label
  return "Unknown"
}

// What each DSP mode is for. Worth stating on the page: the names alone do not
// say which one to pick, and picking wrong is only audible to whoever is
// listening — the one person who cannot tell you until afterwards.
function audioNote(mode) {
  if (mode === "noise-cancel")
    return "Suppresses room noise. The default, and the right one for a call."
  if (mode === "live")
    return "Wider response with light processing, for music and instruments."
  if (mode === "original")
    return "No processing at all — the raw capsule, for recording you will edit."
  return ""
}

function focusTargetLabel(mode) {
  for (var i = 0; i < FOCUS_TARGETS.length; i++)
    if (FOCUS_TARGETS[i].value === mode) return FOCUS_TARGETS[i].label
  return "Unknown"
}

function focusNote(metering) {
  var mode = metering ? metering.mode : null
  if (mode === "center") return "Focuses on the middle of the frame."
  if (mode === "face") return "Follows a face when it finds one."
  if (mode === "area") return "Click the pad to aim the spot."
  return ""
}

// Where the spot sits, as a fraction of the frame, so the preview can draw it
// without knowing the grid. Null when there is no spot to draw — which includes
// every mode but `area`, because the camera keeps the last picked point in those
// bytes and drawing it would show a target that is not in use.
function focusSpot(metering) {
  if (!metering || metering.mode !== "area") return null
  return { x: clamp(metering.x, 0, METERING_MAX) / METERING_MAX,
           y: clamp(metering.y, 0, METERING_MAX) / METERING_MAX }
}

// A click on the preview, in 0..1 of its width and height, as grid coordinates.
function focusPoint(fractionX, fractionY) {
  return {
    x: Math.round(clamp(fractionX, 0, 1) * METERING_MAX),
    y: Math.round(clamp(fractionY, 0, 1) * METERING_MAX)
  }
}

// The auto-privacy chips as a ButtonGroup takes them. Built here rather than in
// the panel because ButtonGroup keys on strings and these are seconds — the
// conversion in both directions belongs in one place, next to the list itself.
function autoPrivacyOptions() {
  var out = []
  for (var i = 0; i < AUTO_PRIVACY_CHOICES.length; i++)
    out.push({ value: String(AUTO_PRIVACY_CHOICES[i].seconds),
               label: AUTO_PRIVACY_CHOICES[i].label })
  return out
}

function autoPrivacyLabel(seconds) {
  if (seconds === null || seconds === undefined) return "Unknown"
  var n = Math.max(0, Math.round(Number(seconds) || 0))
  for (var i = 0; i < AUTO_PRIVACY_CHOICES.length; i++)
    if (AUTO_PRIVACY_CHOICES[i].seconds === n) return AUTO_PRIVACY_CHOICES[i].label
  // A value set by the vendor app or by hand on the CLI, which the chips have no
  // home for. Reported rather than rounded to the nearest chip: the camera holds
  // what it holds, and the chips show none selected.
  if (n % 60 === 0) return (n / 60) + " min"
  return n + " s"
}

// How the camera's own preset slots read, for the line under the framing presets.
// Saving a framing preset here mirrors it into the slot of the same number, so
// this is what says whether that worked.
function nativePresetSummary(vendor) {
  if (!vendor || !vendor.nativePresets) return ""
  var saved = []
  for (var i = 0; i < PRESET_SLOTS.length; i++) {
    var entry = vendor.nativePresets[PRESET_SLOTS[i]]
    if (entry && entry.saved) saved.push(PRESET_SLOTS[i])
  }
  if (!saved.length) return "None stored in the camera"
  if (saved.length === 1) return "Slot " + saved[0] + " stored in the camera"
  return "Slots " + saved.join(", ") + " stored in the camera"
}

// The same slots as a plain map of slot number to true/false/null, for `state`.
// The summary line above is prose and the page's rows are objects; a script wants
// neither. Null stays null here too — an unread slot is not an empty one.
function nativePresetSlots(vendor) {
  var out = {}
  var slots = (vendor && vendor.nativePresets) ? vendor.nativePresets : {}
  for (var i = 0; i < PRESET_SLOTS.length; i++) {
    var entry = slots[PRESET_SLOTS[i]]
    out[PRESET_SLOTS[i]] = entry ? entry.saved === true : null
  }
  return out
}

// ---- capture formats ----
//
// Read-only, deliberately. A format belongs to whoever holds the stream, so
// setting one here would apply to this process's own capture and vanish when it
// exits. The list is the useful part: it says what to ask a meeting app for.

function parseFormats(raw) {
  var text = String(raw || "").trim()
  if (!text) return { ok: false, error: "no output", formats: [] }
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "invalid helper output", formats: [] }
  }
  if (!data || typeof data !== "object")
    return { ok: false, error: "invalid helper output", formats: [] }

  var formats = []
  var list = Array.isArray(data.formats) ? data.formats : []
  for (var i = 0; i < list.length; i++) {
    var f = list[i]
    if (!f || typeof f !== "object" || !f.fourcc) continue
    var sizes = []
    var rawSizes = Array.isArray(f.sizes) ? f.sizes : []
    for (var s = 0; s < rawSizes.length; s++) {
      var size = rawSizes[s]
      if (!size || !isFinite(Number(size.width)) || !isFinite(Number(size.height))) continue
      var fps = []
      var rawFps = Array.isArray(size.fps) ? size.fps : []
      for (var n = 0; n < rawFps.length; n++)
        if (isFinite(Number(rawFps[n]))) fps.push(Number(rawFps[n]))
      sizes.push({ width: Number(size.width), height: Number(size.height), fps: fps })
    }
    formats.push({
      fourcc: String(f.fourcc),
      description: String(f.description || f.fourcc),
      compressed: !!f.compressed,
      sizes: sizes
    })
  }
  return { ok: data.ok !== false && formats.length > 0,
           error: String(data.error || ""), formats: formats }
}

// One line per format: what it is and the largest mode it offers. The full size
// list is what `pixy formats` is for — a panel row that tried to hold ten
// resolutions would be unreadable, and the biggest one is the question people
// actually have.
function formatLines(parsed) {
  var out = []
  var formats = (parsed && Array.isArray(parsed.formats)) ? parsed.formats : []
  for (var i = 0; i < formats.length; i++) {
    var f = formats[i]
    if (!f.sizes.length) { out.push({ name: f.fourcc, detail: "no sizes reported" }); continue }
    // The helper sorts largest first, and highest frame rate first within a size.
    var best = f.sizes[0]
    var detail = best.width + "×" + best.height
    if (best.fps.length) detail += " @ " + Math.round(best.fps[0]) + " fps"
    detail += " · " + f.sizes.length + (f.sizes.length === 1 ? " mode" : " modes")
    out.push({ name: f.fourcc, detail: detail })
  }
  return out
}

// The biggest still the camera can take, which is what the snapshot button gets.
function largestFormat(parsed) {
  var formats = (parsed && Array.isArray(parsed.formats)) ? parsed.formats : []
  var best = null
  for (var i = 0; i < formats.length; i++)
    for (var s = 0; s < formats[i].sizes.length; s++) {
      var size = formats[i].sizes[s]
      if (!best || size.width * size.height > best.width * best.height) best = size
    }
  return best
}

// ---- snapshots ----

function parseSnapshot(raw) {
  var text = String(raw || "").trim()
  if (!text) return { ok: false, error: "no output", path: "" }
  var data
  try {
    data = JSON.parse(text)
  } catch (e) {
    return { ok: false, error: "invalid helper output", path: "" }
  }
  if (!data || typeof data !== "object")
    return { ok: false, error: "invalid helper output", path: "" }
  return {
    ok: data.ok === true,
    error: String(data.error || ""),
    busy: data.busy === true,
    path: String(data.path || ""),
    width: Number(data.width) || 0,
    height: Number(data.height) || 0
  }
}

// What to say after a snapshot. The filename rather than the whole path, because
// the directory is the same every time and the panel is narrow — and the size,
// because "did it save the 4K one" is the question a still raises.
function snapshotLabel(shot) {
  if (!shot) return ""
  if (shot.ok) {
    var name = shot.path.split("/").pop()
    var size = shot.width && shot.height ? " · " + shot.width + "×" + shot.height : ""
    return "Saved " + name + size
  }
  if (shot.busy) return "Another app has the camera"
  return shot.error ? "Snapshot failed: " + shot.error : ""
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

// ---- vendor features ----
//
// One read call for all of them, because each is a separate HID query with its own
// retry budget and folding them into `state` would multiply the cost of the
// panel's most frequent call. Read when the tab that shows them opens.
function vendorArgs(helper) {
  return [helper, "vendor"]
}

function audioArgs(helper, mode) {
  return [helper, "audio", String(mode)]
}

function gestureArgs(helper, enabled) {
  return [helper, "gesture", enabled ? "on" : "off"]
}

function featureArgs(helper, name, enabled) {
  return [helper, "feature", String(name), enabled ? "on" : "off"]
}

function meteringArgs(helper, mode, x, y) {
  var argv = [helper, "metering", String(mode)]
  if (mode === "area") {
    argv.push("--x", String(clamp(Math.round(Number(x) || 0), 0, METERING_MAX)))
    argv.push("--y", String(clamp(Math.round(Number(y) || 0), 0, METERING_MAX)))
  }
  return argv
}

function autoPrivacyArgs(helper, seconds) {
  return [helper, "auto-privacy", String(Math.max(0, Math.round(Number(seconds) || 0)))]
}

function formatsArgs(helper) {
  return [helper, "formats"]
}

function snapshotArgs(helper) {
  return [helper, "snapshot"]
}

function nativePresetArgs(helper, action, slot) {
  var argv = [helper, "native-preset", String(action)]
  if (slot !== undefined && slot !== null) argv.push(String(slot))
  return argv
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
