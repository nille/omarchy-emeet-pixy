import QtQml
import "Model.js" as Model

// Call-edge state that is independent of panel visibility and device I/O.
//
// The panel supplies stream observations from the lightweight holders poll and
// answers snapshotRequested with a fresh full state read. Keeping the token here
// makes a late read harmless after the call ended or a newer call began.
QtObject {
  id: root

  property bool enabled: false
  property bool present: false
  property var actions: ({})
  property bool hasMic: false
  property bool muted: false

  property bool streaming: false
  property int generation: 0
  property int pendingToken: 0
  property var restore: null

  signal snapshotRequested(int token)
  signal planReady(var plan, string edge)

  onEnabledChanged: if (!enabled && pendingToken) {
    generation += 1
    pendingToken = 0
  }

  onPresentChanged: if (!present && pendingToken) {
    generation += 1
    pendingToken = 0
  }

  function observeStreaming(value) {
    var next = !!value
    var edge = Model.callEdge(streaming, next)
    streaming = next
    if (edge === "start") begin()
    else if (edge === "end") finish()
  }

  function begin() {
    generation += 1
    pendingToken = 0
    if (!enabled || !present) return
    pendingToken = generation
    snapshotRequested(pendingToken)
  }

  function acceptSnapshot(token, state) {
    if (token !== pendingToken || !streaming) return false
    pendingToken = 0
    if (!enabled || !state || !state.present || !state.streaming) return false

    var plan = Model.callStartPlan(actions, {
      privacy: state.privacy,
      mode: state.mode,
      muted: hasMic ? muted : undefined
    })
    if (!Model.planIsEmpty(plan)) restore = plan.restore
    planReady(plan, "start")
    return true
  }

  function rejectSnapshot(token) {
    if (token !== pendingToken) return
    pendingToken = 0
  }

  function finish() {
    generation += 1
    pendingToken = 0
    var plan = Model.callEndPlan(restore)
    restore = null
    planReady(plan, "end")
  }
}
