"""android/magisk/mu300-linux-switch/switch.sh: the block it arms goes to the slot Android is not on, made from the
live one with the CRC the bootloader checks, and it refuses when that slot holds a copy of Android's boot image.
Run with --dry-run against files standing in for the partitions; awk and md5sum come from busybox, as on the device."""
import importlib.util
import shutil

from helpers import TOP, ShellTest
from test_boot_image import fake_misc

SWITCH = TOP / 'android' / 'magisk' / 'mu300-linux-switch' / 'switch.sh'


class Switch(ShellTest):
    def setUp(self):
        super().setUp()
        self.busybox = shutil.which('busybox')
        if not self.busybox:
            self.skipTest('no busybox')
        spec = importlib.util.spec_from_file_location('bbi', TOP / 'boot' / 'build-boot-image.py')
        bbi = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bbi)
        self.parts = self.tmp / 'by-name'
        self.parts.mkdir()
        fake_misc(self.parts / 'misc')
        self.blocks = bbi.bootloader_control((self.parts / 'misc').read_bytes())   # android_a, linux_b, android_b, linux_a
        self.stub('id', 'echo 0')

    def images(self, same=False):
        stock = b'ANDROID!' + b'\x11' * (64 << 10)
        (self.parts / 'boot_a').write_bytes(stock)
        (self.parts / 'boot_b').write_bytes(stock if same else b'ANDROID!' + b'\x22' * (64 << 10))

    def switch(self, shell, suffix, *args):
        return self.script(shell, SWITCH, *args, MU300_BY_NAME=self.parts, MU300_BUSYBOX=self.busybox,
                           MU300_SLOT_SUFFIX=suffix)

    def new_block(self, r):
        lines = [l for l in r.stdout.splitlines() if l.startswith('misc  new:')]
        self.assertEqual(len(lines), 1, r.stdout + r.stderr)
        return bytes.fromhex(lines[0].split(':', 1)[1].strip())

    def test_arms_the_slot_android_is_not_on(self):
        _, linux_b, _, linux_a = self.blocks
        self.images()
        before = (self.parts / 'misc').read_bytes()
        for shell in self.each_shell():
            for suffix, want in (('_a', linux_b), ('_b', linux_a)):
                r = self.switch(shell, suffix, '--dry-run')
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertEqual(self.new_block(r), want, suffix)
                self.assertIn('dry run', r.stdout)
        self.assertEqual((self.parts / 'misc').read_bytes(), before)

    def test_refuses_a_copy_of_android(self):
        self.images(same=True)
        for shell in self.each_shell():
            for suffix in ('_a', '_b'):
                r = self.switch(shell, suffix, '--dry-run')
                self.assertNotEqual(r.returncode, 0, suffix)
                self.assertNotIn('misc  new:', r.stdout)
                self.assertIn('same image', r.stderr)

    def test_unknown_slot(self):
        self.images()
        for shell in self.each_shell():
            r = self.switch(shell, '_c', '--dry-run')
            self.assertNotEqual(r.returncode, 0)
            self.assertIn("'_c'", r.stderr)
