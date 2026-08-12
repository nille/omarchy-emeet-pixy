"""Unit tests for scripts/pixy.

Nothing here touches a real camera. Every test either exercises a pure function
or substitutes a fake for the two things that reach hardware — `find_video` /
`find_hidraw` for discovery, and the `Camera` / HID transport for access — so the
suite runs identically with the camera unplugged, on CI, and on a machine that
has never seen a PIXY.

Also asserted throughout: every subcommand returns a JSON-serializable dict and
`main()` exits 0. That is the helper's contract with the panel, and it is the one
thing whose violation would show up as a blank widget rather than an error.
"""

from __future__ import annotations

import errno
import importlib.util
import io
import json
import os
import pathlib
import shutil
import struct
import sys
import tempfile
import threading
import unittest
from contextlib import ExitStack, redirect_stdout
from unittest import mock

HELPER = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "scripts", "pixy")


def load_helper():
    """Import scripts/pixy, which has no .py suffix, as a module."""
    spec = importlib.util.spec_from_loader(
        "pixy", importlib.machinery.SourceFileLoader("pixy", HELPER)
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


pixy = load_helper()


class FakeCamera:
    """Stand-in for the UVC surface.

    Records every write so tests can assert on what would have reached the
    driver, and returns whatever the test seeded — including None, which is how
    a real camera reports a control it does not implement.
    """

    def __init__(self, values=None, specs=None, reject=(), missing=(), menus=None,
                 holds=None):
        self.node = "/dev/videoTEST"
        self.fd = 99
        self.values = dict(values or {})
        self.specs = dict(specs or {})
        self.reject = set(reject)
        self.missing = set(missing)
        self.menus = dict(menus or {})
        # {holder_cid: (held_cid, off_value)} — reproduces the auto/manual
        # interlock: while the holder is not at `off_value`, the held control
        # reads inactive and refuses writes, exactly as the driver behaves.
        self.holds = dict(holds or {})
        self.writes = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return None

    def held(self, cid):
        for holder, (target, off) in self.holds.items():
            if target == cid and self.values.get(holder) != off:
                return True
        return False

    def spec(self, cid):
        if cid in self.missing:
            return None
        spec = dict(self.specs.get(cid, {"min": -540000, "max": 540000, "step": 3600,
                                         "default": 0, "inactive": False}))
        spec.setdefault("type", "integer")
        if self.held(cid):
            spec["inactive"] = True
        return spec

    def get(self, cid):
        return self.values.get(cid)

    def set(self, cid, value):
        if cid in self.reject or self.held(cid):
            return False
        self.writes.append((cid, value))
        self.values[cid] = value
        return True

    def menu(self, cid, lo, hi):
        return self.menus.get(cid, [])


def ptz_specs():
    """Ranges matching the real hardware: ±150° pan, ±90° tilt, 100..150 zoom."""
    return {
        pixy.CID_PAN_ABSOLUTE: {"min": -540000, "max": 540000, "step": 3600, "default": 0, "inactive": False},
        pixy.CID_TILT_ABSOLUTE: {"min": -324000, "max": 324000, "step": 3600, "default": 0, "inactive": False},
        pixy.CID_ZOOM_ABSOLUTE: {"min": 100, "max": 150, "step": 1, "default": 100, "inactive": False},
    }


def cid(key):
    return pixy.IMAGE_BY_KEY[key]["cid"]


def image_camera(**overrides):
    """A FakeCamera wired like the real PIXY's image controls.

    Ranges, defaults and the three auto/manual interlocks are the ones measured
    off the hardware, so a test that passes here is making a claim about the
    actual device rather than about a convenient fiction.
    """
    ranges = {
        "brightness": (0, 255, 128), "contrast": (0, 255, 128),
        "saturation": (0, 255, 128), "sharpness": (0, 255, 128),
        "gamma": (0, 255, 128), "hue": (0, 255, 128),
        "whiteBalanceAuto": (0, 1, 1), "whiteBalance": (2300, 7500, 5000),
        "gain": (0, 100, 0), "autoExposure": (0, 3, 3),
        "exposure": (1, 5000, 300), "focusAuto": (0, 1, 1),
        "focus": (0, 1023, 192), "powerLineFrequency": (0, 2, 2),
        "backlightCompensation": (1, 2, 1),
    }
    booleans = {"whiteBalanceAuto", "focusAuto"}
    specs, values = {}, {}
    for key, (lo, hi, default) in ranges.items():
        kind = "menu" if key in ("autoExposure", "powerLineFrequency") else (
            "boolean" if key in booleans else "integer")
        specs[cid(key)] = {"min": lo, "max": hi, "step": 1, "default": default,
                           "inactive": False, "type": kind}
        values[cid(key)] = default
    kwargs = {
        "specs": specs,
        "values": values,
        "menus": {
            # Auto Exposure's missing indices 0 and 2 are the point: it claims
            # [0..3] and offers two options.
            cid("autoExposure"): [{"value": 1, "label": "Manual Mode"},
                                  {"value": 3, "label": "Aperture Priority Mode"}],
            cid("powerLineFrequency"): [{"value": 0, "label": "Disabled"},
                                        {"value": 1, "label": "50 Hz"},
                                        {"value": 2, "label": "60 Hz"}],
        },
        "holds": {
            cid("whiteBalanceAuto"): (cid("whiteBalance"), 0),
            cid("focusAuto"): (cid("focus"), 0),
            # Manual Mode is 1 here, not 0 — see IMAGE_CONTROLS.
            cid("autoExposure"): (cid("exposure"), 1),
        },
    }
    kwargs.update(overrides)
    return FakeCamera(**kwargs)


def args_for(argv):
    """Parse argv the way main() does, so tests exercise the real parser."""
    return pixy.build_parser().parse_args(argv)


# ---------------------------------------------------------------- ioctl encoding


class IoctlEncodingTests(unittest.TestCase):
    """The ioctl numbers are hand-encoded, so pin them against known values.

    A wrong direction bit or size is the single easiest mistake to make here and
    shows up as a bewildering ENOTTY at runtime, not as a wrong value.
    """

    def test_querycap_is_read_only(self):
        # QUERYCAP only reads; encoding it as read/write yields ENOTTY.
        self.assertEqual(pixy.VIDIOC_QUERYCAP, 0x80685600)

    def test_queryctrl_is_read_write(self):
        self.assertEqual(pixy.VIDIOC_QUERYCTRL, 0xC0445624)

    def test_g_ctrl_and_s_ctrl(self):
        self.assertEqual(pixy.VIDIOC_G_CTRL, 0xC008561B)
        self.assertEqual(pixy.VIDIOC_S_CTRL, 0xC008561C)

    def test_struct_sizes_match_the_encoded_sizes(self):
        # The size baked into each ioctl number must equal the struct actually
        # packed, or the kernel reads past the buffer.
        self.assertEqual(struct.calcsize(pixy.QUERYCTRL_FORMAT), pixy.QUERYCTRL_SIZE)
        self.assertEqual(struct.calcsize(pixy.CTRL_FORMAT), pixy.CTRL_SIZE)


# ---------------------------------------------------------------- HID framing


class BuildReportTests(unittest.TestCase):
    def test_pads_to_report_size(self):
        report = pixy.build_report([0x09, 0x01, 0x01, 0x01])
        self.assertEqual(len(report), pixy.REPORT_SIZE)
        self.assertEqual(report[:4], b"\x09\x01\x01\x01")
        self.assertEqual(report[4:], bytes(pixy.REPORT_SIZE - 4))

    def test_exact_length_payload_is_not_truncated(self):
        payload = [0x09] + [0x11] * (pixy.REPORT_SIZE - 1)
        self.assertEqual(len(pixy.build_report(payload)), pixy.REPORT_SIZE)

    def test_rejects_wrong_report_id(self):
        with self.assertRaises(ValueError):
            pixy.build_report([0x08, 0x01])

    def test_rejects_empty_payload(self):
        with self.assertRaises(ValueError):
            pixy.build_report([])

    def test_rejects_oversized_payload(self):
        with self.assertRaises(ValueError):
            pixy.build_report([0x09] * (pixy.REPORT_SIZE + 1))

    def test_rejects_out_of_range_bytes(self):
        with self.assertRaises(ValueError):
            pixy.build_report([0x09, 256])
        with self.assertRaises(ValueError):
            pixy.build_report([0x09, -1])

    def test_rejects_non_integer_bytes(self):
        with self.assertRaises(ValueError):
            pixy.build_report([0x09, "01"])


class ModeReportTests(unittest.TestCase):
    def test_every_mode_encodes_its_documented_value(self):
        self.assertEqual(pixy.MODE_VALUES, {"standard": 0x00, "tracking": 0x01, "privacy": 0x02})

    def test_mode_names_round_trip(self):
        for name, value in pixy.MODE_VALUES.items():
            self.assertEqual(pixy.MODE_NAMES[value], name)

    def test_set_then_query(self):
        # A mode change is a set followed by the query that commits it.
        reports = pixy.mode_reports("privacy")
        self.assertEqual(len(reports), 2)
        self.assertEqual(
            reports[0][:9], bytes([0x09, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x02])
        )
        self.assertEqual(reports[1][:4], bytes([0x09, 0x01, 0x01, 0x01]))

    def test_each_mode_differs_only_in_the_value_byte(self):
        standard = pixy.mode_reports("standard")[0]
        tracking = pixy.mode_reports("tracking")[0]
        self.assertEqual(standard[:8], tracking[:8])
        self.assertEqual((standard[8], tracking[8]), (0x00, 0x01))

    def test_reports_are_full_size(self):
        for mode in pixy.MODE_VALUES:
            for report in pixy.mode_reports(mode):
                self.assertEqual(len(report), pixy.REPORT_SIZE)


class ReadModeTests(unittest.TestCase):
    """The 0x03 readback is the subtle part, so it gets its own tests.

    An idle camera answers 0x03 for both Standard and Tracking. Privacy answers
    0x02 whether or not anything holds the stream — which is what makes the
    privacy toggle a real toggle instead of a coin flip.
    """

    def reply(self, raw):
        return bytes([0x09, 0x01, 0x01, 0x01, 0x00, 0x01, 0x00, 0x01, raw])

    def test_decodes_each_unambiguous_value(self):
        for raw, expected in ((0x00, "standard"), (0x01, "tracking"), (0x02, "privacy")):
            with mock.patch.object(pixy, "query", return_value=self.reply(raw)):
                self.assertEqual(pixy.read_mode("/dev/hidrawTEST"), (expected, raw))

    def test_privacy_is_readable_on_an_idle_camera(self):
        # The regression this guards: discarding the raw byte when not streaming
        # threw away an unambiguous 0x02 and made the toggle turn privacy on
        # twice in a row.
        with mock.patch.object(pixy, "query", return_value=self.reply(0x02)):
            self.assertEqual(pixy.read_mode("/dev/hidrawTEST", streaming=False), ("privacy", 0x02))

    def test_ambiguous_value_reports_unknown_but_keeps_the_raw_byte(self):
        with mock.patch.object(pixy, "query", return_value=self.reply(0x03)):
            mode, raw = pixy.read_mode("/dev/hidrawTEST", streaming=False)
        self.assertIsNone(mode)
        self.assertEqual(raw, 0x03)

    def test_no_reply_yields_no_raw_byte(self):
        with mock.patch.object(pixy, "query", return_value=None):
            self.assertEqual(pixy.read_mode("/dev/hidrawTEST"), (None, None))

    def test_short_reply_is_not_decoded(self):
        with mock.patch.object(pixy, "query", return_value=bytes([0x09, 0x01])):
            self.assertEqual(pixy.read_mode("/dev/hidrawTEST"), (None, None))

    def test_streaming_flag_does_not_change_the_decode(self):
        # It exists to explain *why* a mode is unknown, never to gate it.
        with mock.patch.object(pixy, "query", return_value=self.reply(0x01)):
            self.assertEqual(
                pixy.read_mode("/dev/hidrawTEST", streaming=True),
                pixy.read_mode("/dev/hidrawTEST", streaming=False),
            )


# ---------------------------------------------------------------- vendor features


def vendor_reply(payload, *values):
    """A reply that echoes a request's group and command bytes, then values.

    Built the way the camera actually answers — echoing bytes 1..3 — because
    `query` matches on those, and a fake that omitted them would pass tests
    against code that could never work on hardware.
    """
    head = list(payload[:4])
    body = list(values)
    return bytes(head + [0x00, len(body), 0x00, len(body)] + body)


class VendorReportTests(unittest.TestCase):
    """The set reports, checked byte for byte against the packet captures.

    These are the bytes that reach the hardware, and a wrong one is either a
    no-op or something undocumented — so each is pinned literally rather than
    round-tripped through the same constants that built it.
    """

    def test_audio_modes_encode_their_captured_values(self):
        self.assertEqual(
            pixy.AUDIO_MODES, {"noise-cancel": 0x01, "live": 0x02, "original": 0x03}
        )

    def test_audio_names_round_trip(self):
        for name, value in pixy.AUDIO_MODES.items():
            self.assertEqual(pixy.AUDIO_NAMES[value], name)

    def test_audio_report_matches_the_capture(self):
        report = pixy.audio_report("live")[0]
        self.assertEqual(
            report[:9], bytes([0x09, 0x05, 0x00, 0x03, 0x00, 0x01, 0x00, 0x01, 0x02])
        )

    def test_gesture_report_matches_the_capture(self):
        on = pixy.gesture_report(True)[0]
        off = pixy.gesture_report(False)[0]
        self.assertEqual(
            on[:10], bytes([0x09, 0x04, 0x02, 0x00, 0x00, 0x02, 0x00, 0x02, 0x02, 0x01])
        )
        # Only the value byte differs, which is what makes this a toggle.
        self.assertEqual(on[:9], off[:9])
        self.assertEqual(off[9], 0x00)

    def test_feature_ids_are_the_three_confirmed_toggles(self):
        # Manual rotation is deliberately absent: the vendor app's rotate buttons
        # produce no USB traffic, so rotation is a host-side transform and not a
        # camera setting. A fourth id here would be an invented command.
        self.assertEqual(
            pixy.FEATURE_IDS,
            {"flipHorizontal": 0x01, "flipVertical": 0x02, "autoRotate": 0x04},
        )

    def test_feature_report_addresses_the_right_feature(self):
        for key, fid in pixy.FEATURE_IDS.items():
            report = pixy.feature_report(key, True)[0]
            self.assertEqual(
                report[:10],
                bytes([0x09, 0x04, 0x00, 0x08, 0x00, 0x02, 0x00, 0x02, fid, 0x01]),
                key,
            )

    def test_metering_sends_a_staged_write_then_a_commit(self):
        reports = pixy.metering_report("face")
        self.assertEqual(len(reports), 2)
        self.assertEqual(reports[0][:4], bytes([0x09, 0x04, 0x00, 0x01]))
        self.assertEqual(reports[1][:4], bytes([0x09, 0x04, 0x00, 0x03]))
        # Both carry the same payload; the camera does not act on the first alone.
        self.assertEqual(reports[0][4:13], reports[1][4:13])

    def test_metering_area_carries_its_coordinates(self):
        report = pixy.metering_report("area", 0x0F, 0x20)[0]
        self.assertEqual(
            report[:13],
            bytes([0x09, 0x04, 0x00, 0x01, 0x00, 0x05, 0x00, 0x05,
                   0x02, 0x0F, 0x20, 0x7F, 0x7F]),
        )

    def test_native_preset_save_sends_no_coordinates(self):
        # The camera stores its own current position. Sending coordinates would
        # mean inventing a payload the vendor app never sends.
        report = pixy.native_preset_report(2, saved=True)[0]
        self.assertEqual(
            report[:10], bytes([0x09, 0x03, 0x01, 0x15, 0x00, 0x02, 0x00, 0x02, 2, 0x01])
        )

    def test_native_preset_clear_differs_only_in_the_enable_byte(self):
        save = pixy.native_preset_report(3, saved=True)[0]
        clear = pixy.native_preset_report(3, saved=False)[0]
        self.assertEqual(save[:9], clear[:9])
        self.assertEqual((save[9], clear[9]), (0x01, 0x00))

    def test_autoprivacy_seconds_are_little_endian(self):
        report = pixy.autoprivacy_report(300)[0]
        self.assertEqual(report[:8], bytes([0x09, 0x02, 0x01, 0x00, 0x00, 0x04, 0x00, 0x04]))
        self.assertEqual(report[8:12], (300).to_bytes(4, "little"))

    def test_autoprivacy_zero_disables_rather_than_erroring(self):
        report = pixy.autoprivacy_report(0)[0]
        self.assertEqual(report[8:12], bytes(4))


class QueryMatchingTests(unittest.TestCase):
    """What `query` accepts as an answer, exercised through a fake hidraw fd.

    Matching is the subtle part. A group holds several commands, so matching on
    the group alone accepts one command's acknowledgement as another's answer —
    which is how a working setter reported itself as failed.
    """

    def run_query(self, payload, replies):
        """Drive query() against a scripted sequence of reads."""
        pending = list(replies)

        def fake_read(fd, size):
            if not pending:
                raise BlockingIOError
            reply = pending.pop(0)
            if reply is None:
                raise BlockingIOError
            return reply

        with mock.patch.object(pixy.os, "open", return_value=7), \
             mock.patch.object(pixy.os, "close"), \
             mock.patch.object(pixy.os, "write"), \
             mock.patch.object(pixy.os, "read", side_effect=fake_read), \
             mock.patch.object(pixy, "drain"), \
             mock.patch.object(pixy.select, "select",
                               side_effect=lambda r, w, x, t: (list(r), [], [])), \
             mock.patch.object(pixy.time, "sleep"):
            return pixy.query("/dev/hidrawTEST", payload)

    def test_accepts_a_reply_echoing_the_command(self):
        payload = [0x09, 0x05, 0x00, 0x04]
        reply = vendor_reply(payload, 0x02)
        self.assertEqual(self.run_query(payload, [reply]), reply)

    def test_rejects_an_acknowledgement_of_a_different_command_in_the_same_group(self):
        # The bug this pins: `09 05 00 03` (set audio) acknowledges with 0x20 where
        # the value belongs. Accepting it as the answer to `09 05 00 04` (read
        # audio) decodes an ack byte as a mode and reports a good write as failed.
        read_payload = [0x09, 0x05, 0x00, 0x04]
        set_ack = vendor_reply([0x09, 0x05, 0x00, 0x03], pixy.ACK_BYTE)
        answer = vendor_reply(read_payload, 0x02)
        self.assertEqual(self.run_query(read_payload, [set_ack, answer]), answer)

    def test_rejects_another_groups_report(self):
        payload = [0x09, 0x05, 0x00, 0x04]
        other = vendor_reply([0x09, 0x01, 0x01, 0x01], 0x02)
        answer = vendor_reply(payload, 0x03)
        self.assertEqual(self.run_query(payload, [other, answer]), answer)

    def test_tolerates_high_bits_set_on_the_group_byte(self):
        # The camera sets high bits on the group: 0x01 comes back as 0x41 or 0x61.
        payload = [0x09, 0x01, 0x01, 0x01]
        aliased = bytes([0x09, 0x41, 0x01, 0x01, 0x00, 0x01, 0x00, 0x01, 0x02])
        self.assertEqual(self.run_query(payload, [aliased]), aliased)

    def test_a_reply_too_short_to_carry_a_command_is_rejected(self):
        payload = [0x09, 0x05, 0x00, 0x04]
        answer = vendor_reply(payload, 0x01)
        self.assertEqual(self.run_query(payload, [bytes([0x09, 0x05]), answer]), answer)

    def test_gives_up_rather_than_looping_forever(self):
        # `select` reports nothing readable rather than being left real, so this
        # asserts the retry budget without spending QUERY_ATTEMPTS timeouts of
        # wall-clock in the suite.
        with mock.patch.object(pixy.os, "open", return_value=7), \
             mock.patch.object(pixy.os, "close"), \
             mock.patch.object(pixy.os, "write"), \
             mock.patch.object(pixy, "drain"), \
             mock.patch.object(pixy.select, "select", return_value=([], [], [])), \
             mock.patch.object(pixy.time, "sleep"):
            self.assertIsNone(pixy.query("/dev/hidrawTEST", [0x09, 0x05, 0x00, 0x04]))

    def test_an_unopenable_node_yields_no_reply(self):
        with mock.patch.object(pixy.os, "open", side_effect=OSError(errno.EACCES, "denied")):
            self.assertIsNone(pixy.query("/dev/hidrawTEST", [0x09, 0x05, 0x00, 0x04]))


class HidSessionTests(unittest.TestCase):
    def test_reuses_one_descriptor_across_queries(self):
        # Why this exists: the first write to a fresh hidraw fd is lost, so a
        # reopened fd pays a full query timeout every time. Reading ten features
        # took 8.4s reopening and 0.56s sharing one fd.
        opened = []

        def fake_open(path, flags):
            opened.append(path)
            return 11

        with mock.patch.object(pixy.os, "open", side_effect=fake_open), \
             mock.patch.object(pixy.os, "close") as closer, \
             mock.patch.object(pixy, "query", return_value=b"reply") as querier:
            with pixy.HidSession("/dev/hidrawTEST") as session:
                session.query([0x09, 0x05, 0x00, 0x04])
                session.query([0x09, 0x04, 0x00, 0x02])
                fd = session.fd
        self.assertEqual(len(opened), 1)
        self.assertEqual(closer.call_count, 1)
        # Both queries borrowed the session's descriptor rather than opening one.
        for call in querier.call_args_list:
            self.assertEqual(call.kwargs["fd"], fd)

    def test_closes_the_descriptor_even_when_the_body_raises(self):
        with mock.patch.object(pixy.os, "open", return_value=11), \
             mock.patch.object(pixy.os, "close") as closer:
            with self.assertRaises(ValueError):
                with pixy.HidSession("/dev/hidrawTEST"):
                    raise ValueError("boom")
        self.assertEqual(closer.call_count, 1)

    def test_a_borrowed_descriptor_is_not_closed_by_query(self):
        # query() must not close a descriptor it did not open, or the session's
        # second call would write to a closed fd.
        with mock.patch.object(pixy.os, "close") as closer, \
             mock.patch.object(pixy.os, "write"), \
             mock.patch.object(pixy.os, "read", side_effect=BlockingIOError), \
             mock.patch.object(pixy, "drain"), \
             mock.patch.object(pixy.select, "select", return_value=([], [], [])), \
             mock.patch.object(pixy.time, "sleep"):
            pixy.query("/dev/hidrawTEST", [0x09, 0x05, 0x00, 0x04], fd=11)
        closer.assert_not_called()


class VendorReadTests(unittest.TestCase):
    def test_audio_decodes_each_mode(self):
        for value, name in pixy.AUDIO_NAMES.items():
            reply = vendor_reply([0x09, 0x05, 0x00, 0x04], value)
            with mock.patch.object(pixy, "query", return_value=reply):
                self.assertEqual(pixy.read_audio("/dev/hidrawTEST"), (name, value))

    def test_audio_keeps_an_unknown_raw_value(self):
        reply = vendor_reply([0x09, 0x05, 0x00, 0x04], 0x7E)
        with mock.patch.object(pixy, "query", return_value=reply):
            self.assertEqual(pixy.read_audio("/dev/hidrawTEST"), (None, 0x7E))

    def test_gesture_reads_byte_nine_not_the_last_byte(self):
        # The regression this guards, seen in another Linux tool for this camera:
        # reports are zero-padded to 32 bytes, so reading the value from the end
        # always yields 0 — indistinguishable from "gesture is off".
        reply = vendor_reply([0x09, 0x04, 0x02, 0x01], 0x02, 0x01)
        padded = reply + bytes(pixy.REPORT_SIZE - len(reply))
        with mock.patch.object(pixy, "query", return_value=padded):
            self.assertTrue(pixy.read_gesture("/dev/hidrawTEST"))

    def test_gesture_off_reads_false(self):
        reply = vendor_reply([0x09, 0x04, 0x02, 0x01], 0x02, 0x00)
        with mock.patch.object(pixy, "query", return_value=reply):
            self.assertFalse(pixy.read_gesture("/dev/hidrawTEST"))

    def test_gesture_distinguishes_off_from_unreadable(self):
        # False and None mean different things to the panel: one is a state, the
        # other is "the camera did not answer".
        with mock.patch.object(pixy, "query", return_value=None):
            self.assertIsNone(pixy.read_gesture("/dev/hidrawTEST"))

    def test_feature_reads_its_value_byte(self):
        for key, fid in pixy.FEATURE_IDS.items():
            reply = vendor_reply([0x09, 0x04, 0x00, 0x07], fid, 0x01)
            with mock.patch.object(pixy, "query", return_value=reply):
                self.assertTrue(pixy.read_feature("/dev/hidrawTEST", key), key)

    def test_feature_short_reply_is_not_decoded(self):
        with mock.patch.object(pixy, "query", return_value=bytes([0x09, 0x04, 0x00, 0x07])):
            self.assertIsNone(pixy.read_feature("/dev/hidrawTEST", "flipHorizontal"))

    def test_metering_reports_mode_and_point(self):
        reply = vendor_reply([0x09, 0x04, 0x00, 0x02], 0x02, 0x38, 0x38, 0x7F, 0x7F)
        with mock.patch.object(pixy, "query", return_value=reply):
            result = pixy.read_metering("/dev/hidrawTEST")
        self.assertEqual(result, {"mode": "area", "raw": 0x02, "x": 0x38, "y": 0x38})

    def test_metering_keeps_stale_coordinates_visible_in_other_modes(self):
        # The camera does not clear the last picked point when leaving area mode.
        # Reporting the bytes anyway is honest; hiding them would imply a reset
        # that never happened.
        reply = vendor_reply([0x09, 0x04, 0x00, 0x02], 0x00, 0x38, 0x38, 0x7F, 0x7F)
        with mock.patch.object(pixy, "query", return_value=reply):
            result = pixy.read_metering("/dev/hidrawTEST")
        self.assertEqual(result["mode"], "center")
        self.assertEqual((result["x"], result["y"]), (0x38, 0x38))

    def test_native_preset_decodes_degrees_matching_the_uvc_space(self):
        # Measured on hardware: saving at UVC pan=-35.0 stores -34.969. The slots
        # are in degrees, not some private HID unit, which is what makes loading
        # them over UVC correct.
        floats = struct.pack("<fff", -34.969, 10.022, 0.0)
        reply = bytes([0x09, 0x03, 0x01, 0x16, 0x00, 0x0E, 0x00, 0x0E, 0x01, 0x01]) + floats
        with mock.patch.object(pixy, "query", return_value=reply):
            entry = pixy.read_native_preset("/dev/hidrawTEST", 1)
        self.assertTrue(entry["saved"])
        self.assertAlmostEqual(entry["pan"], -34.969, places=3)
        self.assertAlmostEqual(entry["tilt"], 10.022, places=3)

    def test_native_preset_empty_slot_reads_unsaved(self):
        reply = bytes([0x09, 0x03, 0x01, 0x16, 0x00, 0x0E, 0x00, 0x0E, 0x02, 0x00]) + bytes(12)
        with mock.patch.object(pixy, "query", return_value=reply):
            entry = pixy.read_native_preset("/dev/hidrawTEST", 2)
        self.assertFalse(entry["saved"])

    def test_native_preset_short_reply_is_not_decoded(self):
        # A truncated reply would unpack neighbouring bytes as floats and report a
        # confident, wrong position.
        with mock.patch.object(pixy, "query", return_value=bytes(16)):
            self.assertIsNone(pixy.read_native_preset("/dev/hidrawTEST", 1))

    def test_autoprivacy_decodes_little_endian_seconds(self):
        reply = bytes([0x09, 0x02, 0x01, 0x01, 0x00, 0x04, 0x00, 0x04]) + (300).to_bytes(4, "little")
        with mock.patch.object(pixy, "query", return_value=reply):
            self.assertEqual(pixy.read_autoprivacy("/dev/hidrawTEST"), 300)

    def test_autoprivacy_zero_is_a_value_not_an_absence(self):
        reply = bytes([0x09, 0x02, 0x01, 0x01, 0x00, 0x04, 0x00, 0x04]) + bytes(4)
        with mock.patch.object(pixy, "query", return_value=reply):
            self.assertEqual(pixy.read_autoprivacy("/dev/hidrawTEST"), 0)


class SetAndConfirmTests(unittest.TestCase):
    """Setters confirm by reading back, and retry a write the camera dropped."""

    def test_a_confirmed_write_stops_after_one_attempt(self):
        with mock.patch.object(pixy, "write_reports") as writer, \
             mock.patch.object(pixy.time, "sleep"):
            result = pixy.set_and_confirm(
                "/dev/hidrawTEST", [b"x"], lambda path: "live", "live"
            )
        self.assertTrue(result["confirmed"])
        self.assertEqual(result["attempts"], 1)
        self.assertEqual(writer.call_count, 1)

    def test_a_dropped_first_write_is_retried(self):
        # The measured quirk: the first write after an idle period is ignored, and
        # the identical command succeeds immediately afterwards.
        answers = iter(["noise-cancel", "live"])
        with mock.patch.object(pixy, "write_reports") as writer, \
             mock.patch.object(pixy.time, "sleep"):
            result = pixy.set_and_confirm(
                "/dev/hidrawTEST", [b"x"], lambda path: next(answers), "live"
            )
        self.assertTrue(result["confirmed"])
        self.assertEqual(result["attempts"], 2)
        self.assertEqual(writer.call_count, 2)

    def test_a_write_the_camera_refuses_reports_unconfirmed_not_failed(self):
        # ok=true with confirmed=false: the command was sent and the camera
        # declined it. That is a real outcome the panel should show, not an error.
        with mock.patch.object(pixy, "write_reports"), \
             mock.patch.object(pixy.time, "sleep"):
            result = pixy.set_and_confirm(
                "/dev/hidrawTEST", [b"x"], lambda path: "noise-cancel", "live"
            )
        self.assertTrue(result["ok"])
        self.assertFalse(result["confirmed"])
        self.assertEqual(result["actual"], "noise-cancel")
        self.assertEqual(result["attempts"], pixy.SET_ATTEMPTS)

    def test_an_unreadable_readback_is_not_mistaken_for_success(self):
        with mock.patch.object(pixy, "write_reports"), \
             mock.patch.object(pixy.time, "sleep"):
            result = pixy.set_and_confirm(
                "/dev/hidrawTEST", [b"x"], lambda path: None, "live"
            )
        self.assertFalse(result["confirmed"])
        self.assertIsNone(result["actual"])


# ---------------------------------------------------------------- discovery


class UeventMatchTests(unittest.TestCase):
    def test_matches_on_usb_ids(self):
        self.assertTrue(pixy.is_pixy_uevent("PRODUCT=328f/c0/100\nHID_ID=0003:0000328F:000000C0"))

    def test_matches_on_name_when_ids_are_absent(self):
        self.assertTrue(pixy.is_pixy_uevent("HID_NAME=EMEET PIXY"))

    def test_is_case_insensitive(self):
        self.assertTrue(pixy.is_pixy_uevent("hid_id=0003:0000328f:000000c0"))
        self.assertTrue(pixy.is_pixy_uevent("hid_name=emeet pixy"))

    def test_rejects_other_devices(self):
        self.assertFalse(pixy.is_pixy_uevent("HID_NAME=Logitech BRIO\nHID_ID=0003:0000046D:0000085E"))

    def test_rejects_empty(self):
        self.assertFalse(pixy.is_pixy_uevent(""))

    def test_requires_both_ids(self):
        # The vendor id alone is another EMEET product, not necessarily a PIXY.
        self.assertFalse(pixy.is_pixy_uevent("HID_ID=0003:0000328F:00000099"))

    def test_partial_name_does_not_match(self):
        self.assertFalse(pixy.is_pixy_uevent("HID_NAME=EMEET SmartCam"))


class FindHidrawTests(unittest.TestCase):
    def test_env_override_wins_when_the_path_exists(self):
        with tempfile.NamedTemporaryFile() as tmp:
            with mock.patch.dict(os.environ, {"PIXY_HIDRAW": tmp.name}):
                self.assertEqual(pixy.find_hidraw(), tmp.name)

    def test_env_override_pointing_nowhere_reports_no_device(self):
        # Better to report "no camera" than to fall through and drive a
        # different device than the one the operator named.
        with mock.patch.dict(os.environ, {"PIXY_HIDRAW": "/dev/hidraw-does-not-exist"}):
            self.assertIsNone(pixy.find_hidraw())

    def test_prefers_the_node_carrying_the_vendor_usage_signature(self):
        uevent = "HID_NAME=EMEET PIXY"

        def fake_read(path):
            return uevent if path.endswith("uevent") else ""

        def fake_read_bytes(path):
            # Only hidraw9 describes itself with the vendor usage pair.
            return pixy.VENDOR_USAGE_SIGNATURE if "hidraw9" in path else b"\x05\x01\x09\x02"

        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("PIXY_HIDRAW", None)
            with mock.patch.object(pixy.glob, "glob", return_value=["/dev/hidraw7", "/dev/hidraw9"]), \
                 mock.patch.object(pixy, "read_sysfs", fake_read), \
                 mock.patch.object(pixy, "read_sysfs_bytes", fake_read_bytes):
                self.assertEqual(pixy.find_hidraw(), "/dev/hidraw9")

    def test_falls_back_to_id_match_when_no_node_advertises_the_signature(self):
        # A firmware that describes itself differently should still work rather
        # than reporting no camera at all.
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("PIXY_HIDRAW", None)
            with mock.patch.object(pixy.glob, "glob", return_value=["/dev/hidraw4"]), \
                 mock.patch.object(pixy, "read_sysfs", lambda p: "HID_NAME=EMEET PIXY"), \
                 mock.patch.object(pixy, "read_sysfs_bytes", lambda p: b""):
                self.assertEqual(pixy.find_hidraw(), "/dev/hidraw4")

    def test_no_matching_node_is_none(self):
        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("PIXY_HIDRAW", None)
            with mock.patch.object(pixy.glob, "glob", return_value=["/dev/hidraw0"]), \
                 mock.patch.object(pixy, "read_sysfs", lambda p: "HID_NAME=Some Keyboard"), \
                 mock.patch.object(pixy, "read_sysfs_bytes", lambda p: b""):
                self.assertIsNone(pixy.find_hidraw())


class FindVideoTests(unittest.TestCase):
    def test_env_override_pointing_nowhere_reports_no_device(self):
        with mock.patch.dict(os.environ, {"PIXY_VIDEO": "/dev/video-nope"}):
            self.assertIsNone(pixy.find_video())

    def test_skips_the_metadata_node(self):
        # The PIXY claims two nodes and only the first captures; QUERYCAP is
        # what tells them apart.
        opened = []

        def fake_open(path, flags):
            opened.append(path)
            return 40 + len(opened)

        def fake_capability(fd):
            return {"card": "EMEET PIXY"} if fd == 42 else None

        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("PIXY_VIDEO", None)
            with mock.patch.object(pixy, "video_capture_nodes", return_value=["/dev/video32", "/dev/video33"]), \
                 mock.patch.object(pixy.os, "open", fake_open), \
                 mock.patch.object(pixy.os, "close", lambda fd: None), \
                 mock.patch.object(pixy, "capability", fake_capability):
                self.assertEqual(pixy.find_video(), "/dev/video33")

    def test_unopenable_node_is_skipped_not_fatal(self):
        def fake_open(path, flags):
            if path == "/dev/video32":
                raise OSError(errno.EACCES, "denied")
            return 42

        with mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("PIXY_VIDEO", None)
            with mock.patch.object(pixy, "video_capture_nodes", return_value=["/dev/video32", "/dev/video33"]), \
                 mock.patch.object(pixy.os, "open", fake_open), \
                 mock.patch.object(pixy.os, "close", lambda fd: None), \
                 mock.patch.object(pixy, "capability", lambda fd: {"card": "EMEET PIXY"}):
                self.assertEqual(pixy.find_video(), "/dev/video33")


class CapabilityTests(unittest.TestCase):
    """QUERYCAP is parsed out of a raw buffer, so check the field offsets."""

    def buffer(self, driver=b"uvcvideo", card=b"EMEET PIXY", caps=0x00000001, device_caps=0):
        buf = bytearray(pixy.QUERYCAP_SIZE)
        buf[0:len(driver)] = driver
        buf[16:16 + len(card)] = card
        buf[48:52] = b"usb-"
        struct.pack_into("<I", buf, 84, caps)
        struct.pack_into("<I", buf, 88, device_caps)
        return buf

    def test_parses_driver_and_card(self):
        buf = self.buffer()

        # Stand in for the kernel by filling the caller's buffer with a fixture.
        def fake_ioctl(fd, request, arg, mutate):
            arg[:] = buf
            return 0

        with mock.patch.object(pixy.fcntl, "ioctl", fake_ioctl):
            cap = pixy.capability(3)
        self.assertEqual(cap["driver"], "uvcvideo")
        self.assertEqual(cap["card"], "EMEET PIXY")
        self.assertEqual(cap["bus"], "usb-")

    def test_device_caps_take_precedence_over_global_caps(self):
        # A metadata node's global caps advertise capture for the whole device;
        # only device_caps describe this node.
        buf = self.buffer(caps=0x00000001, device_caps=0x00001000)

        def fake_ioctl(fd, request, arg, mutate):
            arg[:] = buf
            return 0

        with mock.patch.object(pixy.fcntl, "ioctl", fake_ioctl):
            self.assertIsNone(pixy.capability(3))

    def test_non_capture_node_is_none(self):
        buf = self.buffer(caps=0x00001000, device_caps=0)

        def fake_ioctl(fd, request, arg, mutate):
            arg[:] = buf
            return 0

        with mock.patch.object(pixy.fcntl, "ioctl", fake_ioctl):
            self.assertIsNone(pixy.capability(3))

    def test_failed_ioctl_is_none(self):
        def boom(*a, **k):
            raise OSError(errno.ENOTTY, "Inappropriate ioctl for device")

        with mock.patch.object(pixy.fcntl, "ioctl", boom):
            self.assertIsNone(pixy.capability(3))


class StreamHoldersTests(unittest.TestCase):
    """Who holds the capture stream, split into other apps and our own preview.

    The split is the whole point of this function, so it is worth pinning: only
    one process can stream, and confusing "someone else has it" with "we have it"
    breaks the panel in opposite directions. Fold our own preview into `others`
    and an open panel reports "in use by quickshell"; drop it entirely and the
    panel never learns it is the obstacle, so it never yields and a meeting joined
    while the panel is open gets no video at all.
    """

    NODE_RDEV = 0x8120  # arbitrary; only equality against the fd's rdev matters
    OTHER_RDEV = 0x0801

    def holders(self, fds, node_rdev=NODE_RDEV, pid=1000, ppid=2000, siblings=()):
        """Run stream_holders against a fake /proc.

        `fds` maps a /proc/PID/fd/N path to the rdev the kernel would report for
        it, which is exactly the comparison the real function makes. `siblings`
        lists pids that is_control_helper should recognize as our own non-
        capturing helpers; the real predicate reads /proc cmdlines and has its
        own tests, so it is stubbed here to keep the two questions separate.
        """
        def fake_stat(path):
            if path == "/dev/videoTEST":
                return mock.Mock(st_rdev=node_rdev)
            if path in fds:
                return mock.Mock(st_rdev=fds[path])
            raise OSError(errno.ENOENT, "No such file")

        with mock.patch.object(pixy.os, "stat", fake_stat), \
             mock.patch.object(pixy.glob, "glob", return_value=list(fds)), \
             mock.patch.object(pixy.os, "getpid", return_value=pid), \
             mock.patch.object(pixy.os, "getppid", return_value=ppid), \
             mock.patch.object(pixy, "is_control_helper",
                               lambda p: p in set(siblings)):
            return pixy.stream_holders("/dev/videoTEST")

    def test_no_holders(self):
        self.assertEqual(self.holders({}), ([], []))

    def test_another_app_is_reported_as_other(self):
        others, ours = self.holders({"/proc/4242/fd/7": self.NODE_RDEV})
        self.assertEqual((others, ours), ([4242], []))

    def test_our_own_preview_is_reported_separately(self):
        # The shell is our parent, and it is the process running the preview.
        # It must not show up as another app, but it must show up somewhere.
        others, ours = self.holders({"/proc/2000/fd/9": self.NODE_RDEV})
        self.assertEqual((others, ours), ([], [2000]))

    def test_both_at_once(self):
        others, ours = self.holders({
            "/proc/2000/fd/9": self.NODE_RDEV,
            "/proc/4242/fd/7": self.NODE_RDEV,
        })
        self.assertEqual((others, ours), ([4242], [2000]))

    def test_a_sibling_control_helper_is_not_a_holder(self):
        # *(observed)* This is the "In use by python3" bug. Every control
        # subcommand opens the node for its ioctls, and the panel runs those
        # while polling this — so the panel caught its own helpers and reported
        # the camera busy with a stranger called python3.
        self.assertEqual(self.holders({"/proc/4242/fd/7": self.NODE_RDEV},
                                      siblings=[4242]), ([], []))

    def test_a_sibling_does_not_hide_a_real_holder(self):
        # The two arrive together constantly: the panel polls holders while its
        # own image refresh runs and a call is genuinely up. Dropping the sibling
        # must not drop the app the user needs to be told about.
        others, ours = self.holders({
            "/proc/4242/fd/7": self.NODE_RDEV,
            "/proc/5150/fd/3": self.NODE_RDEV,
        }, siblings=[4242])
        self.assertEqual((others, ours), ([5150], []))

    def test_this_helper_is_never_a_holder(self):
        # On a `preview` run the helper is itself the thing capturing. Counting
        # it would make `pixy preview` report the camera as busy with itself.
        self.assertEqual(self.holders({"/proc/1000/fd/3": self.NODE_RDEV}), ([], []))

    def test_fds_on_other_devices_are_ignored(self):
        self.assertEqual(self.holders({"/proc/4242/fd/7": self.OTHER_RDEV}), ([], []))

    def test_pids_are_sorted_and_deduplicated(self):
        # One process can hold several fds on the node; it is still one holder.
        others, _ = self.holders({
            "/proc/900/fd/3": self.NODE_RDEV,
            "/proc/100/fd/4": self.NODE_RDEV,
            "/proc/900/fd/5": self.NODE_RDEV,
        })
        self.assertEqual(others, [100, 900])

    def test_vanished_fd_is_skipped(self):
        # /proc entries disappear between the glob and the stat as a matter of
        # course; that must not turn into a traceback.
        fds = {"/proc/4242/fd/7": self.NODE_RDEV}
        def fake_stat(path):
            if path == "/dev/videoTEST":
                return mock.Mock(st_rdev=self.NODE_RDEV)
            raise OSError(errno.ENOENT, "No such file")

        with mock.patch.object(pixy.os, "stat", fake_stat), \
             mock.patch.object(pixy.glob, "glob", return_value=list(fds) + ["/proc/1/fd/x"]), \
             mock.patch.object(pixy.os, "getpid", return_value=1000), \
             mock.patch.object(pixy.os, "getppid", return_value=2000):
            self.assertEqual(pixy.stream_holders("/dev/videoTEST"), ([], []))

    def test_missing_node_is_empty_not_an_error(self):
        with mock.patch.object(pixy.os, "stat", side_effect=OSError(errno.ENOENT, "gone")):
            self.assertEqual(pixy.stream_holders("/dev/videoGONE"), ([], []))


class ControlHelperTests(unittest.TestCase):
    """Telling our own control runs apart from apps that actually capture.

    *(observed)* The bug this answers: `holders` reported "In use by python3"
    whenever a control subcommand happened to overlap the poll, because reaching
    a control ioctl requires an open fd on the video node and a /proc scan cannot
    see the difference. The label was the visible half; `streaming` also makes
    the panel drop its preview to yield the camera, so the panel was interrupting
    itself.

    Two mistakes to avoid in the other direction, both pinned below: a sibling
    `preview` really is capturing and must stay a holder, and an unrelated python
    holding the node is not ours to dismiss just because it is also python.
    """

    SELF = "/home/n/plugin/scripts/pixy"

    def helper(self, pid, argv, cwd=None):
        """is_control_helper against a fake /proc/PID/cmdline."""
        raw = b"\0".join(a.encode() for a in argv) + b"\0" if argv else b""

        def fake_read(path):
            return raw if path == f"/proc/{pid}/cmdline" else b""

        def fake_realpath(path):
            # Stands in for the kernel's cwd symlink: a relative argv[0] is
            # resolved through the *other* process's directory.
            prefix = f"/proc/{pid}/cwd/"
            if path.startswith(prefix) and cwd:
                return os.path.normpath(cwd + "/" + path[len(prefix):])
            return os.path.normpath(path)

        with mock.patch.object(pixy, "read_sysfs_bytes", fake_read), \
             mock.patch.object(pixy, "SELF_PATH", self.SELF), \
             mock.patch.object(pixy.os.path, "realpath", fake_realpath):
            return pixy.is_control_helper(pid)

    def test_a_control_run_is_ours(self):
        self.assertTrue(self.helper(4242, ["python3", self.SELF, "image"]))

    def test_every_non_capturing_subcommand_is_ours(self):
        # Named individually because each one opens the node, and a new
        # subcommand that forgets to is the same bug returning.
        for command in ("state", "info", "holders", "image", "profile", "mode",
                        "privacy", "ptz", "zoom", "preset"):
            self.assertTrue(self.helper(4242, ["python3", self.SELF, command]),
                            command)

    def test_a_sibling_preview_is_still_a_holder(self):
        # It genuinely has the stream. A preview run by hand in a terminal is
        # exactly the conflict the panel exists to report.
        self.assertFalse(self.helper(4242, ["python3", self.SELF, "preview"]))

    def test_the_capturing_set_matches_the_parser(self):
        # CAPTURING_COMMANDS is a hand-kept list, so it is checked against the
        # parser's own `streams` flag — the flag main() uses to decide a command
        # emits frames. Adding a streaming subcommand and forgetting this set
        # would make it invisible to the panel.
        parser = pixy.build_parser()
        streaming = set()
        for action in parser._subparsers._group_actions[0].choices.items():
            name, sub = action
            if sub.get_default("streams"):
                streaming.add(name)
        self.assertEqual(streaming, set(pixy.CAPTURING_COMMANDS))

    def test_an_unrelated_python_is_not_ours(self):
        # The name is not the test; the path is. Dismissing anything called
        # python3 would hide a real capture by someone else's script.
        self.assertFalse(self.helper(4242, ["python3", "/usr/bin/somecam", "run"]))

    def test_another_copy_of_the_helper_is_ours(self):
        # Not the same file: installing the plugin copies the tree into
        # ~/.config/omarchy/plugins, so the panel's helpers and a hand-run
        # `./scripts/pixy holders` from the checkout are different paths. The
        # README recommends that command for "what is using my webcam", and path
        # equality alone answered "In use by python3" there — the same bug from
        # the other side. What matters is that the file is a pixy helper.
        with tempfile.TemporaryDirectory() as tmp:
            other = os.path.join(tmp, "pixy")
            shutil.copyfile(HELPER, other)
            self.assertTrue(self.helper(4242, ["python3", other, "image"]))
            self.assertFalse(self.helper(4242, ["python3", other, "preview"]))

    def test_an_unrelated_file_named_pixy_is_not_ours(self):
        # The basename is the cheap prefilter, not the test. Something else
        # called `pixy` holding the camera is a real holder.
        with tempfile.TemporaryDirectory() as tmp:
            impostor = os.path.join(tmp, "pixy")
            pathlib.Path(impostor).write_text("#!/bin/sh\n# not this helper\n")
            self.assertFalse(self.helper(4242, ["python3", impostor, "image"]))

    def test_a_vanished_script_is_not_ours(self):
        # The path is read after the process was seen, so it can be gone — or be
        # a deleted file, or unreadable. None of those may raise, and none may be
        # silently dismissed as ours.
        self.assertFalse(self.helper(4242, ["python3", "/opt/gone/scripts/pixy", "image"]))

    def test_a_relative_invocation_is_resolved_through_its_own_cwd(self):
        # `./scripts/pixy image` from a shell in the plugin directory — how it is
        # run by hand, and how the reproduction for this bug was written.
        self.assertTrue(self.helper(4242, ["python3", "./scripts/pixy", "image"],
                                    cwd="/home/n/plugin"))

    def test_a_relative_invocation_from_elsewhere_is_not_ours(self):
        self.assertFalse(self.helper(4242, ["python3", "./scripts/pixy", "image"],
                                     cwd="/opt/other"))

    def test_flags_before_the_subcommand_are_skipped(self):
        self.assertTrue(self.helper(4242, ["python3", self.SELF, "--columns", "40", "image"]))

    def test_a_preview_with_flags_is_still_a_holder(self):
        self.assertFalse(self.helper(4242, ["python3", self.SELF, "preview", "--fps", "6"]))

    def test_no_subcommand_is_not_capturing(self):
        # argparse is about to reject it, so it never opens anything.
        self.assertTrue(self.helper(4242, ["python3", self.SELF]))

    def test_an_empty_cmdline_is_not_ours(self):
        # Kernel threads read empty, and so does a process that exits between the
        # fd scan and this read. Neither may be silently dismissed.
        self.assertFalse(self.helper(4242, []))

    def test_the_script_run_directly_is_ours(self):
        # No interpreter in argv when the shebang runs it.
        self.assertTrue(self.helper(4242, [self.SELF, "state"]))


# ---------------------------------------------------------------- value snapping


class SnapTests(unittest.TestCase):
    def spec(self, low=-540000, high=540000, step=3600):
        return {"min": low, "max": high, "step": step}

    def test_clamps_below_range(self):
        self.assertEqual(pixy.snap(-999999, self.spec()), -540000)

    def test_clamps_above_range(self):
        self.assertEqual(pixy.snap(999999, self.spec()), 540000)

    def test_lands_on_a_step_boundary(self):
        # Writing an unsnapped value makes the driver round it, so the readback
        # disagrees with the slider and the handle jumps on the next refresh.
        self.assertEqual(pixy.snap(5000, self.spec()) % 3600, 0)

    def test_rounds_to_the_nearest_step(self):
        self.assertEqual(pixy.snap(3600 * 2 + 1700, self.spec()), 3600 * 2)
        self.assertEqual(pixy.snap(3600 * 2 + 1900, self.spec()), 3600 * 3)

    def test_step_of_one_passes_integers_through(self):
        self.assertEqual(pixy.snap(137, self.spec(100, 150, 1)), 137)

    def test_snapping_never_leaves_the_range(self):
        # Rounding up at the top of the range must not overshoot the maximum.
        spec = self.spec(0, 100, 30)
        for value in range(-20, 140):
            result = pixy.snap(value, spec)
            self.assertGreaterEqual(result, 0)
            self.assertLessEqual(result, 100)

    def test_accepts_float_input(self):
        self.assertEqual(pixy.snap(3600.4, self.spec()), 3600)

    def test_zero_step_does_not_divide_by_zero(self):
        # query_control floors step at 1, so this should be unreachable — but a
        # driver reporting step 0 must clamp, not raise ZeroDivisionError and
        # take the whole state read down with it.
        self.assertEqual(pixy.snap(42, {"min": 0, "max": 100, "step": 0}), 42)
        self.assertEqual(pixy.snap(999, {"min": 0, "max": 100, "step": 0}), 100)


# ---------------------------------------------------------------- presets


class PresetStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_state_path_follows_xdg_state_home(self):
        self.assertTrue(pixy.state_path().startswith(self.tmp.name))

    def test_missing_store_reads_as_empty(self):
        self.assertEqual(pixy.read_presets(), {})

    def test_round_trip(self):
        slots = {1: {"pan": 30, "tilt": -10, "zoom": 120}}
        self.assertTrue(pixy.write_presets(slots))
        self.assertEqual(pixy.read_presets(), slots)

    def test_write_creates_the_parent_directory(self):
        self.assertTrue(pixy.write_presets({2: {"pan": 0, "tilt": 0, "zoom": 100}}))
        self.assertTrue(os.path.exists(pixy.state_path()))

    def test_corrupt_json_reads_as_empty(self):
        os.makedirs(os.path.dirname(pixy.state_path()), exist_ok=True)
        with open(pixy.state_path(), "w", encoding="utf-8") as fh:
            fh.write("{not json")
        self.assertEqual(pixy.read_presets(), {})

    def test_out_of_range_slots_are_dropped(self):
        self.write_raw({"slots": {"0": {"pan": 1, "tilt": 1, "zoom": 100},
                                  "4": {"pan": 1, "tilt": 1, "zoom": 100},
                                  "2": {"pan": 5, "tilt": 5, "zoom": 110}}})
        self.assertEqual(set(pixy.read_presets()), {2})

    def test_incomplete_entries_are_dropped(self):
        # A half-written entry would render as a preset that cannot be recalled.
        self.write_raw({"slots": {"1": {"pan": 10, "tilt": 0}, "2": {"pan": 1, "tilt": 2, "zoom": 100}}})
        self.assertEqual(set(pixy.read_presets()), {2})

    def test_non_dict_entries_are_dropped(self):
        self.write_raw({"slots": {"1": "nope", "2": {"pan": 1, "tilt": 2, "zoom": 100}}})
        self.assertEqual(set(pixy.read_presets()), {2})

    def test_non_numeric_slot_keys_are_dropped(self):
        self.write_raw({"slots": {"left": {"pan": 1, "tilt": 2, "zoom": 100}}})
        self.assertEqual(pixy.read_presets(), {})

    def test_non_numeric_values_are_dropped(self):
        self.write_raw({"slots": {"1": {"pan": "far", "tilt": 2, "zoom": 100}}})
        self.assertEqual(pixy.read_presets(), {})

    def test_missing_slots_key_reads_as_empty(self):
        self.write_raw({"version": 1})
        self.assertEqual(pixy.read_presets(), {})

    def test_slots_of_wrong_type_reads_as_empty(self):
        self.write_raw({"slots": [1, 2, 3]})
        self.assertEqual(pixy.read_presets(), {})

    def test_write_leaves_no_temp_file_behind(self):
        pixy.write_presets({1: {"pan": 0, "tilt": 0, "zoom": 100}})
        leftovers = [n for n in os.listdir(os.path.dirname(pixy.state_path())) if n.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_unwritable_store_reports_failure_rather_than_raising(self):
        with mock.patch.object(pixy.os, "makedirs", side_effect=OSError(errno.EROFS, "read-only")):
            self.assertFalse(pixy.write_presets({1: {"pan": 0, "tilt": 0, "zoom": 100}}))

    def write_raw(self, blob):
        os.makedirs(os.path.dirname(pixy.state_path()), exist_ok=True)
        with open(pixy.state_path(), "w", encoding="utf-8") as fh:
            json.dump(blob, fh)


# ---------------------------------------------------------------- error text


class DescribeTests(unittest.TestCase):
    def test_permission_denied_points_at_the_udev_rule(self):
        # The most likely first-run failure, so the message has to name the fix.
        text = pixy.describe(OSError(errno.EACCES, "Permission denied"))
        self.assertIn("udev", text)

    def test_busy_is_named_plainly(self):
        self.assertEqual(pixy.describe(OSError(errno.EBUSY, "Device or resource busy")), "device busy")

    def test_unplugged_is_named_plainly(self):
        self.assertEqual(pixy.describe(OSError(errno.ENOENT, "No such file")), "device disappeared")

    def test_other_oserror_falls_back_to_strerror(self):
        self.assertEqual(pixy.describe(OSError(errno.EIO, "Input/output error")), "Input/output error")

    def test_non_oserror_is_stringified(self):
        self.assertEqual(pixy.describe(ValueError("bad value")), "bad value")

    def test_empty_exception_still_yields_text(self):
        # An empty string here would render as a blank error in the panel.
        self.assertEqual(pixy.describe(ValueError()), "ValueError")


# ---------------------------------------------------------------- PTZ writes


class ApplyPtzTests(unittest.TestCase):
    def test_writes_degrees_as_arcseconds(self):
        cam = FakeCamera(specs=ptz_specs())
        result = pixy.apply_ptz(cam, pan=30, tilt=-10)
        self.assertEqual(result["written"], {"pan": 30, "tilt": -10})
        self.assertEqual(dict(cam.writes)[pixy.CID_PAN_ABSOLUTE], 30 * 3600)
        self.assertEqual(dict(cam.writes)[pixy.CID_TILT_ABSOLUTE], -10 * 3600)

    def test_zoom_is_written_unscaled(self):
        cam = FakeCamera(specs=ptz_specs())
        pixy.apply_ptz(cam, zoom=125)
        self.assertEqual(dict(cam.writes)[pixy.CID_ZOOM_ABSOLUTE], 125)

    def test_omitted_axes_are_not_written(self):
        cam = FakeCamera(specs=ptz_specs())
        pixy.apply_ptz(cam, pan=10)
        self.assertEqual([cid for cid, _ in cam.writes], [pixy.CID_PAN_ABSOLUTE])

    def test_out_of_range_values_are_clamped(self):
        cam = FakeCamera(specs=ptz_specs())
        result = pixy.apply_ptz(cam, pan=9999, tilt=-9999, zoom=9999)
        self.assertEqual(result["written"], {"pan": 150, "tilt": -90, "zoom": 150})

    def test_unsupported_axis_is_reported_not_raised(self):
        cam = FakeCamera(specs=ptz_specs(), missing={pixy.CID_ZOOM_ABSOLUTE})
        result = pixy.apply_ptz(cam, zoom=120)
        self.assertIn("zoom", result["failed"])
        self.assertEqual(result["written"], {})

    def test_driver_rejection_is_reported_not_raised(self):
        cam = FakeCamera(specs=ptz_specs(), reject={pixy.CID_PAN_ABSOLUTE})
        result = pixy.apply_ptz(cam, pan=10, tilt=5)
        self.assertIn("pan", result["failed"])
        self.assertEqual(result["written"], {"tilt": 5})

    def test_no_axes_requested_is_a_no_op(self):
        cam = FakeCamera(specs=ptz_specs())
        result = pixy.apply_ptz(cam)
        self.assertEqual(result, {"written": {}, "failed": {}})
        self.assertEqual(cam.writes, [])


# ---------------------------------------------------------------- image controls


class ImageTableTests(unittest.TestCase):
    """The table is a published interface: profiles on disk are keyed by it."""

    def test_keys_are_unique(self):
        keys = [c["key"] for c in pixy.IMAGE_CONTROLS]
        self.assertEqual(len(keys), len(set(keys)))

    def test_cids_are_unique(self):
        cids = [c["cid"] for c in pixy.IMAGE_CONTROLS]
        self.assertEqual(len(cids), len(set(cids)))

    def test_every_auto_reference_resolves(self):
        # A typo here would produce a control the panel can never explain the
        # dimming of, and an `apply_image` KeyError on the failure path.
        for entry in pixy.IMAGE_CONTROLS:
            if entry.get("auto"):
                self.assertIn(entry["auto"], pixy.IMAGE_BY_KEY, entry["key"])

    def test_autos_are_listed_before_the_controls_they_hold(self):
        # Not required by apply_image, which orders explicitly, but the panel
        # renders in table order and a switch below its slider reads backwards.
        order = [c["key"] for c in pixy.IMAGE_CONTROLS]
        for entry in pixy.IMAGE_CONTROLS:
            if entry.get("auto"):
                self.assertLess(order.index(entry["auto"]), order.index(entry["key"]))

    def test_reset_exclusions_name_real_controls(self):
        for key in pixy.RESET_EXCLUDE:
            self.assertIn(key, pixy.IMAGE_BY_KEY)

    def test_the_curated_set_is_the_everyday_controls(self):
        # `image --curated` is the only reader — the panel shows all of them — so
        # this list is a claim about which controls people reach for, and adding to
        # it is a design decision rather than a detail.
        self.assertEqual(
            [c["key"] for c in pixy.IMAGE_CONTROLS if c.get("curated")],
            ["brightness", "contrast", "saturation", "sharpness", "gamma",
             "whiteBalanceAuto", "whiteBalance"],
        )

    def test_continuous_zoom_is_not_in_the_table(self):
        # It advertises [0..0] on this camera: writes succeed, nothing moves.
        self.assertNotIn(0x009A090F, [c["cid"] for c in pixy.IMAGE_CONTROLS])


class ReadImageTests(unittest.TestCase):
    def test_reports_every_control_in_table_order(self):
        controls = pixy.read_image(image_camera())
        self.assertEqual([c["key"] for c in controls],
                         [c["key"] for c in pixy.IMAGE_CONTROLS])

    def test_curated_only_narrows_the_list(self):
        controls = pixy.read_image(image_camera(), curated_only=True)
        self.assertEqual([c["key"] for c in controls],
                         ["brightness", "contrast", "saturation", "sharpness",
                          "gamma", "whiteBalanceAuto", "whiteBalance"])

    def test_carries_range_type_and_value(self):
        control = next(c for c in pixy.read_image(image_camera())
                       if c["key"] == "whiteBalance")
        self.assertEqual(control["min"], 2300)
        self.assertEqual(control["max"], 7500)
        self.assertEqual(control["type"], "integer")
        self.assertEqual(control["value"], 5000)
        self.assertEqual(control["unit"], "K")
        self.assertEqual(control["auto"], "whiteBalanceAuto")

    def test_unsupported_controls_are_dropped_not_flagged(self):
        cam = image_camera(missing={cid("hue")})
        self.assertNotIn("hue", [c["key"] for c in pixy.read_image(cam)])

    def test_degenerate_ranges_are_dropped(self):
        # The `Zoom, Continuous` shape: a control with no range would render as
        # a slider that cannot move, which is worse than no slider.
        cam = image_camera()
        cam.specs[cid("gain")] = {"min": 0, "max": 0, "step": 1, "default": 0,
                                  "inactive": False, "type": "integer"}
        self.assertNotIn("gain", [c["key"] for c in pixy.read_image(cam)])

    def test_unreadable_controls_are_dropped(self):
        cam = image_camera()
        del cam.values[cid("sharpness")]
        self.assertNotIn("sharpness", [c["key"] for c in pixy.read_image(cam)])

    def test_menu_controls_carry_their_options(self):
        control = next(c for c in pixy.read_image(image_camera())
                       if c["key"] == "autoExposure")
        self.assertEqual(control["type"], "menu")
        self.assertEqual([o["value"] for o in control["options"]], [1, 3])

    def test_non_menu_controls_carry_no_options(self):
        control = next(c for c in pixy.read_image(image_camera())
                       if c["key"] == "brightness")
        self.assertNotIn("options", control)

    def test_inactive_is_reported_from_the_driver(self):
        # This is what the panel dims from, so it has to be the live flag rather
        # than the panel's own idea of which autos are on.
        controls = {c["key"]: c for c in pixy.read_image(image_camera())}
        self.assertTrue(controls["whiteBalance"]["inactive"])
        cam = image_camera()
        cam.values[cid("whiteBalanceAuto")] = 0
        controls = {c["key"]: c for c in pixy.read_image(cam)}
        self.assertFalse(controls["whiteBalance"]["inactive"])

    def test_reading_writes_nothing(self):
        # Enumerating menus used to test-write each index. It no longer does,
        # and it must not start again: the panel reads this on every refresh.
        cam = image_camera()
        pixy.read_image(cam)
        self.assertEqual(cam.writes, [])


class ApplyImageTests(unittest.TestCase):
    def test_writes_only_what_was_asked_for(self):
        cam = image_camera()
        result = pixy.apply_image(cam, {"brightness": 160})
        self.assertEqual(result["written"], {"brightness": 160})
        self.assertEqual([c for c, _ in cam.writes], [cid("brightness")])

    def test_out_of_range_values_are_clamped(self):
        cam = image_camera()
        result = pixy.apply_image(cam, {"gain": 9999, "brightness": -5})
        self.assertEqual(result["written"], {"gain": 100, "brightness": 0})

    def test_reports_the_readback_not_the_request(self):
        # The device clamps silently, so the readback is the only honest answer —
        # and it is what the panel's slider handle should move to.
        cam = image_camera()
        cam.set = lambda c, v: (cam.values.__setitem__(c, 42), True)[1]
        result = pixy.apply_image(cam, {"brightness": 200})
        self.assertEqual(result["written"], {"brightness": 42})

    def test_unsupported_control_is_reported_not_raised(self):
        cam = image_camera(missing={cid("hue")})
        result = pixy.apply_image(cam, {"hue": 100})
        self.assertIn("hue", result["failed"])
        self.assertEqual(result["written"], {})

    def test_going_manual_turns_the_auto_off_first(self):
        # In table order the auto comes first anyway; this pins the outcome, not
        # the sequence, because the outcome is what breaks if the ordering moves.
        cam = image_camera()
        result = pixy.apply_image(cam, {"whiteBalanceAuto": 0, "whiteBalance": 3200})
        self.assertEqual(result["failed"], {})
        self.assertEqual(cam.values[cid("whiteBalance")], 3200)

    def test_going_auto_writes_the_value_before_the_auto(self):
        # The case a single table-order pass gets wrong: the auto would go on
        # first and bury the value, which then reappears the next time someone
        # switches that auto off.
        cam = image_camera()
        cam.values[cid("whiteBalanceAuto")] = 0
        result = pixy.apply_image(cam, {"whiteBalance": 6500, "whiteBalanceAuto": 1})
        self.assertEqual(result["failed"], {})
        self.assertEqual(cam.values[cid("whiteBalance")], 6500)
        self.assertEqual(cam.values[cid("whiteBalanceAuto")], 1)

    def test_a_held_control_fails_when_its_auto_was_not_asked_for(self):
        cam = image_camera()
        result = pixy.apply_image(cam, {"whiteBalance": 4000})
        self.assertIn("white balance", result["failed"]["whiteBalance"])
        self.assertEqual(result["written"], {})

    def test_a_held_control_is_silent_when_its_auto_was_asked_for(self):
        # Loading a profile captured in auto mode, onto a camera already in auto
        # mode: the buried value cannot be written and that is the correct
        # outcome, not something to warn about. Without this the panel would
        # report a failure on every recall of an auto-mode profile.
        cam = image_camera()
        result = pixy.apply_image(cam, {"whiteBalance": 4000, "whiteBalanceAuto": 1})
        self.assertEqual(result["failed"], {})
        self.assertNotIn("whiteBalance", result["written"])
        self.assertEqual(cam.values[cid("whiteBalance")], 5000)

    def test_each_control_is_written_at_most_once(self):
        cam = image_camera()
        pixy.apply_image(cam, {"whiteBalanceAuto": 0, "whiteBalance": 3200,
                               "brightness": 140})
        self.assertEqual(len(cam.writes), len(set(c for c, _ in cam.writes)))

    def test_uncover_reaches_a_value_under_an_auto_that_stays_on(self):
        cam = image_camera()
        result = pixy.apply_image(cam, {"whiteBalance": 4400}, uncover=True)
        self.assertEqual(result["written"], {"whiteBalance": 4400})
        self.assertEqual(cam.values[cid("whiteBalance")], 4400)
        # And the auto is left as it was found.
        self.assertEqual(cam.values[cid("whiteBalanceAuto")], 1)

    def test_uncover_restores_the_auto_even_when_the_write_fails(self):
        # Leaving an auto switched off because a reset went sideways would be a
        # worse outcome than the stale value it was trying to clear.
        cam = image_camera(reject={cid("whiteBalance")})
        pixy.apply_image(cam, {"whiteBalance": 4400}, uncover=True)
        self.assertEqual(cam.values[cid("whiteBalanceAuto")], 1)

    def test_uncover_uses_the_documented_manual_value(self):
        # Auto Exposure is a menu whose manual index is 1; writing 0 would be
        # rejected and the exposure would stay buried.
        cam = image_camera()
        result = pixy.apply_image(cam, {"exposure": 900}, uncover=True)
        self.assertEqual(result["written"], {"exposure": 900})
        self.assertEqual(cam.values[cid("autoExposure")], 3)

    def test_without_uncover_a_held_value_is_left_alone(self):
        cam = image_camera()
        pixy.apply_image(cam, {"whiteBalance": 4400})
        self.assertEqual(cam.values[cid("whiteBalance")], 5000)

    def test_nothing_requested_is_a_no_op(self):
        cam = image_camera()
        self.assertEqual(pixy.apply_image(cam, {}), {"written": {}, "failed": {}})
        self.assertEqual(cam.writes, [])


class ResetTargetsTests(unittest.TestCase):
    def test_uses_the_drivers_defaults(self):
        targets = pixy.reset_targets(image_camera())
        self.assertEqual(targets["brightness"], 128)
        self.assertEqual(targets["whiteBalance"], 5000)
        self.assertEqual(targets["focus"], 192)

    def test_skips_power_line_frequency(self):
        # The driver's default is 60 Hz, so resetting it would introduce the
        # flicker the control exists to remove on 50 Hz mains.
        self.assertNotIn("powerLineFrequency", pixy.reset_targets(image_camera()))

    def test_includes_controls_currently_held_by_an_auto(self):
        # They are reachable via `uncover`, and a reset that skipped them would
        # leave a detuned value to surface later.
        self.assertIn("whiteBalance", pixy.reset_targets(image_camera()))

    def test_skips_controls_the_camera_does_not_have(self):
        cam = image_camera(missing={cid("hue")})
        self.assertNotIn("hue", pixy.reset_targets(cam))

    def test_skips_degenerate_ranges(self):
        cam = image_camera()
        cam.specs[cid("gain")] = {"min": 0, "max": 0, "step": 1, "default": 0,
                                  "inactive": False, "type": "integer"}
        self.assertNotIn("gain", pixy.reset_targets(cam))

    def test_a_reset_reaches_neutral_from_a_fully_detuned_camera(self):
        # The end-to-end claim the Reset button makes, including the values
        # buried under autos that were already on.
        cam = image_camera()
        cam.values.update({
            cid("brightness"): 40, cid("whiteBalanceAuto"): 1,
            cid("whiteBalance"): 3000, cid("focusAuto"): 1, cid("focus"): 900,
            cid("autoExposure"): 3, cid("exposure"): 2000,
        })
        result = pixy.apply_image(cam, pixy.reset_targets(cam), uncover=True)
        self.assertEqual(result["failed"], {})
        for key in ("brightness", "whiteBalance", "focus", "exposure"):
            self.assertEqual(cam.values[cid(key)],
                             cam.specs[cid(key)]["default"], key)
        for key in ("whiteBalanceAuto", "focusAuto", "autoExposure"):
            self.assertEqual(cam.values[cid(key)],
                             cam.specs[cid(key)]["default"], key)


class ParseAssignmentsTests(unittest.TestCase):
    def test_parses_pairs(self):
        values, errors = pixy.parse_assignments(["brightness=160", "contrast=90"])
        self.assertEqual(values, {"brightness": 160, "contrast": 90})
        self.assertEqual(errors, [])

    def test_none_is_accepted(self):
        # argparse leaves an unused `append` action as None.
        self.assertEqual(pixy.parse_assignments(None), ({}, []))

    def test_unknown_keys_are_collected_not_raised(self):
        values, errors = pixy.parse_assignments(["nope=1", "gamma=140"])
        self.assertEqual(values, {"gamma": 140})
        self.assertEqual(len(errors), 1)
        self.assertIn("nope", errors[0])

    def test_a_missing_equals_sign_is_an_error(self):
        values, errors = pixy.parse_assignments(["brightness"])
        self.assertEqual(values, {})
        self.assertIn("KEY=VALUE", errors[0])

    def test_non_numeric_values_are_an_error(self):
        values, errors = pixy.parse_assignments(["brightness=bright"])
        self.assertEqual(values, {})
        self.assertIn("brightness", errors[0])

    def test_fractional_values_round(self):
        # The panel sends integers; a human at the CLI may not.
        self.assertEqual(pixy.parse_assignments(["brightness=127.6"])[0],
                         {"brightness": 128})

    def test_whitespace_around_the_key_is_tolerated(self):
        self.assertEqual(pixy.parse_assignments([" brightness =10"])[0],
                         {"brightness": 10})

    def test_a_repeated_key_takes_the_last_value(self):
        self.assertEqual(pixy.parse_assignments(["gamma=100", "gamma=140"])[0],
                         {"gamma": 140})


# ---------------------------------------------------------------- profiles


class ProfileStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_missing_store_reads_as_empty(self):
        self.assertEqual(pixy.read_profiles(), {})

    def test_round_trip(self):
        profiles = {"warm": {"brightness": 150, "saturation": 140}}
        self.assertTrue(pixy.write_profiles(profiles))
        self.assertEqual(pixy.read_profiles(), profiles)

    def test_profiles_do_not_clobber_framing_presets(self):
        # The whole reason the two live under separate keys: recalling a framing
        # preset must not change how the picture looks, and vice versa.
        pixy.write_presets({1: {"pan": 30, "tilt": -10, "zoom": 120}})
        pixy.write_profiles({"warm": {"brightness": 150}})
        self.assertEqual(pixy.read_presets(), {1: {"pan": 30, "tilt": -10, "zoom": 120}})
        self.assertEqual(pixy.read_profiles(), {"warm": {"brightness": 150}})

    def test_framing_presets_do_not_clobber_profiles(self):
        pixy.write_profiles({"warm": {"brightness": 150}})
        pixy.write_presets({2: {"pan": 0, "tilt": 0, "zoom": 100}})
        self.assertEqual(pixy.read_profiles(), {"warm": {"brightness": 150}})

    def test_corrupt_json_reads_as_empty(self):
        os.makedirs(os.path.dirname(pixy.state_path()), exist_ok=True)
        with open(pixy.state_path(), "w", encoding="utf-8") as fh:
            fh.write("{not json")
        self.assertEqual(pixy.read_profiles(), {})

    def test_a_top_level_non_object_reads_as_empty(self):
        os.makedirs(os.path.dirname(pixy.state_path()), exist_ok=True)
        with open(pixy.state_path(), "w", encoding="utf-8") as fh:
            fh.write("[1, 2, 3]")
        self.assertEqual(pixy.read_store(), {})

    def test_unknown_keys_in_a_profile_are_dropped(self):
        # A profile written by a later build that added controls still loads, as
        # its recognized subset, rather than failing outright.
        self.write_raw({"profiles": {"warm": {"brightness": 150, "tint": 12}}})
        self.assertEqual(pixy.read_profiles(), {"warm": {"brightness": 150}})

    def test_non_numeric_values_are_dropped(self):
        self.write_raw({"profiles": {"warm": {"brightness": "high", "gamma": 140}}})
        self.assertEqual(pixy.read_profiles(), {"warm": {"gamma": 140}})

    def test_a_profile_left_with_nothing_usable_is_dropped(self):
        self.write_raw({"profiles": {"warm": {"tint": 5}, "cool": {"gamma": 100}}})
        self.assertEqual(set(pixy.read_profiles()), {"cool"})

    def test_non_dict_profiles_are_dropped(self):
        self.write_raw({"profiles": {"warm": "nope", "cool": {"gamma": 100}}})
        self.assertEqual(set(pixy.read_profiles()), {"cool"})

    def test_profiles_of_wrong_type_reads_as_empty(self):
        self.write_raw({"profiles": ["warm"]})
        self.assertEqual(pixy.read_profiles(), {})

    def test_write_leaves_no_temp_file_behind(self):
        pixy.write_profiles({"warm": {"brightness": 150}})
        leftovers = [n for n in os.listdir(os.path.dirname(pixy.state_path()))
                     if n.endswith(".tmp")]
        self.assertEqual(leftovers, [])

    def test_unwritable_store_reports_failure_rather_than_raising(self):
        with mock.patch.object(pixy.os, "makedirs",
                               side_effect=OSError(errno.EROFS, "read-only")):
            self.assertFalse(pixy.write_profiles({"warm": {"brightness": 150}}))

    def write_raw(self, blob):
        os.makedirs(os.path.dirname(pixy.state_path()), exist_ok=True)
        with open(pixy.state_path(), "w", encoding="utf-8") as fh:
            json.dump(blob, fh)


class ConcurrentStoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name})
        patcher.start()
        self.addCleanup(patcher.stop)

    def race(self, first, second):
        first_writing = threading.Event()
        release_first = threading.Event()
        guard = threading.Lock()
        first_call = [True]
        original = pixy.write_store

        def delayed_write(blob):
            with guard:
                delay = first_call[0]
                first_call[0] = False
            if delay:
                first_writing.set()
                if not release_first.wait(2):
                    return False
            return original(blob)

        results = []
        with mock.patch.object(pixy, "write_store", side_effect=delayed_write):
            one = threading.Thread(target=lambda: results.append(first()))
            two = threading.Thread(target=lambda: results.append(second()))
            one.start()
            self.assertTrue(first_writing.wait(2))
            two.start()
            # Give the second writer time to reach the lock. Without a lock it
            # reads the old document and completes before the first is released.
            threading.Event().wait(0.05)
            release_first.set()
            one.join(2)
            two.join(2)
        self.assertFalse(one.is_alive())
        self.assertFalse(two.is_alive())
        self.assertEqual(len(results), 2)
        self.assertTrue(all(result[0] for result in results))

    def test_concurrent_preset_and_profile_updates_preserve_both(self):
        self.race(
            lambda: pixy.update_preset(1, {"pan": 10, "tilt": 5, "zoom": 120}),
            lambda: pixy.update_profile("warm", {"brightness": 150}),
        )
        self.assertEqual(pixy.read_presets(),
                         {1: {"pan": 10, "tilt": 5, "zoom": 120}})
        self.assertEqual(pixy.read_profiles(), {"warm": {"brightness": 150}})

    def test_concurrent_slot_updates_preserve_both_slots(self):
        self.race(
            lambda: pixy.update_preset(1, {"pan": 10, "tilt": 5, "zoom": 120}),
            lambda: pixy.update_preset(2, {"pan": -20, "tilt": 0, "zoom": 130}),
        )
        self.assertEqual(set(pixy.read_presets()), {1, 2})

    # A clear that finds nothing must not write. Writing normalizes, and
    # normalizing drops what this build does not recognize — so a no-op clear
    # would silently prune a newer build's keys. That is the exact loss
    # clean_profiles is written to avoid, so it must not arrive by this door.
    def clear_probe(self, action):
        path = pixy.state_path()
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({
                "profiles": {"warm": {"brightness": 150, "unknownFutureKey": 7}},
                "slots": {"1": {"pan": 1, "tilt": 2, "zoom": 100, "roll": 9}},
                "somethingElseEntirely": {"kept": True},
            }, fh)
        with open(path, "rb") as fh:
            before = fh.read()
        result = action()
        with open(path, "rb") as fh:
            return before, fh.read(), result

    def test_clearing_an_absent_profile_leaves_the_document_untouched(self):
        before, after, (written, existed, _) = self.clear_probe(
            lambda: pixy.update_profile("nope", None))
        self.assertTrue(written)
        self.assertFalse(existed)
        self.assertEqual(before, after)

    def test_clearing_an_empty_slot_leaves_the_document_untouched(self):
        before, after, (written, _) = self.clear_probe(
            lambda: pixy.update_preset(3, None))
        self.assertTrue(written)
        self.assertEqual(before, after)

    def test_a_real_clear_still_writes(self):
        before, after, (written, existed, profiles) = self.clear_probe(
            lambda: pixy.update_profile("warm", None))
        self.assertTrue(written)
        self.assertTrue(existed)
        self.assertNotEqual(before, after)
        self.assertEqual(profiles, {})

    def test_the_profile_clear_command_reports_a_missing_name(self):
        self.clear_probe(lambda: None)
        result = json.loads(json.dumps(pixy.cmd_profile(
            args_for(["profile", "clear", "nope"]))))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "no such profile")


