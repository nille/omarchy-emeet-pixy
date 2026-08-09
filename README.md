# EMEET PIXY for Omarchy

An EMEET PIXY webcam control panel for the Omarchy 4 bar.

Close the lens, switch AI tracking on or off, aim the camera, and recall framing
presets — from a bar widget that looks and behaves like the first-party ones.

![The bar widget among the other bar icons](docs/bar.png)

| Everything at once | Behind the cog | Lens closed |
| --- | --- | --- |
| ![The main panel: privacy switch, mode chips, live preview, jog pad, sliders, image controls, microphone and presets](docs/panel-main.png) | ![The advanced page: the rest of the image controls and named picture profiles](docs/panel-advanced.png) | ![Privacy mode: the preview collapsed to a closed-lens placeholder](docs/panel-privacy.png) |

## What it does

- **Privacy at a glance.** The bar glyph is a crossed-out webcam whenever the
  lens is closed, and it turns the theme's alert color. Right-click the icon to
  toggle privacy without opening anything. This is the one camera state with real
  consequences if you misread it, so it gets the unambiguous glyph and the loud
  color.
- **AI tracking.** Standard or Tracking, as a chip pair. Privacy is not a third
  chip — it is the hero switch, because it is the state you need to reach without
  reading the panel first.
- **Pan, tilt, and zoom.** A jog pad for aiming by feel, plus sliders that show
  the actual angle the camera is at. Positions are read back from the hardware, so
  the panel shows where the lens is pointing even after another app moved it.
- **A live preview, sized for framing.** A small video thumbnail sits above the
  jog pad and starts on its own when you open the panel, so aiming is one glance
  instead of a glance and a guess. Deliberately small: it is a framing aid, not a
  viewer. It stops the moment you close the panel or the lens, so nothing here
  keeps the camera light on — and there is a switch on the FRAMING header to turn
  it off for good when you would rather the camera stayed free for other apps.
- **Microphone, too.** Mute, volume, and a live input level meter for the camera's
  own mic. On a call it is usually the mic in use, so muting it belongs next to
  closing the lens rather than two panels away. The bar stays one glyph — the
  webcam — and reports mute in its tooltip rather than as a second icon.
- **Three framing presets.** Save a position, recall it later. Save and load are
  exact inverses.
- **Image controls that work during a call.** Brightness, contrast, saturation,
  sharpness, gamma and white balance in the panel, with hue, gain, exposure,
  focus and the rest behind a cog. These go over UVC control ioctls, not the
  capture stream, so they can be adjusted while a meeting client holds the
  camera — which is when a dark room actually needs fixing. Named picture
  profiles save and recall every control at once.
- **Honest about what it cannot know or do.** The camera can neither report nor
  change Standard vs Tracking while nothing is using it, so the chips dim out and
  say why instead of showing a confidently wrong toggle or taking a press that
  goes nowhere.
- **Keyboard driven.** The panel is fully navigable without a mouse.
- **Themed.** Colors, font, corner rounding, and border weights all come from the
  active Omarchy theme, so `omarchy theme set` restyles it live.

## Install

```bash
omarchy plugin add https://github.com/nille/omarchy-emeet-pixy --enable
```

`--enable` puts it straight into the bar's right section. Without it, add it later
via **Omarchy menu → Bar → Widgets**, or with:

```bash
omarchy plugin enable nille.emeet-pixy --section right
```

Then install the udev rule, which is what makes the mode controls work as a normal
user:

```bash
sudo tee /etc/udev/rules.d/70-emeet-pixy.rules >/dev/null <<'EOF'
KERNEL=="hidraw*", ATTRS{idVendor}=="328f", ATTRS{idProduct}=="00c0", MODE="0660", TAG+="uaccess"
EOF
sudo udevadm control --reload && sudo udevadm trigger
```

Replug the camera afterwards. Without the rule, pan/tilt/zoom still work — they go
over UVC, which needs no special access — but privacy and tracking do not, and the
panel will say why.

No build step, no compiled binary, and no Python packages to install. The helper
is a single Python 3 standard-library script, which is what lets `omarchy plugin
add` — which deliberately never runs plugin code or install hooks — set this up
end to end. The udev rule is the one step that needs root, so it stays a step you
run yourself rather than something a plugin install does behind your back.

