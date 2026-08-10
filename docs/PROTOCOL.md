# EMEET PIXY control protocol

What `scripts/pixy` sends the camera, and why it sends it that way. Written down
because the interesting parts are the ones a reader would otherwise assume were
arbitrary: the duplicated length byte, the second report after every mode change,
the value `0x03`, and the fact that half the camera's own features are
deliberately unused.

## Provenance

Two sources, and it is worth keeping them apart.

**Inherited.** The starting point was the survey at
<https://nille.net/writing/control-emeet-pixy-webcam-linux/> and the projects it
links. That is where the vendor HID interface, the report id, and the general
shape of a report came from. None of it is official documentation.

**Verified here.** Every constant in `scripts/pixy` was then checked against the
device itself — an EMEET PIXY, USB `328f:00c0`, on Linux 6.x with `uvcvideo`. The
findings below marked *(observed)* are things this camera actually did, repeatedly,
on this firmware. They are not from a datasheet, and a firmware update could
invalidate any of them.

There is no vendor specification. Treat the whole document as a field report.

## Two control surfaces

The camera answers on two unrelated interfaces, and the helper uses each for only
what it is good at.

| | Interface | Used for |
|---|---|---|
| UVC | V4L2 on `/dev/videoN` | pan, tilt, zoom, image controls, capture |
| Vendor HID | `/dev/hidrawN` | mode, audio DSP, gestures, flip/rotate, focus metering, the camera's own preset slots, the idle shutter timeout |