# ---------------------------------------------------------------- commands


class CommandContractTests(unittest.TestCase):
    """Every command returns JSON-serializable data and never raises."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name})
        patcher.start()
        self.addCleanup(patcher.stop)
        # No vendor node unless a test asks for one. `preset save` mirrors into the
        # camera's own slots, so without this the suite would reach a real hidraw
        # on a developer machine and write to the hardware. Tests that want the
        # mirror patch this themselves.
        absent = mock.patch.object(pixy, "find_hidraw", return_value=None)
        absent.start()
        self.addCleanup(absent.stop)

    def assert_json(self, result):
        self.assertIsInstance(result, dict)
        json.dumps(result)  # raises if the view carries anything unserializable
        return result

    def test_state_with_no_camera_reports_absent(self):
        with mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "find_hidraw", return_value=None):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertFalse(result["present"])
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "no-camera")
        # The panel reads .presets unconditionally.
        self.assertEqual(result["presets"], {})

    def test_state_reports_degrees_not_arcseconds(self):
        cam = FakeCamera(
            values={pixy.CID_PAN_ABSOLUTE: 30 * 3600, pixy.CID_TILT_ABSOLUTE: -10 * 3600,
                    pixy.CID_ZOOM_ABSOLUTE: 130},
            specs=ptz_specs(),
        )
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value=None), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "capability", return_value={"card": "EMEET PIXY", "driver": "uvcvideo"}):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertEqual((result["pan"], result["tilt"], result["zoom"]), (30, -10, 130))
        self.assertEqual((result["panMin"], result["panMax"]), (-150, 150))
        self.assertEqual((result["tiltMin"], result["tiltMax"]), (-90, 90))

    def test_state_without_hid_explains_why_the_mode_is_unknown(self):
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value=None), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "capability", return_value=None):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertIsNone(result["mode"])
        self.assertIsNone(result["privacy"])
        self.assertEqual(result["modeUnknown"], "no-hid")

    def test_state_marks_privacy_separately_from_mode(self):
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "read_mode", return_value=("privacy", 0x02)), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "capability", return_value=None):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertTrue(result["privacy"])
        self.assertEqual(result["mode"], "privacy")

    def test_state_idle_camera_reports_needs_stream(self):
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "read_mode", return_value=(None, 0x03)), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "capability", return_value=None):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertEqual(result["modeUnknown"], "needs-stream")
        self.assertFalse(result["privacy"])

    def test_state_silent_camera_reports_no_response(self):
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "read_mode", return_value=(None, None)), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "capability", return_value=None):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertEqual(result["modeUnknown"], "no-response")
        self.assertIsNone(result["privacy"])

    def test_state_ambiguous_byte_still_confirms_the_shutter_is_open(self):
        # 0x03 resolves to no mode, but it is not silence: the camera answered,
        # and privacy would have answered 0x02. So the shutter is known-open even
        # though Standard and Tracking cannot be told apart.
        self.assertIn(pixy.MODE_AMBIGUOUS, pixy.MODE_NOT_PRIVACY)
        self.assertNotIn(pixy.MODE_VALUES["privacy"], pixy.MODE_NOT_PRIVACY)

    def test_mode_write_with_a_silent_readback_reports_unknown_privacy(self):
        # The write went out and the confirmation query got nothing back. That is
        # not evidence the lens is open.
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "write_reports", return_value=None), \
             mock.patch.object(pixy, "read_mode", return_value=(None, None)), \
             mock.patch.object(pixy.time, "sleep", return_value=None):
            result = self.assert_json(pixy.cmd_mode(args_for(["mode", "standard"])))
        self.assertIsNone(result["privacy"])
        self.assertIsNone(result["mode"])
        self.assertFalse(result["confirmed"])

    def test_mode_write_on_an_idle_camera_reports_the_shutter_open(self):
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "write_reports", return_value=None), \
             mock.patch.object(pixy, "read_mode", return_value=(None, 0x03)), \
             mock.patch.object(pixy.time, "sleep", return_value=None):
            result = self.assert_json(pixy.cmd_mode(args_for(["mode", "standard"])))
        self.assertFalse(result["privacy"])

    def test_state_names_who_holds_the_stream(self):
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value=None), \
             mock.patch.object(pixy, "stream_holders", return_value=([4242], [])), \
             mock.patch.object(pixy, "process_name", return_value="zoom"), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "capability", return_value=None):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertTrue(result["streaming"])
        self.assertEqual(result["streamUsers"], ["zoom"])
        self.assertFalse(result["selfStreaming"])

    def test_state_reports_our_own_preview_without_calling_it_busy(self):
        # The panel's own preview holds the stream. `streaming` must stay false —
        # otherwise the preview sees itself as a blocker and shuts itself off,
        # then reopens because the blocker vanished, forever. `selfStreaming`
        # carries the fact instead, and the holder is not named as a user.
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value=None), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [2000])), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "capability", return_value=None):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertFalse(result["streaming"])
        self.assertEqual(result["streamUsers"], [])
        self.assertTrue(result["selfStreaming"])

    def test_state_without_a_video_node_still_reports_stream_fields(self):
        # The panel reads all three unconditionally.
        with mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "read_mode", return_value=(None, 0x03)):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertFalse(result["streaming"])
        self.assertFalse(result["selfStreaming"])
        self.assertEqual(result["streamUsers"], [])

    def test_state_busy_node_stays_ok(self):
        # A meeting app holding the camera is expected, not a failure — PTZ
        # still works, so flipping ok=false would make the panel cry wolf.
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value=None), \
             mock.patch.object(pixy, "stream_holders", return_value=([1], [])), \
             mock.patch.object(pixy, "process_name", return_value="firefox"), \
             mock.patch.object(pixy, "Camera", side_effect=OSError(errno.EBUSY, "busy")):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertTrue(result["ok"])
        self.assertEqual(result["videoError"], "device busy")

    def test_state_unexpected_video_error_is_not_ok(self):
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value=None), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "Camera", side_effect=OSError(errno.EIO, "I/O error")):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertFalse(result["ok"])

    def test_state_hid_error_is_reported_as_data(self):
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "read_mode", side_effect=OSError(errno.EACCES, "denied")), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "capability", return_value=None):
            result = self.assert_json(pixy.cmd_state(args_for(["state"])))
        self.assertEqual(result["modeUnknown"], "hid-error")
        self.assertIsNone(result["privacy"])
        self.assertIn("udev", result["hidError"])

    def test_holders_reports_the_same_fields_as_state(self):
        # The panel merges this reply into the state it already has, so the field
        # names have to match `state` exactly or the merge silently does nothing.
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "find_hidraw", return_value=None), \
             mock.patch.object(pixy, "stream_holders", return_value=([4242], [2000])), \
             mock.patch.object(pixy, "process_name", return_value="zoom"), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "capability", return_value=None):
            state = pixy.cmd_state(args_for(["state"]))
            holders = self.assert_json(pixy.cmd_holders(args_for(["holders"])))
        for key in ("streaming", "streamUsers", "selfStreaming"):
            self.assertEqual(holders[key], state[key], key)

    def test_holders_does_not_query_the_hid_interface(self):
        # The entire reason this subcommand exists: read_mode costs ~600 ms of
        # HID round-trip and settle sleeps, which is what makes `state` too slow
        # to poll. Touching it here would make `holders` pointless.
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [])), \
             mock.patch.object(pixy, "read_mode", side_effect=AssertionError("HID query")), \
             mock.patch.object(pixy, "query", side_effect=AssertionError("HID query")), \
             mock.patch.object(pixy, "Camera", side_effect=AssertionError("opened the node")):
            result = self.assert_json(pixy.cmd_holders(args_for(["holders"])))
        self.assertTrue(result["ok"])

    def test_holders_reports_only_other_apps_as_streaming(self):
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "stream_holders", return_value=([], [2000])):
            result = self.assert_json(pixy.cmd_holders(args_for(["holders"])))
        self.assertFalse(result["streaming"])
        self.assertTrue(result["selfStreaming"])
        self.assertEqual(result["streamUsers"], [])

    def test_holders_without_a_camera_still_carries_every_field(self):
        with mock.patch.object(pixy, "find_video", return_value=None):
            result = self.assert_json(pixy.cmd_holders(args_for(["holders"])))
        self.assertFalse(result["present"])
        self.assertFalse(result["streaming"])
        self.assertFalse(result["selfStreaming"])
        self.assertEqual(result["streamUsers"], [])

    def test_mode_without_hid_reports_absent(self):
        with mock.patch.object(pixy, "find_hidraw", return_value=None):
            result = self.assert_json(pixy.cmd_mode(args_for(["mode", "tracking"])))
        self.assertFalse(result["ok"])
        self.assertFalse(result["present"])

    def test_mode_reports_only_a_confirmed_mode(self):
        # Echoing the request would let the panel claim privacy is on when the
        # write may not have landed.
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "write_reports"), \
             mock.patch.object(pixy.time, "sleep"), \
             mock.patch.object(pixy, "read_mode", return_value=(None, 0x03)):
            result = self.assert_json(pixy.cmd_mode(args_for(["mode", "standard"])))
        self.assertTrue(result["ok"])
        self.assertEqual(result["requested"], "standard")
        self.assertIsNone(result["mode"])
        self.assertFalse(result["confirmed"])

    def test_mode_confirms_privacy(self):
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "write_reports"), \
             mock.patch.object(pixy.time, "sleep"), \
             mock.patch.object(pixy, "read_mode", return_value=("privacy", 0x02)):
            result = self.assert_json(pixy.cmd_mode(args_for(["mode", "privacy"])))
        self.assertTrue(result["confirmed"])
        self.assertTrue(result["privacy"])

    def test_mode_reports_streaming_only_when_something_holds_the_node(self):
        # Regression: `stream_holders` returns a 2-tuple, and a tuple is always
        # truthy, so `bool(stream_holders(node))` reported every camera as
        # streaming. The lists have to be unpacked and tested individually.
        cases = (((["x"], []), True), (([], ["x"]), True), (([], []), False))
        for holders, expected in cases:
            with self.subTest(holders=holders):
                with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
                     mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
                     mock.patch.object(pixy, "stream_holders", return_value=holders), \
                     mock.patch.object(pixy, "write_reports"), \
                     mock.patch.object(pixy.time, "sleep"), \
                     mock.patch.object(pixy, "read_mode", return_value=("standard", 0x00)):
                    result = self.assert_json(pixy.cmd_mode(args_for(["mode", "standard"])))
                self.assertIs(result["streaming"], expected)

    def test_single_tracking_command_serializes_privacy_transition(self):
        # Call automation dispatches one absolute `mode tracking` command. The
        # helper owns the ordered hardware transaction, so this is the
        # integration boundary that must put Standard on the wire first.
        sent = []
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "write_reports", side_effect=lambda p, r: sent.append(r)), \
             mock.patch.object(pixy.time, "sleep"), \
             mock.patch.object(pixy, "read_mode", return_value=("privacy", 0x02)):
            pixy.cmd_mode(args_for(["mode", "tracking"]))
        self.assertEqual(len(sent), 2)
        self.assertEqual(sent[0][0][8], pixy.MODE_VALUES["standard"])
        self.assertEqual(sent[1][0][8], pixy.MODE_VALUES["tracking"])

    def test_tracking_from_standard_writes_once(self):
        sent = []
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "write_reports", side_effect=lambda p, r: sent.append(r)), \
             mock.patch.object(pixy.time, "sleep"), \
             mock.patch.object(pixy, "read_mode", return_value=("standard", 0x00)):
            pixy.cmd_mode(args_for(["mode", "tracking"]))
        self.assertEqual(len(sent), 1)

    def test_mode_write_failure_is_reported_as_data(self):
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "write_reports", side_effect=OSError(errno.EACCES, "denied")), \
             mock.patch.object(pixy.time, "sleep"), \
             mock.patch.object(pixy, "read_mode", return_value=("standard", 0x00)):
            result = self.assert_json(pixy.cmd_mode(args_for(["mode", "privacy"])))
        self.assertFalse(result["ok"])
        self.assertIn("udev", result["error"])

    def test_privacy_toggle_turns_privacy_on_when_off(self):
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "write_reports"), \
             mock.patch.object(pixy.time, "sleep"), \
             mock.patch.object(pixy, "read_mode", return_value=("standard", 0x00)):
            result = self.assert_json(pixy.cmd_toggle_privacy(args_for(["privacy"])))
        self.assertEqual(result["requested"], "privacy")

    def test_privacy_toggle_turns_privacy_off_when_on(self):
        # The regression: an idle camera reports privacy unambiguously, so the
        # toggle must alternate rather than turning privacy on twice.
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "write_reports"), \
             mock.patch.object(pixy.time, "sleep"), \
             mock.patch.object(pixy, "read_mode", return_value=("privacy", 0x02)):
            result = self.assert_json(pixy.cmd_toggle_privacy(args_for(["privacy"])))
        self.assertEqual(result["requested"], "standard")

    def test_privacy_toggle_leaves_privacy_for_standard_not_tracking(self):
        # Leaving privacy should not quietly enable a camera behavior nobody
        # asked for.
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "write_reports"), \
             mock.patch.object(pixy.time, "sleep"), \
             mock.patch.object(pixy, "read_mode", return_value=("privacy", 0x02)):
            result = pixy.cmd_toggle_privacy(args_for(["privacy"]))
        self.assertNotEqual(result["requested"], "tracking")

    def test_privacy_toggle_on_unknown_mode_errs_toward_privacy_on(self):
        # The safe direction when someone is reaching for the button.
        with mock.patch.object(pixy, "find_hidraw", return_value="/dev/hidrawTEST"), \
             mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "write_reports"), \
             mock.patch.object(pixy.time, "sleep"), \
             mock.patch.object(pixy, "read_mode", return_value=(None, 0x03)):
            result = pixy.cmd_toggle_privacy(args_for(["privacy"]))
        self.assertEqual(result["requested"], "privacy")

    def test_ptz_without_a_target_is_a_no_op_error(self):
        result = self.assert_json(pixy.cmd_ptz(args_for(["ptz"])))
        self.assertFalse(result["ok"])

    def test_ptz_home_recenters_both_axes(self):
        cam = FakeCamera(values={pixy.CID_PAN_ABSOLUTE: 0, pixy.CID_TILT_ABSOLUTE: 0}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "Camera", return_value=cam):
            result = self.assert_json(pixy.cmd_ptz(args_for(["ptz", "--home"])))
        self.assertEqual(result["written"], {"pan": 0, "tilt": 0})
        self.assertTrue(result["ok"])

    def test_ptz_nudge_resolves_against_the_live_position(self):
        # Relative motion must compose with a move made from another app, so it
        # is resolved from the camera rather than from a local guess.
        cam = FakeCamera(values={pixy.CID_PAN_ABSOLUTE: 20 * 3600, pixy.CID_TILT_ABSOLUTE: 0}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "Camera", return_value=cam):
            result = self.assert_json(pixy.cmd_ptz(args_for(["ptz", "--nudge", "right", "--step", "5"])))
        self.assertEqual(result["written"]["pan"], 25)

    def test_ptz_nudge_directions_map_correctly(self):
        for direction, axis, expected in (
            ("left", "pan", -5), ("right", "pan", 5), ("up", "tilt", 5), ("down", "tilt", -5)
        ):
            cam = FakeCamera(values={pixy.CID_PAN_ABSOLUTE: 0, pixy.CID_TILT_ABSOLUTE: 0}, specs=ptz_specs())
            with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
                 mock.patch.object(pixy, "Camera", return_value=cam):
                result = pixy.cmd_ptz(args_for(["ptz", "--nudge", direction, "--step", "5"]))
            self.assertEqual(result["written"].get(axis), expected, direction)

    def test_ptz_nudge_clamps_at_the_rail(self):
        cam = FakeCamera(values={pixy.CID_PAN_ABSOLUTE: 150 * 3600, pixy.CID_TILT_ABSOLUTE: 0}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "Camera", return_value=cam):
            result = pixy.cmd_ptz(args_for(["ptz", "--nudge", "right", "--step", "20"]))
        self.assertEqual(result["written"]["pan"], 150)

    def test_ptz_without_a_camera_reports_absent(self):
        with mock.patch.object(pixy, "find_video", return_value=None):
            result = self.assert_json(pixy.cmd_ptz(args_for(["ptz", "--home"])))
        self.assertFalse(result["ok"])
        self.assertFalse(result["present"])

    def test_zoom_writes_and_reads_back(self):
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "Camera", return_value=cam):
            result = self.assert_json(pixy.cmd_zoom(args_for(["zoom", "130"])))
        self.assertEqual(result["zoom"], 130)
        self.assertTrue(result["ok"])

    def test_zoom_out_of_range_is_clamped_not_rejected(self):
        cam = FakeCamera(values={pixy.CID_ZOOM_ABSOLUTE: 100}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "Camera", return_value=cam):
            result = self.assert_json(pixy.cmd_zoom(args_for(["zoom", "999"])))
        self.assertEqual(result["written"]["zoom"], 150)

    def test_preset_rejects_an_out_of_range_slot(self):
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "save", "9"])))
        self.assertFalse(result["ok"])

    def test_preset_save_then_load_is_an_exact_inverse(self):
        # The reason presets are stored locally as UVC triples at all.
        cam = FakeCamera(
            values={pixy.CID_PAN_ABSOLUTE: 45 * 3600, pixy.CID_TILT_ABSOLUTE: -20 * 3600,
                    pixy.CID_ZOOM_ABSOLUTE: 140},
            specs=ptz_specs(),
        )
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "Camera", return_value=cam):
            saved = self.assert_json(pixy.cmd_preset(args_for(["preset", "save", "2"])))
        self.assertEqual(saved["saved"], {"pan": 45, "tilt": -20, "zoom": 140})

        moved = FakeCamera(
            values={pixy.CID_PAN_ABSOLUTE: 0, pixy.CID_TILT_ABSOLUTE: 0, pixy.CID_ZOOM_ABSOLUTE: 100},
            specs=ptz_specs(),
        )
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "Camera", return_value=moved):
            loaded = self.assert_json(pixy.cmd_preset(args_for(["preset", "load", "2"])))
        self.assertEqual(loaded["written"], {"pan": 45, "tilt": -20, "zoom": 140})

    def test_preset_load_of_an_empty_slot_says_empty(self):
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "load", "1"])))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "empty")

    def test_preset_clear_removes_only_that_slot(self):
        pixy.write_presets({1: {"pan": 1, "tilt": 1, "zoom": 100},
                            3: {"pan": 3, "tilt": 3, "zoom": 130}})
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "clear", "1"])))
        self.assertTrue(result["ok"])
        self.assertEqual(set(pixy.read_presets()), {3})

    def test_preset_clear_of_an_empty_slot_still_succeeds(self):
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "clear", "2"])))
        self.assertTrue(result["ok"])

    def test_preset_save_reports_unreadable_axis_rather_than_storing_a_partial(self):
        cam = FakeCamera(values={pixy.CID_PAN_ABSOLUTE: 0}, specs=ptz_specs())
        with mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"), \
             mock.patch.object(pixy, "Camera", return_value=cam):
            result = self.assert_json(pixy.cmd_preset(args_for(["preset", "save", "1"])))
        self.assertFalse(result["ok"])
        self.assertEqual(pixy.read_presets(), {})

    def mirroring(self, device=None):
        """Patch in a camera whose vendor slots a `preset` call will mirror into."""
        self.device = device if device is not None else FakeVendorDevice()
        stack = ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(mock.patch.object(pixy, "find_hidraw",
                                              return_value="/dev/hidrawTEST"))
        stack.enter_context(mock.patch.object(pixy, "query", side_effect=self.device.query))
        stack.enter_context(mock.patch.object(pixy, "write_reports",
                                             side_effect=self.device.write_reports))
        stack.enter_context(mock.patch.object(pixy.time, "sleep"))
        return self.device

    def ptz_camera(self, pan=45, tilt=-20, zoom=140):
        cam = FakeCamera(
            values={pixy.CID_PAN_ABSOLUTE: pan * 3600,
                    pixy.CID_TILT_ABSOLUTE: tilt * 3600,
                    pixy.CID_ZOOM_ABSOLUTE: zoom},
            specs=ptz_specs(),
        )
        stack = ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(mock.patch.object(pixy, "find_video", return_value="/dev/videoTEST"))
        stack.enter_context(mock.patch.object(pixy, "Camera", return_value=cam))
        return cam

    def test_preset_save_mirrors_into_the_cameras_own_slot(self):
        # So a preset made here shows up in EMEET Studio and survives a reboot.
        device = self.mirroring()
        device.pan, device.tilt = 45.0, -20.0
        self.ptz_camera()
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "save", "2"])))
        self.assertTrue(result["ok"])
        self.assertTrue(result["native"]["confirmed"])
        self.assertTrue(device.presets[2][0])

    def test_preset_clear_erases_the_cameras_slot_too(self):
        device = self.mirroring(FakeVendorDevice(
            presets={1: (True, 45.0, -20.0), 2: (False, 0.0, 0.0), 3: (False, 0.0, 0.0)}
        ))
        pixy.write_presets({1: {"pan": 45, "tilt": -20, "zoom": 140}})
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "clear", "1"])))
        self.assertTrue(result["ok"])
        self.assertFalse(device.presets[1][0])

    def test_a_mirror_that_fails_does_not_lose_the_local_preset(self):
        # The local store is the authority — it is the only one that holds zoom —
        # so a camera that ignores the vendor write must not fail the save.
        self.mirroring(FakeVendorDevice(deaf={(0x03, 0x01, 0x16)}))
        self.ptz_camera()
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "save", "1"])))
        self.assertTrue(result["ok"])
        self.assertFalse(result["native"]["confirmed"])
        self.assertEqual(pixy.read_presets()[1], {"pan": 45, "tilt": -20, "zoom": 140})

    def test_a_camera_without_a_vendor_node_still_saves_locally(self):
        # The ordinary state of a camera whose udev rule is not installed.
        self.ptz_camera()
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "save", "1"])))
        self.assertTrue(result["ok"])
        self.assertIsNone(result["native"])
        self.assertIn(1, pixy.read_presets())

    def test_local_skips_the_mirror_entirely(self):
        device = self.mirroring()
        self.ptz_camera()
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "save", "1", "--local"])))
        self.assertTrue(result["ok"])
        self.assertIsNone(result["native"])
        self.assertEqual(device.writes, [])

    def test_preset_load_does_not_touch_the_cameras_slots(self):
        # Load drives UVC from the local triple, which is the only copy that has
        # the zoom. Reading or writing a vendor slot here would be pure cost.
        device = self.mirroring()
        pixy.write_presets({1: {"pan": 10, "tilt": 5, "zoom": 120}})
        self.ptz_camera(pan=0, tilt=0, zoom=100)
        result = self.assert_json(pixy.cmd_preset(args_for(["preset", "load", "1"])))
        self.assertTrue(result["ok"])
        self.assertEqual(device.writes, [])
        self.assertEqual(device.reads, [])

    def test_preset_views_key_slots_as_strings_for_json(self):
        # JSON object keys are strings; the panel indexes presets by slot, so a
        # numeric key here would silently miss every lookup.
        pixy.write_presets({1: {"pan": 1, "tilt": 1, "zoom": 100}})
        result = pixy.cmd_preset(args_for(["preset", "clear", "3"]))
        self.assertEqual(set(result["presets"]), {"1"})

    def test_info_without_a_camera_reports_absent(self):
        with mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "find_hidraw", return_value=None), \
             mock.patch.object(pixy, "video_capture_nodes", return_value=[]):
            result = self.assert_json(pixy.cmd_info(args_for(["info"])))
        self.assertFalse(result["present"])
        self.assertEqual(result["error"], "no-camera")


class FakeVendorDevice:
    """A camera that answers vendor HID queries from in-memory state.

    Routed on bytes 1..3 of the payload, which is what identifies a command on
    this protocol, and it answers reads from whatever the writes left behind — so
    a setter that builds the wrong report or reads the wrong offset fails here the
    way it would on hardware, rather than passing against a canned reply.

    `deaf` names commands to answer with silence, and `stubborn` names ones to
    ignore the first write to, which is the camera's real behaviour after an idle
    period.
    """

    def __init__(self, audio=0x01, gesture=True, features=None, metering=(0x00, 56, 56),
                 autoprivacy=0, presets=None, deaf=(), stubborn=()):
        self.audio = audio
        self.gesture = gesture
        self.features = dict(features or {0x01: False, 0x02: False, 0x04: True})
        self.metering = metering
        self.autoprivacy = autoprivacy
        # slot -> (saved, pan, tilt)
        self.presets = dict(presets or {1: (False, 0.0, 0.0), 2: (False, 0.0, 0.0),
                                        3: (False, 0.0, 0.0)})
        self.deaf = set(deaf)
        self.stubborn = set(stubborn)
        self.writes = []
        self.reads = []

    @staticmethod
    def key(report):
        return tuple(report[1:4])

    def write_reports(self, path, reports):
        for report in reports:
            key = self.key(report)
            self.writes.append(key)
            if key in self.stubborn:
                self.stubborn.discard(key)
                continue
            if key == (0x05, 0x00, 0x03):
                self.audio = report[8]
            elif key == (0x04, 0x02, 0x00):
                self.gesture = bool(report[9])
            elif key == (0x04, 0x00, 0x08):
                self.features[report[8]] = bool(report[9])
            elif key == (0x04, 0x00, 0x03):  # the commit; 0x01 only stages
                # The camera keeps the last picked point when the mode carries
                # none, rather than taking the zeros the report sends.
                x, y = (report[9], report[10]) if report[8] == 0x02 else self.metering[1:]
                self.metering = (report[8], x, y)
            elif key == (0x03, 0x01, 0x15):
                slot, saved = report[8], bool(report[9])
                previous = self.presets.get(slot, (False, 0.0, 0.0))
                self.presets[slot] = ((True, self.pan, self.tilt) if saved
                                      else (False, previous[1], previous[2]))
            elif key == (0x02, 0x01, 0x00):
                self.autoprivacy = int.from_bytes(report[8:12], "little")

    # Where the lens is, for a save to capture.
    pan = 0.0
    tilt = 0.0

    def query(self, path, payload, fd=None):
        report = pixy.build_report(payload)
        key = self.key(report)
        self.reads.append(key)
        if key in self.deaf:
            return None
        if key == (0x05, 0x00, 0x04):
            return vendor_reply(payload, self.audio)
        if key == (0x04, 0x02, 0x01):
            return vendor_reply(payload, 0x02, int(self.gesture))
        if key == (0x04, 0x00, 0x07):
            return vendor_reply(payload, report[8], int(self.features.get(report[8], False)))
        if key == (0x04, 0x00, 0x02):
            return vendor_reply(payload, *self.metering)
        if key == (0x03, 0x01, 0x16):
            saved, pan, tilt = self.presets.get(report[8], (False, 0.0, 0.0))
            return vendor_reply(payload, report[8], int(saved),
                                *struct.pack("<fff", pan, tilt, 0.0))
        if key == (0x02, 0x01, 0x01):
            return vendor_reply(payload, *self.autoprivacy.to_bytes(4, "little"))
        return None


class VendorCommandTests(unittest.TestCase):
    """The vendor-feature commands as the panel calls them."""

    def fake_open(self, path, flags):
        self.opened.append(path)
        return 13

    def run_cmd(self, argv, device=None, hid="/dev/hidrawTEST", cam=None,
                node="/dev/videoTEST"):
        self.device = device if device is not None else FakeVendorDevice()
        self.opened = []
        self.cam = cam
        stack = [
            mock.patch.object(pixy, "find_hidraw", return_value=hid),
            mock.patch.object(pixy, "query", side_effect=self.device.query),
            mock.patch.object(pixy, "write_reports", side_effect=self.device.write_reports),
            # SET_SETTLE is real hardware latency, and paying it per setter would
            # cost seconds across this suite.
            mock.patch.object(pixy.time, "sleep"),
            mock.patch.object(pixy.os, "open", side_effect=self.fake_open),
            mock.patch.object(pixy.os, "close"),
            mock.patch.object(pixy, "find_video", return_value=node),
        ]
        if cam is not None:
            stack.append(mock.patch.object(pixy, "Camera", return_value=cam))
        with ExitStack() as entered:
            for patcher in stack:
                entered.enter_context(patcher)
            result = pixy.build_parser().parse_args(argv).fn(args_for(argv))
        self.assertIsInstance(result, dict)
        json.dumps(result)  # the panel parses stdout unconditionally
        return result

    def assert_absent(self, argv):
        """Every vendor command must survive a camera with no writable hidraw."""
        with mock.patch.object(pixy, "find_hidraw", return_value=None):
            result = pixy.build_parser().parse_args(argv).fn(args_for(argv))
        self.assertIsInstance(result, dict)
        json.dumps(result)
        self.assertFalse(result["ok"])
        self.assertFalse(result["present"])
        return result

    def test_every_vendor_command_survives_a_missing_hid_node(self):
        for argv in (["audio"], ["audio", "live"], ["gesture"], ["gesture", "on"],
                     ["feature"], ["feature", "flipHorizontal", "on"], ["metering"],
                     ["metering", "face"], ["auto-privacy"], ["auto-privacy", "60"],
                     ["vendor"], ["native-preset", "list"], ["native-preset", "save", "1"]):
            with self.subTest(argv=argv):
                self.assert_absent(argv)

    def test_vendor_reads_every_feature_in_one_call(self):
        result = self.run_cmd(["vendor"], FakeVendorDevice(
            audio=0x02, gesture=True, autoprivacy=300,
            presets={1: (True, 9.4, -15.9), 2: (False, 0.0, 0.0), 3: (False, 0.0, 0.0)},
        ))
        self.assertTrue(result["ok"])
        self.assertEqual(result["audio"], "live")
        self.assertTrue(result["gesture"])
        self.assertEqual(result["autoPrivacy"], 300)
        self.assertEqual(set(result["features"]), set(pixy.FEATURE_IDS))
        self.assertEqual(result["metering"]["mode"], "center")
        self.assertTrue(result["nativePresets"]["1"]["saved"])
        self.assertFalse(result["nativePresets"]["2"]["saved"])

    def test_vendor_shares_one_descriptor_for_all_of_it(self):
        # Ten features, one open. Reopening per query costs a full query timeout
        # each, because the first write to a fresh descriptor is dropped.
        self.run_cmd(["vendor"])
        self.assertEqual(self.opened, ["/dev/hidrawTEST"])

    def test_vendor_reports_a_silent_feature_as_null_not_missing(self):
        # The panel distinguishes "off" from "could not read", so a feature the
        # camera ignores has to be present and null rather than absent.
        result = self.run_cmd(["vendor"], FakeVendorDevice(
            deaf={(0x04, 0x02, 0x01), (0x02, 0x01, 0x01)}
        ))
        self.assertTrue(result["ok"])
        self.assertIn("gesture", result)
        self.assertIsNone(result["gesture"])
        self.assertIsNone(result["autoPrivacy"])

    def test_audio_read_names_the_mode(self):
        result = self.run_cmd(["audio"], FakeVendorDevice(audio=0x03))
        self.assertEqual(result["audio"], "original")

    def test_audio_set_confirms_from_the_readback(self):
        result = self.run_cmd(["audio", "live"], FakeVendorDevice(audio=0x01))
        self.assertTrue(result["confirmed"])
        self.assertEqual(result["audio"], "live")
        self.assertEqual(self.device.audio, 0x02)

    def test_audio_set_retries_the_dropped_cold_write(self):
        result = self.run_cmd(["audio", "live"],
                              FakeVendorDevice(audio=0x01, stubborn={(0x05, 0x00, 0x03)}))
        self.assertTrue(result["confirmed"])
        self.assertEqual(result["attempts"], 2)

    def test_gesture_toggle_flips_the_live_value(self):
        result = self.run_cmd(["gesture", "toggle"], FakeVendorDevice(gesture=True))
        self.assertFalse(result["gesture"])
        self.assertFalse(self.device.gesture)

    def test_gesture_toggle_without_a_readable_state_refuses(self):
        # Toggling from an unknown state would be a coin flip on a privacy-adjacent
        # feature, so it errors instead of guessing.
        result = self.run_cmd(["gesture", "toggle"],
                              FakeVendorDevice(deaf={(0x04, 0x02, 0x01)}))
        self.assertFalse(result["ok"])
        self.assertEqual(self.device.writes, [])

    def test_feature_read_with_no_name_reports_all_three(self):
        result = self.run_cmd(["feature"])
        self.assertEqual(set(result["features"]), set(pixy.FEATURE_IDS))

    def test_feature_set_touches_only_the_named_toggle(self):
        result = self.run_cmd(["feature", "flipVertical", "on"])
        self.assertEqual(result["feature"], "flipVertical")
        self.assertTrue(result["value"])
        self.assertTrue(self.device.features[pixy.FEATURE_IDS["flipVertical"]])
        self.assertFalse(self.device.features[pixy.FEATURE_IDS["flipHorizontal"]])

    def test_metering_area_needs_a_point(self):
        result = self.run_cmd(["metering", "area"])
        self.assertFalse(result["ok"])
        self.assertEqual(self.device.writes, [])

    def test_metering_area_rejects_an_out_of_range_point(self):
        result = self.run_cmd(["metering", "area", "--x", "200", "--y", "10"])
        self.assertFalse(result["ok"])
        self.assertEqual(self.device.writes, [])

    def test_metering_area_stores_the_point(self):
        result = self.run_cmd(["metering", "area", "--x", "20", "--y", "90"])
        self.assertTrue(result["confirmed"])
        self.assertEqual(result["metering"], {"mode": "area", "raw": 0x02, "x": 20, "y": 90})

    def test_metering_stages_then_commits(self):
        self.run_cmd(["metering", "face"])
        self.assertEqual(self.device.writes[:2], [(0x04, 0x00, 0x01), (0x04, 0x00, 0x03)])

    def test_metering_reports_the_stale_point_it_cannot_clear(self):
        # Leaving `area` does not reset x/y in the camera; reporting the stale
        # numbers is honest, and pretending they were cleared would not be.
        result = self.run_cmd(["metering", "center"],
                              FakeVendorDevice(metering=(0x02, 20, 90)))
        self.assertEqual(result["metering"]["mode"], "center")
        self.assertEqual((result["metering"]["x"], result["metering"]["y"]), (20, 90))

    def test_auto_privacy_round_trips_a_timeout(self):
        result = self.run_cmd(["auto-privacy", "600"])
        self.assertEqual(result["autoPrivacy"], 600)
        self.assertEqual(self.device.autoprivacy, 600)

    def test_auto_privacy_zero_disables_rather_than_reading(self):
        result = self.run_cmd(["auto-privacy", "0"], FakeVendorDevice(autoprivacy=300))
        self.assertEqual(result["autoPrivacy"], 0)
        self.assertEqual(self.device.autoprivacy, 0)

    def test_auto_privacy_rejects_a_negative_timeout(self):
        result = self.run_cmd(["auto-privacy", "-1"])
        self.assertFalse(result["ok"])
        self.assertEqual(self.device.writes, [])

    def test_native_preset_list_needs_no_slot(self):
        result = self.run_cmd(["native-preset", "list"], FakeVendorDevice(
            presets={1: (True, 9.4, -15.9), 2: (False, 0.0, 0.0), 3: (False, 0.0, 0.0)}
        ))
        self.assertEqual(set(result["nativePresets"]), {"1", "2", "3"})
        self.assertAlmostEqual(result["nativePresets"]["1"]["pan"], 9.4, places=3)

    def test_native_preset_rejects_an_out_of_range_slot(self):
        result = self.run_cmd(["native-preset", "save", "4"])
        self.assertFalse(result["ok"])
        self.assertEqual(self.device.writes, [])

    def test_native_preset_save_stores_where_the_lens_is(self):
        device = FakeVendorDevice()
        device.pan, device.tilt = 12.5, -3.25
        result = self.run_cmd(["native-preset", "save", "2"], device)
        self.assertTrue(result["confirmed"])
        self.assertTrue(result["entry"]["saved"])
        self.assertAlmostEqual(result["entry"]["pan"], 12.5, places=3)

    def test_native_preset_clear_empties_only_that_slot(self):
        result = self.run_cmd(["native-preset", "clear", "1"], FakeVendorDevice(
            presets={1: (True, 9.4, -15.9), 2: (True, 1.0, 2.0), 3: (False, 0.0, 0.0)}
        ))
        self.assertFalse(result["entry"]["saved"])
        self.assertTrue(result["nativePresets"]["2"]["saved"])

    def test_native_preset_load_drives_the_lens_over_uvc(self):
        # The vendor load command acknowledges and does not move the lens, so load
        # reads the stored degrees over HID and writes them as UVC pan/tilt. A
        # regression to HID motion would show up here as an unwritten camera.
        cam = FakeCamera(specs=ptz_specs())
        result = self.run_cmd(
            ["native-preset", "load", "1"],
            FakeVendorDevice(presets={1: (True, 10.0, -5.0), 2: (False, 0.0, 0.0),
                                      3: (False, 0.0, 0.0)}),
            cam=cam,
        )
        self.assertTrue(result["ok"])
        self.assertEqual(cam.values[pixy.CID_PAN_ABSOLUTE], 10 * pixy.ARCSEC_PER_DEGREE)
        self.assertEqual(cam.values[pixy.CID_TILT_ABSOLUTE], -5 * pixy.ARCSEC_PER_DEGREE)
        # No HID write at all: the slot was only read.
        self.assertEqual(self.device.writes, [])
        self.assertEqual(result["pan"], 10)

    def test_native_preset_load_of_an_empty_slot_says_empty(self):
        result = self.run_cmd(["native-preset", "load", "3"], cam=FakeCamera(specs=ptz_specs()))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "empty")

    def test_native_preset_load_of_an_unreadable_slot_is_not_called_empty(self):
        # "Empty" and "the camera did not answer" lead to different fixes, so they
        # must not collapse into the same message.
        result = self.run_cmd(["native-preset", "load", "1"],
                              FakeVendorDevice(deaf={(0x03, 0x01, 0x16)}),
                              cam=FakeCamera(specs=ptz_specs()))
        self.assertFalse(result["ok"])
        self.assertNotEqual(result["error"], "empty")


class FormatsCommandTests(unittest.TestCase):
    """`formats`, which is read-only on purpose."""

    def run_cmd(self, formats, node="/dev/videoTEST"):
        cam = FakeCamera()
        with mock.patch.object(pixy, "find_video", return_value=node), \
             mock.patch.object(pixy, "Camera", return_value=cam), \
             mock.patch.object(pixy, "enumerate_formats", return_value=formats):
            result = pixy.cmd_formats(args_for(["formats"]))
        self.cam = cam
        self.assertIsInstance(result, dict)
        json.dumps(result)
        return result

    FAKE = [{"fourcc": "MJPG", "pixelFormat": 1196444237, "description": "Motion-JPEG",
             "compressed": True,
             "sizes": [{"width": 3840, "height": 2160, "fps": [30.0]}]}]

    def test_lists_what_the_camera_advertises(self):
        result = self.run_cmd(self.FAKE)
        self.assertTrue(result["ok"])
        self.assertEqual(result["formats"], self.FAKE)

    def test_reports_the_format_the_preview_itself_uses(self):
        # The panel shows this next to the list so the preview's modest 640x480
        # YUYV does not read as the camera's ceiling.
        result = self.run_cmd(self.FAKE)
        self.assertEqual(result["capture"]["fourcc"], "YUYV")
        self.assertEqual(result["capture"]["width"], pixy.CAPTURE_WIDTH)

    def test_writes_nothing_to_the_camera(self):
        self.run_cmd(self.FAKE)
        self.assertEqual(self.cam.writes, [])

    def test_a_camera_that_advertises_nothing_is_not_ok(self):
        result = self.run_cmd([])
        self.assertFalse(result["ok"])
        self.assertEqual(result["formats"], [])

    def test_without_a_camera_reports_absence_as_data(self):
        with mock.patch.object(pixy, "find_video", return_value=None):
            result = pixy.cmd_formats(args_for(["formats"]))
        json.dumps(result)
        self.assertFalse(result["present"])


class SnapshotPathTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def test_the_first_snapshot_keeps_the_name_it_was_given(self):
        path = pixy.snapshot_path(os.path.join(self.tmp.name, "shot.jpg"))
        self.assertEqual(path, os.path.join(self.tmp.name, "shot.jpg"))

    def test_an_existing_file_is_not_clobbered(self):
        first = pixy.snapshot_path(os.path.join(self.tmp.name, "shot.jpg"))
        pathlib.Path(first).write_bytes(b"x")
        second = pixy.snapshot_path(os.path.join(self.tmp.name, "shot.jpg"))
        self.assertEqual(second, os.path.join(self.tmp.name, "shot-1.jpg"))

    def test_the_counter_keeps_the_extension_last(self):
        for index in range(3):
            pathlib.Path(pixy.snapshot_path(
                os.path.join(self.tmp.name, "shot.jpg"))).write_bytes(b"x")
        self.assertEqual(
            pixy.snapshot_path(os.path.join(self.tmp.name, "shot.jpg")),
            os.path.join(self.tmp.name, "shot-3.jpg"),
        )

    def test_creates_the_directory_it_writes_into(self):
        nested = os.path.join(self.tmp.name, "a", "b", "shot.jpg")
        self.assertEqual(pixy.snapshot_path(nested), nested)
        self.assertTrue(os.path.isdir(os.path.dirname(nested)))

    def test_expands_a_tilde_and_an_environment_variable(self):
        with mock.patch.dict(os.environ, {"HOME": self.tmp.name, "SHOTDIR": self.tmp.name}):
            self.assertEqual(pixy.snapshot_path("~/shot.jpg"),
                             os.path.join(self.tmp.name, "shot.jpg"))
            self.assertEqual(pixy.snapshot_path("$SHOTDIR/other.jpg"),
                             os.path.join(self.tmp.name, "other.jpg"))

    def test_the_default_follows_the_pictures_directory(self):
        with mock.patch.dict(os.environ, {"XDG_PICTURES_DIR": "/tmp/shots"}):
            self.assertEqual(pixy.snapshot_default(), "/tmp/shots/" + pixy.SNAPSHOT_NAME)

    def test_the_default_falls_back_to_pictures_under_home(self):
        # `${VAR:-default}` is shell syntax that expandvars does not understand, so
        # an unset XDG_PICTURES_DIR once expanded to a path starting with the
        # literal fallback text.
        env = {k: v for k, v in os.environ.items() if k != "XDG_PICTURES_DIR"}
        env["HOME"] = "/home/someone"
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(pixy.snapshot_default(),
                             "/home/someone/Pictures/" + pixy.SNAPSHOT_NAME)


class SnapshotCommandTests(unittest.TestCase):
    """`snapshot`, which writes the MJPEG frame to disk verbatim."""

    JPEG = b"\xff\xd8\xff\xe0" + b"payload" * 8

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def fake_capture(self, frames=None, error=None, size=(3840, 2160)):
        """A Capture that hands back canned frames without touching a device."""
        captured = list(frames if frames is not None else [self.JPEG] * 8)
        outer = self

        class Cap:
            def __init__(self, node, width, height, pixel_format=pixy.PIXFMT_YUYV):
                outer.requested = (width, height, pixel_format)
                self.width, self.height = size

            def __enter__(self):
                if error:
                    raise error
                return self

            def __exit__(self, *exc):
                outer.released = True

            def frame(self):
                outer.frames_taken = getattr(outer, "frames_taken", 0) + 1
                return captured.pop(0)

        return Cap

    def run_cmd(self, argv, capture=None, formats=None, node="/dev/videoTEST"):
        formats = formats if formats is not None else [
            {"fourcc": "MJPG", "sizes": [{"width": 3840, "height": 2160, "fps": [30.0]}]},
            {"fourcc": "YUYV", "sizes": [{"width": 640, "height": 480, "fps": [30.0]}]},
        ]
        with mock.patch.object(pixy, "find_video", return_value=node), \
             mock.patch.object(pixy, "Camera", return_value=FakeCamera()), \
             mock.patch.object(pixy, "enumerate_formats", return_value=formats), \
             mock.patch.object(pixy, "Capture", capture or self.fake_capture()):
            result = pixy.build_parser().parse_args(argv).fn(args_for(argv))
        self.assertIsInstance(result, dict)
        json.dumps(result)
        return result

    def out(self, name="shot.jpg"):
        return os.path.join(self.tmp.name, name)

    def test_writes_the_frame_to_disk_byte_for_byte(self):
        # No encoder is involved: an MJPEG frame off this camera is already a
        # complete JPEG file, and re-encoding it would be lossy for no reason.
        result = self.run_cmd(["snapshot", "--output", self.out()])
        self.assertTrue(result["ok"])
        self.assertEqual(pathlib.Path(result["path"]).read_bytes(), self.JPEG)
        self.assertEqual(result["bytes"], len(self.JPEG))
        self.assertEqual(result["format"], "MJPG")

    def test_defaults_to_the_largest_mjpeg_size(self):
        self.run_cmd(["snapshot", "--output", self.out()])
        self.assertEqual(self.requested, (3840, 2160, pixy.fourcc("MJPG")))

    def test_an_explicit_size_is_used_without_asking_the_camera(self):
        self.run_cmd(["snapshot", "--output", self.out(),
                      "--width", "1280", "--height", "720"])
        self.assertEqual(self.requested, (1280, 720, pixy.fourcc("MJPG")))

    def test_reports_the_size_the_driver_actually_gave(self):
        # The driver may substitute a size it prefers; reporting the request would
        # claim a 4K still that is not one.
        result = self.run_cmd(["snapshot", "--output", self.out(),
                               "--width", "4000", "--height", "3000"],
                              capture=self.fake_capture(size=(3840, 2160)))
        self.assertEqual((result["width"], result["height"]), (3840, 2160))

    def test_warmup_frames_are_discarded_before_the_one_that_is_kept(self):
        frames = [b"\xff\xd8warm"] * 4 + [self.JPEG]
        result = self.run_cmd(["snapshot", "--output", self.out(), "--warmup", "4"],
                              capture=self.fake_capture(frames=frames))
        self.assertEqual(self.frames_taken, 5)
        self.assertEqual(pathlib.Path(result["path"]).read_bytes(), self.JPEG)

    def test_no_warmup_keeps_the_very_first_frame(self):
        result = self.run_cmd(["snapshot", "--output", self.out(), "--warmup", "0"])
        self.assertEqual(self.frames_taken, 1)
        self.assertTrue(result["ok"])

    def test_a_non_jpeg_frame_is_refused_rather_than_written(self):
        # A .jpg holding something else is worse than no file: nothing can open it
        # and the failure surfaces long after the snapshot.
        result = self.run_cmd(["snapshot", "--output", self.out()],
                              capture=self.fake_capture(frames=[b"\x00" * 16] * 8))
        self.assertFalse(result["ok"])
        self.assertFalse(os.path.exists(self.out()))

    def test_a_busy_stream_is_named_as_busy(self):
        result = self.run_cmd(["snapshot", "--output", self.out()],
                              capture=self.fake_capture(error=OSError(errno.EBUSY, "busy")))
        self.assertFalse(result["ok"])
        self.assertTrue(result["busy"])

    def test_another_oserror_is_not_reported_as_busy(self):
        result = self.run_cmd(["snapshot", "--output", self.out()],
                              capture=self.fake_capture(error=OSError(errno.ENODEV, "gone")))
        self.assertFalse(result["ok"])
        self.assertFalse(result["busy"])

    def test_a_camera_with_no_mjpeg_size_is_reported_not_guessed(self):
        result = self.run_cmd(["snapshot", "--output", self.out()],
                              formats=[{"fourcc": "YUYV", "sizes": []}])
        self.assertFalse(result["ok"])
        self.assertIn("MJPEG", result["error"])

    def test_an_unwritable_destination_is_reported_with_its_path(self):
        with mock.patch.object(pixy, "snapshot_path",
                               side_effect=OSError(errno.EACCES, "denied")):
            result = self.run_cmd(["snapshot", "--output", "/nowhere/shot.jpg"])
        self.assertFalse(result["ok"])

    def test_without_a_camera_reports_absence_as_data(self):
        with mock.patch.object(pixy, "find_video", return_value=None):
            result = pixy.cmd_snapshot(args_for(["snapshot"]))
        json.dumps(result)
        self.assertFalse(result["present"])


class ImageCommandTests(unittest.TestCase):
    """`image` and `profile` as the panel calls them."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patcher = mock.patch.dict(os.environ, {"XDG_STATE_HOME": self.tmp.name})
        patcher.start()
        self.addCleanup(patcher.stop)

    def run_cmd(self, argv, cam=None, node="/dev/videoTEST"):
        cam = cam if cam is not None else image_camera()
        self.cam = cam
        with mock.patch.object(pixy, "find_video", return_value=node), \
             mock.patch.object(pixy, "Camera", return_value=cam):
            result = pixy.build_parser().parse_args(argv).fn(args_for(argv))
        self.assertIsInstance(result, dict)
        json.dumps(result)  # the panel parses stdout unconditionally
        return result

    def test_image_read_returns_every_control(self):
        result = self.run_cmd(["image"])
        self.assertTrue(result["ok"])
        self.assertEqual(len(result["controls"]), len(pixy.IMAGE_CONTROLS))

    def test_image_read_writes_nothing(self):
        self.run_cmd(["image"])
        self.assertEqual(self.cam.writes, [])

    def test_image_curated_narrows_the_payload(self):
        result = self.run_cmd(["image", "--curated"])
        self.assertEqual([c["key"] for c in result["controls"]],
                         [c["key"] for c in pixy.IMAGE_CONTROLS if c.get("curated")])

    def test_image_set_reports_the_write_and_the_fresh_state(self):
        # One round trip both writes and refreshes: the `inactive` flags in
        # particular are only knowable after the write.
        result = self.run_cmd(["image", "--set", "brightness=160"])
        self.assertTrue(result["ok"])
        self.assertEqual(result["written"], {"brightness": 160})
        values = {c["key"]: c["value"] for c in result["controls"]}
        self.assertEqual(values["brightness"], 160)

    def test_image_set_reports_a_held_control_as_not_ok(self):
        result = self.run_cmd(["image", "--set", "whiteBalance=4000"])
        self.assertFalse(result["ok"])
        self.assertIn("whiteBalance", result["failed"])
        # And still returns the controls, so the panel can re-render rather than
        # sitting on stale values after a refused write.
        self.assertTrue(result["controls"])

    def test_image_rejects_a_bad_assignment_without_touching_the_camera(self):
        with mock.patch.object(pixy, "find_video") as find:
            result = pixy.cmd_image(args_for(["image", "--set", "nope=1"]))
        self.assertFalse(result["ok"])
        self.assertIn("nope", result["error"])
        find.assert_not_called()

    def test_image_force_applies_the_valid_assignments(self):
        result = self.run_cmd(["image", "--force", "--set", "nope=1",
                               "--set", "gamma=140"])
        self.assertTrue(result["ok"])
        self.assertEqual(result["written"], {"gamma": 140})
        self.assertEqual(len(result["warnings"]), 1)

    def test_image_reset_reaches_neutral(self):
        cam = image_camera()
        cam.values.update({cid("brightness"): 40, cid("whiteBalance"): 3000})
        result = self.run_cmd(["image", "--reset"], cam=cam)
        self.assertTrue(result["ok"])
        values = {c["key"]: c["value"] for c in result["controls"]}
        self.assertEqual(values["brightness"], 128)
        self.assertEqual(values["whiteBalance"], 5000)

    def test_image_reset_leaves_power_line_frequency_alone(self):
        cam = image_camera()
        cam.values[cid("powerLineFrequency")] = 1
        result = self.run_cmd(["image", "--reset"], cam=cam)
        values = {c["key"]: c["value"] for c in result["controls"]}
        self.assertEqual(values["powerLineFrequency"], 1)

    def test_image_reset_with_a_set_lets_the_set_win(self):
        result = self.run_cmd(["image", "--reset", "--set", "brightness=170"])
        self.assertEqual(result["written"]["brightness"], 170)

    def test_image_without_a_camera_reports_absence_as_data(self):
        result = self.run_cmd(["image"], node=None)
        self.assertFalse(result["ok"])
        self.assertFalse(result["present"])

    def test_profile_save_captures_advanced_controls_too(self):
        # A profile that stored only the panel's front page would silently fail
        # to restore an exposure set behind the cog — the case profiles are for.
        result = self.run_cmd(["profile", "save", "warm"])
        self.assertTrue(result["ok"])
        self.assertIn("exposure", result["saved"])
        self.assertIn("focus", result["saved"])

    def test_profile_round_trip(self):
        cam = image_camera()
        cam.values[cid("brightness")] = 150
        self.run_cmd(["profile", "save", "warm"], cam=cam)
        cam.values[cid("brightness")] = 100
        result = self.run_cmd(["profile", "load", "warm"], cam=cam)
        self.assertTrue(result["ok"])
        self.assertEqual(cam.values[cid("brightness")], 150)

    def test_profile_load_of_a_manual_profile_onto_an_auto_camera(self):
        cam = image_camera()
        cam.values.update({cid("whiteBalanceAuto"): 0, cid("whiteBalance"): 3100})
        self.run_cmd(["profile", "save", "manual"], cam=cam)
        cam.values.update({cid("whiteBalanceAuto"): 1, cid("whiteBalance"): 5000})
        result = self.run_cmd(["profile", "load", "manual"], cam=cam)
        self.assertEqual(result["failed"], {})
        self.assertEqual(cam.values[cid("whiteBalanceAuto")], 0)
        self.assertEqual(cam.values[cid("whiteBalance")], 3100)

    def test_profile_list_needs_no_camera(self):
        pixy.write_profiles({"warm": {"brightness": 150}})
        with mock.patch.object(pixy, "find_video") as find:
            result = pixy.cmd_profile(args_for(["profile", "list"]))
        self.assertEqual(set(result["profiles"]), {"warm"})
        find.assert_not_called()

    def test_profile_clear_removes_one_and_keeps_the_rest(self):
        pixy.write_profiles({"warm": {"brightness": 150}, "cool": {"brightness": 100}})
        result = pixy.cmd_profile(args_for(["profile", "clear", "warm"]))
        self.assertTrue(result["ok"])
        self.assertEqual(set(result["profiles"]), {"cool"})

    def test_profile_clear_of_a_missing_name_is_reported_not_silent(self):
        result = pixy.cmd_profile(args_for(["profile", "clear", "nope"]))
        self.assertFalse(result["ok"])
        self.assertIn("no such profile", result["error"])

    def test_profile_load_of_a_missing_name_is_reported_not_silent(self):
        result = pixy.cmd_profile(args_for(["profile", "load", "nope"]))
        self.assertFalse(result["ok"])
        self.assertIn("no such profile", result["error"])

    def test_profile_requires_a_name(self):
        for action in ("save", "load", "clear"):
            result = pixy.cmd_profile(args_for(["profile", action]))
            self.assertFalse(result["ok"], action)
            self.assertIn("name", result["error"], action)

    def test_a_blank_name_is_refused(self):
        # It would round-trip through JSON as a profile nobody can name or find.
        result = pixy.cmd_profile(args_for(["profile", "save", "   "]))
        self.assertFalse(result["ok"])

    def test_saving_over_a_name_replaces_it(self):
        cam = image_camera()
        cam.values[cid("brightness")] = 150
        self.run_cmd(["profile", "save", "warm"], cam=cam)
        cam.values[cid("brightness")] = 90
        result = self.run_cmd(["profile", "save", "warm"], cam=cam)
        self.assertEqual(result["profiles"]["warm"]["brightness"], 90)