### Uninstall

```bash
omarchy plugin remove nille.emeet-pixy
sudo rm -f /etc/udev/rules.d/70-emeet-pixy.rules
```

No daemon and no unit file. Two things live outside the plugin directory: its
entry in `~/.config/omarchy/shell.json`, removed by `plugin remove`, and your
presets in `~/.local/state/omarchy-emeet-pixy/presets.json`, which you can delete
by hand if you want them gone.

Privacy mode lives in the camera, not here — if you uninstall with the lens
closed, it stays closed.

### Requirements

- Omarchy 4 (the Quickshell bar)
- Python 3.9+ (already present on Omarchy)
- An EMEET PIXY (USB `328f:00c0`)
- The udev rule above, for the privacy and tracking controls
- `qt6-multimedia-ffmpeg`, for the panel's video preview (already present on
  Omarchy). Everything else works without it; only the thumbnail goes missing.

No `v4l-utils`, no `libusb`, nothing to compile. V4L2 controls are driven through
raw `ioctl`s from the standard library.

## Settings

| Key | Default | What it does |
| --- | --- | --- |
| `refreshIntervalSec` | `10` | How often to re-read camera state while the panel is open. |
| `ptzStep` | `5` | How far one jog-pad press or slider step moves the camera, in degrees. |
| `hideWhenAbsent` | `false` | Remove the bar icon when no camera is found, instead of showing a dimmed one. |
| `preview` | `true` | Show a live video preview in the panel. There is a switch for this on the panel's FRAMING header — it writes this same setting. See [The preview and other apps](#the-preview-and-other-apps). |

```json
{
  "id": "nille.emeet-pixy",
  "refreshIntervalSec": 15,
  "ptzStep": 10
}
```

Or from the CLI, without editing the file:

```bash
omarchy bar set nille.emeet-pixy refreshIntervalSec 15 --json
omarchy bar set nille.emeet-pixy ptzStep 10 --json
omarchy bar set nille.emeet-pixy hideWhenAbsent true --json
omarchy bar set nille.emeet-pixy preview false --json
```

`--json` is what distinguishes the number `15` and the boolean `true` from the
strings `"15"` and `"true"`.

## Using it

### Mouse

| Action | Result |
| --- | --- |
| Left-click icon | Open the panel |
| Right-click icon | Toggle privacy |
| Middle-click icon | Recenter the camera |
| Scroll icon | Zoom |
| Privacy switch | Close or open the lens |
| Standard / Tracking chips | Set the control mode (dimmed unless the camera is in use) |
| Jog pad arrows | Pan and tilt |
| Center of the jog pad | Recenter |
| Click the preview | Recenter |
| Switch on the FRAMING header | Turn the preview off or on |
| Drag an image slider | Brightness, contrast, saturation, sharpness, gamma, white balance |
| Auto white balance switch | Hand the temperature back to the camera |
| Cog on the IMAGE header | Advanced controls and picture profiles |
| `󰦛` on the IMAGE header | Reset every image control to the driver's default |
| Click a profile row | Apply that picture |
| `×` on a profile row | Delete it |
| Mic button | Mute or unmute the microphone |
| Right-click the mic slider | Mute or unmute |
| Save on a preset row | Store the current framing |
| Click a filled preset row | Recall it |
| `×` on a preset row | Clear it |
| Scroll anywhere in the panel | Scroll the panel |

Scrolling always scrolls. The wheel deliberately does **not** adjust the slider
under the cursor: a gesture aimed at reaching the presets used to land on the pan
slider and swing the camera instead. Sliders are adjusted by dragging them, by
`h`/`l` on the focused row, or with the arrow keys.

### Keyboard

| Key | Result |
| --- | --- |
| `j` / `k` | Move the cursor |
| `h` / `l` | Adjust the slider under the cursor |
| `space` | Activate the row under the cursor |
| `p` | Privacy on/off |
| `t` | Tracking ⇄ Standard (only while the camera is in use) |
| `m` | Mute the microphone |
| `v` | Turn the preview off/on |
| `c` | Recenter |
| `i` | Open or close the advanced image view |
| `s` | Save the current framing into the preset under the cursor |
| `x` | Clear the preset under the cursor |
| `1` / `2` / `3` | Recall that preset |
| `r` | Re-read the camera |
| `Esc` | Close |