(Three, counting the microphone — but it needs no protocol work at all. See
[The microphone is not a protocol problem](#the-microphone-is-not-a-protocol-problem).)

The split is not cosmetic. UVC pan/tilt/zoom are **absolute and readable**, so
the panel can show a real position instead of dead-reckoning from the moves it
happens to have made. The control mode has no UVC equivalent at all, so it has to
go over HID.

### Why HID PTZ is not used

The camera does expose PTZ over HID (groups `0x03` and `0x63`). The helper never
touches them.

*(observed)* HID PTZ commands move the motors while leaving the UVC position
readback unchanged. After one HID move, `V4L2_CID_PAN_ABSOLUTE` reports a
position the lens is no longer at, and there is no way to resynchronize short of
a UVC absolute write. Mixing the two paths permanently desynchronizes the
readout. A panel that cannot trust its own position display is worse than one
with a slightly smaller feature set, so the HID PTZ path is left alone.

This is a statement about HID *motion commands* specifically. The camera's own
preset slots are HID and are used — see
[The camera's own preset slots](#the-cameras-own-preset-slots) — because their
stored coordinates turn out to be in the UVC space, so they can be recalled over
UVC without any HID motion command being sent.

## Finding the right nodes

Both surfaces need discovery, and both have a trap.

**HID.** The camera claims several `hidraw` nodes and only one answers vendor
reports. Matching on the USB ids alone picks whichever node udev enumerated
first, which is a coin flip across reboots. The helper instead reads each
candidate's report descriptor and prefers the node whose descriptor contains

```
05 83 09 83      # usage page 0x83, usage 0x83
```

*(observed)* Exactly one node carries that pair, and it is the one that answers.
If no node advertises it — a plausible firmware difference — the helper falls
back to the USB id match rather than reporting no camera.

**Video.** The PIXY exposes two `/dev/videoN` nodes; the second is a metadata
node that accepts no controls. `VIDIOC_QUERYCAP` distinguishes them, and the
`device_caps` field is the one to read, not `capabilities`: the global field
advertises capture for the whole device, so a metadata node looks like a capture
node if you check the wrong one.

Both lookups can be overridden with `PIXY_HIDRAW` and `PIXY_VIDEO`. If an
override names a path that does not exist, the helper reports no camera rather
than falling through to autodetection — driving a *different* device than the one
the operator named is the worse failure.

## UVC controls

Three controls, driven through raw `ioctl`s rather than by shelling out to
`v4l2-ctl`, so the plugin needs nothing outside the Python standard library.

| Control | CID | Unit | Range on this camera |
|---|---|---|---|
| `V4L2_CID_PAN_ABSOLUTE` | `0x009A0908` | arc-seconds | ±540000 (±150°) |
| `V4L2_CID_TILT_ABSOLUTE` | `0x009A0909` | arc-seconds | ±324000 (±90°) |
| `V4L2_CID_ZOOM_ABSOLUTE` | `0x009A090D` | driver units | 100..150 |

Pan and tilt are arc-seconds, so a degree is 3600 units and the step is exactly
one degree. Zoom is unitless in the driver; 100..150 corresponds to 1.00×..1.50×,
which is how the official app displays it and what the number means.

The ranges above are what this camera reported, but the helper never hardcodes
them for writes — it re-reads `VIDIOC_QUERYCTRL` and clamps against whatever the
driver says. The duplicated bounds in `Model.js` exist only so the sliders have
sane extents before the first reply arrives.

**Snapping matters.** Values are rounded onto a step boundary before writing. An
unsnapped write is silently rounded by the driver, so the readback disagrees with
what the slider was set to and the handle visibly jumps on the next refresh.

**Settling matters too.** A full sweep takes time. Reading back immediately after
a write returns the old position, so anything that writes then reads waits
`PTZ_SETTLE` (0.35 s) in between.

## Capture, for the terminal preview

`scripts/pixy preview` captures frames itself rather than shelling out to
anything, which puts two more V4L2 details on the record.

**YUYV, not MJPEG.** The camera offers both. YUYV was chosen for one reason: it
interleaves luma with chroma, so byte `2*x` of a row is pixel `x`'s brightness and
a brightness-only render needs no decoding at all. MJPEG would mean hand-rolling a
baseline JPEG decoder inside a file that is not allowed to import anything outside
the standard library. The panel's own preview is QtMultimedia and has no such
constraint; this path exists for a terminal.

**Streaming, not read().** *(observed)* This camera does not advertise
`V4L2_CAP_READWRITE`, so a plain `read()` on the node returns `EINVAL` no matter
what. Frames only come out of the mmap streaming path, which is six ioctls in a
fixed order:

```
S_FMT → REQBUFS → QUERYBUF → mmap → QBUF → STREAMON → DQBUF ⇄ QBUF
```

`S_FMT` is a request, not a command — the driver rewrites width, height, and
`bytes_per_line` to what it accepted, so they are read back rather than trusted. A
size silently adjusted from the requested one misaligns every row of output, and a
`bytes_per_line` wider than `width * 2` shears the image progressively down the
frame rather than failing.

Teardown matters as much as setup: a stream left on holds the camera against every
other app on the system, and mapped buffers outlive the fd if they are not
explicitly unmapped. `Capture` is a context manager for that reason and undoes
every acquisition step in reverse, including on a partially-failed `__enter__`.

### The `v4l2_buffer` offset trap

*(observed, painfully)* `struct v4l2_buffer` contains a `timeval` and two unions,
and its field offsets are **not** derivable by reading the struct definition and
counting. The offsets in `scripts/pixy` came from compiling `offsetof` against this
kernel's headers:

| Field | Offset |
|---|---|
| `index` | 0 |
| `type` | 4 |
| `bytesused` | 8 |
| `memory` | 60 |
| `m.offset` | 64 |
| `length` | 72 |
| *sizeof* | 88 |

The obvious hand derivation over-pads `v4l2_timecode` and lands `memory` 16 bytes
late. That does not fail at the mistake — the wrong offset reads a neighbouring
field, `mmap` maps garbage, and the visible symptom is `ENOTTY` several ioctls
later, which reads like a wrong ioctl number rather than a wrong struct.

There is one free check, and it is worth knowing: the size is encoded in the ioctl
number itself. `VIDIOC_QBUF` is `0xc058560f`, and `0x58` is 88 — so
`BUFFER_SIZE` disagreeing with `(VIDIOC_QBUF >> 16) & 0x3fff` is a bug that can be
caught without hardware. `tests/test_pixy.py` asserts exactly that.

### Stream exclusivity, and why the control plane is unaffected

*(observed)* Exactly one process at a time may hold the capture stream. `open()`
still succeeds for everyone — that is the confusing part — and the refusal arrives
later, at `S_FMT` or `REQBUFS`, as `EBUSY` (errno 16).

What was verified, in both directions:

| Situation | Result |
|---|---|
| Another app streaming, we try to capture | `EBUSY` at `S_FMT` |
| We are streaming, another app tries | `EBUSY` at `S_FMT`/`REQBUFS` |
| Another app streaming, we set pan/tilt/zoom | works |
| Another app streaming, we set privacy/tracking | works, and `read_mode` is *more* informative |
| Nothing streaming, we set pan/tilt/zoom/image | works |
| Nothing streaming, we set privacy | works |
| Nothing streaming, we set standard/tracking | **silently discarded** |

Rows three and four are the important ones. `VIDIOC_S_CTRL` on an open fd and HID
writes to `/dev/hidrawN` are both entirely independent of who holds the stream, so
every control this widget exposes keeps working during someone else's video call.
Only the preview competes. That asymmetry is why the preview yields and why it can
be switched off without costing any functionality.

The last row is the one exception to "the control plane always works", and it runs
the opposite way to everything else here: not blocked by *another* app streaming,
but by *nobody* streaming. It has its own section below.

A blocked competitor is also *detectable*, which is what makes yielding possible at
all rather than merely polite: a process refused with `EBUSY` still has the node
open, so it appears under `/proc/*/fd`. The panel can therefore tell that it is
itself the obstacle and release. `stream_holders()` returns
`(other_pids, our_pids)` for that reason — folding the two together makes an open
panel report "in use by quickshell", and discarding our own side means the panel
never learns it is in the way.

The residual gap is single-shot clients. `ffmpeg -f v4l2` opens the device, fails,
and exits within microseconds; no poll interval and no `inotify` handler can react
inside that window. (`inotify` does deliver `IN_OPEN` on `/dev/videoN` in ~9 ms,
but it carries no PID, so it cannot distinguish another app's open from the
helper's own `state` read — reacting to it would drop the preview on every
refresh.) Apps that hold the device open while negotiating, which is what browsers
and meeting clients do, are handled. For the rest there is the `preview` setting.

## The microphone is not a protocol problem

Worth stating explicitly, because it is the one camera feature that needed no
reverse engineering: the PIXY's microphone is a standard USB audio class device.
It appears as an ALSA card and PipeWire publishes it as `Audio/Source`, so mute and
volume are ordinary PipeWire property writes. `scripts/pixy` does not touch it and
has no reason to.

There is one trap, and it is in *identification* rather than in control.

*(observed)* The camera publishes **two** PipeWire nodes carrying the nickname
`EMEET PIXY`:

| `node.name` | `media.class` | `audio` |
|---|---|---|
| `alsa_input.usb-EMEET_EMEET_PIXY_<serial>-02.mono-fallback` | `Audio/Source` | present |
| `v4l2_input.pci-…-usb-0_2_1.0` | `Video/Source` | null |

Note the second name. It begins `v4l2_input`, so any filter looking for "input" —
or "source", or "capture" — in the node name matches the camera as well as the
microphone. Identity strings cannot separate them either, since the nickname is
identical and both descriptions start with "EMEET PIXY".

The discriminator is `PwNode.audio`: non-null on the microphone, null on the camera.
It is a constant property rather than one that fills in after binding, and it reads
correctly well before `PwObjectTracker` has bound anything — verified at 100 ms from
shell startup. `Model.js`'s `isPixyMic()` checks it first for that reason.

An earlier version matched on the name pattern alone and returned whichever node
PipeWire enumerated first. That happens to be the microphone on the development
machine, which is exactly what makes the bug worth recording: it worked, and it
would have kept working until enumeration order changed, at which point the mute
button would have driven a camera node and silently done nothing.
`tests/qml/tst_model_mic.qml` pins both orderings.

The other reason not to use `Pipewire.defaultAudioSource`: a webcam is rarely the
system default. Taking the default would put a control in a panel titled PIXY that
adjusts some other microphone entirely.

## Vendor HID reports

Every report is exactly 32 bytes, zero-padded, and starts with report id `0x09`.

```
byte  0    1    2    3    4    5    6    7    8...
     09   GG   AA   BB   00   LL   00   LL   <payload>
          ^    ^    ^         ^         ^
          |    |    |         |         └── payload length, again
          |    |    |         └──────────── payload length
          |    └────┴────────────────────── command selector
          └─────────────────────────────────command group
```

*(observed)* The length appears **twice**, at offsets 5 and 7. Sending it once
and leaving the other zero gets the report ignored. There is presumably a
structural reason — an outer envelope wrapping an inner one, most likely — but
from the outside it is simply a rule: state the length in both places.

`build_report()` is the only function in the helper that produces bytes for the
camera, and it is deliberately strict — wrong report id, over 32 bytes, or a
byte outside 0..255 all raise rather than reaching the hardware. Validating in
one place means no call site can get it wrong.

### Queries are write-then-read

A vendor query writes a report and reads the reply on the same file descriptor.
Four details are load-bearing:

1. **Replies echo bytes 1–3 of the request.** *(observed)* Every group in use
   answers with the group byte in byte 1 and the two command bytes in bytes 2–3,
   verbatim. That is what makes a reply matchable at all — the camera also emits
   unsolicited status reports, and taking the first thing that arrives decodes
   another group's payload as the answer.
2. **Matching on the group alone is not enough.** *(observed, and it shipped as a
   bug)* A group carries several commands. Group `0x05` holds both `00 03` (set
   audio) and `00 04` (read audio), and a set is acknowledged with `0x20` where
   the value belongs. A read issued right after a set therefore accepted the
   set's ack as its own answer, decoded `0x20` as a mode, and reported a write
   that had landed as failed. The helper matches the command bytes too.
3. **The group byte is masked with `0x1f`.** *(observed)* Replies come back with
   high bits set in byte 1 — `0x01` returns as `0x41` or `0x61` — so comparing it
   raw never matches. The command bytes are *not* masked; they come back exactly
   as sent.
4. **Reads are retried, and the fd is drained first.** *(observed)* An unread
   reply is drained by the *next* query, so one missed answer corrupts the
   following one too. Four attempts, draining before each.

### The first write on a fresh descriptor is lost

*(observed)* This is the reason a query is retried at all, and it is more specific
than "the camera answers slowly". Timed with instrumentation:

| | Latency |
|---|---|
| Reply to a write on an already-used fd | ~30 ms |
| Reply to the first write after `open()` | never — the write is silently dropped |

So every query on a freshly opened descriptor spent a full `QUERY_TIMEOUT`
(0.6 s) waiting for an answer to a report the camera never saw, then succeeded
immediately on attempt two. Ten feature reads cost **8.49 s**. Sharing one
descriptor across them costs **0.56 s** — `HidSession` exists for exactly this,
and `pixy vendor` opens the node once for all ten. Commands that issue a single
query gain nothing from it and do not use it.

### The first config write after idle is dropped too

*(observed)* Separately from the above, and not fixed by sharing a descriptor: the
first *set* report after a period of inactivity does not take effect. The
identical command sent immediately afterwards succeeds. Verified across audio,
gesture, and focus metering — cold attempts report `attempts: 2`, warm ones
`attempts: 1`.

`set_and_confirm()` is the single place this is handled: every vendor setter
writes, waits `SET_SETTLE`, reads back, and retries once if the readback
disagrees. A setter whose write landed exits on the first pass, so the retry costs
nothing in the normal case — and because confirmation comes from a readback rather
than from the write returning, `confirmed: false` is a real, reportable outcome
rather than a hidden failure.

Writes of multiple reports also pause 25 ms between them: *(observed)* the camera
acknowledges a config report before it is ready for the commit that follows, and
back-to-back writes get dropped.

### Control mode — group `0x01`

| Mode | Value |
|---|---|
| Standard | `0x00` |
| Tracking | `0x01` |
| Privacy | `0x02` |

Setting a mode is two reports: the write, then the query that follows it.

```
09 01 01 00 00 01 00 01 VV      # set mode to VV
09 01 01 01                     # query mode — also commits the write
```

*(observed)* The query is not just a readback. Sending the set report alone does
not reliably take effect; the query that follows is what commits it. So the
helper always sends both, and reads the reply to find out what the camera
actually did.

Reading the mode is the query report alone. The mode is byte 8 of the reply.

### The `0x03` problem

*(observed)* An **idle** camera — nothing holding the video stream — answers
`0x03` to the mode query, for both Standard and Tracking. It does not distinguish
them. Once any app opens the stream, it answers `0x00` or `0x01` correctly.

Privacy is the exception: it answers `0x02` whether or not anything is streaming.

This shapes three behaviors:

- `read_mode()` returns `(None, 0x03)` — unknown, with the raw byte kept. It does
  not resolve the ambiguity to a guess, because guessing "Standard" would have
  the panel claim tracking is off while the camera is visibly following someone
  around the room.
- The panel says so out loud rather than showing a confidently wrong toggle, and
  dims the chips — see the write refusal below, which is the same firmware
  condition and the reason the chips are disabled rather than merely unlit.
- **The privacy toggle still works on an idle camera**, because `0x02` is
  unambiguous. An earlier version discarded the raw byte whenever the mode came
  back unknown, which threw away a perfectly good `0x02` and made the toggle turn
  privacy *on* twice in a row. The `streaming` flag exists only to explain why a
  mode is unknown; it never gates the decode.

When the mode genuinely cannot be determined, the toggle errs toward turning
privacy **on**. That is the safe direction for someone reaching for the button.

*(observed)* One side effect worth knowing: **the panel's own preview counts as a
stream**, so opening the panel resolves the ambiguity. Closed, `state` reports
`modeRaw: 3` and `mode: null`; open with the preview running it reports
`modeRaw: 0` and `mode: "standard"`. This is why the mode chips can show a filled
dot at all in normal use — and it is the one thing setting `preview: false` costs.

### An idle camera also refuses the write

*(observed)* The ambiguity above is only half of it: an idle camera does not merely
fail to *report* Standard vs Tracking, it refuses to *change* it. The HID write is
accepted — `write_reports` succeeds, the helper returns `ok: true` — and the
firmware discards it.

Tested in both directions, since one direction alone could have been a readback
artifact rather than a lost write:

| Start | While idle, write | Then open a stream and read | Verdict |
|---|---|---|---|
| Standard | Tracking | `standard` | write lost |
| Tracking | Standard | `tracking` | write lost |

The same write during a stream lands on the first attempt (3/3 trials, ~1.7 s after
stream start).

Privacy is exempt in **both** directions: `0x02` writes fine on an idle camera, and
so does leaving privacy. This is the reason `Panel.qml`'s `setMode` guard skips
privacy and skips any write made *from* privacy — gating those would let the lens
be closed on an idle camera and then not reopened.

So the panel dims both chips and disables the group while the camera is idle, with
a note saying why. An earlier version left them live and merely showed neither as
active: honest about the readback, but it read as a bug, and pressing a chip then
did nothing with no error to explain it. That was reported as "neither Standard nor
Tracking is highlighted", which is how this behavior was found.

*(observed)* Unrelated flake noticed while testing this, not currently handled: a
direct `pixy mode privacy` on an idle camera lands about 2 times in 3 — the
readback comes back `0x03` and `confirmed: false`. The panel's privacy path was
reliable in the same conditions, so this is recorded rather than worked around.

### Leaving privacy

*(observed)* A direct privacy → tracking transition is ignored by the firmware.
The camera stays in privacy while the panel believes it switched. Switching to
Tracking from Privacy therefore writes Standard first, then Tracking.

And leaving privacy via the toggle goes to **Standard**, never Tracking — closing
the lens and reopening it should not quietly enable a camera behavior nobody
asked for.

*(observed)* That intent only holds while something is streaming. On an idle camera
the lens does reopen, but the Standard part of the write is discarded like any other
idle Standard/Tracking write: a camera that was in Tracking before privacy is in
Tracking again afterward, confirmed by starting a stream and reading it back. Not
worked around — the alternative is refusing to reopen the lens, and a lens that
stays shut is a worse outcome than a tracking mode that survived.

## Other vendor feature groups

Everything below speaks the same 32-byte report. Each feature has a set command
and a read command in the same group, and the helper never trusts a write: it
reads back through `set_and_confirm()`.

*(observed)* Group `0x04`'s read replies put the *value* at byte 9, not at the end
of the report. Reports are zero-padded to 32 bytes, so decoding from the last byte
always yields `0` — which looks exactly like "the feature is off" and is a live bug
in at least one other Linux tool for this camera. `read_gesture` and `read_feature`
read byte 9, and there are tests pinning that.

### Audio DSP mode — group `0x05`

| Mode | Value | What it is |
|---|---|---|
| Noise cancelling | `0x01` | the default; suppresses background noise |
| Live | `0x02` | wide-band, for music |
| Original | `0x03` | no processing |

```
09 05 00 03 00 01 00 01 VV      # set
09 05 00 04                     # read — mode is byte 8
```

This is DSP inside the camera, not a PipeWire filter: it survives a reboot and
applies to every host the camera is plugged into.

### Gesture control — group `0x04`, command `02 00`

```
09 04 02 00 00 02 00 02 02 EE   # set: EE = 01 on, 00 off
09 04 02 01 00 01 00 01 02      # read — value at byte 9
```

### Image orientation — group `0x04`, command `00 08`

Three independent toggles, addressed by a feature id in byte 8:

| Feature | Id |
|---|---|
| Horizontal flip (mirror) | `0x01` |
| Vertical flip | `0x02` |
| Auto-rotate (portrait) | `0x04` |

```
09 04 00 08 00 02 00 02 FF EE   # set feature FF to EE
09 04 00 07 00 01 00 01 FF      # read feature FF — value at byte 9
```

These are applied by the camera to the outgoing stream, so they affect every app
at once — unlike a mirror applied in a meeting client's own preview.

### Focus metering — group `0x04`, commands `00 01` / `00 03`

| Mode | Value |
|---|---|
| Center | `0x00` |
| Face | `0x01` |
| Area | `0x02` |

```
09 04 00 01 00 05 00 05 MM XX YY 7f 7f      # stage
09 04 00 03 00 05 00 05 MM XX YY 7f 7f      # commit
09 04 00 02                                 # read — mode byte 8, x byte 9, y byte 10
```

*(observed)* Two writes are required. Command `00 01` stages and `00 03` commits;
the camera does not act on `00 01` alone. EMEET Studio sends both with an identical
payload, and so does the helper.

`XX`/`YY` are the target point for `area`, 0..0x7F from the left and top. The
trailing `7f 7f` bytes were constant in every capture and are sent verbatim.

*(observed)* The x/y bytes **persist after leaving `area` mode** — the camera keeps
the last point picked, and sending zeros with a non-area mode does not clear them.
There is no known reset. The helper reports them alongside the mode rather than as
state of their own, because they only mean anything in `area`.

### Idle shutter timeout — group `0x02`

```
09 02 01 00 00 04 00 04 SS SS SS SS     # set: seconds, 32-bit little-endian
09 02 01 01                             # read — seconds at bytes 8..11
```

Zero disables it. This runs **in the camera**: after N seconds with no stream the
lens closes itself, and it stays configured across a reboot or a move to a
different host. Nothing on this machine needs to be running for it to work, which
is why it is worth exposing at all.

## The camera's own preset slots

The camera has three PTZ preset slots of its own — the ones EMEET Studio uses.
Three things had to be established before they could be used, and the answers do
not point the same way.

**Save works, and stores UVC degrees.** *(observed)*

```
09 03 01 15 00 02 00 02 SS EE   # SS = slot 1-3, EE = 01 save, 00 erase
09 03 01 16 00 01 00 01 SS      # read — saved flag byte 9, then <fff at bytes 10..21
```

No coordinates are sent on a save: the camera stores wherever the lens currently
points. The stored values come back as three little-endian floats, and the first
two are **degrees in the same space as the UVC readback** — saving at UVC
pan = -35.0 stores -34.969. The third float was 0.0 in every reading here and in
the reference captures, so it is not decoded. Erase is the same report with the
enable byte at `0x00`.

This corrects an earlier claim in this document, which said the slots used a
different coordinate space. They do not. What diverges is HID *motion*, which is a
separate thing — see [Why HID PTZ is not used](#why-hid-ptz-is-not-used).

**Load does not work.** *(observed)* The vendor load command `0x18` is inert on
this firmware. It is acknowledged with `0x20` and the lens does not move — tested
with a stream open and Standard mode set, comparing averaged frames before and
after against a calibrated baseline:

| Measurement | Frame difference |
|---|---|
| Noise floor (nothing sent) | 0.24 |
| A known 80° UVC pan | 56.08 |
| After a preset load | 0.35 |

The calibration leg is the point of that table. An earlier run of the same test was
inconclusive because the noise floor came out higher than the signal, and a null
result is worth nothing until the detector has been shown to detect something.

**So load is synthesized.** The helper reads the slot's stored degrees over HID and
drives the lens there over **UVC**. No HID motion command is ever sent, so the
position readback stays truthful — which is the one thing using the vendor load
command could not have given even if it worked.

### Framing presets: local store, mirrored to the camera

The local store remains the authority, and the reason is zoom: the camera's slots
hold pan and tilt only. A preset kept solely in the camera would silently forget
the zoom level it was saved at.

Presets are stored as UVC triples in
`$XDG_STATE_HOME/omarchy-emeet-pixy/presets.json` (defaulting to
`~/.local/state/...`):

```json
{ "slots": { "2": { "pan": 45, "tilt": -20, "zoom": 140 } } }
```

Unrecognized top-level keys are ignored on read, so a future `version` field can
be added without invalidating existing stores.

`preset save` then mirrors the slot into the camera's slot of the same number, and
`preset clear` erases it, so a preset made here is visible to EMEET Studio and
survives a reboot. The mirror is best-effort and deliberately never fatal: it runs
*after* the local write, and a camera with no writable `hidraw` — the ordinary
state of one whose udev rule is not installed — saves locally and reports
`native: null`. `--local` skips the mirror entirely.

Save and load remain exact inverses, because that property comes from the local
file rather than from the camera.

Reads are defensive — a malformed store, an out-of-range slot, a half-written
entry, or a non-numeric value is dropped rather than rendered as a preset that
cannot be recalled. Writes go through a temp file and a rename so an interrupted
save cannot corrupt the store.

## Format enumeration

`pixy formats` lists what the camera advertises, which is `v4l2-ctl
--list-formats-ext` without needing `v4l-utils` installed. Three nested
index-driven ioctls, each terminated by `EINVAL` rather than by a count:

```
VIDIOC_ENUM_FMT → VIDIOC_ENUM_FRAMESIZES → VIDIOC_ENUM_FRAMEINTERVALS
```

*(observed)* On this camera: MJPG at 3840×2160@30, 2560×1440@30, 1920×1080@60/30,
1280×720@60/30 and below; YUYV only at 640×480 and 640×360. That asymmetry is why
the terminal preview is 640×480 and why `snapshot` asks for MJPEG.

**The union padding trap.** `v4l2_frmsizeenum` and `v4l2_frmivalenum` each end in a
union whose largest arm is bigger than the discrete arm being decoded. Padding for
the discrete arm alone under-allocates by 16 bytes, and the symptom is
`SystemError: buffer overflow` from `fcntl.ioctl` — which names neither the struct
nor the field. As with `v4l2_buffer`, the size is encoded in the ioctl number, so
`struct.calcsize(fmt) == (ioctl >> 16) & 0x3fff` catches it without hardware, and
the tests assert it for all three.

Setting a format is deliberately **not** implemented. A format is not a camera
setting — it belongs to whoever holds the stream, so writing one here would apply
to this process's own capture and vanish when it exits. The useful thing to ship is
the list: it tells you what to ask your meeting app for.

## Snapshots

`pixy snapshot` writes a full-resolution still, and the whole trick is that it
needs no image library. *(observed)* An MJPEG frame off this camera is a complete
JPEG file — SOI marker and all — so a 4K still is the mmap'd buffer written to disk
verbatim. No encoder, no decoder, nothing outside the standard library. The frame
is checked for the `ff d8` SOI before it is written, because a `.jpg` holding
something else is worse than no file at all.

Warmup frames are discarded first: the frames immediately after `STREAMON` are dark
or half-exposed, and unlike a preview a snapshot has no later frame to redeem it.

This takes the stream, so it fails with `EBUSY` during a call. That is reported as
data rather than worked around — there is no way to grab a frame from a stream
someone else holds.

## Permissions

UVC controls work as a normal user; `/dev/hidrawN` does not. Without a rule, the
mode readout is unavailable while pan/tilt/zoom keep working — which is exactly
what the panel reports rather than failing wholesale.

```
# /etc/udev/rules.d/70-emeet-pixy.rules
KERNEL=="hidraw*", ATTRS{idVendor}=="328f", ATTRS{idProduct}=="00c0", MODE="0660", TAG+="uaccess"
```

`EACCES` on the HID node is the most likely first-run failure, so the helper's
error text names the udev rule directly instead of saying "permission denied".

## If the firmware changes

The parts most likely to break, roughly in order: the `0x03` ambiguity and the
idle camera refusing mode writes (both read like bugs and may get fixed — and if
they are, `Model.modeWritable` starts dimming chips that would now work, so it is
the first thing to revisit), the inert preset-load command `0x18` (if a firmware
update makes it work, the synthesized UVC load is still the better path, because it
keeps the position readback honest), the dropped first write after idle, the
privacy → tracking transition being ignored, and the doubled length byte. The
command groups, the mode values, and the report id are the parts that feel
structural.

The capture path is the least likely to move, because none of it is EMEET's — the
struct layouts belong to the kernel's UAPI and the ioctl numbers are stable by
contract. The one device-specific assumption there is that a YUYV mode exists at
all; `_set_format` checks the pixel format it got back and fails loudly rather
than rendering whatever the driver substituted.

`scripts/pixy info` dumps the node paths, device identity, and the ranges the
driver reports, which is the right first command when something stops working.
`tests/test_pixy.py` encodes every claim above that can be checked without
hardware, so a change in behavior shows up as a named failing test rather than a
mysteriously inert camera.