def yuyv_frame(width, height, luma):
    """Build a YUYV frame whose luma at (x, y) is luma(x, y).

    YUYV is two bytes per pixel with luma first, so pixel x of a row lives at
    byte 2*x. Chroma is filled with 128 (neutral) so a wrong stride or a
    chroma/luma mix-up shows up as a visibly wrong value rather than as noise
    that happens to average out.
    """
    data = bytearray()
    for y in range(height):
        for x in range(width):
            data.append(luma(x, y) & 0xFF)
            data.append(128)
    return bytes(data)


class FourccTests(unittest.TestCase):
    def test_yuyv_matches_the_kernel_value(self):
        # v4l2_fourcc('Y','U','Y','V') as the kernel computes it. Getting the
        # byte order backwards yields a format the driver silently rejects.
        self.assertEqual(pixy.PIXFMT_YUYV, 0x56595559)

    def test_is_little_endian_over_the_characters(self):
        self.assertEqual(pixy.fourcc("ABCD"),
                         ord("A") | (ord("B") << 8) | (ord("C") << 16) | (ord("D") << 24))


class FourccNameTests(unittest.TestCase):
    def test_round_trips_every_format_in_use(self):
        for code in ("YUYV", "MJPG", "NV12"):
            self.assertEqual(pixy.fourcc_name(pixy.fourcc(code)), code)

    def test_yuyv_names_itself(self):
        self.assertEqual(pixy.fourcc_name(pixy.PIXFMT_YUYV), "YUYV")


