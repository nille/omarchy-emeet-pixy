import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import QtMultimedia
import qs.Commons
import qs.Ui
import "Model.js" as Model

// EMEET PIXY webcam control. Every control is a qs.Ui component, so color,
// typography, spacing, corner rounding, and border weights all come from the
// active Omarchy theme rather than from anything hardcoded here.
Panel {
  id: root
  moduleName: "nille.emeet-pixy"
  ipcTarget: "nille.emeet-pixy"
  manageIpc: false

  // manageIpc: false so this panel owns the single IpcHandler its target
  // allows, and can expose camera control to keybindings and scripts.

  // PIXY_DIR points the helper at a working tree instead of the installed
  // plugin, which is what makes tests/harness/shell.qml drive the code you are
  // editing rather than the last copy you installed.
  readonly property string pluginDir: Quickshell.env("PIXY_DIR")
    || (Quickshell.env("HOME") + "/.config/omarchy/plugins/nille.emeet-pixy")
  readonly property string helper: pluginDir + "/scripts/pixy"

  // ---------------------------------------------------------------- theme
  //
  // Take the host bar's resolved colors and font when we have a bar, fall back
  // to the qs.Commons singletons otherwise. Color.* and Style.* are already
  // theme-reactive, so binding through them is what makes this widget follow
  // `omarchy theme set` live.
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color faint: Qt.darker(foreground, 1.9)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  // No openPanelIndicatorWidth/Height hint on purpose. Those tell the bar how long
  // to draw its open-panel mark, and the bar's own icon-sized default is already
  // right for a single-glyph widget — centred on the one glyph there is. Nothing
  // here reads the bar's axis either: one glyph looks the same on both.

  // Bar glyph color. Privacy is carried entirely by the crossed-out glyph, not
  // by color: the strike-through is unambiguous on its own, and a bar that turns
  // red for a state the user chose on purpose reads as a fault rather than a
  // setting. Absent stays dimmed, which is a real degradation.
  readonly property color barIconColor: {
    var base = bar ? bar.barForeground : Color.foreground
    return present ? base : Qt.darker(base, 1.55)
  }

  // ---------------------------------------------------------------- state

  property var camera: Model.parseState("")
  property string lastError: ""
  property bool loading: false
  property bool refreshQueued: false
  property bool everLoaded: false

  readonly property bool present: camera.present
  readonly property bool privacy: camera.privacy
  readonly property var presets: camera.presets

  readonly property int refreshIntervalSec: Math.max(2, Math.min(3600, Number(setting("refreshIntervalSec", 10)) || 10))
  readonly property int ptzStep: Math.max(1, Math.min(45, Number(setting("ptzStep", Model.PTZ_STEP)) || Model.PTZ_STEP))
  readonly property bool hideWhenAbsent: setting("hideWhenAbsent", false) === true

  // Optimistic local values so dragging feels instant. While a set is in flight
  // the control shows what the user asked for, not the last value read back —
  // otherwise the handle snaps backwards on every refresh mid-drag. The sentinel
  // sits outside every real range, so "unset" needs no second flag.
  readonly property int noPending: -1000
  property int pendingPan: noPending
  property int pendingTilt: noPending
  property int pendingZoom: noPending

  readonly property int shownPan: pendingPan === noPending ? camera.pan : pendingPan
  readonly property int shownTilt: pendingTilt === noPending ? camera.tilt : pendingTilt
  readonly property int shownZoom: pendingZoom === noPending ? camera.zoom : pendingZoom

  // Pan and tilt only, because that is precisely what Recenter changes. Folding
  // zoom in here leaves the button enabled at 0°, 0°, 1.30× while pressing it
  // does nothing visible, which reads as a broken control rather than a no-op.
  readonly property bool atHome: shownPan === 0 && shownTilt === 0

  // Carry sub-notch touchpad deltas between wheel events, as the bar's other
  // scrollable widgets do.
  property real wheelAccumulator: 0

  // Slot whose save is in flight, so the row can acknowledge the click before
  // the refresh brings the new position back.
  property int savingSlot: -1

  // ---------------------------------------------------------------- preview
  //
  // The camera outputs MJPEG natively and Qt decodes it, so the preview is a
  // CaptureSession rather than anything hand-rolled. The helper's ASCII renderer
  // still exists for the CLI, but the panel does not use it.
  //
  // Capture runs only while the popout is open, and three things outrank it:
  // privacy (nothing to show, and the stream would light the activity LED for a
  // black frame), the `preview` setting, and — the important one — another app
  // already holding the stream.
  //
  // That last case is a hard V4L2 constraint, not a courtesy: exactly one
  // process can hold the capture stream, so a preview started during a call
  // makes the *call* fail with EBUSY, not just the preview. Yielding is the only
  // correct behavior, and it costs nothing that matters — the control plane
  // (pan/tilt/zoom over UVC, privacy and tracking over HID) keeps working while
  // another app streams, so the widget is still fully usable mid-meeting.
  // `setting()` is the source of truth, so the panel switch and the widget
  // settings dialog are the same value and cannot disagree.
  //
  // `previewPending` is an optimistic override covering the round trip: the write
  // goes out to `omarchy-shell`, the shell rewrites shell.json, and the new
  // settings object comes back as a property change. That is fast but not
  // instant, and a switch that stays put for a beat after being clicked reads as
  // broken. Cleared as soon as the setting agrees with it.
  property var previewPending: null
  readonly property bool previewEnabled: previewPending !== null
    ? previewPending
    : setting("preview", true) !== false
  readonly property string previewBlocker: Model.previewBlocker(camera, previewEnabled,
                                                               opened, snapshotRunning)
  readonly property bool previewWanted: previewBlocker === ""
  property string previewError: ""

  // Drop the override once the real setting has caught up. Guarded on the raw
  // setting rather than on `previewEnabled`, which the override itself feeds —
  // comparing against it would always agree and never clear.
  readonly property bool previewSetting: setting("preview", true) !== false
  onPreviewSettingChanged: {
    if (previewPending === previewSetting) {
      previewPending = null
      previewPendingTimeout.stop()
    }
  }

  // Persisted, not session-only: a preview left running during a call is exactly
  // the thing someone turns off once and expects to stay off.
  function setPreviewEnabled(enabled) {
    if (previewEnabled === enabled) return
    previewPending = enabled
    previewPendingTimeout.restart()
    // execDetached with argv rather than bar.run, which wraps its argument in
    // `bash -lc`: there is nothing here that needs a shell, and no bar to depend
    // on, so the harness can drive this too.
    Quickshell.execDetached(Model.previewSettingArgs(moduleName, enabled))
  }

  // Give up on the override if the write never lands — `omarchy-shell` missing
  // from PATH, or the IPC refused. Without this the switch would sit in the
  // position it was clicked to forever while the preview stayed as it was, which
  // is the one failure worse than the switch not moving at all.
  Timer {
    id: previewPendingTimeout
    interval: 2000
    onTriggered: root.previewPending = null
  }

  function togglePreview() { setPreviewEnabled(!previewEnabled) }

  // The node the helper found, matched into QtMultimedia's device list. Matching
  // by id rather than by description because two PIXYs would be indistinguishable
  // by name, and the helper has already decided which node is the capture one.
  readonly property var previewDevice: {
    if (!camera.video || !mediaDevices.videoInputs) return null
    var inputs = mediaDevices.videoInputs
    for (var i = 0; i < inputs.length; i++)
      if (String(inputs[i].id) === String(camera.video)) return inputs[i]
    return null
  }

  // Smallest format at or above 360 lines. Without pinning, Qt picks the
  // camera's largest mode — 3840x2160 on this device — which is absurd for a
  // thumbnail and spends real CPU decoding frames that get scaled away.
  readonly property var previewFormat: {
    var dev = previewDevice
    if (!dev || !dev.videoFormats) return null
    var best = null
    for (var i = 0; i < dev.videoFormats.length; i++) {
      var f = dev.videoFormats[i]
      if (f.resolution.height < 360) continue
      if (!best || f.resolution.width * f.resolution.height
                 < best.resolution.width * best.resolution.height) best = f
    }
    return best
  }

  MediaDevices { id: mediaDevices }

  // ---------------------------------------------------------------- image
  //
  // Brightness, contrast, and the rest of the UVC picture controls. Read and
  // written over the same /dev/videoN the preview uses, but through control
  // ioctls rather than the stream — which is why this whole section keeps working
  // while a meeting app holds the camera, verified against the device. That is
  // what makes it worth having here: adjusting exposure is something you do
  // *during* a call, when the app that owns the stream is the one showing you the
  // problem.
  //
  // The panel keeps no table of controls. The helper reads the real ranges,
  // types, menu options and auto/manual flags off the driver and sends them, so a
  // firmware that drops a control or reports a different range needs no change
  // here. `image.controls` is the whole model.
  property var image: Model.parseImage("")
  property var imageProfiles: []
  readonly property var imageControls: image.controls
  readonly property var curatedImage: Model.curatedControls(imageControls)
  readonly property var advancedImage: Model.advancedControls(imageControls)
  readonly property bool hasImage: imageControls.length > 0
  readonly property var imageValues: Model.controlValues(imageControls)

  // Optimistic values, keyed by control, for exactly the same reason the PTZ
  // sliders have them: a drag emits far more sets than round trips, and a handle
  // that snaps back to the last readback mid-sweep is unusable. Cleared per
  // control as the readback catches up.
  property var imagePending: ({})

  // What a row should show: the pending value if one is in flight, otherwise what
  // the driver reported. `withValue` hands back a copy, so every label, percentage
  // and nudge helper answers about the pending value without knowing it exists.
  function shownControl(control) {
    if (!control) return control
    var pending = imagePending[control.key]
    return pending === undefined ? control : Model.withValue(control, pending)
  }

  // ---- the advanced view ----
  //
  // A view rather than a second popup: the advanced controls are the same section
  // seen closer up, and a nested window would put the framing preview and the
  // panel's own cursor model behind it. `imageView` swaps the panel body, so the
  // keyboard model stays one cursor over one visible list.
  property bool imageAdvanced: false

  // Read by every main-page section, so "a sub-page replaces the panel" is stated
  // once rather than being an `!imageAdvanced` repeated eight times — and so
  // adding the second sub-page did not mean revisiting every section.
  readonly property bool onMainPage: !imageAdvanced && !devicePage

  function openImageAdvanced() {
    imageAdvanced = true
    focusSection = "advanced"
    // The first control, not Back: opening a page with the cursor on the way out
    // of it makes Enter undo the thing that was just asked for.
    selectedIndex = advancedControlRow
    // The profile list is only read here, because this is the only place it is
    // shown — the main panel never needs it.
    readProfiles()
    Qt.callLater(function() {
      if (scrollArea && scrollArea.contentItem) scrollArea.contentItem.contentY = 0
    })
  }

  function closeImageAdvanced() {
    imageAdvanced = false
    focusSection = "image"
    selectedIndex = 0
    profileDraft = ""
    // Hiding the field is not enough to release the keyboard. `visible: false` on
    // an ancestor leaves the TextField holding activeFocus, which keeps
    // keyCatcher.blocked true — the main page's whole key map goes dead and the
    // presses pile up in an invisible field. The field's own Esc handler returns
    // focus, but leaving by the Back button with the mouse does not, so the
    // catcher takes it back here for every exit path.
    if (keyCatcher) keyCatcher.forceActiveFocus()
    Qt.callLater(function() {
      if (scrollArea && scrollArea.contentItem) scrollArea.contentItem.contentY = 0
    })
  }

  // The name in the save field. Held here rather than in the TextField so it
  // survives the field being destroyed when the view closes, and so the Save
  // button and the field agree on one value.
  property string profileDraft: ""
  readonly property string profileDraftState: Model.profileNameState(imageProfiles, profileDraft)

  // Put the cursor on the save row and the keyboard in the field together, so
  // 's' and clicking the field leave the panel in the same state.
  function focusProfileField() {
    if (!imageAdvanced) return
    setCursor("advanced", advancedSaveRow)
    // Pre-filled, because "Profile 2" is a better starting point than an empty
    // field: the common case is saving what is on screen under any name at all,
    // and a name that is already there can be typed over.
    if (profileDraft === "") profileDraft = Model.nextProfileName(imageProfiles)
    if (profileField) profileField.forceActiveFocus()
  }

  // ---------------------------------------------------------------- device page
  //
  // The camera's own firmware settings: microphone DSP mode, gesture control, the
  // orientation flips, what the autofocus aims at, the idle shutter timeout, and
  // the camera's own preset slots. All vendor HID, all persistent in the camera —
  // which is what makes them worth carrying, and also why they are on a page of
  // their own rather than in the main list.
  //
  // Read on demand, not on the refresh timer. `pixy vendor` is ten HID queries
  // sharing one descriptor; it costs ~0.6 s, and none of it changes unless
  // something here or the vendor app writes it. So it is read when the page opens
  // and after each write, and never polled.
  property var vendor: Model.parseVendor("")
  property var vendorPending: ({})
  readonly property var vendorShown: Model.applyVendorPending(vendor, vendorPending)
  property bool vendorLoaded: false
  property bool vendorLoading: false

  property bool devicePage: false

  // The formats list, read once with the page. Read-only by design — see
  // Model.parseFormats — so there is nothing to write back and no reason to reread.
  property var formats: Model.parseFormats("")
  property bool formatsLoaded: false

  // The last snapshot's outcome, so the button can report where the file went.
  // Null until one is taken; cleared when the panel closes, since a path from a
  // previous session is not news.
  property var lastSnapshot: null
  property bool snapshotRunning: false

  function openDevicePage() {
    devicePage = true
    focusSection = "device"
    selectedIndex = deviceBackRow
    refreshVendor()
    if (!formatsLoaded) {
      formatsProc.command = Model.formatsArgs(helper)
      formatsProc.running = true
    }
    Qt.callLater(function() {
      if (scrollArea && scrollArea.contentItem) scrollArea.contentItem.contentY = 0
    })
  }

  function closeDevicePage() {
    devicePage = false
    focusSection = "mode"
    selectedIndex = 0
    if (keyCatcher) keyCatcher.forceActiveFocus()
    Qt.callLater(function() {
      if (scrollArea && scrollArea.contentItem) scrollArea.contentItem.contentY = 0
    })
  }

  function refreshVendor() {
    if (vendorProc.running) return
    vendorLoading = true
    vendorProc.command = Model.vendorArgs(helper)
    vendorProc.running = true
  }

  function publishVendor(raw) {
    vendor = Model.parseVendor(raw)
    vendorLoaded = true
    // Every optimistic value dropped at once, rather than key by key: this reply
    // is a full read of all of them, so anything still pending is either
    // confirmed or was refused, and both cases want the hardware's answer.
    vendorPending = ({})
    clampCursor()
  }

  // One queue for every vendor write, and it has to be a queue rather than
  // latest-wins: these are unrelated settings, so a gesture write followed by an
  // audio write must not lose the gesture. Each reply is discarded and one shared
  // reread follows, because the setters answer with only their own field.
  property var vendorQueue: []

  function vendorWrite(argv, pending) {
    if (pending) {
      var next = {}
      for (var k in vendorPending) next[k] = vendorPending[k]
      for (var p in pending) next[p] = pending[p]
      vendorPending = next
    }
    if (vendorProc.running) {
      vendorQueue = vendorQueue.concat([argv])
      return
    }
    vendorProc.command = argv
    vendorProc.running = true
  }

  function drainVendorQueue() {
    if (!vendorQueue.length) {
      // Nothing left to write, so read the truth back. Deferred for the same
      // reason drainImageQueue is: `running` is still true inside onExited.
      Qt.callLater(function() { root.refreshVendor() })
      return
    }
    var argv = vendorQueue[0]
    vendorQueue = vendorQueue.slice(1)
    Qt.callLater(function() { root.vendorWrite(argv, null) })
  }

  function setAudioMode(mode) {
    if (!present || !mode) return
    vendorWrite(Model.audioArgs(helper, mode), { audio: mode })
  }

  function setGesture(enabled) {
    if (!present) return
    vendorWrite(Model.gestureArgs(helper, enabled), { gesture: enabled })
  }

  function setFeature(key, enabled) {
    if (!present || !key) return
    var pending = {}
    pending[key] = enabled
    vendorWrite(Model.featureArgs(helper, key, enabled), pending)
  }

  // The spot's coordinates travel with the mode, because the camera takes both in
  // one report — and switching to Spot without them would aim at whatever point
  // was last picked, which is not where the user just clicked.
  function setFocusTarget(mode, x, y) {
    if (!present || !mode) return
    var spot = vendorShown.metering || { x: 0, y: 0 }
    var px = x === undefined ? spot.x : x
    var py = y === undefined ? spot.y : y
    vendorWrite(Model.meteringArgs(helper, mode, px, py),
                { focus: { mode: mode, x: px, y: py } })
  }

  // A click on the preview while Spot is the focus target. Fractions rather than
  // pixels, so the conversion to the camera's grid lives in one testable place.
  function setFocusSpot(fractionX, fractionY) {
    var point = Model.focusPoint(fractionX, fractionY)
    setFocusTarget("area", point.x, point.y)
  }

  function setAutoPrivacy(seconds) {
    if (!present) return
    vendorWrite(Model.autoPrivacyArgs(helper, seconds), { autoPrivacy: seconds })
  }

  // The camera's own slots, distinct from the framing presets above: these hold
  // pan and tilt only, in the camera, shared with EMEET Studio. Saving a framing
  // preset already mirrors into the slot of the same number, so this page only
  // needs to say what they hold and let one be cleared.
  function clearNativePreset(slot) {
    // Slot 0 is what deviceNativeAt returns for a row that is not a slot at all,
    // which is how 'x' arrives here from elsewhere on the page.
    if (!present || !slot) return
    vendorWrite(Model.nativePresetArgs(helper, "clear", slot), null)
  }

  // A still needs the capture stream, and the panel's own preview is usually
  // holding it — so this is the one action here that has to take the camera away
  // from something. `snapshotRunning` unloads the preview (see previewLoader), and
  // the process starts a beat later because releasing a V4L2 device is not
  // synchronous with dropping the QML object: firing immediately gets EBUSY from
  // our own preview, which would be an absurd way to fail.
  //
  // Another *app* holding the stream is a different matter and is not worked
  // around: there is no way to grab a frame from a stream someone else owns, so
  // the helper reports `busy` and the button says so.
  function takeSnapshot() {
    if (!present || snapshotRunning) return
    lastSnapshot = null
    snapshotRunning = true
    snapshotDelay.restart()
  }

  Timer {
    id: snapshotDelay
    interval: 250
    onTriggered: {
      snapshotProc.command = Model.snapshotArgs(root.helper)
      snapshotProc.running = true
    }
  }

  // ---------------------------------------------------------------- call automation
  //
  // Which actions are enabled, from the settings, so the switches on the device
  // page and the widget settings dialog are the same values and cannot disagree.
  //
  // `callPending` is the same optimistic override the preview switch carries, for
  // the same reason: the write goes out to `omarchy-shell`, the shell rewrites
  // shell.json, and the new settings object comes back as a property change. Fast,
  // but not instant, and a switch that stays put for a beat reads as broken.
  property var callPending: ({})

  function callSetting(key) {
    var pending = callPending[key]
    return pending === undefined ? setting(key, false) === true : pending
  }

  readonly property var callActions: ({
    openLens: callSetting("callOpenLens"),
    tracking: callSetting("callTracking"),
    unmute: callSetting("callUnmute")
  })
  readonly property bool callAutomation: callActions.openLens || callActions.tracking
    || callActions.unmute

  function setCallAction(key, enabled) {
    if (callSetting(key) === enabled) return
    var next = {}
    for (var k in callPending) next[k] = callPending[k]
    next[key] = enabled
    callPending = next
    callPendingTimeout.restart()
    Quickshell.execDetached(Model.boolSettingArgs(moduleName, key, enabled))
  }

  // Drop the overrides the real settings have caught up with. Same shape as the
  // preview's, and the same failure it guards against: a write that never lands —
  // `omarchy-shell` missing from PATH, or the IPC refused — would otherwise leave
  // the switch showing a value nothing acts on.
  onSettingsChanged: {
    var next = {}
    var kept = false
    for (var key in callPending) {
      if (callPending[key] === (setting(key, false) === true)) continue
      next[key] = callPending[key]
      kept = true
    }
    callPending = next
    if (!kept) callPendingTimeout.stop()
  }

  Timer {
    id: callPendingTimeout
    interval: 2000
    onTriggered: root.callPending = ({})
  }

  // What the last call start changed, and therefore what its end should put back.
  // Null when no call is in progress. Session-only on purpose: a shell restart
  // mid-call has no way to know what the pre-call state was, and replaying a
  // stale one would be worse than leaving the camera as the call left it.
  property var callRestore: null

  // The line the panel shows about it, so automation is visible rather than
  // spooky — a camera that opens its own lens should say who did that.
  property string callNote: ""

  // The edge detector. `camera.streaming` counts only *other* apps, which is what
  // makes this work at all: the panel's own preview holds the stream too, and
  // counting it would fire automation every time the popout opened.
  //
  // Driven off a watched copy rather than a Connections on the property, because
  // both the full `state` read and the fast `holders` poll republish it and the
  // edge has to be taken once per real change.
  property bool wasStreaming: false

  onCameraChanged: {
    var edge = Model.callEdge(wasStreaming, camera.streaming)
    wasStreaming = camera.streaming
    if (edge === "start") applyCallStart()
    else if (edge === "end") applyCallEnd()
  }

  function applyCallStart() {
    if (!callAutomation || !present) return
    var plan = Model.callStartPlan(callActions, {
      privacy: privacy, mode: camera.mode, muted: hasMic ? micMuted : undefined
    })
    if (Model.planIsEmpty(plan)) return
    callRestore = plan.restore
    applyCallPlan(plan)
    callNote = "Call started — " + Model.callActionLabel(plan)
  }

  function applyCallEnd() {
    var plan = Model.callEndPlan(callRestore)
    callRestore = null
    if (Model.planIsEmpty(plan)) { callNote = ""; return }
    applyCallPlan(plan)
    callNote = "Call ended — " + Model.callActionLabel(plan)
  }

  // Applies a plan through the panel's ordinary paths, so automation cannot do
  // anything a click cannot.
  //
  // Order matters and it is the order below. Leaving privacy comes before the mode
  // write because the firmware ignores Standard/Tracking from privacy; entering it
  // comes after, for the same reason in reverse. `mode` is therefore written
  // between the two directions of privacy, which is why they are separate branches
  // rather than one call.
  function applyCallPlan(plan) {
    if (plan.privacy === false) setMode("standard")
    if (plan.mode) setMode(plan.mode)
    if (plan.privacy === true) setMode("privacy")
    if (plan.muted !== undefined) setMicMuted(plan.muted)
  }

  // ---------------------------------------------------------------- microphone
  //
  // The camera's microphone is a plain PipeWire source, so this needs no helper
  // work at all — no vendor reports, no ioctls. Volume and mute are PipeWire
  // properties, written directly.
  //
  // It is deliberately *this camera's* node rather than `Pipewire.defaultAudioSource`.
  // A webcam is rarely the system default, and a mic control inside a panel titled
  // PIXY that silently drives the laptop's built-in array would be worse than no
  // control: muting it would look like it worked.
  readonly property var pwNodes: Pipewire.nodes ? Pipewire.nodes.values : []
  readonly property var mic: Model.findPixyMic(pwNodes)
  readonly property bool hasMic: mic !== null && mic !== undefined
  readonly property bool micMuted: Model.micMuted(mic)
  readonly property real micVolume: Model.micVolume(mic)

  // Binding is what makes `audio.volume` and `audio.muted` readable and writable
  // at all; an unbound node reports neither. Bound unconditionally rather than
  // only while the panel is open, because the bar glyph shows mute state with the
  // panel closed — which is the point of putting it there.
  PwObjectTracker { objects: root.mic ? [root.mic] : [] }

  // The level meter's source. Metering costs a real PipeWire stream, so it runs
  // only while the panel is open and only while something could actually be
  // heard: a bouncing meter under a muted slider says the opposite of the truth.
  PwNodePeakMonitor {
    id: micPeak
    node: root.mic
    enabled: root.opened && root.hasMic && !root.micMuted
  }

  // Surfaced as properties rather than read off `micPeak` inline, so the meter
  // and anything inspecting it (the harness, a test) agree by construction.
  readonly property bool micMetering: micPeak.enabled
  readonly property real micPeakValue: Math.max(0, Math.min(1, micPeak.peak))

  function setMicVolume(v) {
    if (!hasMic || !mic.audio) return
    mic.audio.volume = Math.max(0, Math.min(1, v))
  }

  function toggleMicMute() {
    if (!hasMic || !mic.audio) return
    mic.audio.muted = !mic.audio.muted
  }

  function setMicMuted(muted) {
    if (!hasMic || !mic.audio) return
    mic.audio.muted = muted
  }

  // ---------------------------------------------------------------- cursor
  //
  // Sections, top to bottom:
  //   "header"  - privacy switch (no rows; selectedIndex -1)
  //   "mode"    - Standard / Tracking chips (0)
  //   "framing" - preview switch (0), pan (1), tilt (2), zoom (3), recenter (4)
  //   "image"   - one row per curated image control, only when the camera has any
  //   "mic"     - volume slider (0), only when the camera's mic is present
  //   "presets" - one row per slot (0..2)
  //
  // Two sub-pages replace all of them with one section of their own — "advanced"
  // for the image controls, "device" for the camera's firmware settings. Each is a
  // different page, not a longer one, so walking the cursor between them would be
  // walking between screens.
  //
  // The jog pad is deliberately not a cursor row: PanelKeyCatcher maps the arrow
  // keys to the same signal as h/j/k/l, so a 2D pad has no keys of its own to
  // claim. The pan and tilt sliders are the keyboard path — and they show the
  // current angle, which the pad cannot.
  property string focusSection: "mode"
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property bool headerHasCursor: cursorActive && focusSection === "header"

  // "mic" appears only when the camera's own microphone is on the graph, so j/k
  // never walks onto a section that is not rendered — a camera without a mic, or
  // one whose mic node has not appeared yet, would otherwise give the cursor a
  // dead stop halfway down the panel.
  readonly property var visibleSections: {
    // The sub-pages are their own pages, so each is the only section on itself —
    // and they keep "header" out too, because the hero is hidden there.
    if (imageAdvanced) return ["advanced"]
    if (devicePage) return ["device"]
    var list = ["header"]
    if (present) {
      list.push("mode", "framing")
      // Same reasoning as "mic": a camera whose image controls could not be read
      // renders no section, so the cursor must not be able to land on one.
      if (hasImage) list.push("image")
      if (hasMic) list.push("mic")
      list.push("presets", "camera")
    }
    return list
  }

  function sectionCount(section) {
    if (section === "header") return 0
    if (section === "mode") return 1
    if (section === "framing") return 5
    // Row per control rather than a fixed count: the list comes from the driver.
    if (section === "image") return curatedImage.length
    // Back, then the advanced rows, then the profile list and its save field.
    if (section === "advanced") return advancedImage.length + 2 + imageProfiles.length
    if (section === "device") return deviceNativeRow + Model.PRESET_SLOTS.length
    if (section === "mic") return 1
    if (section === "presets") return Model.PRESET_SLOTS.length
    // The one row that opens the device page. A section of its own rather than a
    // cog on some other header, because nothing above it is what it leads to.
    if (section === "camera") return 1
    return 0
  }

  // The advanced view's rows, laid out as: Back, then every control, then one row
  // per saved profile, then the save field. Named rather than compared inline so
  // the layout is stated once and the four places that dispatch on it agree.
  //
  // Back is row 0 because it is drawn first. It was numbered after the last
  // control at one point, on the theory that j from the bottom of the list should
  // reach it — but that makes j jump from the bottom slider to the top of the
  // page and then back down into the profiles, which reads as the cursor
  // misfiring. Drawn order is the only order the eye can follow.
  readonly property int advancedBackRow: 0
  readonly property int advancedControlRow: 1
  readonly property int advancedProfileRow: advancedControlRow + advancedImage.length
  readonly property int advancedSaveRow: advancedProfileRow + imageProfiles.length

  function advancedControlAt(index) {
    var i = index - advancedControlRow
    return i >= 0 && i < advancedImage.length ? advancedImage[i] : null
  }

  function advancedProfileAt(index) {
    var i = index - advancedProfileRow
    return i >= 0 && i < imageProfiles.length ? imageProfiles[i] : ""
  }

  // The device page's rows, in drawn order for the same reason the advanced view's
  // are: rows are numbered down the screen, so j goes down the screen. Two of the
  // groups have their length from Model rather than from here, so the arithmetic
  // chains rather than being written out — adding a fourth orientation toggle then
  // needs no change below.
  //
  // The formats list is deliberately not in here. It is read-only text, so a
  // cursor row for it would be a row where Enter does nothing — the same dead stop
  // the advanced page's tests exist to prevent.
  readonly property int deviceBackRow: 0
  readonly property int deviceAudioRow: 1
  readonly property int deviceGestureRow: 2
  readonly property int deviceFocusRow: 3
  readonly property int deviceFeatureRow: 4
  readonly property int deviceAutoPrivacyRow: deviceFeatureRow + Model.FEATURE_TOGGLES.length
  readonly property int deviceCallRow: deviceAutoPrivacyRow + 1
  readonly property int deviceSnapshotRow: deviceCallRow + Model.CALL_ACTION_META.length
  readonly property int deviceNativeRow: deviceSnapshotRow + 1

  function deviceFeatureAt(index) {
    var i = index - deviceFeatureRow
    return i >= 0 && i < Model.FEATURE_TOGGLES.length ? Model.FEATURE_TOGGLES[i] : null
  }

  function deviceCallAt(index) {
    var i = index - deviceCallRow
    return i >= 0 && i < Model.CALL_ACTION_META.length ? Model.CALL_ACTION_META[i] : null
  }

  function deviceNativeAt(index) {
    var i = index - deviceNativeRow
    return i >= 0 && i < Model.PRESET_SLOTS.length ? Model.PRESET_SLOTS[i] : 0
  }

  // Enter on a device row. Chip groups cycle rather than toggle, matching what
  // h/l does to them, so one key covers a three-option row.
  function activateDeviceRow(index) {
    if (index === deviceBackRow) { closeDevicePage(); return }
    if (index === deviceAudioRow) { cycleAudio(1); return }
    if (index === deviceGestureRow) { setGesture(!vendorShown.gesture); return }
    if (index === deviceFocusRow) { cycleFocus(1); return }
    if (index === deviceAutoPrivacyRow) { cycleAutoPrivacy(1); return }
    if (index === deviceSnapshotRow) { takeSnapshot(); return }
    var feature = deviceFeatureAt(index)
    if (feature) { setFeature(feature.key, !vendorShown.features[feature.key]); return }
    var call = deviceCallAt(index)
    if (call) { setCallAction(call.setting, !callActions[call.key]); return }
    var slot = deviceNativeAt(index)
    // A native slot's only action from the keyboard is to be cleared: saving one
    // happens through the framing presets above, which mirror into it and also
    // record the zoom these slots cannot hold.
    if (slot) clearNativePreset(slot)
  }

  // h/l on a device row. Only the chip groups have a direction; the switches use
  // Enter, matching how the image page treats booleans versus menus.
  function adjustDeviceRow(index, direction) {
    if (index === deviceAudioRow) { cycleAudio(direction); return }
    if (index === deviceFocusRow) { cycleFocus(direction); return }
    if (index === deviceAutoPrivacyRow) { cycleAutoPrivacy(direction); return }
    // A switch keeps direction meaningful, as the image page's booleans do: l
    // turns it on, h off, so pressing l on something already on leaves it on.
    if (index === deviceGestureRow) { setGesture(direction > 0); return }
    var feature = deviceFeatureAt(index)
    if (feature) { setFeature(feature.key, direction > 0); return }
    var call = deviceCallAt(index)
    if (call) setCallAction(call.setting, direction > 0)
  }

  // Cycling helpers. Wrapping rather than stopping at the ends, because these are
  // short option lists rather than ranges — a three-chip row that refuses to move
  // reads as a dead key, and there is no "past the end" to protect.
  function cycleAudio(direction) {
    var modes = Model.AUDIO_MODES
    var at = 0
    for (var i = 0; i < modes.length; i++)
      if (modes[i].value === vendorShown.audio) at = i
    setAudioMode(modes[(at + direction + modes.length) % modes.length].value)
  }

  function cycleFocus(direction) {
    var targets = Model.FOCUS_TARGETS
    var current = vendorShown.metering ? vendorShown.metering.mode : null
    var at = 0
    for (var i = 0; i < targets.length; i++)
      if (targets[i].value === current) at = i
    setFocusTarget(targets[(at + direction + targets.length) % targets.length].value)
  }

  function cycleAutoPrivacy(direction) {
    var choices = Model.AUTO_PRIVACY_CHOICES
    var at = 0
    for (var i = 0; i < choices.length; i++)
      if (choices[i].seconds === vendorShown.autoPrivacy) at = i
    setAutoPrivacy(choices[(at + direction + choices.length) % choices.length].seconds)
  }

  function setHeaderCursor() {
    cursorActive = true
    focusSection = "header"
    selectedIndex = -1
  }

  function setCursor(section, index) {
    cursorActive = true
    focusSection = section
    selectedIndex = index
  }

  function moveCursor(delta) {
    var sections = visibleSections
    if (!sections.length) return
    var sIdx = sections.indexOf(focusSection)
    if (sIdx < 0) {
      focusSection = sections[0]
      selectedIndex = sectionCount(focusSection) ? 0 : -1
      return
    }
    var max = sectionCount(focusSection) - 1

    if (delta > 0) {
      if (selectedIndex < max) { selectedIndex = selectedIndex + 1; return }
      if (sIdx < sections.length - 1) {
        focusSection = sections[sIdx + 1]
        selectedIndex = sectionCount(focusSection) ? 0 : -1
      }
    } else {
      if (selectedIndex > 0) { selectedIndex = selectedIndex - 1; return }
      if (sIdx > 0) {
        var prev = sections[sIdx - 1]
        focusSection = prev
        var prevMax = sectionCount(prev) - 1
        selectedIndex = prevMax >= 0 ? prevMax : -1
      }
    }
  }

  // h/l adjusts whichever control the cursor sits on.
  function adjustHorizontal(direction) {
    if (focusSection === "mode") {
      setMode(camera.mode === "tracking" ? "standard" : "tracking")
      return
    }
    if (focusSection === "mic") {
      // 5% a press, matching the granularity of the shell's own audio panel so
      // one h/l feels the same everywhere in the bar.
      setMicVolume(micVolume + direction * 0.05)
      return
    }
    if (focusSection === "image") {
      adjustControl(curatedImage[selectedIndex], direction)
      return
    }
    if (focusSection === "advanced") {
      adjustControl(advancedControlAt(selectedIndex), direction)
      return
    }
    if (focusSection === "device") {
      adjustDeviceRow(selectedIndex, direction)
      return
    }
    if (focusSection !== "framing") return
    // The preview switch (row 0) is boolean, so h/l has nothing to sweep — Enter
    // and `v` are its interaction, the same as the mode chips.
    if (selectedIndex === 1) setPan(shownPan + direction * ptzStep)
    else if (selectedIndex === 2) setTilt(shownTilt + direction * ptzStep)
    else if (selectedIndex === 3) setZoom(shownZoom + direction * 5)
  }

  // h/l on an image row. What that means depends on the control, and all three
  // cases are h/l rather than some being Enter-only: the rows look alike, and a
  // key that works on four of five sliders is worse than one that works on all.
  //
  // Menus cycle instead of sweeping, because a two-option menu has no range to
  // sweep — and cycling is also what Enter does, so the two agree.
  function adjustControl(control, direction) {
    if (!control || Model.isHeld(control)) return
    var shown = shownControl(control)
    if (control.type === "menu") {
      var option = Model.nextOption(shown, direction)
      if (option) setImageControl(control.key, option.value)
      return
    }
    if (control.type === "boolean") {
      // Direction is meaningful here, unlike Enter's toggle: l turns it on, h off.
      // Pressing l on something already on should leave it on, not flip it.
      setImageControl(control.key, direction > 0 ? control.max : control.min)
      return
    }
    setImageControl(control.key, Model.controlNudge(shown, direction))
  }

  // Enter on an image row. Only the switches and menus have an activate action;
  // for a slider h/l is the whole interaction, as with pan and tilt.
  function activateControl(control) {
    if (!control || Model.isHeld(control)) return
    if (control.type === "boolean") {
      setImageControl(control.key,
                      shownControl(control).value ? control.min : control.max)
      return
    }
    if (control.type === "menu") {
      var option = Model.nextOption(shownControl(control), 1)
      if (option) setImageControl(control.key, option.value)
    }
  }

  function activateCursor() {
    if (focusSection === "header") { togglePrivacy(); return }
    if (focusSection === "mode") {
      setMode(camera.mode === "tracking" ? "standard" : "tracking")
      return
    }
    // Sliders have no activate action — h/l is their whole interaction.
    if (focusSection === "framing") {
      if (selectedIndex === 0) togglePreview()
      else if (selectedIndex === 4) home()
      return
    }
    if (focusSection === "image") {
      activateControl(curatedImage[selectedIndex])
      return
    }
    if (focusSection === "advanced") {
      if (selectedIndex === advancedBackRow) { closeImageAdvanced(); return }
      if (selectedIndex === advancedSaveRow) {
        // Enter on the name field means "type here" while it is empty, and "save
        // that" once it is not. Both because saving a blank name does nothing —
        // which made Enter a dead key on the one row that looks most like it wants
        // one — and because the cursor is drawn on the field without the field
        // holding the keyboard, so typing a name went to the shortcuts instead and
        // the `i` in "Evening" closed the whole view. Found by typing into it.
        if (profileDraftState === "blank") focusProfileField()
        else saveProfile(profileDraft)
        return
      }
      var name = advancedProfileAt(selectedIndex)
      // Recall, matching the framing presets: a saved profile's one action is to
      // be applied, and `x` is how every panel in the bar spells "remove this".
      if (name) { loadProfile(name); return }
      activateControl(advancedControlAt(selectedIndex))
      return
    }
    if (focusSection === "device") {
      activateDeviceRow(selectedIndex)
      return
    }
    if (focusSection === "camera") { openDevicePage(); return }
    // The mic row is the exception: its slider does have an activate action,
    // because mute is the thing you reach for in a hurry and h/l down to zero is
    // not the same as muting.
    if (focusSection === "mic") { toggleMicMute(); return }
    if (focusSection === "presets") {
      var slot = Model.PRESET_SLOTS[selectedIndex]
      // Recall a saved slot, store into an empty one. One key doing both is
      // what makes presets usable without reaching for the mouse, and an empty
      // slot has no other sensible action.
      if (Model.hasPreset(presets, slot)) loadPreset(slot)
      else savePreset(slot)
    }
  }

  function clampCursor() {
    var sections = visibleSections
    if (!sections.length) return
    // "header" has no rows, so let it through rather than knocking the cursor
    // off the privacy switch every time a refresh republishes state.
    if (focusSection === "header") return
    if (sections.indexOf(focusSection) < 0) {
      focusSection = sections[0]
      selectedIndex = sectionCount(focusSection) ? 0 : -1
      return
    }
    var count = sectionCount(focusSection)
    if (count === 0) { selectedIndex = -1; return }
    if (selectedIndex > count - 1) selectedIndex = count - 1
    if (selectedIndex < 0) selectedIndex = 0
  }

  // Scroll the panel by one wheel notch.
  //
  // Exists because PanelSlider swallows wheel events: its internal MouseArea has
  // an onWheel that adjusts the value and accepts the event unconditionally, so
  // the Flickable above it never sees the gesture. Scrolling down to the presets
  // therefore stopped at the first slider and started panning the camera instead
  // — a scroll gesture aimed at the list, silently redirected into moving hardware.
  //
  // The slider is a shared qs.Ui component, so it cannot be fixed from here; the
  // rows intercept the wheel before it reaches the slider and call this. Deliberate
  // consequence: there is no wheel path to adjusting a slider. Drag, h/l, and the
  // arrow keys all still work, and a wheel over a list should scroll the list.
  function scrollBy(pixelDelta) {
    var flick = scrollArea ? scrollArea.contentItem : null
    if (!flick || flick.contentY === undefined) return
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    if (maxY <= 0) return
    flick.contentY = Math.max(0, Math.min(maxY, flick.contentY - pixelDelta))
  }

  // Keep the focused row inside the ScrollView's viewport; without this, j/k
  // can walk the cursor off-screen.
  function ensureCursorVisible(item) {
    if (!item || !scrollArea) return
    var flick = scrollArea.contentItem
    if (!flick || flick.contentY === undefined) return
    var margin = Style.space(6)
    var maxY = Math.max(0, (flick.contentHeight || 0) - flick.height)
    if (maxY <= 0) { flick.contentY = 0; return }
    var pt = item.mapToItem(flick.contentItem || flick, 0, 0)
    var top = pt.y
    var bottom = top + (item.height || 0)
    if (top < flick.contentY + margin)
      flick.contentY = Math.max(0, Math.min(maxY, top - margin))
    else if (bottom > flick.contentY + flick.height - margin)
      flick.contentY = Math.max(0, Math.min(maxY, bottom + margin - flick.height))
  }

  // ---------------------------------------------------------------- actions

  // Every mutation goes through one detached process. Fire-and-forget plus a
  // follow-up read is deliberate: a slider drag emits far more sets than round
  // trips we would want to await, and the refresh reconciles anyway.
  function run(argv) {
    Quickshell.execDetached(argv)
    settleTimer.restart()
  }

  function togglePrivacy() {
    if (!present) return
    run(Model.privacyArgs(helper))
  }

  // Guarded in one place rather than at each caller, because there are four —
  // the chips, `t`, h/l and Enter on the mode row, and the `tracking`/`standard`
  // IPC methods — and a keybinding that silently does nothing is the same bug as
  // a chip that does.
  //
  // Both directions of privacy are exempt, and the second one is easy to miss.
  // *Entering* privacy works on an idle camera, so gating it would break the one
  // control that most needs to work when the camera is doing nothing. *Leaving*
  // it is a mode write like any other — `privacyOff` is literally
  // setMode("standard") — and it also works idle, verified: the lens reopens even
  // though which of Standard/Tracking it lands in is up to the firmware. Without
  // this second exemption the guard would lock the lens shut on an idle camera,
  // turning a fix for a dead button into a trap. See Model.modeWritable.
  function setMode(mode) {
    if (!present) return
    if (mode !== "privacy" && !camera.privacy && !Model.modeWritable(camera)) return
    run(Model.modeArgs(helper, mode))
  }

  // Pan and tilt travel together in one helper call, because they are one
  // physical move: sending them separately makes the camera swing twice.
  function setPan(value) {
    if (!present) return
    pendingPan = Model.clampPan(value)
    if (pendingTilt === noPending) pendingTilt = camera.tilt
    ptzDebounce.restart()
  }

  function setTilt(value) {
    if (!present) return
    pendingTilt = Model.clampTilt(value)
    if (pendingPan === noPending) pendingPan = camera.pan
    ptzDebounce.restart()
  }

  function flushPtz() {
    if (pendingPan === noPending && pendingTilt === noPending) return
    run(Model.ptzArgs(helper, shownPan, shownTilt))
    // Motors take a moment; read back late enough to catch where they landed.
    motorTimer.restart()
  }

  // The jog pad's path. --nudge lets the helper do the arithmetic against the
  // position it just read, so a pad press stays correct even if the camera was
  // moved from another app since our last refresh.
  function nudge(dx, dy) {
    if (!present) return
    var direction = Model.nudgeFor(dx, dy)
    if (!direction) return
    // Move the sliders now so the pad feels connected to them, then let the
    // readback correct us.
    if (dx !== 0) pendingPan = Model.clampPan(shownPan + dx * ptzStep)
    if (dy !== 0) pendingTilt = Model.clampTilt(shownTilt + dy * ptzStep)
    run(Model.nudgeArgs(helper, direction, ptzStep))
    motorTimer.restart()
  }

  function home() {
    if (!present) return
    // Pan and tilt only. `ptz --home` recenters the lens and deliberately
    // leaves zoom alone — zoom has no center to return to — so optimistically
    // resetting it here would drop the slider to 1.00× and let the readback
    // yank it back a moment later.
    pendingPan = 0
    pendingTilt = 0
    run(Model.homeArgs(helper))
    motorTimer.restart()
  }

  function setZoom(value) {
    if (!present) return
    pendingZoom = Model.clampZoom(value)
    zoomDebounce.restart()
  }

  function flushZoom() {
    if (pendingZoom === noPending) return
    run(Model.zoomArgs(helper, pendingZoom))
  }

  function savePreset(slot) {
    if (!present) return
    savingSlot = slot
    run(Model.presetArgs(helper, "save", slot))
    saveTimer.restart()
  }

  function loadPreset(slot) {
    if (!present || !Model.hasPreset(presets, slot)) return
    var entry = presets[slot]
    pendingPan = entry.pan
    pendingTilt = entry.tilt
    pendingZoom = entry.zoom
    run(Model.presetArgs(helper, "load", slot))
    motorTimer.restart()
  }

  function clearPreset(slot) {
    if (!present || !Model.hasPreset(presets, slot)) return
    run(Model.presetArgs(helper, "clear", slot))
  }

  // ---- image controls ----
  //
  // Writes are batched by the debounce below rather than sent per event, and the
  // batch matters for more than cost: the helper orders an auto switch and the
  // control it gates correctly *within one call*, so turning off auto white
  // balance and setting a temperature together works, while two calls would race
  // the driver's interlock and the temperature would be refused.
  function setImageControl(key, value) {
    if (!present || !key) return
    var control = Model.findControl(imageControls, key)
    // Nothing read yet — the panel has never been opened, and this is a keybinding
    // arriving cold. Send it straight through rather than dropping it: the helper
    // knows the real range and clamps, and the readback it answers with is what
    // populates the list for next time.
    if (!control) {
      var direct = {}
      direct[key] = Math.round(Number(value))
      imageWrite(Model.imageArgs(helper, direct))
      return
    }
    var snapped = Model.snapControl(control, value)
    // Copy rather than mutate: a var property assigned in place notifies nothing,
    // so the rows would keep showing the previous value until something else
    // happened to change.
    var next = {}
    for (var k in imagePending) next[k] = imagePending[k]
    next[key] = snapped
    imagePending = next
    imageDebounce.restart()
  }

  function flushImage() {
    var keys = Object.keys(imagePending)
    if (!keys.length) return
    imageWrite(Model.imageArgs(helper, imagePending))
  }

  // Every image write goes out through a Process rather than execDetached, unlike
  // the PTZ path. The reply is the authoritative readback — including the
  // `inactive` flags, which can only be known *after* the write — so awaiting it
  // costs one round trip and saves a separate refresh.
  //
  // Reassigning `command` on a running Process is not a queue, so an overlapping
  // call would be dropped or interleaved with the one in flight — reachable by
  // nudging a slider while a profile load or a Reset round trip is still open.
  // Dropping it outright is wrong for a write, because the value the user just
  // asked for would be the thing that disappeared, so the latest one waits and
  // goes out when the process exits. Latest-wins is safe here: the queued argv is
  // built from imagePending, which is itself cumulative until the readback clears
  // it, so a superseded batch carries nothing the next one lacks.
  property var imageQueued: null

  function imageWrite(argv) {
    if (imageProc.running) { imageQueued = argv; return }
    imageQueued = null
    imageProc.command = argv
    imageProc.running = true
  }

  // Deferred, because `running` is still true inside onExited and the readback
  // this reply carries has to land before the next call goes out.
  function drainImageQueue() {
    if (!imageQueued) return
    var argv = imageQueued
    imageQueued = null
    Qt.callLater(function() { root.imageWrite(argv) })
  }

  function refreshImage() {
    if (imageProc.running) return
    imageWrite(Model.imageReadArgs(helper))
  }

  function resetImage() {
    if (!present) return
    // Drop the optimistic values first: they are about to be wrong, and a pending
    // brightness surviving the reset would leave that one row showing the old
    // value while every other row snapped to neutral.
    imagePending = ({})
    imageDebounce.stop()
    imageWrite(Model.imageResetArgs(helper))
  }

  function publishImage(raw) {
    // Merged rather than replaced, because not every reply carries a control
    // list: a write refused before the camera was touched — an unknown key from a
    // keybinding — answers with an error alone, and parsing that directly would
    // blank the whole section over one bad argument. The camera going away is
    // covered by `present` instead, which hides the section outright.
    image = Model.mergeImage(image, raw)
    // Clear the optimistic values the reply has caught up with, and only those:
    // anything still mid-drag keeps its pending value until the debounce fires,
    // or the handle jumps out from under the finger.
    if (!imageDebounce.running) imagePending = ({})
    clampCursor()
  }

  // ---- image profiles ----
  //
  // Deliberately separate from the framing presets, and stored under a different
  // key in the same file. A framing preset recalls pan, tilt and zoom; recalling
  // one must not silently change the picture, and vice versa.
  function readProfiles() {
    profileWrite(Model.profileArgs(helper, "list"))
  }

  function saveProfile(name) {
    var trimmed = String(name || "").trim()
    if (!present || !trimmed) return
    profileWrite(Model.profileArgs(helper, "save", trimmed))
    profileDraft = ""
  }

  function loadProfile(name) {
    if (!present || !name) return
    // A profile can carry a value for a control an auto switch is currently
    // holding, so the readback is the only honest source for what landed —
    // dropping the pending values keeps a stale one from masking a refusal.
    imagePending = ({})
    imageDebounce.stop()
    profileWrite(Model.profileArgs(helper, "load", name))
  }

  function clearProfile(name) {
    if (!name) return
    profileWrite(Model.profileArgs(helper, "clear", name))
  }

  // Same overlap problem as imageWrite, but queued in order rather than
  // latest-wins: these are four distinct commands, not one cumulative batch, so a
  // save followed by a list must not lose the save — and "clear then list" run out
  // of order would answer with a list that still contains the cleared profile.
  property var profileQueue: []

  function profileWrite(argv) {
    if (profileProc.running) {
      profileQueue = profileQueue.concat([argv])
      return
    }
    profileProc.command = argv
    profileProc.running = true
  }

  function drainProfileQueue() {
    if (!profileQueue.length) return
    var argv = profileQueue[0]
    profileQueue = profileQueue.slice(1)
    Qt.callLater(function() { root.profileWrite(argv) })
  }

  function publishProfiles(raw) {
    // The save field is the last row, so a list that grows or shrinks moves it —
    // and a cursor left at the old index lands on a profile row instead. Saving
    // is exactly when that happens, and the consequence is that the next Enter
    // recalls the profile just written rather than saving again. So the cursor is
    // followed to where the row went; clampCursor only pulls it back in range,
    // which does nothing when the page got longer.
    var onSaveRow = focusSection === "advanced" && selectedIndex === advancedSaveRow
    imageProfiles = Model.parseProfiles(raw)
    if (onSaveRow) selectedIndex = advancedSaveRow
    // `load` and `save` answer with a full readback; `list` and every failure do
    // not, and merging is what keeps those from blanking the section.
    image = Model.mergeImage(image, raw)
    if (!imageDebounce.running) imagePending = ({})
    clampCursor()
  }

  function refresh() {
    if (stateProc.running) { refreshQueued = true; return }
    loading = true
    stateProc.command = Model.stateArgs(helper)
    stateProc.running = true
  }

  function publish(raw) {
    var parsed = Model.parseState(raw)
    camera = parsed
    lastError = parsed.error || ""
    everLoaded = true
    // Drop the optimistic values now that real state has arrived, so the
    // controls follow the hardware again — including changes made from another
    // app. Anything still mid-drag keeps its pending value until the debounce
    // fires, or the handle would jump out from under the finger.
    if (!ptzDebounce.running) {
      pendingPan = noPending
      pendingTilt = noPending
    }
    if (!zoomDebounce.running) pendingZoom = noPending
    clampCursor()
  }

  // ---------------------------------------------------------------- IPC

  IpcHandler {
    target: "nille.emeet-pixy"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    // Camera control without opening the panel, so a Hyprland keybinding can
    // cover the lens instantly — the case that matters most here.
    function privacyToggle(): void { root.togglePrivacy() }
    function privacyOn(): void { root.setMode("privacy") }
    function privacyOff(): void { root.setMode("standard") }
    function tracking(): void { root.setMode("tracking") }
    function standard(): void { root.setMode("standard") }
    function pan(degrees: string): void { root.setPan(Number(degrees)) }
    function tilt(degrees: string): void { root.setTilt(Number(degrees)) }
    function nudge(direction: string): void {
      root.run(Model.nudgeArgs(root.helper, direction, root.ptzStep))
    }
    function zoom(level: string): void { root.setZoom(Number(level)) }
    function home(): void { root.home() }

    // Mic, for the same reason privacy is here: mute is a keybinding, not
    // something you want to open a panel to reach. `micVolume` takes 0..100
    // rather than 0..1, because a keybinding is written by hand.
    function micToggle(): void { root.toggleMicMute() }
    function micOn(): void { root.setMicMuted(false) }
    function micOff(): void { root.setMicMuted(true) }
    function micVolume(percent: string): void { root.setMicVolume(Number(percent) / 100) }

    // Preview, so "release the camera before this call" is one keybinding. These
    // persist — the same write the panel switch makes — so `previewOff` bound to
    // a key is a real off switch and not something that comes back at restart.
    function previewToggle(): void { root.togglePreview() }
    function previewOn(): void { root.setPreviewEnabled(true) }
    function previewOff(): void { root.setPreviewEnabled(false) }

    // Image controls, by name, because these are the settings someone wants on a
    // key: "brighten the picture" mid-call is a keybinding, and the whole reason
    // this works during a call is that it is a control ioctl rather than the
    // stream. `image` takes the helper's own key names, so the CLI and the
    // keybinding spell the same thing the same way.
    function image(key: string, value: string): void {
      root.setImageControl(key, Number(value))
    }
    function imageReset(): void { root.resetImage() }
    function profile(name: string): void { root.loadProfile(name) }

    function preset(slot: string): void { root.loadPreset(Number(slot)) }

    // The camera's own firmware settings. Here for the same reason the image
    // controls are: these are the things someone wants on a key or in a script —
    // "mirror the picture for the whiteboard", "put the mic in Live mode for
    // music". Every one of them persists in the camera, so a keybinding that sets
    // one is setting it for good, not for this session.
    //
    // These do not wait for the read the device page does. A write is a write; the
    // panel does not have to be open, and `vendorWrite` queues behind whatever the
    // page may already be doing.
    function audio(mode: string): void { root.setAudioMode(mode) }
    function gesture(enabled: string): void { root.setGesture(Model.boolArg(enabled)) }
    function mirror(enabled: string): void {
      root.setFeature("flipHorizontal", Model.boolArg(enabled))
    }
    function flip(enabled: string): void {
      root.setFeature("flipVertical", Model.boolArg(enabled))
    }
    function autoRotate(enabled: string): void {
      root.setFeature("autoRotate", Model.boolArg(enabled))
    }
    // Two calls rather than one with optional coordinates, because the IPC client
    // requires every declared argument: a three-argument `focus` would mean typing
    // two numbers to ask for Face. `focus area` re-aims at the last picked point,
    // which is what the camera would do anyway.
    function focus(target: string): void { root.setFocusTarget(target) }
    function focusSpot(x: string, y: string): void {
      root.setFocusSpot(Number(x), Number(y))
    }
    function autoPrivacy(seconds: string): void { root.setAutoPrivacy(Number(seconds)) }
    function nativeClear(slot: string): void { root.clearNativePreset(Number(slot)) }

    // A still on a keybinding, which is most of why snapshots exist here at all.
    // Nothing is returned: the capture takes a moment and the path is in `state`
    // afterwards, so a script that wants the file polls for it rather than
    // blocking the shell's IPC thread on a V4L2 read.
    function snapshot(): void { root.takeSnapshot() }

    function refresh(): void { root.refresh(); root.refreshImage() }
    // Only meaningful when something wants `state` to answer for the firmware
    // settings: they are read on demand, so a script asks for them, waits, and
    // then reads `state`.
    function readDevice(): void { root.refreshVendor() }

    function state(): string {
      return JSON.stringify({
        present: root.present,
        mode: root.camera.mode,
        privacy: root.privacy,
        streaming: root.camera.streaming,
        pan: root.camera.pan,
        tilt: root.camera.tilt,
        zoom: root.camera.zoom,
        presets: root.presets,
        // Both, because "on" is a preference and "showing" is what is true right
        // now — a preview enabled but blocked by another app is neither.
        preview: root.previewEnabled,
        previewActive: root.previewWanted && root.previewError === "",
        micPresent: root.hasMic,
        micMuted: root.micMuted,
        micVolume: Math.round(root.micVolume * 100),
        // Values keyed by control name, not the whole payload: a script asking
        // for the state wants "what is brightness", and the ranges and menu
        // options it would have to wade through to find out are `pixy image`'s
        // job. Empty until the panel has read them at least once.
        image: root.imageValues,
        imageProfiles: root.imageProfiles,
        // The firmware settings, and `deviceRead` alongside them because they are
        // read on demand: every field here is null until something asks. Without
        // the flag a script cannot tell "gestures are off" from "nobody has looked
        // yet", which is the same distinction the page itself draws.
        deviceRead: root.vendorLoaded,
        audio: root.vendorShown.audio,
        gesture: root.vendorShown.gesture,
        mirror: root.vendorShown.features.flipHorizontal,
        flip: root.vendorShown.features.flipVertical,
        autoRotate: root.vendorShown.features.autoRotate,
        focus: root.vendorShown.metering ? root.vendorShown.metering.mode : null,
        focusSpot: Model.focusSpot(root.vendorShown.metering),
        autoPrivacy: root.vendorShown.autoPrivacy,
        nativePresets: Model.nativePresetSlots(root.vendorShown),
        // What the last snapshot did, so a keybinding that takes one can find the
        // file. Null before the first, and `snapshotBusy` because the capture
        // outlasts the IPC call that started it.
        snapshotBusy: root.snapshotRunning,
        snapshot: root.lastSnapshot,
        // Both halves of the call automation: what is enabled, and whether one is
        // in effect right now.
        callActions: root.callActions,
        callActive: root.callRestore !== null,
        error: root.lastError
      })
    }
  }

  // ---------------------------------------------------------------- processes

  Process {
    id: stateProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publish(text)
    }
    onExited: function(exitCode) {
      // The helper always prints JSON and exits 0, even with no camera. A
      // nonzero exit therefore means it could not run at all, and publish()
      // never fired — so say so instead of showing a blank panel.
      if (exitCode !== 0 && !root.everLoaded) {
        root.camera = Model.parseState("")
        root.lastError = "helper not runnable — chmod +x scripts/pixy"
        root.everLoaded = true
      }
    }
    onRunningChanged: {
      if (running) return
      root.loading = false
      if (root.refreshQueued) {
        root.refreshQueued = false
        Qt.callLater(function() { root.refresh() })
      }
    }
  }

  // The fast lane for "someone else wants the camera". Only the stream-holder
  // fields are updated, so a reply landing mid-drag cannot disturb the sliders.
  Process {
    id: holdersProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.camera = Model.mergeHolders(root.camera, text)
    }
  }

  // Image reads and writes share one process, because they are one call: the
  // helper always answers a write with the full readback, so a write *is* a read
  // and running them separately would only invite them to overlap.
  Process {
    id: imageProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publishImage(text)
    }
    onExited: function(exitCode) {
      // The helper prints JSON and exits 0 even when it cannot reach the camera,
      // so a nonzero exit means it never ran and publishImage never fired. The
      // main refresh already reports an unrunnable helper, so this only has to
      // avoid leaving stale sliders behind.
      if (exitCode !== 0) root.image = Model.parseImage("")
      root.drainImageQueue()
    }
  }

  Process {
    id: profileProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.publishProfiles(text)
    }
    onExited: root.drainProfileQueue()
  }

  // Vendor reads and writes share one process, as the image ones do — but for the
  // opposite reason. An image write answers with a full readback, so a write *is* a
  // read. A vendor setter answers with only its own field, so the reply is dropped
  // and `drainVendorQueue` follows the last write with one shared read.
  Process {
    id: vendorProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // Only a `vendor` reply carries every field, and only that one is worth
        // publishing. A setter's reply is narrower than the parse expects, so
        // publishing it would blank the rows it does not mention.
        if (vendorProc.command && vendorProc.command.length === 2) root.publishVendor(text)
      }
    }
    onExited: function(exitCode) {
      root.vendorLoading = false
      // A nonzero exit means the helper never ran, so nothing was published. The
      // main refresh already reports an unrunnable helper; this only has to stop
      // the page claiming it is still loading.
      if (exitCode !== 0) root.vendorLoaded = true
      root.drainVendorQueue()
    }
  }

  Process {
    id: formatsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.formats = Model.parseFormats(text)
        root.formatsLoaded = true
      }
    }
  }

  Process {
    id: snapshotProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.lastSnapshot = Model.parseSnapshot(text)
    }
    onExited: {
      root.snapshotRunning = false
      // A snapshot takes the stream, so the panel's own preview has to have
      // yielded it — and the state the panel is showing is now a refresh behind.
      root.refresh()
    }
  }

  // Debounce image writes. Longer than the PTZ debounce because these are ioctls
  // on a device that may be mid-stream, and a slider sweep is worth collapsing
  // into one call — the helper writes a whole batch in one correctly ordered pass.
  Timer {
    id: imageDebounce
    interval: 140
    onTriggered: root.flushImage()
  }

  // Poll for other apps while — and only while — our preview holds the stream.
  //
  // This is a latency fix, not a second refresh. The full `state` call costs
  // ~780 ms, almost all of it the HID mode query and its settle sleeps, so it
  // cannot run faster than it does. But an app that opens the camera and
  // immediately tries to stream gets one attempt: at a 10 s interval it would
  // usually fail before we noticed it was there, which defeats the whole point of
  // yielding. `holders` costs ~55 ms and answers exactly the question that needs
  // answering quickly.
  //
  // It stops once the preview is down, which makes yielding fast and re-acquiring
  // slow. That asymmetry is deliberate: being late to get out of the way costs
  // someone their video, while being late to resume our own thumbnail costs a few
  // seconds of a placeholder. Only the expensive mistake is worth polling for.
  Timer {
    interval: 1500
    repeat: true
    running: root.opened && root.previewWanted
    onTriggered: if (!holdersProc.running) {
      holdersProc.command = Model.holdersArgs(root.helper)
      holdersProc.running = true
    }
  }

  // Debounce drags. Short enough that the camera tracks the handle, long enough
  // to collapse the burst of events one sweep produces.
  Timer {
    id: ptzDebounce
    interval: 120
    onTriggered: root.flushPtz()
  }

  Timer {
    id: zoomDebounce
    interval: 90
    onTriggered: root.flushZoom()
  }

  // Read back shortly after a mutation so the panel reflects what the camera
  // actually accepted, rather than trusting the optimistic value forever.
  Timer {
    id: settleTimer
    interval: 400
    onTriggered: root.refresh()
  }

  // Pan and tilt are physical motion, so their readback is only meaningful once
  // the motors stop. A second, later read is what keeps the position label from
  // freezing mid-sweep.
  Timer {
    id: motorTimer
    interval: 1200
    onTriggered: root.refresh()
  }

  Timer {
    id: saveTimer
    interval: 700
    onTriggered: root.savingSlot = -1
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: root.opened
    repeat: true
    onTriggered: {
      root.refresh()
      // Polled alongside the state read so a change made from another app — or
      // from `pixy image --set` on the command line — reaches the sliders. It is
      // a separate call because it is a separate device interface: `state` is HID
      // and costs ~780 ms, `image` is V4L2 ioctls and costs ~170 ms.
      root.refreshImage()
    }
  }

  // One read at startup so the bar icon means something before the first open —
  // specifically so a privacy state left on from last session is visible.
  Component.onCompleted: refresh()

  onOpenedChanged: {
    if (opened) {
      refresh()
      // Not at startup, unlike `refresh()`: the bar glyph says nothing about the
      // picture, so reading fifteen controls before the panel is ever opened would
      // be work done for nobody.
      refreshImage()
      // Here rather than only when the cog opens, because `state` reports the
      // profile names and a script should not have to open a sub-page to get an
      // answer. It costs nothing worth deferring: profiles live in a JSON file, so
      // this reads it without touching the camera.
      readProfiles()
      // Always the main page on open. Either sub-page is somewhere you go for a
      // specific reason, and reopening the panel into one would hide the framing
      // controls from whoever forgot they left it there.
      imageAdvanced = false
      devicePage = false
      profileDraft = ""
      // A path from a previous session is not news, and neither is a note about a
      // call that has already ended.
      lastSnapshot = null
      callNote = ""
      focusSection = present ? "mode" : "header"
      selectedIndex = present ? 0 : -1
      cursorActive = false
      // Clear a previous session's failure so a camera that was busy last time
      // gets a fresh attempt rather than showing a stale message forever.
      previewError = ""
      Qt.callLater(function() {
        if (scrollArea && scrollArea.contentItem) scrollArea.contentItem.contentY = 0
      })
    }
  }

  // Reopening the lens should retry the preview, not keep whatever error was
  // showing while it was closed.
  // Any transition back to an unblocked state is a retry. Without this, a
  // "Camera is in use" error survives the other app quitting and the preview
  // stays dark until the panel is reopened — the frame would report a problem
  // that has already gone away.
  onPreviewBlockerChanged: if (previewBlocker === "") previewError = ""

  // ---------------------------------------------------------------- bar button

  // One glyph, always: this is the camera widget, and the bar slot it occupies
  // says "PIXY" — so it holds the webcam and nothing else.
  //
  // *(observed)* Mute used to add a second crossed-out mic glyph beside it, and a
  // version before that drew the mic as a badge in the corner of the webcam. Both
  // are gone. The badge was illegible — the bar slot is 27×27 with a 16px optical
  // canvas, so a badge lands around 8px, which is four grey pixels on top of the
  // webcam's own light-filled base. The second glyph was legible but wrong for a
  // different reason: it made one bar entry two buttons wide, and the bar centres
  // its open-panel mark on the whole entry, so the underline meaning "this panel
  // is open" landed between the glyphs — on the mic, the one button that does not
  // open it. Widening a slot to carry a secondary state costs the primary one its
  // own mark, which is a bad trade for a camera widget.
  //
  // Mute is still visible where it is actionable: the MICROPHONE section of the
  // panel, the hover tooltip below, and `micToggle` over IPC for a keybinding.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  visible: !(hideWhenAbsent && everLoaded && !present)

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: Model.barIcon(root.camera)
    foreground: root.barIconColor
    tooltipText: {
      var parts = ["PIXY — " + Model.summary(root.camera)]
      var stream = Model.streamLabel(root.camera)
      if (stream) parts.push(stream)
      // Mic state only when it is muted. An unmuted mic is the resting state and
      // saying so on every hover buries the line that matters. This is now the
      // only place the bar mentions the mic at all, which is why it stays.
      if (root.hasMic && root.micMuted) parts.push("Mic muted")
      return parts.join(" · ")
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.togglePrivacy()
      else if (buttonCode === Qt.MiddleButton) root.home()
      else root.toggle()
    }

    onWheelMoved: function(delta) {
      if (!root.present) return
      var wheel = Util.wheelSteps(root.wheelAccumulator, delta)
      root.wheelAccumulator = wheel.remainder
      if (wheel.steps === 0) return
      root.setZoom(root.shownZoom + wheel.steps * 5)
    }
  }

  // ---------------------------------------------------------------- panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The profile name field owns every key while it has focus, including j/k
      // and h/l — they are letters someone is trying to type. Esc and Enter are
      // handled on the field itself so it can give focus back.
      blocked: profileField.activeFocus

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustHorizontal(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      // Esc backs out of the advanced view before it closes the panel, which is
      // what a nested view has to do: closing the whole panel from inside a
      // sub-page loses two levels for one press.
      onCloseRequested: {
        if (root.imageAdvanced) root.closeImageAdvanced()
        else if (root.devicePage) root.closeDevicePage()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      // 'x' arrives here rather than through textKey — PanelKeyCatcher gives it
      // its own signal so every panel spells "remove this" the same way.
      onDeleteRequested: {
        if (root.focusSection === "presets")
          root.clearPreset(Model.PRESET_SLOTS[root.selectedIndex])
        else if (root.focusSection === "advanced")
          root.clearProfile(root.advancedProfileAt(root.selectedIndex))
        // On the device page 'x' only means anything on a native slot, and there
        // it means the same as Enter — those rows have exactly one action.
        else if (root.focusSection === "device")
          root.clearNativePreset(root.deviceNativeAt(root.selectedIndex))
      }
      onTextKey: function(t) {
        var key = t.toLowerCase()
        if (key === "p") root.togglePrivacy()
        else if (key === "t") root.setMode(root.camera.mode === "tracking" ? "standard" : "tracking")
        else if (key === "c") root.home()
        else if (key === "m") root.toggleMicMute()
        // 'v' for video: 'p' is privacy and the preview is the video feed.
        else if (key === "v") root.togglePreview()
        else if (key === "r") { root.refresh(); root.refreshImage() }
        // 'i' for image: the advanced view, from either side. 'a' would collide
        // with nothing today but reads as "auto" next to three auto switches.
        else if (key === "i") {
          if (root.imageAdvanced) root.closeImageAdvanced()
          else if (root.devicePage) { /* not from here — 'd' owns this page */ }
          else if (root.hasImage) root.openImageAdvanced()
        }
        // 'd' for device: the camera's own settings, from either side. Not 'c',
        // which recenters, and not 'v', which is the preview.
        else if (key === "d") {
          if (root.devicePage) root.closeDevicePage()
          else if (root.present && !root.imageAdvanced) root.openDevicePage()
        }
        else if (key === "s") {
          // Store into the slot under the cursor, which is the only slot the
          // keyboard has unambiguously selected.
          if (root.focusSection === "presets")
            root.savePreset(Model.PRESET_SLOTS[root.selectedIndex])
          // In the advanced view 's' is the profile name field, because naming is
          // the part of saving a profile that needs the keyboard.
          else if (root.focusSection === "advanced") root.focusProfileField()
        }
        // Framing presets only, and only on the main page: the advanced view's
        // profiles are named, not numbered, and the device page's rows are the
        // camera's own slots — recalling a framing preset from either would act on
        // a list that is not on screen.
        else if (root.onMainPage
                 && (key === "1" || key === "2" || key === "3")) root.loadPreset(Number(key))
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.spacing.panelGap

          // ---------- Hero: lens · title/status · privacy switch ----------
          PanelHero {
            id: heroRow
            width: parent.width
            title: "PIXY"
            meta: root.loading && !root.everLoaded
              ? "Looking for the camera"
              : Model.summary(root.camera)
            detail: Model.streamLabel(root.camera)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.present ? 1.0 : 0.5

            // Status only — the switch owns privacy, mouse and keyboard alike.
            iconComponent: Component {
              Text {
                text: Model.barIcon(root.camera)
                // Same reasoning as barIconColor: the glyph carries the state.
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }

            // The quick lens-cover, and the header's only cursor target.
            trailingControl: Component {
              ToggleSwitch {
                id: privacySwitch
                checked: root.privacy
                hasCursor: root.headerHasCursor
                foreground: root.foreground
                // Privacy reads as an alert state, not a neutral preference.
                accent: root.urgent
                enabled: root.present
                opacity: enabled ? 1.0 : 0.4
                onHovered: function(on) { if (on) root.setHeaderCursor() }
                onToggled: root.togglePrivacy()

                PanelToolTip {
                  visible: privacySwitch.containsMouse
                  text: root.privacy ? "Open the lens" : "Close the lens"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          // ---------- Nothing found ----------
          Column {
            width: parent.width
            spacing: Style.spacing.lg
            visible: root.onMainPage && root.everLoaded && !root.present

            PanelSeparator { foreground: root.foreground }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              text: root.lastError
                ? root.lastError
                : "No EMEET PIXY found. Check that it is plugged in, and that the udev rule granting access to its control interface is installed — see the README."
            }

            Button {
              text: "Look again"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              fontFamily: root.fontFamily
              onClicked: root.refresh()
            }
          }

          // ---------- Mode ----------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.onMainPage && root.present

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "MODE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CursorSurface {
              id: modeRow
              width: parent.width
              implicitHeight: modeGroup.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "mode" && root.selectedIndex === 0
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(modeRow)
              foreground: root.foreground
              accent: root.accent
              outline: true

              ButtonGroup {
                id: modeGroup
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                // A radio dot per chip, filled on the active mode. The selected
                // fill alone is a low-alpha wash by design — fine for "which
                // did I pick" in a form, too quiet for "is this camera
                // following me right now", which is the question here. The dot
                // is a second, unmissable channel and it costs no color of its
                // own, so it survives any theme.
                //
                // Both dots read hollow when the mode is unknown, which is the
                // honest rendering: no chip is claiming to be active.
                options: [
                  { value: "standard", label: Model.modeChipLabel("standard", root.camera, root.privacy),
                    tooltip: "Fixed framing" },
                  { value: "tracking", label: Model.modeChipLabel("tracking", root.camera, root.privacy),
                    tooltip: "Follow the subject" }
                ]
                // Dimmed and unclickable while the camera is idle, because the
                // firmware discards a Standard/Tracking write when nothing is
                // capturing. The chips were live before, so pressing one looked
                // like a broken button: no highlight moved and no error appeared,
                // since the write "succeeded" and was simply thrown away. The
                // note below says why, and privacy stays reachable throughout.
                //
                // 0.4 is the shell's own disabled wash, copied from the media
                // widget's transport buttons rather than invented here — there is
                // no Style token for it, so matching the one precedent is the
                // closest thing to a convention.
                enabled: Model.modeWritable(root.camera)
                opacity: enabled ? 1.0 : 0.4
                // Privacy is not a chip: it is the hero switch, because it is
                // the state you need to reach without reading the panel first.
                // While privacy is on, neither chip is the truth, so none is
                // selected rather than showing a stale one as current.
                value: root.privacy ? "" : (root.camera.mode || "")
                foreground: root.foreground
                accent: root.accent
                background: root.bar ? root.bar.background : Color.background
                fontFamily: root.fontFamily
                // 't' drives the mode from the keyboard; the chips are a mouse
                // affordance and stay out of the j/k cursor walk.
                focusable: false
                cursorIndex: -1
                onChanged: function(value) { root.setMode(value) }
                onHovered: function(index, isHovered) { if (isHovered) root.setCursor("mode", 0) }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) root.setCursor("mode", 0)
              }
            }

            // Why the mode reads as unknown. Shown rather than hidden because
            // "Standard or Tracking, cannot tell" is a real state of this
            // camera, and a blank selector with no explanation reads as broken.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: text !== ""
              text: Model.modeNote(root.camera)
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Framing ----------
          Column {
            id: framingColumn
            width: parent.width
            spacing: Style.spacing.md
            visible: root.onMainPage && root.present

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: Math.max(Math.max(framingHeader.implicitHeight,
                                                positionValue.implicitHeight),
                                       Math.max(previewGlyph.implicitHeight,
                                                previewToggle.implicitHeight))

              PanelSectionHeader {
                id: framingHeader
                text: "FRAMING"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Labels the switch. A bare switch on a "FRAMING" header would be
              // ambiguous — there are three other things in the section it could
              // plausibly gate — and the eye is doing the work a word would, at
              // the width a word would not fit in.
              Text {
                id: previewGlyph
                text: Model.previewIcon(root.previewEnabled)
                color: root.previewEnabled ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.icon
                anchors.right: previewToggle.left
                anchors.rightMargin: Style.spacing.sm
                anchors.verticalCenter: parent.verticalCenter
              }

              // The preview switch lives on the FRAMING header rather than in a
              // section of its own, because the preview is a framing aid and the
              // switch is the label for the thing directly below it. It is also
              // where someone looks when the video is the problem.
              //
              // A switch and not a settings-dialog trip: releasing the camera for
              // a call is a thing done *during* the call, and the only reason it
              // ever lived in the settings schema alone is that it started as a
              // preference rather than an action.
              ToggleSwitch {
                id: previewToggle
                checked: root.previewEnabled
                hasCursor: root.cursorActive && root.focusSection === "framing"
                  && root.selectedIndex === 0
                foreground: root.foreground
                accent: root.accent
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                onHovered: function(on) { if (on) root.setCursor("framing", 0) }
                onToggled: root.togglePreview()
                // Anchored in a plain Item rather than wrapped in a CursorSurface:
                // the header row is not a full-width control, and a ring around the
                // whole row would claim the "FRAMING" label too. The switch draws
                // its own ring, so all that is missing is the scroll-into-view the
                // CursorSurface rows get for free.
                onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(previewToggle)

                PanelToolTip {
                  visible: previewToggle.containsMouse
                  text: root.previewEnabled
                    ? "Turn the preview off — frees the camera for other apps"
                    : "Turn the preview on"
                  fontFamily: root.fontFamily
                }
              }

              // Yields the header's right edge to the switch. The angle readout is
              // a duplicate — both sliders below show it — so it is the thing that
              // gives way rather than the control.
              Text {
                id: positionValue
                text: Model.positionLabel(root.shownPan, root.shownTilt)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: previewGlyph.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // ---- Preview, or rather the space it belongs in ----
            //
            // The picture itself is drawn by previewFrame, outside the scrolling
            // column — see the note there. This is the hole it sits in while it is
            // on screen, and it exists so the layout is unchanged by that: same
            // width, same height, same visibility rule, so the panel is exactly as
            // tall as it was and everything below stays where it was.
            //
            // Deliberately small: this is a framing aid, not a viewer. Big enough
            // to see where the lens is pointing while the jog pad moves it, and
            // sitting directly above the pad so aiming is one glance rather than
            // a glance and a guess.
            //
            // 16:9 at a third of the panel height. Any larger and the controls
            // below it start scrolling out of reach, which costs more than the
            // extra pixels are worth.
            // Turned off entirely by the setting, rather than left as an empty
            // frame: someone who disabled the preview does not want a permanent
            // reminder of it taking up a third of the panel. Every other blocked
            // state keeps the frame, because those are temporary and the
            // placeholder is how the panel explains itself.
            Item {
              id: previewSlot
              visible: root.previewEnabled
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width - Style.space(12)
              height: visible ? Math.round(width * Model.PREVIEW_ASPECT) : 0
            }

            // ---- Jog pad ----
            //
            // Cross layout, as on every PTZ control: the arrows are where the
            // motion is, so the mapping needs no label. Mouse-only by design —
            // see the note on the cursor sections above.
            Grid {
              anchors.horizontalCenter: parent.horizontalCenter
              columns: 3
              rowSpacing: Style.spacing.xs
              columnSpacing: Style.spacing.xs

              Item { width: padUp.width; height: padUp.height }
              PanelActionButton {
                id: padUp
                iconText: "󰅃"
                tooltipText: "Tilt up"
                enabled: root.shownTilt < Model.TILT_MAX
                opacity: enabled ? 1.0 : 0.35
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.nudge(0, 1)
              }
              Item { width: padUp.width; height: padUp.height }

              PanelActionButton {
                iconText: "󰅁"
                tooltipText: "Pan left"
                enabled: root.shownPan > Model.PAN_MIN
                opacity: enabled ? 1.0 : 0.35
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.nudge(-1, 0)
              }
              PanelActionButton {
                iconText: "󰆣"
                tooltipText: "Recenter"
                enabled: !root.atHome
                opacity: enabled ? 1.0 : 0.35
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.home()
              }
              PanelActionButton {
                iconText: "󰅂"
                tooltipText: "Pan right"
                enabled: root.shownPan < Model.PAN_MAX
                opacity: enabled ? 1.0 : 0.35
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.nudge(1, 0)
              }

              Item { width: padUp.width; height: padUp.height }
              PanelActionButton {
                iconText: "󰅀"
                tooltipText: "Tilt down"
                enabled: root.shownTilt > Model.TILT_MIN
                opacity: enabled ? 1.0 : 0.35
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.nudge(0, -1)
              }
              Item { width: padUp.width; height: padUp.height }
            }

            // ---- Pan / tilt / zoom ----
            AxisRow {
              width: parent.width
              rowIndex: 1
              label: "Pan"
              glyph: "󰹳"
              minimum: Model.PAN_MIN
              maximum: Model.PAN_MAX
              step: root.ptzStep
              axisValue: root.shownPan
              readout: Model.degreeLabel(root.shownPan)
              onAxisMoved: function(value) { root.setPan(value) }
            }

            AxisRow {
              width: parent.width
              rowIndex: 2
              label: "Tilt"
              glyph: "󰹹"
              minimum: Model.TILT_MIN
              maximum: Model.TILT_MAX
              step: root.ptzStep
              axisValue: root.shownTilt
              readout: Model.degreeLabel(root.shownTilt)
              onAxisMoved: function(value) { root.setTilt(value) }
            }

            AxisRow {
              width: parent.width
              rowIndex: 3
              label: "Zoom"
              glyph: "󰍉"
              minimum: Model.ZOOM_MIN
              maximum: Model.ZOOM_MAX
              step: 1
              axisValue: root.shownZoom
              readout: Model.zoomLabel(root.shownZoom)
              onAxisMoved: function(value) { root.setZoom(value) }
            }

            // ---- Recenter ----
            CursorSurface {
              id: homeRow
              width: parent.width
              implicitHeight: homeButton.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "framing" && root.selectedIndex === 4
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(homeRow)
              foreground: root.foreground
              accent: root.accent
              outline: true

              Button {
                id: homeButton
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: "Recenter"
                iconText: "󰆣"
                leftAlign: true
                bordered: true
                // Nothing to do when already framed dead centre at 1×, and a
                // button that cannot change anything should say so.
                enabled: !root.atHome
                opacity: enabled ? 1.0 : 0.45
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.home()
                onHovered: function(on) { if (on) root.setCursor("framing", 4) }
              }
            }
          }

          // ---------- Image ----------
          //
          // The picture controls, and the section that most justifies this widget
          // existing at all: these are UVC control ioctls, so they keep working
          // while another app holds the capture stream. Fixing a washed-out
          // picture mid-call is a thing you do *in* the call.
          //
          // Five sliders and the white balance pair here; everything with a
          // narrower audience — hue, gain, exposure, focus, mains frequency,
          // backlight — lives behind the cog. The split is by how often you reach
          // for it, not by difficulty: exposure is not hard to understand, it is
          // just not something you touch twice a week.
          //
          // Hidden rather than disabled when there are no controls, on the same
          // reasoning as the mic section: a greyed-out slider stack on a camera
          // whose controls could not be read is a permanent lie, and the failure
          // is already carried by the header's summary.
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.onMainPage && root.present && root.hasImage

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: Math.max(Math.max(imageHeader.implicitHeight,
                                                imageValue.implicitHeight),
                                       Math.max(imageResetButton.implicitHeight,
                                                imageCogButton.implicitHeight))

              PanelSectionHeader {
                id: imageHeader
                text: "IMAGE"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // Says what the section holds without being read row by row —
              // "Brightness, contrast" points at where to look. It is also the
              // only place a failed read can announce itself, since the sliders
              // are hidden in that case.
              Text {
                id: imageValue
                text: Model.imageSummary(root.imageControls)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: imageResetButton.left
                anchors.rightMargin: Style.spacing.md
                anchors.verticalCenter: parent.verticalCenter
              }

              // Reset before the cog, so the two header actions read
              // destructive-then-more rather than the reverse.
              PanelActionButton {
                id: imageResetButton
                iconText: "󰦛"
                tooltipText: "Reset the picture to the camera's defaults"
                // Nothing to do when everything already reads its default, and a
                // button that cannot change anything should say so. Power line
                // frequency is excluded from that judgement, matching the helper:
                // the right value is a property of the room's mains, so Reset
                // deliberately leaves it alone and a camera differing only there
                // is already as neutral as Reset can make it.
                enabled: !Model.imageIsDefault(root.imageControls)
                opacity: enabled ? 1.0 : 0.35
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.right: imageCogButton.left
                anchors.rightMargin: Style.spacing.xs
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.resetImage()
              }

              PanelActionButton {
                id: imageCogButton
                iconText: "󰒓"
                tooltipText: "Advanced controls and image profiles"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                onClicked: root.openImageAdvanced()
              }
            }

            // One row per control the helper marked curated, in the helper's
            // order — which is editorial: an auto switch below the slider it
            // gates reads backwards.
            Repeater {
              model: root.curatedImage

              ControlRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                control: modelData
                rowIndex: index
                section: "image"
              }
            }
          }

          // ---------- Microphone ----------
          //
          // The camera has a mic, and on a call it is usually the mic being used,
          // so muting it belongs next to closing the lens rather than two panels
          // away. Nothing here goes near the helper: it is a plain PipeWire
          // source, so volume and mute are property writes.
          //
          // Hidden rather than disabled when the node is absent. A greyed-out mic
          // row on a camera that has no microphone is a permanent lie about what
          // the hardware can do, and this section has no state worth explaining.
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.onMainPage && root.present && root.hasMic

            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: Math.max(micHeader.implicitHeight, micValue.implicitHeight)

              PanelSectionHeader {
                id: micHeader
                text: "MICROPHONE"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              // One label for level and mute together. "40%" and "Muted" are the
              // same question answered — at 40% muted, the number is not what you
              // need to know.
              Text {
                id: micValue
                text: Model.micLabel(root.hasMic, root.micMuted,
                                     micSlider.dragging ? micSlider.liveValue : root.micVolume)
                color: root.micMuted ? root.urgent : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            CursorSurface {
              id: micRow
              width: parent.width
              implicitHeight: micControls.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "mic" && root.selectedIndex === 0
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(micRow)
              foreground: root.foreground
              accent: root.accent
              outline: true

              Row {
                id: micControls
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.md

                // Mute is a button, not a right-click on the slider alone: it is
                // the action people reach for in a hurry, and a hidden gesture is
                // the wrong place for it. The slider keeps the right-click too,
                // matching the shell's audio panel.
                PanelActionButton {
                  id: micMuteButton
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: Model.micIcon(root.micMuted)
                  tooltipText: root.micMuted ? "Unmute the microphone" : "Mute the microphone"
                  // Muted is an alert state in the same sense privacy is: someone
                  // is talking and not being heard.
                  foreground: root.micMuted ? root.urgent : root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.toggleMicMute()
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  width: parent.width - micMuteButton.width - parent.spacing
                  spacing: Style.space(5)

                  PanelSlider {
                    id: micSlider
                    bar: root.bar
                    width: parent.width
                    minimum: 0
                    maximum: 1
                    step: 0.05
                    value: root.micVolume
                    // Dimmed rather than disabled while muted: dragging it is a
                    // reasonable way to say "set the level I want when I come
                    // back", and a control that refuses input reads as broken.
                    opacity: root.micMuted ? 0.5 : 1.0
                    onMoved: function(v) { root.setMicVolume(v) }
                    onRightClicked: root.toggleMicMute()
                  }

                  // Live input level. The reason it is here rather than left to
                  // the audio panel: "is this camera's mic actually picking me
                  // up" is a hardware question about this device, and the slider
                  // alone cannot answer it — a muted-in-firmware or unplugged mic
                  // looks identical to a working one at 80%.
                  //
                  // Flat while muted rather than hidden, so the row does not
                  // change height on every mute and shift the presets under the
                  // cursor.
                  Rectangle {
                    width: parent.width
                    height: Math.max(Style.space(5), Style.spacing.xs)
                    radius: height / 2
                    color: Util.alpha(root.foreground, 0.18)
                    opacity: root.micMuted ? 0.35 : 1.0

                    Rectangle {
                      height: parent.height
                      radius: parent.radius
                      width: root.micMuted ? 0 : parent.width * root.micPeakValue
                      color: root.foreground
                      Behavior on width { NumberAnimation { duration: 70 } }
                    }
                  }
                }
              }

              // Same wheel interception as AxisRow, and for the same reason: the
              // slider would otherwise eat a scroll aimed at the presets below.
              // Consequence is smaller here than on the axis rows — a stray notch
              // changes mic gain rather than moving the camera — but a gesture
              // aimed at the list should scroll the list either way.
              MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.NoButton
                onWheel: function(wheel) {
                  root.scrollBy(wheel.pixelDelta.y || wheel.angleDelta.y)
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) root.setCursor("mic", 0)
              }
            }
          }

          // ---------- Presets ----------
          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.onMainPage && root.present

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "PRESETS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: Model.PRESET_SLOTS

              PresetRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                slot: modelData
                rowIndex: index
              }
            }
          }

          // ---------- Advanced image controls ----------
          //
          // A view rather than a nested popup. The advanced controls are the same
          // IMAGE section seen closer up, and a second window would hide the panel
          // behind it while giving the cursor two lists to be in at once. Swapping
          // the body keeps one cursor over one visible list, which is the whole
          // reason the keyboard model here is simple.
          //
          // The framing presets deliberately stay on the main page. They are a
          // different kind of thing — pan/tilt/zoom, not picture — and recalling
          // one must not change the image, so putting the two lists side by side
          // would invite exactly the confusion the split exists to prevent.
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.imageAdvanced

            // Back is the first row drawn and the first row the cursor visits, so
            // k from the top control reaches it and j walks the page downward.
            CursorSurface {
              id: backRow
              width: parent.width
              implicitHeight: backButton.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "advanced"
                && root.selectedIndex === root.advancedBackRow
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(backRow)
              foreground: root.foreground
              accent: root.accent
              outline: true

              Button {
                id: backButton
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: "Back"
                iconText: "󰅁"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.closeImageAdvanced()
                onHovered: function(on) {
                  if (on) root.setCursor("advanced", root.advancedBackRow)
                }
              }

              Text {
                text: Model.imageSummary(root.imageControls)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "ADVANCED"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // The same ControlRow the main page uses. Nothing about these controls
            // is structurally different — they are here because they are reached
            // for less often, not because they behave unlike a slider.
            Repeater {
              model: root.advancedImage

              ControlRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                control: modelData
                rowIndex: root.advancedControlRow + index
                section: "advanced"
              }
            }

            // ---- Image profiles ----
            //
            // Deliberately separate from the framing presets, and stored under a
            // different key in the same file: a framing preset recalls where the
            // lens points, a profile recalls how the picture looks, and neither
            // should silently change the other.
            //
            // Named rather than numbered, because these are things like "Evening"
            // and "Bright room" — a name is the point, which is also why saving one
            // needs a text field and a framing preset does not.
            //
            // A profile captures *every* control, curated or not, so one saved
            // after setting the exposure by hand restores the exposure too.
            PanelSeparator { foreground: root.foreground }

            Item {
              width: parent.width
              implicitHeight: profilesHeader.implicitHeight

              PanelSectionHeader {
                id: profilesHeader
                text: "IMAGE PROFILES"
                foreground: root.foreground
                fontFamily: root.fontFamily
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                visible: root.imageProfiles.length === 0
                text: "None saved"
                color: root.faint
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Repeater {
              model: root.imageProfiles

              ProfileRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                name: modelData
                rowIndex: root.advancedProfileRow + index
              }
            }

            // ---- Save the current picture ----
            CursorSurface {
              id: saveRow
              width: parent.width
              implicitHeight: saveInner.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "advanced"
                && root.selectedIndex === root.advancedSaveRow
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(saveRow)
              foreground: root.foreground
              accent: root.accent
              outline: true

              Item {
                id: saveInner
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                implicitHeight: Math.max(profileField.implicitHeight,
                                         profileSaveButton.implicitHeight)

                TextField {
                  id: profileField
                  anchors.left: parent.left
                  anchors.right: profileSaveButton.left
                  anchors.rightMargin: Style.spacing.sm
                  anchors.verticalCenter: parent.verticalCenter
                  placeholderText: "Name this picture"
                  // The draft lives on the root, so the name survives this field
                  // being destroyed when the view closes and the button and the
                  // field cannot disagree about what is being saved.
                  text: root.profileDraft
                  onTextChanged: root.profileDraft = text
                  hasCursor: root.cursorActive && root.focusSection === "advanced"
                    && root.selectedIndex === root.advancedSaveRow
                  foreground: root.foreground
                  accent: root.accent
                  verticalPadding: Style.spacing.xxs
                  onAccepted: root.saveProfile(root.profileDraft)
                  // Esc hands the keyboard back to the panel rather than closing
                  // anything: the field has the keys while it is focused, so it is
                  // the only thing that can give them up.
                  Keys.onEscapePressed: function(event) {
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  }
                  onHoveredChanged: if (hovered) root.setCursor("advanced", root.advancedSaveRow)
                }

                Button {
                  id: profileSaveButton
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  // Says what pressing it does. The helper would overwrite either
                  // way, so the word is the only warning there is.
                  text: root.profileDraftState === "exists" ? "Overwrite" : "Save"
                  iconText: "󰆓"
                  bordered: true
                  enabled: root.present && root.profileDraftState !== "blank"
                  opacity: enabled ? 1.0 : 0.45
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  fontSize: Style.font.caption
                  horizontalPadding: Style.spacing.sm
                  verticalPadding: Style.spacing.xxs
                  onClicked: root.saveProfile(root.profileDraft)
                  onHovered: function(on) {
                    if (on) root.setCursor("advanced", root.advancedSaveRow)
                  }
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) root.setCursor("advanced", root.advancedSaveRow)
              }
            }

            // Why a profile can carry a value that does not land. Shown rather
            // than hidden because it is the one thing about profiles that is not
            // obvious, and finding out by having a recall silently do nothing is
            // the worst way to learn it.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "A profile stores every control above. Values held by an auto switch are saved, but only take effect once that switch is off."
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Camera settings entry ----------
          //
          // Its own row rather than a cog on a section header, which is where the
          // advanced image view is reached from. The difference is what the page
          // holds: the cog above IMAGE opens more of IMAGE, while this opens the
          // camera's own firmware — the microphone's DSP mode, the mirror flips, the
          // idle shutter — which belongs to no section on this page. A cog on
          // PRESETS would have implied it was more presets.
          Column {
            width: parent.width
            spacing: Style.spacing.sm
            visible: root.onMainPage && root.present

            PanelSeparator { foreground: root.foreground }

            CursorSurface {
              id: cameraRow
              width: parent.width
              implicitHeight: cameraRowButton.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "camera"
                && root.selectedIndex === 0
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(cameraRow)
              foreground: root.foreground
              accent: root.accent
              outline: true

              Button {
                id: cameraRowButton
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: "Camera settings"
                iconText: "󰘚"
                leftAlign: true
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.openDevicePage()
                onHovered: function(on) { if (on) root.setCursor("camera", 0) }

                PanelToolTip {
                  visible: cameraRowButton.hot
                  text: "Microphone mode, gestures, mirroring, focus, snapshots"
                  fontFamily: root.fontFamily
                }
              }
            }
          }

          // ---------- Device page ----------
          //
          // The camera's own firmware settings, on a page of their own for the same
          // reason the advanced image view is a page: one cursor over one visible
          // list. It is a separate page from that one because these are a different
          // kind of thing — settings stored in the camera, which follow it to
          // another machine, rather than V4L2 controls that belong to this host.
          //
          // Row order is the drawn order and the cursor order both, and every row
          // takes its index from the deviceXRow properties rather than a literal —
          // the arithmetic there chains off the Model lists, so the two cannot
          // drift apart when a toggle is added.
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.devicePage

            // Back first, as in the advanced view: k from the first control reaches
            // it and j walks the page downward.
            CursorSurface {
              id: deviceBackRowSurface
              width: parent.width
              implicitHeight: deviceBackButton.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "device"
                && root.selectedIndex === root.deviceBackRow
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(deviceBackRowSurface)
              foreground: root.foreground
              accent: root.accent
              outline: true

              Button {
                id: deviceBackButton
                anchors.left: parent.left
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                text: "Back"
                iconText: "󰅁"
                foreground: root.foreground
                accent: root.accent
                fontFamily: root.fontFamily
                onClicked: root.closeDevicePage()
                onHovered: function(on) {
                  if (on) root.setCursor("device", root.deviceBackRow)
                }
              }

              // Says the read is happening, because it takes about six tenths of a
              // second: eleven HID queries sharing one descriptor. Without this the
              // page opens showing rows that are all "not reported" and then
              // silently fills in, which reads as a page that failed and recovered.
              Text {
                text: root.vendorLoading
                  ? "Reading the camera…"
                  : Model.nativePresetSummary(root.vendorShown)
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                anchors.right: parent.right
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "CAMERA SETTINGS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            // Why there is nothing to show. The rows below stay drawn either way —
            // they say "not reported" individually — but a missing udev rule is a
            // fixable cause with an instruction attached, and repeating it eleven
            // times down the page would be worse than saying it once here.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: text !== "" && !root.vendorLoading
              text: Model.vendorNote(root.vendorShown)
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            DeviceChipRow {
              width: parent.width
              rowIndex: root.deviceAudioRow
              glyph: "󰍯"
              label: "Microphone mode"
              options: Model.AUDIO_MODES
              value: root.vendorShown.audio || ""
              known: root.vendorShown.audio !== null
              note: Model.audioNote(root.vendorShown.audio)
              onPicked: function(value) { root.setAudioMode(value) }
            }

            DeviceSwitchRow {
              width: parent.width
              rowIndex: root.deviceGestureRow
              glyph: "󰟋"
              label: "Gesture control"
              note: "Lets a raised hand start and stop the camera's own tracking."
              checked: root.vendorShown.gesture === true
              known: root.vendorShown.gesture !== null
              onSwitched: function(enabled) { root.setGesture(enabled) }
            }

            DeviceChipRow {
              width: parent.width
              rowIndex: root.deviceFocusRow
              glyph: "󰋱"
              label: "Focus target"
              options: Model.FOCUS_TARGETS
              value: root.vendorShown.metering ? (root.vendorShown.metering.mode || "") : ""
              known: root.vendorShown.metering !== null
                && root.vendorShown.metering.mode !== null
              note: Model.focusNote(root.vendorShown.metering)
              onPicked: function(value) { root.setFocusTarget(value) }
            }

            // ---- Focus spot ----
            //
            // Only while Spot is the target, because the pad sets a point that no
            // other target uses — and the camera keeps the last one in those bytes,
            // so a pad shown under Face would be aiming something inert.
            //
            // A pad rather than the preview itself. The preview is on the main page
            // and this is not, and putting the click there would mean either
            // duplicating the preview here or sending someone back a page to aim
            // something they cannot see from there. The pad shows the current point,
            // which is the part that was missing.
            Item {
              width: parent.width
              visible: Model.focusSpot(root.vendorShown.metering) !== null
              implicitHeight: visible ? spotPad.height + Style.spacing.sm : 0

              Rectangle {
                id: spotPad
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: parent.top
                width: parent.width - Style.space(24)
                height: Math.round(width * 9 / 16)
                radius: Style.cornerRadius
                color: Qt.darker(root.bar ? root.bar.background : Color.background, 1.3)
                border.width: Style.normalBorderWidth
                border.color: root.faint

                readonly property var spot: Model.focusSpot(root.vendorShown.metering)

                // The point, drawn as crosshairs rather than a dot: a dot on a flat
                // pad is ambiguous about which pixel it means, and this is a
                // coordinate rather than a blob.
                Item {
                  visible: spotPad.spot !== null
                  x: spotPad.spot ? spotPad.spot.x * spotPad.width : 0
                  y: spotPad.spot ? spotPad.spot.y * spotPad.height : 0

                  Rectangle {
                    x: -Style.space(9)
                    y: -Style.normalBorderWidth / 2
                    width: Style.space(18)
                    height: Math.max(1, Style.normalBorderWidth)
                    color: root.accent
                  }

                  Rectangle {
                    x: -Style.normalBorderWidth / 2
                    y: -Style.space(9)
                    width: Math.max(1, Style.normalBorderWidth)
                    height: Style.space(18)
                    color: root.accent
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.CrossCursor
                  acceptedButtons: Qt.LeftButton
                  onClicked: function(mouse) {
                    root.setFocusSpot(mouse.x / width, mouse.y / height)
                  }
                  hoverEnabled: true
                  onEntered: if (root.bar) root.bar.showTooltip(spotPad, "Click to aim the focus spot")
                  onExited: if (root.bar) root.bar.hideTooltip(spotPad)
                }
              }
            }

            Repeater {
              model: Model.FEATURE_TOGGLES

              DeviceSwitchRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                rowIndex: root.deviceFeatureRow + index
                glyph: index === 0 ? "󱃧" : (index === 1 ? "󱃨" : "󰑤")
                label: modelData.label
                note: modelData.note
                checked: root.vendorShown.features[modelData.key] === true
                known: root.vendorShown.features[modelData.key] !== null
                onSwitched: function(enabled) { root.setFeature(modelData.key, enabled) }
              }
            }

            DeviceChipRow {
              width: parent.width
              rowIndex: root.deviceAutoPrivacyRow
              glyph: "󱨔"
              label: "Close the lens when idle"
              options: Model.autoPrivacyOptions()
              // Seconds through a string, because ButtonGroup keys on strings. The
              // conversion is Model's on both sides so the two agree.
              value: root.vendorShown.autoPrivacy === null
                ? "" : String(root.vendorShown.autoPrivacy)
              known: root.vendorShown.autoPrivacy !== null
              note: "The camera covers itself after this long with nothing capturing"
                + " — " + Model.autoPrivacyLabel(root.vendorShown.autoPrivacy) + " now."
              onPicked: function(value) { root.setAutoPrivacy(Number(value)) }
            }

            // ---- Call automation ----
            //
            // Here rather than in the settings dialog as well as it, because these
            // act on the camera and this is the camera's page — and because someone
            // who just watched the lens open by itself looks for the switch that did
            // that, not for a preferences window.
            //
            // These are shell settings rather than camera state, so they are the one
            // group on this page that survives the camera being unplugged. Drawn all
            // the same: turning one on before a call is the point.
            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "WHEN A CALL STARTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              // Says what counts as a call, which is the one thing about this that
              // is not obvious — and the reason it needs no list of meeting apps.
              text: "A call is any other app holding the video stream. Each of these"
                + " is put back the way it was afterwards."
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: Model.CALL_ACTION_META

              DeviceSwitchRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                rowIndex: root.deviceCallRow + index
                glyph: index === 0 ? "󰄄" : (index === 1 ? "󰶑" : "󰍬")
                label: modelData.label
                note: modelData.note
                checked: root.callActions[modelData.key]
                onSwitched: function(enabled) {
                  root.setCallAction(modelData.setting, enabled)
                }
              }
            }

            // What automation just did. Only present after it has done something, so
            // this is not a permanent row — a camera that opens its own lens should
            // say who did that, and then stop saying it.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: text !== ""
              text: root.callNote
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // ---- Snapshot ----
            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "SNAPSHOT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            CursorSurface {
              id: snapshotRowSurface
              width: parent.width
              implicitHeight: snapshotContent.implicitHeight + Style.spacing.controlGap
              hasCursor: root.cursorActive && root.focusSection === "device"
                && root.selectedIndex === root.deviceSnapshotRow
              onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(snapshotRowSurface)
              foreground: root.foreground
              accent: root.accent
              outline: true

              Column {
                id: snapshotContent
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.spacing.xs

                Button {
                  id: snapshotButton
                  width: parent.width
                  text: root.snapshotRunning ? "Taking a still…" : "Take a still"
                  iconText: "󰹑"
                  leftAlign: true
                  bordered: true
                  enabled: root.present && !root.snapshotRunning
                  opacity: enabled ? 1.0 : 0.45
                  foreground: root.foreground
                  accent: root.accent
                  fontFamily: root.fontFamily
                  onClicked: root.takeSnapshot()
                  onHovered: function(on) {
                    if (on) root.setCursor("device", root.deviceSnapshotRow)
                  }
                }

                // Where it went, and how big. Both because the directory is the
                // same every time — so the filename is the news — and because "did
                // it save the 4K one" is the question a still raises.
                Text {
                  width: parent.width
                  wrapMode: Text.WordWrap
                  visible: text !== ""
                  text: {
                    if (root.snapshotRunning) return "The preview yields for a moment."
                    var label = Model.snapshotLabel(root.lastSnapshot)
                    if (label) return label
                    var best = Model.largestFormat(root.formats)
                    return best
                      ? "Saves a " + best.width + "×" + best.height + " JPEG to ~/Pictures."
                      : "Saves a JPEG to ~/Pictures."
                  }
                  color: root.lastSnapshot && !root.lastSnapshot.ok ? root.urgent : root.faint
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              HoverHandler {
                onHoveredChanged: if (hovered) root.setCursor("device", root.deviceSnapshotRow)
              }
            }

            // ---- Camera preset slots ----
            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "CAMERA PRESET SLOTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              // Says why this list is not the same as the panel's own presets, which
              // is the question three numbered slots on a second page raises. The
              // zoom part is the reason the framing presets exist at all.
              text: "The camera's own three slots, shared with EMEET Studio. They hold"
                + " pan and tilt only, so the framing presets on the main page keep"
                + " the zoom as well and write these at the same time."
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: Model.PRESET_SLOTS

              NativeSlotRow {
                required property var modelData
                required property int index
                width: panelColumn.width
                slot: modelData
                rowIndex: root.deviceNativeRow + index
              }
            }

            // ---- Capture formats ----
            //
            // Read-only, and last on the page for that reason: it is the one block
            // here that sets nothing. Worth showing anyway — "what can this camera
            // actually do" is a question people ask of a webcam, and the answer is
            // otherwise only in `v4l2-ctl`, which this plugin deliberately does not
            // depend on.
            PanelSeparator { foreground: root.foreground }

            PanelSectionHeader {
              text: "CAPTURE FORMATS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: Model.formatLines(root.formats)

              Item {
                required property var modelData
                width: panelColumn.width
                implicitHeight: Math.max(formatName.implicitHeight,
                                         formatDetail.implicitHeight)

                Text {
                  id: formatName
                  text: modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  id: formatDetail
                  text: modelData.detail
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(6)
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              visible: Model.formatLines(root.formats).length === 0
              text: root.formatsLoaded
                ? "The camera did not report its formats."
                : "Reading the camera's formats…"
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            // Why there is no way to pick one. Stated rather than left as an
            // absence: a list of resolutions that cannot be clicked invites the
            // conclusion that the buttons are missing.
            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              text: "A format belongs to whichever app is capturing, so it is chosen"
                + " there rather than here — this list is what to ask for."
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Keyboard hints ----------
          Column {
            width: parent.width
            spacing: Style.spacing.md
            visible: root.present

            PanelSeparator { foreground: root.foreground }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              // Per page, because the keys differ: 1-3 and the framing presets do
              // not exist behind the cog, and a hint line listing keys that do
              // nothing on the visible page is worse than none.
              text: {
                if (root.imageAdvanced)
                  return "j/k move · h/l adjust · enter recall · s name · x clear · esc back · i close · r refresh"
                if (root.devicePage)
                  return "j/k move · h/l change · enter toggle · x clear slot · esc back · d close"
                var keys = "j/k move · h/l adjust · 1-3 recall · s save · x clear · p privacy · t tracking"
                if (root.hasMic) keys += " · m mute"
                keys += " · v preview · c recenter"
                if (root.hasImage) keys += " · i advanced"
                return keys + " · d camera · r refresh"
              }
            }
          }
        }
      }

      // ---------------------------------------------------------------- preview
      //
      // *(reported)* "since it is longer than the containing box there is no way to
      // see the preview window when adjusting most of the settings" — which is the
      // whole point of half of them. Mirroring, the focus target, brightness and the
      // image sliders are all settings you judge by looking at the picture, and the
      // picture was at the top of a panel that had grown two pages taller than the
      // box it lives in.
      //
      // So the preview is drawn here, a sibling of the ScrollView rather than a row
      // inside it: it sits in its slot in FRAMING while that slot is on screen, and
      // shrinks into a corner of the viewport once the slot scrolls past the top.
      // Model.previewDock does the arithmetic; this only draws where it says.
      //
      // One camera and one VideoOutput throughout. Re-parenting or duplicating it
      // would mean two objects wanting the same /dev/videoN, and the second would
      // fail with EBUSY against the first — the panel's own preview competing with
      // itself, which is the failure this widget spends the most care avoiding.
      //
      // Outside the ScrollView, so the docked picture is not clipped by it and does
      // not scroll. Inside the key catcher, so it is above the panel's content and
      // below nothing — a floating preview under the rows would be invisible, which
      // is the state being fixed.
      Item {
        id: previewLayer
        anchors.fill: parent
        // Nothing to draw when the setting is off, and nothing to draw on either
        // sub-page: the slot lives in FRAMING, which those pages replace. Docking it
        // there anyway was tempting — the device page's mirror and focus rows are
        // exactly where a picture helps — but it would cover the rows it is meant to
        // help with, on a page with no framing controls to relate it to.
        visible: root.previewEnabled && root.onMainPage && root.present

        // The slot's top edge in viewport coordinates, and the one binding that makes
        // the whole thing move.
        //
        // Summed from the three y positions between the slot and the scrolled column
        // rather than taken from mapToItem, which would be shorter and would not
        // update: mapToItem is a plain function call, so a binding that used it would
        // only re-evaluate when something else it read changed. Adding the positions
        // by name is what subscribes this to both scrolling and relayout — a mic node
        // appearing above the slot moves it just as surely as a scroll does.
        readonly property real slotY: previewSlot.visible
          ? panelColumn.y + framingColumn.y + previewSlot.y - scrollOffset
          : 0

        // Kept separate because it is the one value that has to be read off the
        // Flickable, and the ScrollView's contentItem is typed as a plain Item —
        // so this is also where the guard for "before the view exists" belongs.
        readonly property real scrollOffset: {
          var flick = scrollArea.contentItem
          return flick && flick.contentY !== undefined ? flick.contentY : 0
        }

        readonly property var dock: Model.previewDock({
          y: previewLayer.slotY,
          height: previewSlot.height,
          width: previewSlot.width,
          available: previewSlot.visible
        }, {
          width: previewLayer.width,
          height: previewLayer.height,
          inset: Style.space(10),
          // Model owns the fraction and the reasoning for it — see
          // PREVIEW_DOCK_FRACTION, and *(reported)* "the preview window is too small".
          miniWidth: Math.round(previewLayer.width * Model.PREVIEW_DOCK_FRACTION),
          // Below this the placeholder keeps its glyph and drops its sentence. Stated
          // in the theme's own units so a large font scale reaches the threshold at
          // the same apparent size a small one does — the question is whether a line
          // of text fits, and that is a question about the font.
          compactBelow: Style.space(200),
          corner: "top"
        })

        Rectangle {
          id: previewFrame
          x: previewLayer.dock.x
          y: previewLayer.dock.y
          width: previewLayer.dock.width
          height: previewLayer.dock.height
          radius: Style.cornerRadius
          color: Qt.darker(root.bar ? root.bar.background : Color.background, 1.3)
          // The docked picture floats over the rows below it, so it needs an edge
          // that separates it from them — the accent while docked, the ordinary
          // faint outline while it is in its slot and the layout does that job.
          // hoverBorderWidth rather than a number: it is the theme's own "this one
          // is emphasised" width, the same one the cursor ring uses.
          border.width: previewLayer.dock.docked
            ? Style.hoverBorderWidth : Style.normalBorderWidth
          border.color: previewLayer.dock.docked ? root.accent : root.faint

          // Only the shrink is animated, and only lightly. The position follows the
          // scroll directly — an eased x/y would lag the finger and read as the
          // picture sliding around on its own.
          Behavior on border.width { NumberAnimation { duration: 120 } }
          Behavior on border.color { ColorAnimation { duration: 120 } }

          // Enough to lift it off the content it covers. Free where it costs
          // nothing: no shadow while the picture is in its slot, because there is
          // nothing underneath for it to be lifted off.
          layer.enabled: previewLayer.dock.docked
          opacity: previewLayer.dock.docked ? 0.97 : 1.0

          // The video is clipped by this inset child rather than by the frame
          // itself, and the inset is what makes the border survive.
          //
          // *(observed)* `clip: true` on the bordered Rectangle scissored away
          // its own top border row. The frame's top edge lands on a fractional
          // device row at 1.25x scale — 214.4 — while its bottom lands on a
          // whole one, so the scissor rect rounds inward at the top only and
          // eats the 1px border there. Three sides drawn and one missing, which
          // is how it was reported.
          //
          // Live video hid it: the picture is painted over that row, so the bug
          // was only visible with the lens closed or the camera busy — the
          // states where the frame is empty and its outline is the only thing
          // there. Clipping a child inset by the border width keeps the scissor
          // rect strictly inside the border instead of on top of it, so no
          // rounding direction can clip it.
          Item {
            id: previewClip
            anchors.fill: parent
            anchors.margins: previewFrame.border.width
            clip: true

            // The Camera lives inside a Loader, and this is not a lazy-init
            // nicety: assigning `cameraDevice` opens /dev/videoN and holds the
            // fd for as long as the object exists, whether or not it is
            // `active`. A permanently-instantiated Camera therefore keeps an
            // open handle on the webcam from shell startup — which is exactly
            // the thing a privacy-facing widget must not do. Unloading it is
            // what actually releases the device.
            Loader {
              id: previewLoader
              anchors.fill: parent
              active: root.previewWanted && root.previewDevice !== null

              sourceComponent: Component {
                Item {
                  CaptureSession {
                    camera: liveCamera
                    videoOutput: liveOutput
                  }

                  Camera {
                    id: liveCamera
                    active: true
                    cameraDevice: root.previewDevice
                    // Left unset if no suitable format was found, rather than
                    // assigned null: Qt then picks its own, which is worse
                    // than pinned but better than refusing to start.
                    cameraFormat: root.previewFormat ? root.previewFormat : cameraFormat
                    onErrorOccurred: function(error, errorString) {
                      // A camera held by a meeting app is the common case and
                      // is not worth a scary message, so the overlay below
                      // states it plainly and the panel carries on.
                      root.previewError = errorString || "preview unavailable"
                    }
                  }

                  VideoOutput {
                    id: liveOutput
                    anchors.fill: parent
                    fillMode: VideoOutput.PreserveAspectCrop
                    visible: root.previewError === ""
                  }
                }
              }
            }
          }

          // Stands in for the image whenever there is nothing to show, so
          // the space never reads as a broken video element. Saying why is
          // the whole point: a blank preview during a call is otherwise
          // indistinguishable from a broken widget.
          Column {
            anchors.centerIn: parent
            width: parent.width - Style.space(8)
            spacing: Style.spacing.xs
            visible: !previewLoader.active || root.previewError !== ""

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.privacy ? "󱜷" : "󰖠"
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: previewLayer.dock.compact
                ? Style.font.icon : Style.font.iconLarge
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideRight
              text: {
                var note = Model.previewNote(root.camera, root.previewEnabled,
                                             root.opened, root.snapshotRunning)
                if (note) return note
                // Only reached once nothing is blocking it, so anything left
                // is a genuine fault from the camera itself.
                if (root.previewError) return root.previewError
                if (!root.previewDevice) return "No preview device"
                return "Starting…"
              }
              color: root.faint
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              // Dropped once the picture is small: a sentence wrapped to four
              // lines inside a thumbnail is not a sentence anyone reads, and the
              // note above it already names the reason.
              visible: text !== "" && !previewLayer.dock.compact
              text: Model.previewHint(root.camera, root.previewEnabled,
                                      root.opened, root.snapshotRunning)
              color: root.faint
              opacity: 0.75
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // Clicking the preview recenters, which is the one framing action
          // worth having directly on the image. Docked it does the same thing —
          // the picture means the same wherever it is drawn — and the tooltip is
          // the only part that changes, because a floating thumbnail has to say
          // what it is before it says what clicking it does.
          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton
            onClicked: root.home()
            hoverEnabled: true
            onEntered: if (root.bar) root.bar.showTooltip(previewFrame,
              previewLayer.dock.docked ? "Live preview · click to recenter"
                                       : "Click to recenter")
            onExited: if (root.bar) root.bar.hideTooltip(previewFrame)
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- components

  // One slider axis: glyph, value, and the slider itself. Pan, tilt, and zoom
  // differ only in range and labels, so they share this.
  component AxisRow: CursorSurface {
    id: axisRow

    required property int rowIndex
    property string label: ""
    property string glyph: ""
    property string readout: ""
    property real minimum: 0
    property real maximum: 1
    property real step: 1
    property real axisValue: 0

    signal axisMoved(int value)

    implicitHeight: axisSlider.implicitHeight + Style.spacing.controlGap
    hasCursor: root.cursorActive && root.focusSection === "framing" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(axisRow)
    foreground: root.foreground
    accent: root.accent
    outline: true

    Text {
      id: axisGlyph
      text: axisRow.glyph
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.icon
      anchors.left: parent.left
      anchors.leftMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter

      PanelToolTip {
        visible: glyphHover.hovered
        text: axisRow.label
        fontFamily: root.fontFamily
      }

      HoverHandler { id: glyphHover }
    }

    Text {
      id: axisReadout
      text: axisRow.readout
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      // Fixed width so the slider does not shift as the number's digit count
      // changes under the handle.
      width: Math.max(implicitWidth, Style.space(38))
      horizontalAlignment: Text.AlignRight
      anchors.right: parent.right
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
    }

    PanelSlider {
      id: axisSlider
      bar: root.bar
      anchors.left: axisGlyph.right
      anchors.right: axisReadout.left
      anchors.leftMargin: Style.spacing.md
      anchors.rightMargin: Style.spacing.md
      anchors.verticalCenter: parent.verticalCenter
      minimum: axisRow.minimum
      maximum: axisRow.maximum
      step: axisRow.step
      integer: true
      value: axisRow.axisValue
      onMoved: function(v) { axisRow.axisMoved(Math.round(v)) }
    }

    // Take the wheel before the slider can, and hand it to the panel's scroller.
    //
    // Without this, scrolling down toward the presets lands on the pan slider and
    // starts moving the camera instead of scrolling: a gesture aimed at the list,
    // silently redirected into driving hardware.
    //
    // It has to be a MouseArea, not a WheelHandler. PanelSlider adjusts on wheel
    // from an internal MouseArea, and a MouseArea beats a sibling WheelHandler
    // regardless of declaration order — verified, because the reverse is the
    // intuitive guess and it is wrong. A MouseArea stacked on top does win, so
    // that is what this is. Nothing but wheel is claimed, so the slider keeps
    // every press, drag, and right-click.
    //
    // Deliberate consequence: there is no wheel path to adjusting these sliders.
    // Drag, h/l on the focused row, and the arrow keys all still work.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      onWheel: function(wheel) {
        root.scrollBy(wheel.pixelDelta.y || wheel.angleDelta.y)
      }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor("framing", axisRow.rowIndex)
    }
  }

  // One image control: glyph, label, value, and whichever widget its type calls
  // for. Every image row on both pages is one of these — the curated sliders, the
  // auto switches, and the menus behind the cog — because the difference between
  // them is the control's type, which the helper reports, not the page they sit on.
  //
  // Three widgets, chosen by type:
  //   boolean → ToggleSwitch, because auto/manual is a switch
  //   menu    → Button, cycling, because these menus have two or three options and
  //             a dropdown would cost a click to show what already fits on the row
  //   else    → PanelSlider
  //
  // A held control (the driver's INACTIVE flag: its auto partner is on) is dimmed
  // and inert, with the reason spelled out under the label. Dimmed and not hidden
  // because the value is still real and comes back the moment auto goes off —
  // and a row that vanishes when a switch is flipped makes the list jump.
  component ControlRow: CursorSurface {
    id: controlRow

    required property var control
    required property int rowIndex
    required property string section

    // What the row displays: the pending value while a write is in flight.
    readonly property var shown: root.shownControl(control)
    readonly property bool held: Model.isHeld(control)
    readonly property string note: Model.controlNote(root.imageControls, control,
                                                     root.image.failed)

    implicitHeight: controlInner.implicitHeight + Style.spacing.controlGap
    hasCursor: root.cursorActive && root.focusSection === section
      && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(controlRow)
    foreground: root.foreground
    accent: root.accent
    outline: true

    Item {
      id: controlInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(controlLabels.implicitHeight, controlWidget.implicitHeight)
      // The whole row dims together, so "this is not in effect" reads at a glance
      // rather than being deduced from one greyed widget.
      opacity: controlRow.held ? 0.45 : 1.0

      Text {
        id: controlGlyph
        text: Model.controlGlyph(controlRow.control)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      // Label above, reason below. The second line only exists when there is
      // something to say, so an ordinary row is one line tall.
      //
      // Fixed width, not fitted to the text. A Column sizing itself from its own
      // implicitWidth while its children fill `parent.width` is circular — it
      // resolves to zero and the labels vanish while everything else in the row
      // still draws, which is exactly how this shipped the first time. Fixed also
      // lines the sliders up down the section, which fitted would not.
      //
      // Wide enough for "Backlight compensation", the longest label the driver
      // reports. Measured against the rendered panel rather than guessed, twice:
      // at 132 it cut that one to "Backlight compensat…", and eliding a label
      // next to an unlabelled widget leaves the row ambiguous about what it sets.
      // The cost is slider travel, which there is enough of to give up.
      Column {
        id: controlLabels
        anchors.left: controlGlyph.right
        anchors.leftMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        width: Style.space(148)
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          text: controlRow.control ? controlRow.control.label : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // Wrapped rather than elided: this line names the switch holding the row,
        // and "Set by auto white…" cut short is the half that does not identify it.
        // Only held or refused rows have it, so the taller row is the exception.
        Text {
          width: parent.width
          visible: text !== ""
          text: controlRow.note
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // Right-aligned readout, ahead of the widget in the layout so the widget
      // can anchor to it. Fixed minimum width so the slider does not shift as the
      // number's digit count changes under the handle.
      //
      // The Text sits inside an Item rather than being sized directly, because a
      // Text whose own width reads its own implicitWidth is a binding loop as soon
      // as anything else in the expression changes — measured, not guessed.
      Item {
        id: controlReadout
        // Only sliders get one. A switch shows On/Off by its position and a menu
        // button carries its option's name, so a readout beside either repeats it —
        // and for a menu it is worse than redundant: "Aperture Priority Mode" is
        // wide enough that reserving room for it twice drives the loader's span
        // negative, and the button then draws leftward across the label. Measured
        // on the rendered panel, which is where that overlap was found.
        visible: !!controlRow.control && controlRow.control.type !== "boolean"
          && controlRow.control.type !== "menu"
        width: visible ? Math.max(readoutText.implicitWidth, Style.space(38)) : 0
        implicitHeight: readoutText.implicitHeight
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter

        Text {
          id: readoutText
          text: Model.controlValueLabel(controlRow.shown)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      // One loader for all three widget types, so the row's geometry is decided
      // once. Which component loads is the control's type, straight from the
      // driver — no key-by-key table on this side.
      Loader {
        id: controlWidget
        anchors.left: controlLabels.right
        anchors.right: controlReadout.visible ? controlReadout.left : parent.right
        anchors.leftMargin: Style.spacing.md
        anchors.rightMargin: controlReadout.visible ? Style.spacing.md : 0
        anchors.verticalCenter: parent.verticalCenter
        sourceComponent: {
          if (!controlRow.control) return null
          if (controlRow.control.type === "boolean") return switchWidget
          if (controlRow.control.type === "menu") return menuWidget
          return sliderWidget
        }
      }

      Component {
        id: sliderWidget

        PanelSlider {
          bar: root.bar
          minimum: controlRow.control.min
          maximum: controlRow.control.max
          step: controlRow.control.step
          integer: true
          value: controlRow.shown.value
          enabled: !controlRow.held
          onMoved: function(v) { root.setImageControl(controlRow.control.key, v) }
        }
      }

      Component {
        id: switchWidget

        // Right-aligned inside the loader's span rather than filling it: a switch
        // stretched across the row would put its travel wherever the label
        // happened to end.
        Item {
          implicitHeight: autoSwitch.implicitHeight

          ToggleSwitch {
            id: autoSwitch
            checked: controlRow.shown.value !== controlRow.control.min
            interactive: !controlRow.held
            // The row is a CursorSurface and already draws the highlight; the
            // switch's own ring on top of it would be two rings for one cursor.
            cursorRing: false
            foreground: root.foreground
            accent: root.accent
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onToggled: root.activateControl(controlRow.control)

            PanelToolTip {
              visible: autoSwitch.containsMouse
              // Names what turning it off gives you, which is the reason anyone
              // reaches for these: the manual control below becomes live.
              text: autoSwitch.checked
                ? "Turn off to set " + controlRow.control.label.toLowerCase() + " by hand"
                : "Let the camera decide"
              fontFamily: root.fontFamily
            }
          }
        }
      }

      Component {
        id: menuWidget

        // Cycles rather than dropping down. Two or three options fit on the
        // button, so a dropdown would cost a click to reveal what is already
        // visible — and it makes h/l, Enter and the click all one action.
        Item {
          implicitHeight: menuButton.implicitHeight

          Button {
            id: menuButton
            text: Model.controlValueLabel(controlRow.shown)
            bordered: true
            enabled: !controlRow.held
            foreground: root.foreground
            accent: root.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            horizontalPadding: Style.spacing.sm
            verticalPadding: Style.spacing.xxs
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            onClicked: root.activateControl(controlRow.control)
            onHovered: function(on) {
              if (on) root.setCursor(controlRow.section, controlRow.rowIndex)
            }

            PanelToolTip {
              visible: menuButton.hot
              text: "Next setting"
              fontFamily: root.fontFamily
            }
          }
        }
      }
    }

    // Same wheel interception as AxisRow, and for the same reason: PanelSlider
    // swallows the wheel from an internal MouseArea, so a scroll aimed at the
    // presets below would land on whichever image slider it passed over. It has
    // to be a MouseArea — a sibling WheelHandler loses to one regardless of
    // declaration order.
    MouseArea {
      anchors.fill: parent
      acceptedButtons: Qt.NoButton
      onWheel: function(wheel) {
        root.scrollBy(wheel.pixelDelta.y || wheel.angleDelta.y)
      }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor(controlRow.section, controlRow.rowIndex)
    }
  }

  // One saved image profile: its name and a clear button. Deliberately thinner
  // than PresetRow — a framing preset shows the angles it holds because "-30°,
  // 10°, 1.2×" is readable, while a profile holds fifteen numbers that would say
  // nothing laid out on a row.
  component ProfileRow: CursorSurface {
    id: profileRow

    required property string name
    required property int rowIndex

    implicitHeight: profileInner.implicitHeight + Style.spacing.lg
    hasCursor: root.cursorActive && root.focusSection === "advanced"
      && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(profileRow)
    foreground: root.foreground
    accent: root.accent
    fill: root.hoverFill
    currentFill: root.selectedFill

    // Declared before the content so the clear button sits above it and receives
    // its own clicks; this only catches the rest of the row.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor("advanced", profileRow.rowIndex)
      onClicked: root.loadProfile(profileRow.name)
    }

    Item {
      id: profileInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(profileLabels.implicitHeight,
                               profileClearButton.implicitHeight)

      Text {
        id: profileGlyph
        text: "󰋩"
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: profileLabels
        anchors.left: profileGlyph.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: profileClearButton.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          text: profileRow.name
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: "Click to apply"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        id: profileClearButton
        iconText: "󰅖"
        tooltipText: "Delete this profile"
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xxs
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.clearProfile(profileRow.name)
        onHovered: function(on) { if (on) root.setCursor("advanced", profileRow.rowIndex) }
      }
    }
  }

  // ---- device page rows ----
  //
  // Three shapes cover the whole page: a row of chips, a switch, and a camera
  // slot. They are components rather than repeated blocks because the page is
  // eleven rows of two shapes, and the cursor ring, the hover-to-cursor handler
  // and the scroll interception have to be identical on every one of them — a row
  // that forgets `ensureCursorVisible` is a row j walks off the bottom of.
  //
  // Both carry a `known` flag. A firmware setting the camera did not answer for is
  // not off, and a switch drawn off would be the panel making that claim on the
  // hardware's behalf.
  component DeviceChipRow: CursorSurface {
    id: chipRow

    required property int rowIndex
    property string glyph: ""
    property string label: ""
    property string note: ""
    property var options: []
    property string value: ""
    property bool known: true

    signal picked(string value)

    implicitHeight: chipContent.implicitHeight + Style.spacing.controlGap
    hasCursor: root.cursorActive && root.focusSection === "device"
      && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(chipRow)
    foreground: root.foreground
    accent: root.accent
    outline: true

    Column {
      id: chipContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.spacing.xs

      // Chips below the label rather than beside it: three of these hold options
      // named in words ("Noise cancelling"), and a label plus three words does not
      // fit the panel's width without eliding one of them.
      Row {
        width: parent.width
        spacing: Style.spacing.md

        Text {
          text: chipRow.glyph
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.icon
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          text: chipRow.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          anchors.verticalCenter: parent.verticalCenter
        }
      }

      ButtonGroup {
        width: parent.width
        options: chipRow.options
        // Empty rather than a guess when the camera did not answer: no chip
        // selected is the honest rendering, the same as the mode group's.
        value: chipRow.known ? chipRow.value : ""
        enabled: root.present
        opacity: enabled ? 1.0 : 0.4
        foreground: root.foreground
        accent: root.accent
        background: root.bar ? root.bar.background : Color.background
        fontFamily: root.fontFamily
        fontSize: Style.font.caption
        // h/l and Enter come from the panel's cursor, as they do for the mode
        // chips — the group keeping its own Tab focus would give the page two
        // cursors to be in at once.
        focusable: false
        cursorIndex: -1
        onChanged: function(value) { chipRow.picked(value) }
        onHovered: function(index, isHovered) {
          if (isHovered) root.setCursor("device", chipRow.rowIndex)
        }
      }

      Text {
        width: parent.width
        visible: text !== ""
        text: chipRow.known ? chipRow.note : "The camera did not report this."
        color: root.faint
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor("device", chipRow.rowIndex)
    }
  }

  component DeviceSwitchRow: CursorSurface {
    id: switchRow

    required property int rowIndex
    property string glyph: ""
    property string label: ""
    property string note: ""
    property bool checked: false
    property bool known: true

    signal switched(bool enabled)

    implicitHeight: switchContent.implicitHeight + Style.spacing.controlGap
    hasCursor: root.cursorActive && root.focusSection === "device"
      && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(switchRow)
    foreground: root.foreground
    accent: root.accent
    outline: true

    Item {
      id: switchContent
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(switchLabels.implicitHeight, rowSwitch.implicitHeight)

      Text {
        id: switchGlyph
        text: switchRow.glyph
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: switchLabels
        anchors.left: switchGlyph.right
        anchors.leftMargin: Style.spacing.md
        anchors.right: rowSwitch.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          text: switchRow.label
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // Wrapped, not elided: these lines say what the setting does to the
        // hardware, and half of that sentence is worse than none.
        Text {
          width: parent.width
          visible: text !== ""
          text: switchRow.known ? switchRow.note : "The camera did not report this."
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      ToggleSwitch {
        id: rowSwitch
        checked: switchRow.known && switchRow.checked
        interactive: root.present
        opacity: interactive ? (switchRow.known ? 1.0 : 0.6) : 0.4
        // The row draws the cursor ring; the switch's own on top of it would be
        // two rings for one cursor.
        cursorRing: false
        foreground: root.foreground
        accent: root.accent
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onToggled: switchRow.switched(!rowSwitch.checked)
      }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor("device", switchRow.rowIndex)
    }
  }

  // One of the camera's own preset slots. Read-mostly on purpose: these hold pan
  // and tilt only, saving a framing preset above already mirrors into the slot of
  // the same number, and a Save here would store an angle without the zoom the
  // framing preset of that number is showing — two lists claiming to be slot 2.
  component NativeSlotRow: CursorSurface {
    id: slotRow

    required property int slot
    required property int rowIndex

    readonly property var entry: root.vendorShown.nativePresets
      ? root.vendorShown.nativePresets[slot] : null
    readonly property bool stored: entry !== null && entry !== undefined && entry.saved

    implicitHeight: slotInner.implicitHeight + Style.spacing.lg
    hasCursor: root.cursorActive && root.focusSection === "device"
      && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(slotRow)
    foreground: root.foreground
    accent: root.accent
    fill: root.hoverFill
    currentFill: root.selectedFill

    Item {
      id: slotInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      implicitHeight: Math.max(slotLabels.implicitHeight, slotClearButton.implicitHeight)

      Text {
        id: slotNumberText
        text: slotRow.slot
        color: slotRow.stored ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: slotLabels
        anchors.left: slotNumberText.right
        anchors.leftMargin: Style.spacing.xl
        anchors.right: slotClearButton.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          text: slotRow.entry === null || slotRow.entry === undefined
            ? "Not reported"
            : (slotRow.stored ? "Stored in the camera" : "Empty")
          color: slotRow.stored ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: "Saved by framing preset " + slotRow.slot
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        id: slotClearButton
        iconText: "󰅖"
        visible: slotRow.stored
        tooltipText: "Clear this slot in the camera"
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xxs
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.clearNativePreset(slotRow.slot)
        onHovered: function(on) { if (on) root.setCursor("device", slotRow.rowIndex) }
      }
    }

    HoverHandler {
      onHoveredChanged: if (hovered) root.setCursor("device", slotRow.rowIndex)
    }
  }

  // One preset slot: its number, what it holds, and save/clear actions.
  component PresetRow: CursorSurface {
    id: presetRow

    required property int slot
    required property int rowIndex

    readonly property bool filled: Model.hasPreset(root.presets, slot)

    implicitHeight: presetInner.implicitHeight + Style.spacing.xl
    hasCursor: root.cursorActive && root.focusSection === "presets" && root.selectedIndex === rowIndex
    onHasCursorChanged: if (hasCursor) root.ensureCursorVisible(presetRow)
    foreground: root.foreground
    accent: root.accent
    fill: root.hoverFill
    currentFill: root.selectedFill

    // Declared before presetInner so the buttons sit above it and receive their
    // own clicks; this only catches the rest of the row.
    MouseArea {
      id: presetMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onContainsMouseChanged: if (containsMouse) root.setCursor("presets", presetRow.rowIndex)
      // Clicking a filled slot recalls it; clicking an empty one stores the
      // current framing, so the row is useful before it holds anything.
      onClicked: presetRow.filled ? root.loadPreset(presetRow.slot) : root.savePreset(presetRow.slot)
    }

    Item {
      id: presetInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(10)
      anchors.rightMargin: Style.space(6)
      implicitHeight: Math.max(presetLabels.implicitHeight, saveButton.implicitHeight)

      Text {
        id: slotNumber
        text: presetRow.slot
        color: presetRow.filled ? root.foreground : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        font.bold: true
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
      }

      Column {
        id: presetLabels
        anchors.left: slotNumber.right
        anchors.leftMargin: Style.spacing.xl
        anchors.right: saveButton.left
        anchors.rightMargin: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        spacing: Style.spacing.xxs

        Text {
          width: parent.width
          text: presetRow.filled ? Model.presetLabel(root.presets, presetRow.slot) : "Empty"
          color: presetRow.filled ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          text: presetRow.filled ? "Click to recall" : "Click to store the current framing"
          color: root.faint
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }

      Button {
        id: clearButton
        iconText: "󰅖"
        visible: presetRow.filled
        tooltipText: "Clear this preset"
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xxs
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.clearPreset(presetRow.slot)
        onHovered: function(on) { if (on) root.setCursor("presets", presetRow.rowIndex) }
      }

      Button {
        id: saveButton
        iconText: "󰆓"
        tooltipText: presetRow.filled ? "Overwrite with the current framing" : "Store the current framing"
        active: root.savingSlot === presetRow.slot
        foreground: root.foreground
        accent: root.accent
        fontFamily: root.fontFamily
        horizontalPadding: Style.spacing.sm
        verticalPadding: Style.spacing.xxs
        anchors.right: clearButton.visible ? clearButton.left : parent.right
        anchors.rightMargin: clearButton.visible ? Style.spacing.xs : 0
        anchors.verticalCenter: parent.verticalCenter
        onClicked: root.savePreset(presetRow.slot)
        onHovered: function(on) { if (on) root.setCursor("presets", presetRow.rowIndex) }
      }
    }
  }
}
