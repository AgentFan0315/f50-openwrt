"""The zip: customize.sh in a fake Magisk installer environment (and, with Task 10, tools/make-magisk-zips.sh)."""
import os
import shutil
import unittest
import zipfile

from helpers import TOP, ShellTest

MAGISK_ENV = r'''
ui_print() { echo "$1"; }
abort() { echo "ABORT $1"; rm -rf "$MODPATH"; exit 1; }
set_perm() { chmod "$4" "$1"; }
set_perm_recursive() { chmod -R u+rwX "$1"; }
BOOTMODE=true; MAGISK_VER_CODE=30700
'''

BUSYBOX = shutil.which('busybox')


@unittest.skipUnless(BUSYBOX, 'no busybox')
class Customize(ShellTest):
    def setUp(self):
        super().setUp()
        (self.tmp / 'magisk').mkdir()
        os.symlink(BUSYBOX, self.tmp / 'magisk' / 'busybox')

    def zip_with(self, install_sh):
        z = self.tmp / 'm.zip'
        with zipfile.ZipFile(z, 'w') as f:
            f.writestr('mu300/install.sh', install_sh + '\n')
            f.writestr('module.prop', 'id=x\n')
            f.writestr('action.sh', '#!/system/bin/sh\n')
            f.writestr('switch.sh', '#!/system/bin/sh\n')
            f.writestr('system/bin/mu300-linux', '#!/system/bin/sh\n')
        return z

    def run_customize(self, shell, install_sh, bootmode='true'):
        z = self.zip_with(install_sh)
        mod = self.tmp / 'modpath'
        mod.mkdir(exist_ok=True)
        code = (MAGISK_ENV + f'BOOTMODE={bootmode}; ZIPFILE="{z}"; MODPATH="{mod}"; TMPDIR="{self.tmp}/t"; '
                f'MAGISKBIN="{self.tmp}/magisk"; mkdir -p "$TMPDIR"; set +e +u; '
                f'. "{TOP}/android/magisk/installer/customize.sh"; echo "after opts=$-"')
        return self.sh(shell, code), mod

    def test_success_installs_the_switch(self):
        for shell in self.each_shell():
            r, mod = self.run_customize(shell, 'echo installing; exit 0')
            self.assertIn('installing', r.stdout)
            self.assertTrue((mod / 'switch.sh').exists() and (mod / 'module.prop').exists())
            self.assertNotIn('e', r.stdout.split('after opts=')[1].split()[0])   # Magisk's options untouched

    def test_failure_and_dry_run_abort(self):
        for shell in self.each_shell():
            for rc, word in ((1, 'not installed'), (3, 'Dry run')):
                r, mod = self.run_customize(shell, f'exit {rc}')
                self.assertIn('ABORT', r.stdout)
                self.assertIn(word, r.stdout)
                self.assertFalse(mod.exists())

    def test_recovery_is_refused(self):
        for shell in self.each_shell():
            r, _ = self.run_customize(shell, 'echo ran; exit 0', bootmode='false')
            self.assertIn('ABORT', r.stdout)
            self.assertNotIn('ran', r.stdout)


if __name__ == '__main__':
    unittest.main()