class FormatEnumerationTests(unittest.TestCase):
    """Struct sizes and decoding for the three nested enumerations."""

    def test_enumeration_ioctl_numbers(self):
        self.assertEqual(pixy.VIDIOC_ENUM_FMT, 0xC0405602)
        self.assertEqual(pixy.VIDIOC_ENUM_FRAMESIZES, 0xC02C564A)
        self.assertEqual(pixy.VIDIOC_ENUM_FRAMEINTERVALS, 0xC034564B)

    def test_struct_sizes_match_the_sizes_encoded_in_the_ioctls(self):
        # The bug this pins: padding for the *discrete* arm of the union rather
        # than the whole union under-allocates by 16 bytes, and the ioctl fails as
        # "SystemError: buffer overflow" rather than anything that names the cause.
        for ioctl, fmt in (
            (pixy.VIDIOC_ENUM_FMT, pixy.FMTDESC_FORMAT),
            (pixy.VIDIOC_ENUM_FRAMESIZES, pixy.FRAMESIZE_FORMAT),
            (pixy.VIDIOC_ENUM_FRAMEINTERVALS, pixy.FRAMEIVAL_FORMAT),
        ):
            self.assertEqual((ioctl >> 16) & 0x3FFF, struct.calcsize(fmt))

    def fake_ioctl(self, formats):
        """An ioctl that answers the three enumerations from a nested dict.

        Terminates each enumeration with EINVAL, which is how the kernel says
        "no more" rather than reporting an error.
        """
        def handler(fd, request, buf, mutate):
            if request == pixy.VIDIOC_ENUM_FMT:
                index = struct.unpack_from("<I", buf, 0)[0]
                if index >= len(formats):
                    raise OSError(errno.EINVAL, "no such format")
                entry = formats[index]
                struct.pack_into("<III32sI", buf, 0, index,
                                 pixy.V4L2_BUF_TYPE_VIDEO_CAPTURE, entry.get("flags", 0),
                                 entry["description"].encode(), pixy.fourcc(entry["fourcc"]))
                return 0
            if request == pixy.VIDIOC_ENUM_FRAMESIZES:
                index, pixel_format = struct.unpack_from("<II", buf, 0)
                entry = next(f for f in formats
                             if pixy.fourcc(f["fourcc"]) == pixel_format)
                if index >= len(entry["sizes"]):
                    raise OSError(errno.EINVAL, "no such size")
                width, height, _rates = entry["sizes"][index]
                struct.pack_into("<IIIII", buf, 0, index, pixel_format,
                                 pixy.V4L2_FRMSIZE_TYPE_DISCRETE, width, height)
                return 0
            if request == pixy.VIDIOC_ENUM_FRAMEINTERVALS:
                index, pixel_format, width, height = struct.unpack_from("<IIII", buf, 0)
                entry = next(f for f in formats
                             if pixy.fourcc(f["fourcc"]) == pixel_format)
                rates = next(r for w, h, r in entry["sizes"] if (w, h) == (width, height))
                if index >= len(rates):
                    raise OSError(errno.EINVAL, "no such interval")
                struct.pack_into("<IIIIIII", buf, 0, index, pixel_format, width, height,
                                 pixy.V4L2_FRMIVAL_TYPE_DISCRETE, 1, rates[index])
                return 0
            raise OSError(errno.ENOTTY, "unexpected ioctl")

        return handler

    FAKE = [
        {"fourcc": "MJPG", "description": "Motion-JPEG", "flags": 0x0001,
         "sizes": [(1920, 1080, [60, 30]), (640, 480, [30])]},
        {"fourcc": "YUYV", "description": "YUYV 4:2:2",
         "sizes": [(640, 480, [30])]},
    ]

    def enumerate(self):
        with mock.patch.object(pixy.fcntl, "ioctl", side_effect=self.fake_ioctl(self.FAKE)):
            return pixy.enumerate_formats(42)

    def test_reports_every_format(self):
        formats = self.enumerate()
        self.assertEqual([f["fourcc"] for f in formats], ["MJPG", "YUYV"])
        self.assertEqual(formats[0]["description"], "Motion-JPEG")

    def test_marks_compressed_formats(self):
        formats = self.enumerate()
        self.assertTrue(formats[0]["compressed"])
        self.assertFalse(formats[1]["compressed"])

    def test_sizes_are_largest_first(self):
        # The panel shows the biggest mode first, and snapshot picks sizes[0] as
        # the default — so the order is behaviour, not presentation.
        sizes = self.enumerate()[0]["sizes"]
        self.assertEqual([(s["width"], s["height"]) for s in sizes],
                         [(1920, 1080), (640, 480)])

    def test_frame_rates_are_fps_highest_first(self):
        # Reported as frames per second, not the kernel's interval fraction.
        self.assertEqual(self.enumerate()[0]["sizes"][0]["fps"], [60.0, 30.0])

    def test_a_driver_that_reports_nothing_yields_an_empty_list(self):
        with mock.patch.object(pixy.fcntl, "ioctl",
                               side_effect=OSError(errno.EINVAL, "none")):
            self.assertEqual(pixy.enumerate_formats(42), [])

    def test_non_discrete_sizes_are_skipped_rather_than_misdecoded(self):
        # Stepwise and continuous entries have a different payload shape; decoding
        # one as discrete would report confident, wrong numbers.
        def handler(fd, request, buf, mutate):
            if request == pixy.VIDIOC_ENUM_FRAMESIZES:
                index, pixel_format = struct.unpack_from("<II", buf, 0)
                if index > 0:
                    raise OSError(errno.EINVAL, "done")
                struct.pack_into("<IIIII", buf, 0, index, pixel_format, 2, 640, 480)
                return 0
            raise OSError(errno.EINVAL, "done")

        with mock.patch.object(pixy.fcntl, "ioctl", side_effect=handler):
            self.assertEqual(pixy.enumerate_framesizes(42, pixy.PIXFMT_YUYV), [])