The jog pad is deliberately not a keyboard row: the arrow keys and `hjkl` are the
same binding in every Omarchy panel, so a 2D pad has no keys of its own to claim.
The pan and tilt sliders are the keyboard path — and they show the current angle,
which the pad cannot.

Inside the advanced image view the keys shift to what is on that page: `s` moves
to the profile name field instead of saving a framing preset, `x` deletes the
profile under the cursor, `Esc` backs out to the main panel rather than closing,
and `1`–`3` do nothing, because profiles are named rather than numbered. On an
image row `h`/`l` sweeps a slider, cycles a menu, or turns a switch off and on —
`l` on, `h` off, so the key that means "more" always means the same thing.

On the name row `Enter` puts the keyboard in the field and fills in a suggested
name if it is empty, and saves once there is one. It has to be both: the field
draws under the cursor without holding the keyboard, so without that first press
a typed name goes to the shortcuts — and the `i` in "Evening" closes the view.

While the name field has focus it owns every key, `j` and `h` included: they are
letters someone is typing. `Enter` saves and `Esc` hands focus back.

### Hyprland bindings

Everything is reachable over IPC, so you can control the camera without opening
the panel. Add to `~/.config/hypr/bindings.conf`:

```
bind = SUPER SHIFT, C, exec, quickshell -p $OMARCHY_PATH/shell ipc call nille.emeet-pixy privacyToggle
bind = SUPER ALT,   C, exec, quickshell -p $OMARCHY_PATH/shell ipc call nille.emeet-pixy toggle
bind = SUPER SHIFT, M, exec, quickshell -p $OMARCHY_PATH/shell ipc call nille.emeet-pixy micToggle
```

Privacy and mute are the two worth binding: both are faster than reaching for the
panel, and both are things you want mid-sentence. Privacy works whether or not
anything is currently using the camera.

Available calls: `open`, `close`, `show`, `hide`, `toggle`, `privacyToggle`,
`privacyOn`, `privacyOff`, `tracking`, `standard`, `pan <degrees>`,
`tilt <degrees>`, `nudge <left|right|up|down>`, `zoom <100-150>`, `home`,
`preset <1-3>`, `micToggle`, `micOn`, `micOff`, `micVolume <0-100>`,
`previewToggle`, `previewOn`, `previewOff`, `image <key> <value>`, `imageReset`,
`profile <name>`, `refresh`, `state`.

`micOn` and `micOff` are named for the microphone, not for muting: `micOff` mutes.

