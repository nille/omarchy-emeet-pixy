# Marketplace submission

Answers for the [omarchyplugins.com](https://omarchyplugins.com/publish.html) submission form,
kept here so a resubmission or a listing correction does not have to reconstruct them.

Open the form: <https://github.com/HANCORE-linux/omarchy-plugin-marketplace/issues/new?template=submit-plugin.yml>

Title is prefilled as `[Plugin]: ` — complete it as `[Plugin]: EMEET PIXY`.

## Repository URL

```
https://github.com/nille/omarchy-emeet-pixy
```

## Category

**Hardware.** The form offers System and Widgets too, and both fit loosely — but every control here
is a specific USB device's, and someone browsing Hardware for webcam support is the person this is
for. `manifest.json` says `"category": "System"` for the *widget settings dialog*, which groups it
among the bar's system widgets; that is a different taxonomy and the mismatch is deliberate.

## Tags

Three is the maximum and submissions with more are rejected, so:

- **Bar** — what it is
- **Quickshell** — what it needs
- **Hyprland** — where it runs

Not **Media**: that reads as playback. Not **AI**: the camera does the tracking in firmware, and
claiming AI for passing a mode flag through would be the wrong kind of accurate.

## Suggest a missing tag

```
Webcam
```

Nothing in the list covers a camera, and Hardware is a category rather than a tag. Reusable —
anything for a capture device would want it.

## Maintainer notes

> Needs an EMEET PIXY (USB `328f:00c0`); the bar icon dims and the panel says so when it is absent,
> so an install without the hardware is harmless.
>
> No build step and no packages: the helper is a single Python 3 standard-library script, so
> `omarchy plugin add` — which never runs plugin code or install hooks — sets it up end to end.
> V4L2 controls go through raw `ioctl`s rather than `v4l-utils`.
>
> One root step, documented in the README and not performed by the plugin: a udev rule granting the
> active local user the camera's vendor HID interface (`TAG+="uaccess"`, `MODE="0660"`, matched on
> that one vendor and product id). It is what makes the privacy shutter and AI tracking controls
> work as a normal user. Pan, tilt and zoom go over UVC and need no special access, so without the
> rule the plugin degrades rather than breaks — and the panel names the missing permission instead
> of failing silently.
>
> `qt6-multimedia-ffmpeg` is needed for the video preview and is already present on Omarchy.
> Without it only the preview goes missing.
>
> Writes exactly two paths outside its own directory, both on explicit user action: its widget entry
> in `~/.config/omarchy/shell.json`, through Omarchy's own `setBarWidget` IPC rather than by editing
> the file, and framing and picture presets in `~/.local/state/omarchy-emeet-pixy/presets.json`.
> Some settings — the mirror, flip and autofocus options on the SETTINGS tab — live in the camera's
> firmware and persist across reboots by design, which the README says plainly.
>
> MIT. 704 tests: 405 Python (`python3 -m unittest discover -s tests`) and 299 QML
> (`QT_QPA_PLATFORM=offscreen /usr/lib/qt6/bin/qmltestrunner -input tests/qml`), both run in GitHub
> Actions on every pull request and every push to `main`. `omarchy plugin validate .` is clean on the
> `v1.1.0` tag.

## Checklist

All five apply as written:

- Public repository with installation and removal instructions — [Install](../README.md#install) and
  [Uninstall](../README.md#uninstall), the latter covering the presets file and the backup directory
  `plugin remove` leaves behind.
- License and external dependencies documented — MIT in [LICENSE](../LICENSE), dependencies under
  [Requirements](../README.md#requirements).
- Own the plugin and its preview assets — screenshots of this panel on this machine.
- Does not overwrite user configuration without consent — see the maintainer notes above.
- Approval is a listing, not a security review — understood.