class CaptureIoctlEncodingTests(unittest.TestCase):
    """Pinned against `offsetof` output from this kernel's headers.

    These are the values an earlier version got wrong by hand-deriving the
    padding in struct v4l2_buffer, which failed as a bewildering ENOTTY several
    ioctls later rather than at the mistake. Pinning them means a bad edit fails
    here instead.
    """

    def test_streaming_ioctl_numbers(self):
        self.assertEqual(pixy.VIDIOC_S_FMT, 0xC0D05605)
        self.assertEqual(pixy.VIDIOC_REQBUFS, 0xC0145608)
        self.assertEqual(pixy.VIDIOC_QUERYBUF, 0xC0585609)
        self.assertEqual(pixy.VIDIOC_QBUF, 0xC058560F)
        self.assertEqual(pixy.VIDIOC_DQBUF, 0xC0585611)
        self.assertEqual(pixy.VIDIOC_STREAMON, 0x40045612)
        self.assertEqual(pixy.VIDIOC_STREAMOFF, 0x40045613)

    def test_buffer_size_matches_the_size_encoded_in_qbuf(self):
        # The size field of the ioctl number is authoritative: if BUFFER_SIZE
        # disagrees with it, the kernel reads a different struct than we packed.
        self.assertEqual((pixy.VIDIOC_QBUF >> 16) & 0x3FFF, pixy.BUFFER_SIZE)

    def test_format_size_matches_the_size_encoded_in_s_fmt(self):
        self.assertEqual((pixy.VIDIOC_S_FMT >> 16) & 0x3FFF, pixy.FORMAT_SIZE)

    def test_buffer_offsets_fit_inside_the_struct(self):
        for name in ("BUF_OFF_INDEX", "BUF_OFF_TYPE", "BUF_OFF_BYTESUSED",
                     "BUF_OFF_MEMORY", "BUF_OFF_OFFSET", "BUF_OFF_LENGTH"):
            self.assertLessEqual(getattr(pixy, name) + 4, pixy.BUFFER_SIZE, name)


