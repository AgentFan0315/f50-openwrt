"""tools/android-install.sh: the SD card branch, cut out between its markers and run with stubs for Android's
tools (sm, mke2fs, umount) and files standing in for block devices."""
import re

from helpers import TOP, ShellTest
from test_boot_init import fake_ext4

SRC = (TOP / 'tools' / 'android-install.sh').read_text()


class SdCard(ShellTest):
    def setUp(self):
        super().setUp()
        m = re.search(r'# --- sd begin\n(.*?)# --- sd end', SRC, re.S)
        self.assertIsNotNone(m, 'android-install.sh has no sd block')
        self.fn = m.group(1)
        self.dev = self.tmp / 'mmcblk1p1'
        self.stub('mke2fs', 'echo "mke2fs $*" >> "$STUBLOG/calls"')
        self.stub('umount', 'echo "umount $*" >> "$STUBLOG/calls"')
        (self.tmp / 'mounts').write_text('')

    def run_fn(self, shell, call, volumes='', still_mounted=False):
        (self.tmp / 'volumes').write_text(volumes)
        after = volumes if still_mounted else volumes.replace(' mounted ', ' unmounted ')
        (self.tmp / 'volumes.after').write_text(after)
        self.stub('sm', 'case "$1" in list-volumes) cat "$STUBLOG/volumes" ;; '
                        'unmount) echo "sm unmount $2" >> "$STUBLOG/calls"; cp "$STUBLOG/volumes.after" "$STUBLOG/volumes" ;; esac')
        code = ('say() { echo "[device] $*"; }\n' + f'MU300_MOUNTS="{self.tmp}/mounts"\n' + self.fn
                + f'\n{call}\necho "rc=$?"')
        r = self.sh(shell, code)
        calls = (self.tmp / 'calls').read_text() if (self.tmp / 'calls').exists() else ''
        (self.tmp / 'calls').unlink(missing_ok=True)
        return r.stdout, calls

    def test_blank_card_is_formatted(self):
        self.dev.write_bytes(bytes(4096))
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 1')
            self.assertIn('rc=0', out)
            self.assertIn(f'mke2fs -t ext4 -L mu300sd -F {self.dev}', calls)

    def test_foreign_ext4_is_refused(self):
        fake_ext4(self.dev, 'photos')
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 1')
            self.assertIn('rc=1', out)
            self.assertIn('photos', out)
            self.assertNotIn('mke2fs', calls)

    def test_existing_installation_is_kept_or_replaced(self):
        fake_ext4(self.dev, 'mu300sd')
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 0')
            self.assertIn('rc=0', out); self.assertNotIn('mke2fs', calls)
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 1')
            self.assertIn('rc=0', out); self.assertIn('mke2fs', calls)

    def test_keep_without_installation_fails(self):
        self.dev.write_bytes(bytes(4096))
        for shell in self.each_shell():
            out, _ = self.run_fn(shell, f'sd_prepare {self.dev} 0')
            self.assertIn('rc=1', out)

    def test_android_releases_the_card(self):
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {self.dev}', volumes='public:179,1 mounted ABCD-1234\n')
            self.assertIn('rc=0', out)
            self.assertIn('sm unmount public:179,1', calls)

    def test_card_android_keeps_is_refused(self):
        for shell in self.each_shell():
            out, _ = self.run_fn(shell, f'sd_release {self.dev}', volumes='public:179,1 mounted ABCD-1234\n',
                                 still_mounted=True)
            self.assertIn('rc=1', out)

    def test_adopted_card_is_refused(self):
        # a card adopted as internal storage is encrypted and part of Android's data: never ours to take
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {self.dev}', volumes='private:179,3 mounted 1234-uuid\n')
            self.assertIn('rc=1', out)
            self.assertNotIn('sm unmount', calls)

    def test_builtin_private_storage_is_not_an_adopted_card(self):
        # Android lists its own data partition as "private mounted null" (no colon): that is no reason to refuse
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {self.dev}',
                                     volumes='private mounted null\nemulated;0 mounted null\n'
                                             'public:179,1 mounted ABCD-1234\n')
            self.assertIn('rc=0', out)
            self.assertIn('sm unmount public:179,1', calls)

    def test_leftover_mounts_of_the_card_only(self):
        # whatever is still mounted from the card goes; the eMMC (mmcblk0) and another card (mmcblk10) stay
        t = self.tmp
        (t / 'mounts').write_text(f'{t}/mmcblk0p40 /data ext4 rw 0 0\n'
                                  f'{t}/mmcblk1p1 /mnt/media_rw/ABCD vfat rw 0 0\n'
                                  f'{t}/mmcblk1p2 /mnt/other ext4 rw 0 0\n'
                                  f'{t}/mmcblk10p1 /mnt/ten vfat rw 0 0\n')
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {self.dev}')
            self.assertIn('rc=0', out)
            self.assertIn('umount /mnt/media_rw/ABCD', calls)
            self.assertIn('umount /mnt/other', calls)
            self.assertNotIn('/data', calls); self.assertNotIn('/mnt/ten', calls)
            self.assertNotIn('mmcblk0', calls); self.assertNotIn('mmcblk10', calls)

    def test_whole_card_never_reaches_the_emmc(self):
        # a card without a partition table: SD_DEV is mmcblk1 itself, and mmcblk0 must stay mounted
        t = self.tmp
        (t / 'mounts').write_text(f'{t}/mmcblk0 /emmc ext4 rw 0 0\n'
                                  f'{t}/mmcblk0p40 /data ext4 rw 0 0\n'
                                  f'{t}/mmcblk1 /mnt/media_rw/ABCD vfat rw 0 0\n')
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {t}/mmcblk1')
            self.assertIn('rc=0', out)
            self.assertIn('umount /mnt/media_rw/ABCD', calls)
            self.assertNotIn('/data', calls); self.assertNotIn('/emmc', calls)
            self.assertNotIn('mmcblk0', calls)
