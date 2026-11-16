"""boot/build-boot-image.py: the misc bootloader_control blocks written for a one-shot Linux trial.

Unisoc LK decodes a slot_info byte as successful_boot(bit 7) | tries_remaining(bits 6..4) |
priority(bits 3..0), not as the AOSP priority<<4 | tries<<1 | successful. Getting this wrong is
what left an NX302J stuck on a slot it could not boot: the blocks called the Linux slot
successful, so LK stopped counting tries and never fell back to Android. These assertions pin
the layout and the rule that a Linux trial slot is never marked successful."""
import importlib.util
import struct
import unittest
import zlib
from pathlib import Path

from helpers import TOP

SCRIPT = TOP / "boot" / "build-boot-image.py"


def load():
    spec = importlib.util.spec_from_file_location("build_boot_image", SCRIPT)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def stock_misc(slot_a=0x9E, slot_b=0x9F):
    """The misc head of an NX302J: a bootloader_control block at 0x800 with a valid CRC."""
    block = bytearray(32)
    block[0:4] = b"_b\0\0"
    block[4:8] = b"BCAB"
    struct.pack_into("<I", block, 8, 0x0201)
    block[12] = slot_a
    block[14] = slot_b
    struct.pack_into("<I", block, 28, zlib.crc32(bytes(block[:28])))
    head = bytearray(4096)
    head[0x800:0x820] = block
    return bytes(head)


def decode(byte):
    """The layout LK actually uses."""
    return {"successful": (byte >> 7) & 1, "tries": (byte >> 4) & 7, "priority": byte & 0xF}


class SlotInfo(unittest.TestCase):
    def setUp(self):
        self.m = load()

    def blocks(self, **kw):
        a, lb, b, la = self.m.bootloader_control(stock_misc(**kw))
        return {"android_a": a, "linux_b_trial": lb, "android_b": b, "linux_a_trial": la}

    def test_stock_values_decode_the_unisoc_way(self):
        # 0x9e / 0x9f is what the device ships, and LK reports priority 14/15, tries 1, successful 1
        self.assertEqual(decode(0x9E), {"successful": 1, "tries": 1, "priority": 14})
        self.assertEqual(decode(0x9F), {"successful": 1, "tries": 1, "priority": 15})

    def test_android_blocks_match_the_stock_values(self):
        got = self.blocks()
        self.assertEqual(got["android_b"][12], 0x9E)
        self.assertEqual(got["android_b"][14], 0x9F)
        self.assertEqual(got["android_a"][12], 0x9F)
        self.assertEqual(got["android_a"][14], 0x9E)

    def test_trial_slot_is_never_successful(self):
        got = self.blocks()
        for name, slot in (("linux_b_trial", 14), ("linux_a_trial", 12)):
            info = decode(got[name][slot])
            self.assertEqual(info["successful"], 0, name)
            self.assertGreaterEqual(info["tries"], 1, name)

    def test_trial_slot_outranks_the_android_slot(self):
        # LK boots the highest priority; the trial has to win for exactly one boot
        got = self.blocks()
        for name, trial, android in (("linux_b_trial", 14, 12), ("linux_a_trial", 12, 14)):
            self.assertGreater(decode(got[name][trial])["priority"],
                               decode(got[name][android])["priority"], name)

    def test_suffix_names_the_linux_slot(self):
        got = self.blocks()
        self.assertEqual(got["linux_b_trial"][0:4], b"_b\0\0")
        self.assertEqual(got["linux_a_trial"][0:4], b"_a\0\0")
        self.assertEqual(got["android_b"][0:4], b"_b\0\0")
        self.assertEqual(got["android_a"][0:4], b"_a\0\0")

    def test_crc_is_recomputed_for_every_block(self):
        for name, blk in self.blocks().items():
            self.assertEqual(zlib.crc32(blk[:28]), struct.unpack("<I", blk[28:])[0], name)

    def test_rejects_a_head_without_a_control_block(self):
        bad = bytearray(4096)
        with self.assertRaises(SystemExit):
            self.m.bootloader_control(bytes(bad))


if __name__ == "__main__":
    unittest.main()