class SampleLumaTests(unittest.TestCase):
    def test_reads_the_luma_plane_not_the_chroma(self):
        # Every luma byte is 200 and every chroma byte 128. Sampling the wrong
        # byte of the pair returns 128, so this distinguishes them.
        frame = yuyv_frame(64, 48, lambda x, y: 200)
        grid = pixy.sample_luma(frame, 64, 48, 128, 4, 4)
        self.assertEqual(grid, [[200] * 4] * 4)

    def test_reduces_to_the_requested_geometry(self):
        frame = yuyv_frame(64, 48, lambda x, y: 100)
        grid = pixy.sample_luma(frame, 64, 48, 128, 8, 5)
        self.assertEqual(len(grid), 5)
        self.assertTrue(all(len(row) == 8 for row in grid))

    def test_a_horizontal_gradient_stays_horizontal(self):
        # Left dark, right bright: each row must increase and every row must
        # agree, which is what a transposed x/y index would break.
        frame = yuyv_frame(64, 48, lambda x, y: x * 4)
        grid = pixy.sample_luma(frame, 64, 48, 128, 8, 4)
        for row in grid:
            self.assertEqual(row, sorted(row))
            self.assertLess(row[0], row[-1])
        self.assertEqual(len(set(tuple(r) for r in grid)), 1)

    def test_a_vertical_gradient_stays_vertical(self):
        frame = yuyv_frame(64, 48, lambda x, y: y * 5)
        grid = pixy.sample_luma(frame, 64, 48, 128, 8, 4)
        firsts = [row[0] for row in grid]
        self.assertEqual(firsts, sorted(firsts))
        self.assertLess(firsts[0], firsts[-1])
        for row in grid:
            self.assertEqual(len(set(row)), 1)

    def test_honors_a_stride_wider_than_the_frame(self):
        # Drivers may pad each row. Ignoring bytes_per_line skews every row
        # progressively, which looks like a sheared image rather than an error.
        width, height, stride = 32, 8, 96
        data = bytearray()
        for y in range(height):
            row = bytearray()
            for x in range(width):
                row.append(50 if y % 2 == 0 else 150)
                row.append(128)
            row.extend(b"\xff" * (stride - len(row)))
            data.extend(row)
        grid = pixy.sample_luma(bytes(data), width, height, stride, 4, 8)
        self.assertEqual([row[0] for row in grid], [50, 150] * 4)

    def test_an_empty_frame_yields_no_grid(self):
        self.assertEqual(pixy.sample_luma(b"", 64, 48, 128, 4, 4), [])

    def test_a_degenerate_geometry_yields_no_grid(self):
        frame = yuyv_frame(64, 48, lambda x, y: 100)
        self.assertEqual(pixy.sample_luma(frame, 64, 48, 128, 0, 4), [])
        self.assertEqual(pixy.sample_luma(frame, 64, 48, 128, 4, 0), [])

    def test_a_truncated_frame_does_not_raise(self):
        # A short DQBUF is plausible on a partial frame, and a preview that
        # throws there would kill the stream instead of dropping one frame.
        frame = yuyv_frame(64, 48, lambda x, y: 100)[: 64 * 2 * 10]
        grid = pixy.sample_luma(frame, 64, 48, 128, 4, 4)
        self.assertEqual(len(grid), 4)


