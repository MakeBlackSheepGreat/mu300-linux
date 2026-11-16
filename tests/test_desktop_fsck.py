"""Internal-root repair happens before mounting and skips healthy filesystems."""
from helpers import ShellTest, TOP


class DesktopFsck(ShellTest):
    def setUp(self):
        super().setUp()
        # The function is a device shell script; the stand-in for the musl loader has to reach it in
        # POSIX form. A Windows path (C:\...) is handed to the shell with escapes, the loader never
        # runs (rc=127), and every expectation would describe the "no repair tools" branch instead.
        self.function = (TOP / "boot/internal-ext4.sh").read_text()
        self.loader = self.tmp / "loader"
        self.loader.write_text('#!/bin/sh\necho "$*" >> "$STUBLOG/fsck"\nexit "${TEST_FSCK_RC:-0}"\n')
        self.loader.chmod(0o755)
        self.stub("log", 'echo "$*" >> "$STUBLOG/log"')
        self.stub("setup_usb_gadget", 'echo usb-ready >> "$STUBLOG/usb"')
        self.root = self.tmp / "root"
        self.calls = self.tmp / "fsck"

    def body(self, loader=None):
        function = self.function.replace("/repair/lib/ld-musl-aarch64.so.1",
                                         (loader or self.loader).as_posix())
        function = function.replace("/etc/mu300-desktop-fsck-force", (self.tmp / "force").as_posix())
        function = function.replace("/run/mu300-root-fsck.log", (self.tmp / "fsck.log").as_posix())
        return function + '\ndesktop_ext4_check "$TEST_ROOT"'

    def run_case(self, magic, state, rc, loader=None):
        data = bytearray(4096)
        data[1080:1084] = magic.to_bytes(2, "little") + state.to_bytes(2, "little")
        self.root.write_bytes(data)
        self.calls.unlink(missing_ok=True)
        (self.tmp / "usb").unlink(missing_ok=True)
        return self.sh(self.shells[0], self.body(loader), TEST_ROOT=self.root.as_posix(),
                       TEST_FSCK_RC=str(rc))

    def test_clean_error_and_unknown_filesystems(self):
        source = (TOP / "desktop/boot/storage.sh").read_text()
        for magic, state, rc, ok, called in [(0xEF53, 1, 0, True, False),
                                             (0xEF53, 3, 1, True, True),
                                             (0xEF53, 3, 4, False, True),
                                             (0x1234, 3, 0, False, False)]:
            with self.subTest(magic=hex(magic), state=state, rc=rc):
                r = self.run_case(magic, state, rc)
                self.assertEqual(r.returncode == 0, ok, r.stderr)
                self.assertEqual(self.calls.exists(), called)
                self.assertEqual((self.tmp / "usb").exists(), called)
                if called:
                    self.assertIn("-fy " + self.root.as_posix(), self.calls.read_text())
        self.assertLess(source.index('desktop_ext4_check "$d"'),
                        source.index('mount -t ext4 -o noatime "$d" /disk'))

    def test_missing_repair_tools_let_the_kernel_replay_the_journal(self):
        # A phone ramdisk (NX302J) carries no /repair/: the loader is absent, the shell reports
        # 127, and the old code failed the check - so a filesystem whose journal had not been
        # replayed yet never got mounted and the device fell back to Android on every boot.
        absent = self.tmp / "no-such-repair" / "ld-musl-aarch64.so.1"
        r = self.run_case(0xEF53, 3, 0, loader=absent)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(self.calls.exists())


if __name__ == "__main__":
    import unittest

    unittest.main()
