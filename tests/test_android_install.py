"""tools/android-install.sh: the SD card branch, cut out between its markers and run with stubs for Android's
tools (sm, mke2fs, umount) and files standing in for block devices."""
import re
import shutil

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

    def run_fn(self, shell, call, volumes='', still_mounted=False, sm_fails=False, pre=''):
        (self.tmp / 'volumes').write_text(volumes)
        after = volumes if still_mounted else volumes.replace(' mounted ', ' unmounted ')
        (self.tmp / 'volumes.after').write_text(after)
        fail = 'echo "Error: no volume manager" >&2; exit 3' if sm_fails else 'cat "$STUBLOG/volumes"'
        self.stub('sm', f'case "$1" in list-volumes) {fail} ;; '
                        'unmount) echo "sm unmount $2" >> "$STUBLOG/calls"; cp "$STUBLOG/volumes.after" "$STUBLOG/volumes" ;; esac')
        code = ('say() { echo "[device] $*"; }\n' + f'MU300_MOUNTS="{self.tmp}/mounts"\nMU300_SYSFS="{self.tmp}/sys"\n'
                + f'T="{self.tmp}"\n' + self.fn + f'\n{pre}\n{call}\necho "rc=$?"')
        r = self.sh(shell, code)
        calls = (self.tmp / 'calls').read_text() if (self.tmp / 'calls').exists() else ''
        (self.tmp / 'calls').unlink(missing_ok=True)
        return r.stdout, calls

    def test_blank_card_is_formatted(self):
        self.dev.write_bytes(bytes(4096))
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 1')
            self.assertIn('rc=0\n', out)
            self.assertIn(f'mke2fs -t ext4 -L mu300sd -F {self.dev}', calls)

    def test_foreign_ext4_is_refused(self):
        fake_ext4(self.dev, 'photos')
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 1')
            self.assertIn('rc=1\n', out)
            self.assertIn('photos', out)
            self.assertNotIn('mke2fs', calls)

    def test_unlabelled_ext4_is_refused(self):
        # an ext4 without a label is still someone's Linux data
        fake_ext4(self.dev, '')
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 1')
            self.assertIn('rc=1\n', out)
            self.assertIn('refusing to format', out)
            self.assertNotIn('mke2fs', calls)

    def test_non_ext4_card_is_formatted(self):
        # a FAT/exFAT card (magic bytes not 53ef): formatted after ERASE on the host
        fake_ext4(self.dev, 'NO NAME', magic=b'\x00\x00')
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 1')
            self.assertIn('rc=0\n', out)
            self.assertIn('mke2fs', calls)

    def test_existing_installation_is_kept_or_replaced(self):
        fake_ext4(self.dev, 'mu300sd')
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 0')
            self.assertIn('rc=0\n', out); self.assertNotIn('mke2fs', calls)
            out, calls = self.run_fn(shell, f'sd_prepare {self.dev} 1')
            self.assertIn('rc=0\n', out); self.assertIn('mke2fs', calls)

    def test_keep_without_installation_fails(self):
        self.dev.write_bytes(bytes(4096))
        for shell in self.each_shell():
            out, _ = self.run_fn(shell, f'sd_prepare {self.dev} 0')
            self.assertIn('rc=1\n', out)

    def test_android_releases_the_card(self):
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {self.dev}', volumes='public:179,1 mounted ABCD-1234\n')
            self.assertIn('rc=0\n', out)
            self.assertIn('sm unmount public:179,1', calls)

    def test_card_android_keeps_is_refused(self):
        for shell in self.each_shell():
            out, _ = self.run_fn(shell, f'sd_release {self.dev}', volumes='public:179,1 mounted ABCD-1234\n',
                                 still_mounted=True)
            self.assertIn('rc=1\n', out)

    def test_adopted_card_is_refused(self):
        # a card adopted as internal storage is encrypted and part of Android's data: never ours to take
        for shell in self.each_shell():
            for vols in ('private:179,3 mounted 1234-uuid\n', 'private:179,2 unmounted 1234-uuid\n'):
                out, calls = self.run_fn(shell, f'sd_release {self.dev}', volumes=vols)
                self.assertIn('rc=1\n', out)
                self.assertNotIn('sm unmount', calls)

    def test_failing_volume_manager_is_a_refusal(self):
        # no answer from sm is no proof that Android has let go of the card
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {self.dev}', sm_fails=True)
            self.assertIn('rc=1\n', out)
            self.assertNotIn('umount', calls)

    def test_usb_stick_is_left_alone(self):
        # public:8,1 is a USB disk (major 8): neither unmounted nor a reason to refuse; only the card (179) counts
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {self.dev}', still_mounted=True,
                                     volumes='public:8,1 mounted 5555-6666\n')
            self.assertIn('rc=0\n', out)
            self.assertNotIn('sm unmount', calls)

    def test_builtin_private_storage_is_not_an_adopted_card(self):
        # Android lists its own data partition as "private mounted null" (no colon): that is no reason to refuse
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {self.dev}',
                                     volumes='private mounted null\nemulated;0 mounted null\n'
                                             'public:179,1 mounted ABCD-1234\n')
            self.assertIn('rc=0\n', out)
            self.assertIn('sm unmount public:179,1', calls)

    def test_leftover_mounts_of_the_card_only(self):
        # vold mounts the card through /dev/block/vold/public:179,N, which sm unmount takes care of; these are
        # mounts of the card's own nodes made by hand. They go; the eMMC (mmcblk0) and another card (mmcblk10) stay
        t = self.tmp
        (t / 'mounts').write_text(f'{t}/mmcblk0p40 /data ext4 rw 0 0\n'
                                  f'{t}/mmcblk1p1 /mnt/media_rw/ABCD vfat rw 0 0\n'
                                  f'{t}/mmcblk1p2 /mnt/other ext4 rw 0 0\n'
                                  f'{t}/mmcblk10p1 /mnt/ten vfat rw 0 0\n')
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, f'sd_release {self.dev}')
            self.assertIn('rc=0\n', out)
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
            self.assertIn('rc=0\n', out)
            self.assertIn('umount /mnt/media_rw/ABCD', calls)
            self.assertNotIn('/data', calls); self.assertNotIn('/emmc', calls)
            self.assertNotIn('mmcblk0', calls)

    def sys_type(self, disk, kind):
        d = self.tmp / 'sys' / 'block' / disk / 'device'
        d.mkdir(parents=True, exist_ok=True)
        (d / 'type').write_text(kind + '\n')

    def test_emmc_is_never_the_card(self):
        self.sys_type('mmcblk0', 'SD')   # even when sysfs would claim it
        for shell in self.each_shell():
            for dev in ('/dev/block/mmcblk0p40', '/dev/block/mmcblk0'):
                out, _ = self.run_fn(shell, f'sd_check {dev}')
                self.assertIn('rc=1\n', out, dev)

    def test_non_sd_device_is_refused(self):
        self.sys_type('mmcblk1', 'SDIO')
        for shell in self.each_shell():
            out, _ = self.run_fn(shell, 'sd_check /dev/block/mmcblk1p1')
            self.assertIn('rc=1\n', out)
            out, _ = self.run_fn(shell, 'sd_check /dev/block/mmcblk2p1')   # no sysfs entry at all
            self.assertIn('rc=1\n', out)

    def test_sd_card_is_accepted(self):
        self.sys_type('mmcblk1', 'SD')
        for shell in self.each_shell():
            for dev in ('/dev/block/mmcblk1p1', '/dev/block/mmcblk1'):
                out, _ = self.run_fn(shell, f'sd_check {dev}')
                self.assertIn('rc=0\n', out, dev)

    def test_fstab_names_the_card(self):
        r = self.tmp / 'ubuntu'
        (r / 'etc').mkdir(parents=True)
        (r / 'etc' / 'fstab').write_text('# static\nLABEL=mu300root / ext4 defaults,noatime 0 1\n'
                                         'tmpfs /tmp tmpfs defaults 0 0\n')
        for shell in self.each_shell():
            out, _ = self.run_fn(shell, f'sd_fstab {r}', pre='set -e')
            self.assertIn('rc=0\n', out)
            self.assertEqual((r / 'etc' / 'fstab').read_text(),
                             '# static\nLABEL=mu300sd / ext4 defaults,noatime 0 1\ntmpfs /tmp tmpfs defaults 0 0\n')
            out, _ = self.run_fn(shell, f'sd_fstab {self.tmp}/openwrt', pre='set -e')   # no fstab: nothing to do
            self.assertIn('rc=0\n', out)

    def fake_mount_helper(self, body):
        (self.tmp / 'android-mount-mu300root.sh').write_text(
            'echo "helper $*" >> "$STUBLOG/calls"\n' + body + '\n')

    def test_internal_installation_is_marked(self):
        self.fake_mount_helper('[ "$1" = -u ] || mkdir -p "$1"')
        mark = self.tmp / 'mu300root-internal' / '.mu300' / 'root-on-sd'
        for shell in self.each_shell():
            out, calls = self.run_fn(shell, 'sd_mark_internal', pre='set -e; SD_MODE=1 OFF=1 SIZE=2 INTERNAL_EXISTS=1')
            self.assertIn('rc=0\n', out)
            self.assertTrue(mark.exists())
            self.assertIn(f'helper -u {self.tmp}/mu300root-internal', calls)
            mark.unlink()

    def test_marker_needs_an_internal_installation(self):
        self.fake_mount_helper('[ "$1" = -u ] || mkdir -p "$1"')
        for shell in self.each_shell():
            for pre in ('SD_MODE=1 OFF=1 SIZE=2 INTERNAL_EXISTS=0', 'SD_MODE=1 INTERNAL_EXISTS=1',
                        'SD_MODE=0 OFF=1 SIZE=2 INTERNAL_EXISTS=1'):
                out, calls = self.run_fn(shell, 'sd_mark_internal', pre='set -e; ' + pre)
                self.assertIn('rc=0\n', out, pre)
                self.assertNotIn('helper', calls, pre)

    def test_marker_never_fails_the_install(self):
        for shell in self.each_shell():
            self.fake_mount_helper('exit 1')   # the internal region does not mount
            out, _ = self.run_fn(shell, 'sd_mark_internal', pre='set -e; SD_MODE=1 OFF=1 SIZE=2 INTERNAL_EXISTS=1')
            self.assertIn('rc=0\n', out)
            # it mounts, but the marker cannot be written (the mount point is a file)
            self.fake_mount_helper('[ "$1" = -u ] || : > "$1"')
            out, calls = self.run_fn(shell, 'sd_mark_internal', pre='set -e; SD_MODE=1 OFF=1 SIZE=2 INTERNAL_EXISTS=1')
            self.assertIn('rc=0\n', out)
            self.assertIn('helper -u', calls)
            (self.tmp / 'mu300root-internal').unlink()
            # the directory is there but the marker is not writable (a directory in its place)
            self.fake_mount_helper('[ "$1" = -u ] || mkdir -p "$1/.mu300/root-on-sd"')
            out, calls = self.run_fn(shell, 'sd_mark_internal', pre='set -e; SD_MODE=1 OFF=1 SIZE=2 INTERNAL_EXISTS=1')
            self.assertIn('rc=0\n', out)
            self.assertIn('helper -u', calls)
            shutil.rmtree(self.tmp / 'mu300root-internal')