class StretchTests(unittest.TestCase):
    def test_finds_the_black_and_white_points(self):
        grid = [[40, 80], [120, 170]]
        low, high = pixy.stretch(grid, clip=0.0)
        self.assertEqual((low, high), (40, 170))

    def test_clips_a_bright_outlier(self):
        # One blown-out lamp among mid-tones. Using max() would put the white
        # point at 255 and crush the subject into the darkest step or two.
        grid = [[100] * 10, [100] * 10, [100] * 9 + [255]]
        low, high = pixy.stretch(grid, clip=0.05)
        self.assertLess(high, 255)

    def test_an_empty_grid_returns_the_full_range(self):
        self.assertEqual(pixy.stretch([]), (0, 255))

    def test_a_flat_frame_never_yields_a_zero_span(self):
        # A lens-cap frame is all one value; a zero span would divide by zero in
        # every renderer downstream.
        low, high = pixy.stretch([[128] * 4] * 4)
        self.assertGreater(high - low, 0)

    def test_a_flat_white_frame_stays_in_range(self):
        low, high = pixy.stretch([[255] * 4] * 4)
        self.assertGreater(high - low, 0)
        self.assertLessEqual(high, 255)


class RenderAsciiTests(unittest.TestCase):
    def test_one_string_per_row_at_the_grid_width(self):
        lines = pixy.render_ascii([[0, 128, 255], [255, 128, 0]])
        self.assertEqual(len(lines), 2)
        self.assertTrue(all(len(line) == 3 for line in lines))

    def test_darkest_and_brightest_land_on_the_ramp_ends(self):
        line = pixy.render_ascii([[0, 255]], ramp=pixy.ASCII_RAMP)[0]
        self.assertEqual(line[0], pixy.ASCII_RAMP[0])
        self.assertEqual(line[-1], pixy.ASCII_RAMP[-1])

    def test_invert_swaps_the_ramp_ends(self):
        # Needed for a light terminal, where dark ink means bright pixels.
        line = pixy.render_ascii([[0, 255]], invert=True)[0]
        self.assertEqual(line[0], pixy.ASCII_RAMP[-1])
        self.assertEqual(line[-1], pixy.ASCII_RAMP[0])

    def test_stays_within_the_ramp_when_levels_are_exceeded(self):
        # An explicit exposure narrower than the data must clamp, not index off
        # the end of the ramp.
        line = pixy.render_ascii([[0, 255]], levels=(100, 150))[0]
        self.assertEqual(line[0], pixy.ASCII_RAMP[0])
        self.assertEqual(line[-1], pixy.ASCII_RAMP[-1])

    def test_block_ramp_is_usable_as_a_ramp(self):
        line = pixy.render_ascii([[0, 255]], ramp=pixy.BLOCK_RAMP)[0]
        self.assertEqual(line, pixy.BLOCK_RAMP[0] + pixy.BLOCK_RAMP[-1])

    def test_shared_levels_give_two_grids_the_same_exposure(self):
        # This is why `levels` exists: half-block rendering splits one frame
        # across two grids and they must not expose independently.
        levels = pixy.stretch([[0, 255]])
        a = pixy.render_ascii([[128]], levels=levels)[0]
        b = pixy.render_ascii([[128]], levels=levels)[0]
        self.assertEqual(a, b)

    def test_an_empty_grid_yields_no_lines(self):
        self.assertEqual(pixy.render_ascii([]), [])