`tracking` and `standard` do nothing while the camera is idle, for the reason in
[How it works](#how-it-works): the firmware would discard the write. They are
still worth binding — during a call, which is when switching tracking is actually
wanted, they work. `privacyOn` / `privacyOff` have no such restriction.

`image` and `profile` are worth binding for the same reason privacy is — they work
mid-call, with the camera held by something else:

```
bind = SUPER SHIFT, B, exec, quickshell -p $OMARCHY_PATH/shell ipc call nille.emeet-pixy image brightness 200
bind = SUPER SHIFT, P, exec, quickshell -p $OMARCHY_PATH/shell ipc call nille.emeet-pixy profile "Evening call"
```

`image` takes the helper's own key names, so a keybinding and the CLI spell the
same control the same way, and it works before the panel has ever been opened —
the value goes straight to the helper, which knows the real range and clamps.

`previewOn`/`previewOff`/`previewToggle` write the persistent `preview` setting,
the same one the panel switch and the widget settings dialog use — so `previewOff`
bound to a key is a real off switch, not something that comes back at the next
shell restart.

`state` reports `micPresent`, `micMuted`, `micVolume`, `preview`, and
`previewActive` alongside the camera fields. The last two are different questions:
`preview` is the setting, `previewActive` is whether an image is on screen right
now. A preview that is enabled but blocked by another app is `true` and `false`.

It also reports `image` as values keyed by control name, and `imageProfiles` as the
saved names. Just the values, not the whole payload — a script asking for the state
wants "what is brightness", and `pixy image` is where the ranges and menu options
live. `image` is empty until the panel has read the controls at least once.

## Image controls

The **IMAGE** section holds the six controls worth reaching for: brightness,
contrast, saturation, sharpness, gamma, and white balance behind its auto switch.
The header shows what has been changed (`Brightness, contrast`, or `Default`), a
reset, and a cog.

**These work while another app has the camera.** That is the whole reason they are
here rather than left to `v4l2-ctl`. Image settings travel over UVC control
ioctls, which are unrelated to the capture stream — so unlike the preview, nothing
about adjusting the picture takes anything away from a call. Fixing a dark room is
something you discover you need *during* the call, with the camera held by a
meeting client, which is exactly when a generic camera tool is least convenient to
go find.

Nothing here has a fixed table of controls. The helper reads the real names,
ranges, types and auto flags off the driver and the panel renders whatever comes
back, so a firmware that drops a control or reports a different range needs no
change on this side. Raw values are shown as a percentage of their range, because
`128` out of a `0..255` the driver never mentions is not information — except
where the number means something on its own, like white balance in kelvin.

### Behind the cog

Hue, gain, auto exposure and exposure time, autofocus and focus, power line
frequency, and backlight compensation. Split off rather than hidden: these are
either set-once (power line frequency depends on your mains, not your lighting) or
things you only touch when something specific is wrong.

The cog opens a page rather than a second popup, so the keyboard still has one
cursor over one visible list. `i` opens and closes it, `Esc` backs out. The page
reads top to bottom the way `j` walks it: Back, the controls, the saved profiles,
then the name field.

### Picture profiles

Also behind the cog. A profile stores every control at once under a name you type,
and clicking it puts them all back.

Deliberately separate from the three framing presets, and stored under a different
key in the same file: a framing preset recalls pan, tilt and zoom, and recalling
one must not quietly change how the picture looks. The two are different kinds of
thing that happen to both be called "presets" in camera software.

### Auto switches hold their manual partner

White balance, exposure and focus each have an auto, and while an auto is on the
driver marks its manual partner *inactive* and refuses writes to it. The panel
dims that row and says which switch is holding it rather than offering a slider
that silently does nothing.

That interlock is why every adjustment goes out as one batched call: turning auto
white balance off and setting a temperature are a single write, ordered so the
switch releases before the value lands. Two separate calls race the driver and the
second one gets refused about half the time.

A held control also keeps whatever value you last set by hand. Turn auto white
balance off, set 3200 K, turn it back on, and the driver still reports 3200
against a default of 5000 — flagged inactive, because the camera is choosing the
temperature now. So "changed from default" and "in effect" are different
questions, and the header answers the second one: a held row is skipped when
deciding whether the picture reads as `Default`, which is what keeps Reset from
offering to undo a setting that is not doing anything.

Profiles save held values too, and they come back as values — inert until you turn
that auto off. Refusing to store them would make a profile lossy in a way that is
invisible until you recall it.

Reset returns everything to the driver's own defaults, with one exception: power
line frequency is left alone, because the right value is a property of the room
rather than of the picture.

## The microphone

The PIXY has a microphone, and it is a plain PipeWire source — no vendor protocol
involved, nothing for the helper to do. So the mic section is volume, mute, and a
live level meter, driven straight through PipeWire.

It controls **this camera's** microphone specifically, not the system default. That
distinction is the whole difficulty: a webcam is rarely the default source, so a
mic control that took the default would quietly drive the laptop's built-in array
instead, and muting it would look like it had worked.

Selecting the right node is less obvious than it sounds. The PIXY publishes *two*
PipeWire nodes with the nickname `EMEET PIXY` — the audio source and the V4L2
camera — and the camera's node is called `v4l2_input`, so matching names for
"input" or "source" catches both. The microphone is the one with an `audio`
interface; that is what the panel keys on. See `isPixyMic` in `Model.js`.

The level meter costs a real PipeWire stream, so it runs only while the panel is
open and only while the mic is unmuted. A meter bouncing under a muted slider would
say the opposite of the truth.

If the camera has no microphone on the graph, the section is hidden rather than
greyed out, and `j`/`k` skips it — a disabled mic row on hardware that has no mic
is a permanent lie about what the device can do.

### Why the bar shows no mic indicator

The bar is one glyph — the webcam — whatever the mic is doing. Mute shows up in the
hover tooltip, in the panel's MICROPHONE section, and over IPC, but not as a second
icon on the bar.

Two other designs were built and removed. A small badge in the corner of the webcam
glyph is illegible: the slot is 27×27 with a 16px optical canvas, so a badge lands
around 8px, which is four grey pixels sitting on the webcam's own light-filled base
— a smudge, not an icon. A separate crossed-out mic glyph beside the webcam was
legible but made one bar entry two buttons wide, and the bar centres its open-panel
mark on the whole entry: the underline meaning "this panel is open" then landed
between the glyphs, on the mic, the one button that does not open it. A widget can
tell the bar how *long* that mark is but not where to put it, so there was no way
to keep both the second glyph and a correct underline.

Widening a camera widget's slot to carry a secondary state, and costing the primary
state its own mark, is the wrong trade. One slot, one glyph, one meaning.

## The preview and other apps

Exactly one process at a time can hold a V4L2 capture stream. That is a kernel
constraint, not a policy, and it cuts both ways: another app streaming makes the
preview fail, and the preview streaming makes the *other app* fail.

The important half is the second one. Nothing else in this widget needs the
stream — pan, tilt, and zoom go over UVC control ioctls, privacy and tracking go
over vendor HID, and none of that cares who is capturing. So the preview is the
only feature that can take something away from a video call, and it is the only
one that yields.

What happens in practice:

- **An app is already using the camera when you open the panel.** No preview. The
  frame shows who has it (`In use by zoom`) and the controls work normally.
- **An app starts using the camera while the panel is open.** The panel notices
  within about a second and releases the camera. The other app gets its video.
- **The other app finishes.** The preview comes back on the next refresh.

Releasing quickly matters more than resuming quickly, so those are polled
differently: a cheap `pixy holders` call runs every 1.5 s while the preview holds
the camera, and the resume rides the ordinary `refreshIntervalSec`. Being slow to
get out of the way costs someone their video; being slow to resume costs a few
seconds of placeholder.

### Turning the preview off

There is a switch on the panel's **FRAMING** header, next to an eye. Flip it and
the frame collapses; every control keeps working. Or press `v`, or bind
`previewOff` to a key.

The switch is persistent. It writes the `preview` setting — the same value the
widget settings dialog shows and the same value the CLI sets:

```bash
omarchy bar set nille.emeet-pixy preview false --json
```

That is deliberate. A preview turned off before a call is turned off *because of*
the call, and a session-only toggle would quietly come back at the next shell
restart, which is exactly when you would stop watching for it. One value with one
meaning also means the panel switch and the settings dialog can never disagree.

Persisting means a round trip: the write goes out to `omarchy-shell`, which
rewrites `shell.json` and hands the new settings back. The switch moves
immediately anyway — it shows what you clicked and reconciles when the write lands
— because a control that sits still for a beat reads as broken.

#### Why you might want it off

Yielding is reactive, so it cannot cover everything. An app that opens the device
and immediately tries to stream — `ffmpeg -f v4l2` does exactly this — gets its
answer in microseconds and exits before any event loop could react. Apps that
hold the device open while negotiating, which is what browsers and meeting clients
do, are handled fine.

With the preview off the panel never opens the capture device at all, so there is
nothing to yield and nothing to race. The widget stays a complete camera
controller during a meeting, which is arguably when you want it most.

## The helper CLI

`scripts/pixy` is usable on its own, and prints JSON on stdout for every
subcommand:

```bash
scripts/pixy state                          # mode, position, zoom, presets
scripts/pixy info                           # nodes, identity, driver ranges
scripts/pixy holders                        # who has the capture stream
scripts/pixy mode privacy                   # standard | tracking | privacy
scripts/pixy privacy                        # toggle privacy
scripts/pixy ptz --pan 30 --tilt -10        # absolute, in degrees
scripts/pixy ptz --nudge right --step 5     # relative
scripts/pixy ptz --home                     # recenter
scripts/pixy zoom 130                       # 100..150
scripts/pixy preset save 1
scripts/pixy preset load 1
scripts/pixy preset clear 1
scripts/pixy image                          # every control, with ranges and flags
scripts/pixy image --set brightness=200     # repeatable; one batch, correctly ordered
scripts/pixy image --reset                  # back to the driver's defaults
scripts/pixy profile save "Evening call"    # stores every image control
scripts/pixy profile load "Evening call"
scripts/pixy profile list
scripts/pixy profile clear "Evening call"
scripts/pixy preview --text --blocks       # live preview, in the terminal
```

`image` and `profile` work while another app holds the capture stream — they are
control ioctls, not the stream. See [Image controls](#image-controls).

Several `--set` flags in one call is not just shorthand: the helper orders a batch
so an auto switch releases before its manual partner is written, which is what
makes this land rather than getting refused.

```bash
scripts/pixy image --set whiteBalanceAuto=0 --set whiteBalance=3200   # works
scripts/pixy image --set whiteBalanceAuto=0                           # then...
scripts/pixy image --set whiteBalance=3200                            # ...races the driver
```

`--curated` limits the reply to the controls the panel shows in its main section.
`--force` applies the assignments that parsed when others did not, instead of
refusing the whole call — and reports what it skipped as `warnings`.

`--reset` and `--set` compose, in one correctly ordered pass:

```bash
scripts/pixy image --reset --set brightness=160    # neutral, but brighter
```

Every reply carries the full readback, so one round trip both writes and refreshes.
That is not a convenience: the auto/manual `inactive` flags can only be known
*after* a write, so a caller that skipped the readback would not know whether its
value took effect.

`preview` is the one streaming subcommand: it prints one JSON object per line as
frames arrive rather than one object at exit, so a caller can render as it goes.
`--text` swaps the JSON for plain characters redrawn in place, which is the form
worth having at a prompt:

```bash
scripts/pixy preview --text --blocks --columns 80   # Ctrl-C to stop
scripts/pixy preview --text --halfblocks            # square pixels, more detail
scripts/pixy preview --frames 1 --warmup 5          # one settled frame, as JSON
```

It samples the YUYV luma plane directly — every second byte is brightness — which
is what keeps a video preview inside the standard-library-only rule with no JPEG
decoder involved. The panel's thumbnail does not use this path; it uses
QtMultimedia for real video. This one exists for a terminal, and for checking the
camera works without opening anything.

Every subcommand exits 0 and reports failure as `{"ok": false, "error": ...}`,
including when the camera is unplugged. The panel is a UI, not an error handler:
it should never have to tell "the helper crashed" apart from "the camera is
unplugged", so both arrive as data.

`scripts/pixy info` is the right first command when something stops working — it
prints which nodes were found, whether the HID node is readable and writable, and
the ranges the driver reports.

`scripts/pixy holders` is a deliberate subset of `state`: the stream-holder fields
and nothing else. It exists because `state` costs about 780 ms, nearly all of it
the HID mode query and its mandatory settle sleeps, while scanning `/proc` for
holders costs about 9 ms. The panel polls it to notice another app wanting the
camera quickly, and it is also the fastest way to answer "what is using my webcam"
by hand:

```bash
scripts/pixy holders   # {"streaming": true, "streamUsers": ["firefox"], ...}
```

`streaming` and `streamUsers` count *other* processes; `selfStreaming` is the
panel's own preview, reported separately because the two mean opposite things —
one is a reason to yield, the other is the thing being yielded.

Runs of `pixy` itself are not counted, with one exception. Reaching a control
ioctl means opening the video node, so while `pixy image` runs it looks exactly
like a video call to a `/proc` scan — and the panel spawns those constantly while
polling this, so it used to catch its own helpers and report `In use by python3`.
The exception is `pixy preview`, which genuinely does hold the stream: a preview
left running in a terminal is a real conflict and is reported as one.

Any copy of the helper counts as ours, not just the one being run. Installing the
plugin copies this tree into `~/.config/omarchy/plugins`, so running the command
above from the checkout while the panel polls from its installed copy means two
different files — and answering `In use by python3` there would be the same bug
from the other direction. The match is on the file's contents rather than the
process name, so an unrelated Python program capturing video is still reported.

## What it deliberately does not do

- **Mirror, flip, and auto-rotate.** Set-once settings, not something you reach
  for from a bar.
- **Audio DSP and gesture control.** The camera has both. Mic mute and volume are
  here because they are PipeWire, immediate, and needed mid-call; the camera's own
  noise suppression and AI voice modes are set-once vendor features. Gesture
  control in particular is a per-session preference that belongs in whatever app
  is using the camera.
- **Choosing a different microphone.** The mic section drives the PIXY's own mic
  and nothing else. Picking among inputs is what the bar's audio panel is for.
- **HID pan/tilt/zoom.** The camera supports it; using it desynchronizes the
  position readback permanently. See [docs/PROTOCOL.md](docs/PROTOCOL.md).
- **The camera's own preset slots.** They store positions in a coordinate space
  that does not match the one this panel drives, so presets are stored locally
  instead. Also in the protocol notes.

## Files

- `manifest.json` — plugin id, bar widget metadata, settings schema and defaults
- `Panel.qml` — bar glyph, popout, cursor model, IPC. Every control is a `qs.Ui`
  component, so nothing about the look is hardcoded here
- `Model.js` — pure functions: parsing, clamping, labels, argv building. No QML
  types, no state, no side effects, which is what makes it testable
- `scripts/pixy` — the helper CLI: V4L2 ioctls, vendor HID, preset and profile
  storage
- `docs/PROTOCOL.md` — the wire protocol, what was verified against hardware, and
  why several of the camera's features are unused
- `tests/test_pixy.py` — 287 unit tests over the helper
- `tests/qml/` — 164 QML tests: input routing, cursor arithmetic, and the
  `Model.js` functions that need a JS engine rather than Python
- `tests/harness/shell.qml` — standalone window for developing the panel without
  a running Omarchy shell, launched by `tests/harness/run`
- `preview.png` — composite of the screenshots above, at the repository root
  because that is where the plugin marketplace looks for a listing image

## How it works

The camera answers on two unrelated interfaces, and the helper uses each for what
it is good at. Pan, tilt, and zoom go over **UVC** (`/dev/videoN`), where they are
absolute and readable — so the panel shows a real position instead of
dead-reckoning from the moves it happens to have made. The Standard / Tracking /
Privacy mode has no UVC equivalent, so it goes over the **vendor HID** interface
(`/dev/hidrawN`) as 32-byte reports.

Pan and tilt travel the wire in arc-seconds (3600 to the degree) and are snapped
to a step boundary before writing, because an unsnapped value gets silently
rounded by the driver and the slider handle then jumps on the next refresh. Zoom's
100..150 is displayed as 1.00×..1.50×, which is what the number means.

Values are applied optimistically while you drag and reconciled from the hardware
shortly after — twice for pan and tilt, since a reading taken mid-sweep is not the
position the camera ends up at.

The panel's preview is QtMultimedia opening the same `/dev/videoN` node the helper
found, pinned to the smallest mode at or above 360 lines. Pinning is not an
optimization detail: left to itself Qt picks the camera's largest mode — 3840x2160
here — and spends real CPU decoding 4K frames to draw a thumbnail. Capture is
bound to "panel open, lens open, nobody else using it, and the setting on" rather
than started and stopped by hand, so there is no path where closing the panel
leaves the stream running.

Two details of that are load-bearing. The `Camera` lives inside a `Loader`, because
assigning `cameraDevice` opens the file descriptor for the object's lifetime
regardless of `active` — without the loader the bar would hold the camera from
startup with the panel closed. And the yielding is what keeps the preview from
breaking video calls; see
[The preview and other apps](#the-preview-and-other-apps).

The microphone is the one part of the widget that does not go through the helper at
all — it is PipeWire, so mute and volume are property writes. See
[The microphone](#the-microphone) for why picking the right node is the hard part.

One quirk is worth knowing about, because it is visible in the UI: **an idle
camera can neither report nor change whether tracking is on.** It answers the same
value for both Standard and Tracking until some app opens the video stream, and it
accepts a Standard/Tracking write in that state only to throw it away — verified
in both directions against the hardware, by setting one mode while idle and then
starting a stream to see which mode the camera was actually in.

So the panel dims both chips while the camera is idle and says why. That is a
change from an earlier version, which left them live: rather than guess at the
mode it showed neither chip as active, which was honest but read as a bug, and
pressing a chip then did nothing at all — the helper reported success because the
report was delivered, and the firmware discarded it. Turn the preview on, or join
a call, and the chips light up and work.

Privacy is exempt in both directions: it can be switched on *and* off on an idle
camera, and its state is always readable. That is what lets the hero switch and
the bar's right-click work when the camera is doing nothing, and it is why the
"needs a stream" guard deliberately does not cover it — gating it would let the
lens be closed and then not reopened, which is worse than the dead chip it was
meant to fix.

[docs/PROTOCOL.md](docs/PROTOCOL.md) has the full derivation, including which
findings came from hardware testing rather than documentation.

## Verify

```bash
omarchy plugin validate .
python3 -m unittest discover -s tests
QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml
```

`plugin validate` runs the same manifest checks the shell enforces at load time,
so it fails before an install does. The unit tests never touch a real camera —
discovery and device access are both substituted, so the suite runs identically
with the camera unplugged. The same goes for the QML tests: no camera, no
microphone, and no PipeWire connection.

Two things about that last command. The path is spelled out because
`/usr/bin/qmltestrunner` on Arch belongs to `qt5-declarative` and **exits silently
with status 1** on Qt6 QML — no output, no error, nothing that looks like a
failure. The Qt6 binary under `/usr/lib/qt6/bin` is the one that works. And
`QT_QPA_PLATFORM=offscreen` is what lets it run without a display.

The QML tests cover the three things Python cannot reach: mouse and wheel routing,
where the correct answer is counter-intuitive enough to be worth pinning; the
`Model.js` functions that need a real JS engine; and the panel's own cursor
arithmetic, where the row layout is computed from lists whose lengths come from the
driver and the user. `Model.js` is QML JavaScript, so `qmltestrunner` tests it
directly rather than pulling in Node and breaking the standard-library-only story.

Two of those files (`tst_preview_pending.qml`, `tst_advanced_cursor.qml`) replicate
a property block from `Panel.qml` rather than instantiating the panel, which needs a
bar, a PipeWire graph and a camera to answer. They pin the logic, not the wiring;
each says so at the top. The wiring is covered live instead, by an offscreen harness
run against the real device.

To work on the panel itself without installing it, the harness stands in for the
bar:

```bash
tests/harness/run
```

That wrapper is not a convenience. `quickshell -p tests/harness/shell.qml` fails
on its own with `module "qs.Ui" is not installed`: the shell's components import
as `qs.Ui` and `qs.Commons`, which resolve relative to the root QML file's
directory, so they only load from a file sitting beside a `qs/` directory. No
`QML_IMPORT_PATH` pointing at the shell fixes it, because the missing piece is
that `qs/` level itself. The wrapper builds it in a temp directory and sets
`PIXY_DIR`, which points the panel's helper at the working tree — without it the
harness drives whatever you last installed, which is rarely what you want while
editing.

The shim is built at run time rather than committed because `omarchy plugin add`
and `plugin validate` both refuse symlinks anywhere inside a plugin folder. That
same restriction means a working tree has to be *copied* into
`~/.config/omarchy/plugins/` rather than linked — which the harness exists to
avoid needing at all.

## Contributing

Issues and pull requests are welcome. Three things worth knowing before you start:

- **This was reverse-engineered against one camera, on one firmware.** There is no
  vendor specification. Everything in `docs/PROTOCOL.md` marked *(observed)* is
  something this device actually did, repeatedly — not something documented
  anywhere. If your PIXY behaves differently, that report is the most useful thing
  you can send, especially the output of `scripts/pixy info` and whether the mode
  readout works on an idle camera.
- **Keep logic out of QML.** Parsing, clamping, and argv building belong in
  `Model.js` as pure functions, which is what makes them testable without a
  running shell. `Panel.qml` should stay presentation.
- **The helper stays standard-library only.** No pip packages, no `v4l2-ctl`, no
  build step. That constraint is what makes `omarchy plugin add` able to install
  this without running any code.

Run all three commands from [Verify](#verify) before opening a PR. Tests must not
require a camera. Please do not hardcode colors, fonts, or spacing — every value
comes from the active Omarchy theme via `qs.Ui`, and a literal breaks theming for
everyone else.

## License

MIT. See [LICENSE](LICENSE).

Not affiliated with or endorsed by EMEET. Reverse-engineered from observation of
the device's own behavior, for interoperability on Linux.