class RenderHalfblocksTests(unittest.TestCase):
    def test_emits_one_line_per_two_grid_rows(self):
        grid = [[0], [255], [0], [255]]
        self.assertEqual(len(pixy.render_halfblocks(grid)), 2)

    def test_maps_the_four_on_off_combinations(self):
        # top only, bottom only, both, neither.
        lines = pixy.render_halfblocks([[255, 0, 255, 0], [0, 255, 255, 0]])
        self.assertEqual(lines, ["▀▄█ "])

    def test_an_odd_row_count_drops_the_unpaired_row(self):
        # Half a character cell cannot be drawn, and padding it would invent a
        # row of image that was never sampled.
        self.assertEqual(len(pixy.render_halfblocks([[0], [255], [0]])), 1)

    def test_invert_swaps_set_and_unset(self):
        plain = pixy.render_halfblocks([[255, 0], [0, 255]])
        inverted = pixy.render_halfblocks([[255, 0], [0, 255]], invert=True)
        self.assertNotEqual(plain, inverted)

    def test_an_empty_grid_yields_no_lines(self):
        self.assertEqual(pixy.render_halfblocks([]), [])


class AutoRowsTests(unittest.TestCase):
    def test_corrects_for_the_character_cell_aspect(self):
        # A character cell is about twice as tall as it is wide, so a 4:3 frame
        # needs far fewer rows than columns * 3/4 or it comes out squashed.
        rows = pixy.auto_rows(60)
        self.assertEqual(rows, round(60 * (pixy.CAPTURE_HEIGHT / pixy.CAPTURE_WIDTH)
                                     / pixy.CELL_ASPECT))
        self.assertLess(rows, 60 * pixy.CAPTURE_HEIGHT / pixy.CAPTURE_WIDTH)

    def test_never_returns_fewer_than_four_rows(self):
        self.assertGreaterEqual(pixy.auto_rows(1), 4)

    def test_scales_with_the_column_count(self):
        self.assertGreater(pixy.auto_rows(120), pixy.auto_rows(60))


class EmitTests(unittest.TestCase):
    def test_writes_one_json_line(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            pixy.emit({"ok": True, "frame": 0})
        self.assertEqual(buf.getvalue(), '{"ok": true, "frame": 0}\n')

    def test_flushes_so_a_stream_is_not_buffered(self):
        # Without the flush the panel sits blank until 8 KB of frames pile up,
        # which is the whole difference between streaming and not.
        flushed = []
        stream = io.StringIO()
        stream.flush = lambda: flushed.append(True)
        with mock.patch.object(sys, "stdout", stream):
            pixy.emit({"ok": True})
        self.assertTrue(flushed)


class PreviewCommandTests(unittest.TestCase):
    """cmd_preview streams, so it holds a different contract to the rest.

    It returns None and prints its own frames, and main() must not append a
    trailing `null` for it.
    """

    def preview_args(self, argv=None):
        return args_for(["preview"] + (argv or []))

    def test_reports_a_missing_camera_as_one_json_frame(self):
        buf = io.StringIO()
        with mock.patch.object(pixy, "find_video", return_value=None), \
             redirect_stdout(buf):
            self.assertIsNone(pixy.cmd_preview(self.preview_args()))
        payload = json.loads(buf.getvalue())
        self.assertFalse(payload["ok"])
        self.assertFalse(payload["present"])

    def test_a_busy_device_is_named_as_busy(self):
        # A meeting app already holding the stream is the common failure, and
        # "busy" is actionable where "preview failed" is not.
        busy = OSError(errno.EBUSY, "Device or resource busy")
        buf = io.StringIO()
        with mock.patch.object(pixy, "find_video", return_value="/dev/video0"), \
             mock.patch.object(pixy, "Capture", side_effect=busy), \
             redirect_stdout(buf):
            pixy.cmd_preview(self.preview_args())
        payload = json.loads(buf.getvalue())
        self.assertFalse(payload["ok"])
        self.assertTrue(payload["busy"])
        self.assertTrue(payload["present"])

    def test_another_oserror_is_not_reported_as_busy(self):
        buf = io.StringIO()
        with mock.patch.object(pixy, "find_video", return_value="/dev/video0"), \
             mock.patch.object(pixy, "Capture",
                               side_effect=OSError(errno.ENODEV, "No such device")), \
             redirect_stdout(buf):
            pixy.cmd_preview(self.preview_args())
        self.assertFalse(json.loads(buf.getvalue())["busy"])

    def fake_capture(self, frames=8):
        """A Capture stand-in that yields synthetic YUYV frames."""
        outer = self

        class FakeCapture:
            width, height, bytes_per_line = 64, 48, 128

            def __init__(self, node, *a, **kw):
                self.node = node
                self.taken = 0

            def __enter__(self):
                return self

            def __exit__(self, *exc):
                outer.closed = True

            def frame(self, timeout=2.0):
                self.taken += 1
                if self.taken > frames:
                    raise OSError(errno.ETIMEDOUT, "no frame arrived")
                return yuyv_frame(64, 48, lambda x, y: (x * 4) % 256)

        return FakeCapture

    def run_preview(self, argv, frames=8):
        self.closed = False
        buf = io.StringIO()
        with mock.patch.object(pixy, "find_video", return_value="/dev/video0"), \
             mock.patch.object(pixy, "Capture", self.fake_capture(frames)), \
             redirect_stdout(buf):
            pixy.cmd_preview(self.preview_args(argv))
        return buf.getvalue()

    def test_emits_one_json_object_per_frame(self):
        out = self.run_preview(["--frames", "3", "--fps", "0", "--warmup", "0"])
        payloads = [json.loads(line) for line in out.strip().splitlines()]
        self.assertEqual(len(payloads), 3)
        self.assertEqual([p["frame"] for p in payloads], [0, 1, 2])
        for p in payloads:
            self.assertTrue(p["ok"])
            self.assertEqual(len(p["lines"]), p["height"])
            self.assertTrue(all(len(line) == p["width"] for line in p["lines"]))

    def test_warmup_frames_are_discarded_not_emitted(self):
        # The first frames after STREAMON are half-exposed; showing them makes
        # the preview open on a black flash.
        out = self.run_preview(["--frames", "2", "--fps", "0", "--warmup", "3"])
        self.assertEqual(len(out.strip().splitlines()), 2)

    def test_text_mode_prints_no_json(self):
        out = self.run_preview(["--frames", "1", "--fps", "0", "--warmup", "0", "--text"])
        self.assertNotIn("{", out)
        self.assertIn("\033[H\033[J", out)

    def test_releases_the_capture_when_the_stream_ends(self):
        # A leaked stream holds the camera against every other app, so the
        # context manager exit is part of the contract, not a detail.
        self.run_preview(["--frames", "1", "--fps", "0", "--warmup", "0"])
        self.assertTrue(self.closed)

    def test_a_timeout_mid_stream_ends_as_data_not_a_traceback(self):
        out = self.run_preview(["--frames", "20", "--fps", "0", "--warmup", "0"], frames=2)
        lines = out.strip().splitlines()
        self.assertEqual(len(lines), 3)
        self.assertFalse(json.loads(lines[-1])["ok"])

    def test_columns_are_clamped_to_something_renderable(self):
        out = self.run_preview(["--frames", "1", "--fps", "0", "--warmup", "0",
                                "--columns", "5000"])
        self.assertLessEqual(json.loads(out.strip())["width"], 200)

    def test_rows_default_to_the_aspect_corrected_count(self):
        out = self.run_preview(["--frames", "1", "--fps", "0", "--warmup", "0",
                                "--columns", "60"])
        self.assertEqual(json.loads(out.strip())["height"], pixy.auto_rows(60))

    def test_halfblocks_emit_the_requested_height(self):
        # Half-block mode samples at double height and folds it back down, so
        # the emitted height must still be the height that was asked for.
        out = self.run_preview(["--frames", "1", "--fps", "0", "--warmup", "0",
                                "--rows", "10", "--halfblocks"])
        payload = json.loads(out.strip())
        self.assertEqual(payload["height"], 10)
        self.assertEqual(len(payload["lines"]), 10)

    def test_streaming_commands_do_not_get_a_trailing_null_from_main(self):
        # main() prints its return value; cmd_preview returns None because it
        # has already printed. Printing again would append `null` and break
        # every line-oriented parser reading the stream.
        buf = io.StringIO()
        with mock.patch.object(pixy, "find_video", return_value=None), \
             redirect_stdout(buf):
            code = pixy.main(["preview"])
        self.assertEqual(code, 0)
        lines = buf.getvalue().strip().splitlines()
        self.assertEqual(len(lines), 1)
        # Every line must be a JSON object, so a bare `null` line is the failure
        # being guarded against — not the word appearing inside a payload.
        self.assertIsInstance(json.loads(lines[0]), dict)


class MainTests(unittest.TestCase):
    """main() must always print one JSON object and exit 0."""

    def run_main(self, argv):
        buf = io.StringIO()
        with redirect_stdout(buf):
            code = pixy.main(argv)
        return code, buf.getvalue()

    def test_prints_one_json_object_and_exits_zero(self):
        with mock.patch.object(pixy, "find_video", return_value=None), \
             mock.patch.object(pixy, "find_hidraw", return_value=None):
            code, out = self.run_main(["state"])
        self.assertEqual(code, 0)
        self.assertEqual(len(out.strip().splitlines()), 1)
        self.assertIsInstance(json.loads(out), dict)

    def test_an_unexpected_exception_still_leaves_as_json(self):
        # A traceback on stderr with empty stdout would render as a mystery
        # blank widget, so the catch-all is part of the contract.
        with mock.patch.object(pixy, "cmd_state", side_effect=RuntimeError("boom")):
            code, out = self.run_main(["state"])
        self.assertEqual(code, 0)
        payload = json.loads(out)
        self.assertFalse(payload["ok"])
        self.assertIn("RuntimeError", payload["error"])

    def test_keyboard_interrupt_exits_quietly(self):
        # Ctrl-C is how a `preview` stream is normally ended, so it exits
        # silently rather than printing an error frame — a traceback here would
        # make every intentional stop look like a camera fault. It stays exit 0
        # like every other path, so callers never have to special-case it.
        with mock.patch.object(pixy, "cmd_state", side_effect=KeyboardInterrupt):
            code, out = self.run_main(["state"])
        self.assertEqual(code, 0)
        self.assertEqual(out, "")

    def test_unknown_subcommand_exits_nonzero_via_argparse(self):
        # argparse's own usage error is the right behavior for a CLI typo; the
        # JSON contract covers runtime failures, not malformed invocations.
        with self.assertRaises(SystemExit) as ctx:
            with redirect_stdout(io.StringIO()), mock.patch.object(sys, "stderr", io.StringIO()):
                pixy.main(["nonsense"])
        self.assertNotEqual(ctx.exception.code, 0)

    def test_mode_rejects_an_unknown_value_at_the_parser(self):
        with self.assertRaises(SystemExit):
            with redirect_stdout(io.StringIO()), mock.patch.object(sys, "stderr", io.StringIO()):
                pixy.main(["mode", "banana"])


class ParserTests(unittest.TestCase):
    def test_every_subcommand_binds_a_function(self):
        for argv in (["state"], ["info"], ["holders"], ["mode", "standard"], ["privacy"],
                     ["ptz", "--home"], ["zoom", "120"], ["preset", "save", "1"],
                     ["image"], ["profile", "list"], ["preview"], ["vendor"],
                     ["snapshot"], ["formats"], ["audio"], ["gesture"], ["feature"],
                     ["metering"], ["auto-privacy"], ["native-preset", "list"]):
            self.assertTrue(callable(args_for(argv).fn), argv)

    def test_only_capturing_commands_are_marked_as_streaming(self):
        # `streams` is what tells main() not to print a return value. Setting it
        # on a non-streaming command would suppress that command's entire reply.
        for argv in (["preview"], ["snapshot"]):
            self.assertTrue(getattr(args_for(argv), "streams", False), argv)
        for argv in (["state"], ["info"], ["holders"], ["privacy"], ["zoom", "120"],
                     ["image"], ["profile", "list"], ["vendor"], ["formats"],
                     ["audio"], ["gesture"], ["feature"], ["metering"],
                     ["auto-privacy"], ["native-preset", "list"]):
            self.assertFalse(getattr(args_for(argv), "streams", False), argv)

    def test_vendor_subcommands_read_when_given_no_argument(self):
        # Every vendor setter doubles as a getter, so the panel can read one
        # feature without a separate command. An argument that became required
        # would break that.
        self.assertIsNone(args_for(["audio"]).mode)
        self.assertIsNone(args_for(["gesture"]).state)
        self.assertIsNone(args_for(["feature"]).name)
        self.assertIsNone(args_for(["metering"]).mode)
        self.assertIsNone(args_for(["auto-privacy"]).seconds)

    def test_metering_area_coordinates_are_integers(self):
        args = args_for(["metering", "area", "--x", "12", "--y", "34"])
        self.assertEqual((args.x, args.y), (12, 34))

    def test_native_preset_slot_is_optional_so_list_needs_no_argument(self):
        self.assertIsNone(args_for(["native-preset", "list"]).slot)
        self.assertEqual(args_for(["native-preset", "save", "2"]).slot, 2)

    def test_nudge_step_defaults_to_five_degrees(self):
        self.assertEqual(args_for(["ptz", "--nudge", "left"]).step, 5)

    def test_ptz_accepts_fractional_degrees(self):
        # The panel sends integers, but a human at the CLI may not.
        self.assertEqual(args_for(["ptz", "--pan", "12.5"]).pan, 12.5)

    def test_preset_slot_is_parsed_as_an_integer(self):
        self.assertEqual(args_for(["preset", "load", "3"]).slot, 3)

    def test_image_set_is_repeatable(self):
        args = args_for(["image", "--set", "brightness=1", "--set", "gamma=2"])
        self.assertEqual(args.set, ["brightness=1", "gamma=2"])

    def test_image_set_defaults_to_none_not_an_empty_list(self):
        # parse_assignments has to tolerate this; argparse's `append` gives None.
        self.assertIsNone(args_for(["image"]).set)

    def test_profile_name_is_optional_so_list_needs_no_argument(self):
        self.assertIsNone(args_for(["profile", "list"]).name)

    def test_image_help_names_every_settable_key(self):
        # The CLI is the documentation for these keys; a control missing from the
        # help text is one nobody can discover.
        text = io.StringIO()
        with redirect_stdout(text), self.assertRaises(SystemExit):
            pixy.build_parser().parse_args(["image", "--help"])
        for control in pixy.IMAGE_CONTROLS:
            self.assertIn(control["key"], text.getvalue())

    def test_a_subcommand_is_required(self):
        with self.assertRaises(SystemExit):
            with mock.patch.object(sys, "stderr", io.StringIO()):
                args_for([])


if __name__ == "__main__":
    unittest.main()
