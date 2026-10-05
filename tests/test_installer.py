"""tools/linux-mode.sh: which adb device install.sh and uninstall.sh work on. With a phone or tablet attached next to
the device the installer must ask, never pick one by itself."""
import unittest

from helpers import TOP, ShellTest

F50 = '324950664950           device usb:1 product:MU300 model:F50 device:MU300 transport_id:1'
U30 = '323960377386           device usb:2 product:U30Air model:U30_Air device:U30Air transport_id:2'
TABLET = 'd16d93c5               device usb:3 product:nabu_global model:21051182G device:nabu transport_id:3'
OFFLINE = '192.168.31.1:55555     offline product:MU5358 model:MU5358 device:MU5358 transport_id:4'


class SelectDevice(ShellTest):
    def run_select(self, shell, devices, answer='', mode=''):
        (self.tmp / 'adb.out').write_text('List of devices attached\n' + ''.join(d + '\n' for d in devices) + '\n')
        self.stub('adb', '[ "$1 $2" = "devices -l" ] && cat "$STUBLOG/adb.out"; exit 0')
        code = (f'TOP="{TOP}"; . "$TOP/tools/i18n.sh"; MU300_LANG=en; '
                'say() { :; }; die() { echo "DIE $*"; exit 1; }; '
                'ask() { printf "ASKED[%s] " "$3"; read -r _a; [ -n "$_a" ] || _a=$3; eval "$1=\\$_a"; }; '
                f'. "$TOP/tools/linux-mode.sh"; unset ANDROID_SERIAL; select_device {mode}; '
                'echo "rc=$? serial=${ANDROID_SERIAL:-none}"')
        return self.sh(shell, code, stdin=answer + '\n').stdout

    def test_one_device_that_is_the_target(self):
        for shell in self.each_shell():
            for dev, serial in ((F50, '324950664950'), (U30, '323960377386')):
                out = self.run_select(shell, [dev])
                self.assertNotIn('ASKED', out)
                self.assertIn(f'serial={serial}', out)

    def test_target_and_tablet_asks_with_the_target_as_default(self):
        for shell in self.each_shell():
            out = self.run_select(shell, [TABLET, F50, OFFLINE])
            self.assertIn('ASKED[2]', out)                 # the F50 is the second line, and the default
            self.assertIn('serial=324950664950', out)
            out = self.run_select(shell, [TABLET, F50], answer='1')
            self.assertIn('serial=d16d93c5', out)          # the user's choice counts
            out = self.run_select(shell, [F50, U30])       # two targets: ask, first is the default
            self.assertIn('ASKED[1]', out)

    def test_only_a_tablet_asks(self):
        # the F50 was in Linux and a tablet was the only adb device: it must not be taken silently
        for shell in self.each_shell():
            out = self.run_select(shell, [TABLET])
            self.assertIn('ASKED[1]', out)

    def test_invalid_choice(self):
        for shell in self.each_shell():
            self.assertIn('DIE', self.run_select(shell, [TABLET, F50], answer='7'))

    def test_quiet_never_asks(self):
        for shell in self.each_shell():
            out = self.run_select(shell, [TABLET, F50], mode='quiet')
            self.assertNotIn('ASKED', out)
            self.assertIn('rc=0 serial=324950664950', out)
            out = self.run_select(shell, [TABLET], mode='quiet')
            self.assertNotIn('ASKED', out)
            self.assertIn('rc=1 serial=none', out)


class Storage(ShellTest):
    """tools/storage.sh: internal region or SD card."""
    GIB = 1024 ** 3

    def run_choose(self, shell, card, internal=30 * GIB, answer='', forced='', label=None, tail=''):
        # card: None, or (device, sectors, has_partition, type); label: None (no ext4 on it) or its ext4 label
        if label is not None:
            (self.tmp / 'label').write_text(label)
        (self.tmp / 'sd').write_text('' if card is None else '%s %s %s\n' % (
            card[0] + ('p1' if card[2] else ''), card[1], card[3]))
        code = (f'TOP="{TOP}"; . "$TOP/tools/i18n.sh"; MU300_LANG=en; '
                'say() { :; }; die() { echo "DIE $*"; exit 1; }; '
                'gib() { echo "$1"; }; '
                'ask() { printf "ASKED[%s] " "$3"; read -r _a; [ -n "$_a" ] || _a=$3; eval "$1=\\$_a"; }; '
                f'su_do() {{ case $1 in *skip=1080*) [ -e "{self.tmp}/label" ] && echo " 53 ef" ;; '
                f'*skip=1144*) cat "{self.tmp}/label" 2>/dev/null ;; *) cat "{self.tmp}/sd" ;; esac; }}; SIZE={internal}; '
                f'{"MU300_STORAGE=" + forced + "; " if forced else "unset MU300_STORAGE; "}'
                '. "$TOP/tools/storage.sh"; sd_probe; ' + (tail or 'choose_storage; ') +
                'echo "mode=$SD_MODE dev=${SD_DEV:-none}"')
        return self.sh(shell, code, stdin=answer + '\n').stdout

    def test_no_card_never_asks(self):
        for shell in self.each_shell():
            out = self.run_choose(shell, None)
            self.assertNotIn('ASKED', out)
            self.assertIn('mode=0 dev=none', out)

    def test_card_asks_with_internal_as_default(self):
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'SD')
        for shell in self.each_shell():
            out = self.run_choose(shell, card)
            self.assertIn('ASKED[internal]', out)
            self.assertIn('mode=0', out)
            out = self.run_choose(shell, card, answer='sd')
            self.assertIn('mode=1 dev=/dev/block/mmcblk1p1', out)

    def test_small_internal_space_makes_the_card_the_default(self):
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, False, 'SD')
        for shell in self.each_shell():
            out = self.run_choose(shell, card, internal=100 * 1024 ** 2)
            self.assertIn('ASKED[sd]', out)
            self.assertIn('mode=1 dev=/dev/block/mmcblk1', out)

    def test_forced(self):
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'SD')
        for shell in self.each_shell():
            self.assertIn('mode=1', self.run_choose(shell, card, forced='sd'))
            out = self.run_choose(shell, card, forced='internal')
            self.assertNotIn('ASKED', out); self.assertIn('mode=0', out)

    def test_forced_sd_without_card_dies(self):
        for shell in self.each_shell():
            self.assertIn('DIE', self.run_choose(shell, None, forced='sd'))

    def test_small_first_partition_is_too_small(self):
        # 64 MiB first partition in front of a big card: too small, not a reason to take the whole device
        card = ('/dev/block/mmcblk1', 64 * 2048, True, 'SD')
        for shell in self.each_shell():
            out = self.run_choose(shell, card)
            self.assertNotIn('ASKED', out)
            self.assertIn('mode=0', out)

    def test_not_an_sd_card(self):
        for shell in self.each_shell():
            self.assertIn('mode=0 dev=none', self.run_choose(shell, ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'MMC')))

    def test_invalid_answer(self):
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'SD')
        for shell in self.each_shell():
            self.assertIn('DIE', self.run_choose(shell, card, answer='usb'))

    def test_sd_existing(self):
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'SD')
        for shell in self.each_shell():
            for label, want in ((None, 'no'), ('mu300sd', 'yes'), ('data', 'foreign'), ('', 'foreign')):
                (self.tmp / 'label').unlink(missing_ok=True)
                out = self.run_choose(shell, card, label=label, tail='echo "existing=$(sd_existing)"; SD_MODE=; ')
                self.assertIn('existing=%s\n' % want, out)

    def test_sd_existing_is_quiet_about_a_fat_card(self):
        # a FAT card has arbitrary bytes where ext4 keeps its label; macOS's tr in a UTF-8 locale printed
        # "tr: Illegal byte sequence" for them in the middle of the installer's report
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'SD')
        (self.tmp / 'label').write_bytes(b'\xff\xfe\x80MSDOS\xc3\x00\x00')
        code = (f'su_do() {{ case $1 in *skip=1080*) echo " 00 00" ;; *skip=1144*) cat "{self.tmp}/label" ;; '
                f'*) echo /dev/block/mmcblk1p1 {card[1]} SD ;; esac; }}; t() {{ printf %s "$1"; }}; '
                f'. "{TOP}/tools/storage.sh"; sd_probe; echo "existing=$(sd_existing)"')
        for shell in self.each_shell():
            r = self.sh(shell, code, LANG='en_US.UTF-8', LC_ALL='en_US.UTF-8')
            self.assertIn('existing=no\n', r.stdout)
            self.assertEqual('', r.stderr)

    def test_foreign_ext4_card_is_refused_before_anything_else(self):
        # the device refuses to format it; saying so only after the download and the build costs the user an hour
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'SD')
        for shell in self.each_shell():
            for kw in ({'answer': 'sd'}, {'forced': 'sd'}):
                out = self.run_choose(shell, card, label='data', **kw)
                self.assertIn('DIE', out)
                self.assertIn('MU300_STORAGE=internal', out)
            self.assertIn('mode=0', self.run_choose(shell, card, label='data'))        # internal stays possible
            self.assertIn('mode=1', self.run_choose(shell, card, label='mu300sd', answer='sd'))
            self.assertIn('DIE', self.run_choose(shell, card, label='', answer='sd'))   # unlabelled ext4 too


    def test_card_with_an_installation_is_the_default(self):
        # init starts a mu300sd card before anything internal: internal storage is not the safe answer then
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'SD')
        for shell in self.each_shell():
            out = self.run_choose(shell, card, label='mu300sd')
            self.assertIn('ASKED[sd]', out)
            self.assertIn('mode=1 dev=/dev/block/mmcblk1p1', out)
            self.assertNotIn('starts that one first', out)

    def test_internal_with_an_installed_card_warns_and_needs_a_confirmation(self):
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'SD')
        for shell in self.each_shell():
            for kw in ({'answer': 'internal\ninternal'}, {'forced': 'internal', 'answer': 'internal'}):
                out = self.run_choose(shell, card, label='mu300sd', **kw)
                self.assertIn('starts that one first', out, kw)
                self.assertIn('uninstall', out, kw)
                self.assertIn('ASKED[no]', out, kw)
                self.assertIn('mode=0', out, kw)
            for kw in ({'answer': 'internal\n'}, {'forced': 'internal', 'answer': 'yes'}):
                out = self.run_choose(shell, card, label='mu300sd', **kw)
                self.assertIn('starts that one first', out, kw)
                self.assertIn('DIE', out, kw)
                self.assertNotIn('mode=', out, kw)

    def test_internal_with_a_card_without_installation_asks_nothing_more(self):
        card = ('/dev/block/mmcblk1', 62 * 2 ** 21, True, 'SD')
        for shell in self.each_shell():
            for label in (None, 'data'):
                (self.tmp / 'label').unlink(missing_ok=True)
                for kw in ({'answer': 'internal'}, {'forced': 'internal'}):
                    out = self.run_choose(shell, card, label=label, **kw)
                    self.assertNotIn('starts that one first', out)
                    self.assertNotIn('ASKED[no]', out)
                    self.assertIn('mode=0', out)

    def test_sd_kernel_ok(self):
        # a mainline bundle without ./features: sdcard has the SD host gated off, and a card install with it would
        # never find its card (it lands in Android)
        k = self.tmp / 'kmain'
        k.mkdir()
        for shell in self.each_shell():
            for features, sd_mode, want in ((None, 1, 1), ('sdcard\n', 1, 0), ('other\n', 1, 1),
                                            (None, 0, 0), ('sdcard\n', 0, 0)):
                (k / 'features').unlink(missing_ok=True)
                if features is not None:
                    (k / 'features').write_text(features)
                r = self.sh(shell, f'. "{TOP}/tools/storage.sh"; SD_MODE={sd_mode}; sd_kernel_ok "{k}"; echo "rc=$?"')
                self.assertEqual(f'rc={want}', r.stdout.strip(), (features, sd_mode))

    def test_installer_refuses_a_card_install_with_a_kernel_that_cannot_read_it(self):
        src = (TOP / 'install.sh').read_text()
        unpack = src.index('tar -xzf "$REL/mu300-kernel-$KERNEL.tar.gz" -C "$KMAIN"')
        check = src.index('sd_kernel_ok "$KMAIN" || die')
        self.assertLess(unpack, check)
        self.assertLess(check, src.index("say \"$(t 'Adding the vendor files from your device to the images')\""))


class InstallEnv(ShellTest):
    """mu300-install.env, what android-install.sh is told: tools/storage.sh's write_install_env (install.sh) and
    install.ps1's InstallEnvText write the same text (tests/installer.Tests.ps1 compares the two)."""
    COMMON = dict(OFF=27762098176, FORMAT=1, OSES='ubuntu openwrt', WIPE_LEGACY=0, UPDATE=0, BOOT_OS='openwrt',
                  DEFAULT_LINUX=1, BOOT_ATTEMPTS=5, IMPORT_HOTSPOT=1, KERNEL='6.18', PWHASH='$6$salt$hash/x.y')

    def write_env(self, shell, **v):
        code = ''.join(f"{k}='{val}'; " for k, val in v.items())
        r = self.sh(shell, code + f'. "{TOP}/tools/storage.sh"; write_install_env')
        self.assertEqual('', r.stderr)
        return r.stdout

    @staticmethod
    def parse(text):
        return dict(line.split('=', 1) for line in text.splitlines())

    def test_sd_mode_carries_the_card_and_the_internal_region(self):
        # SIZE in SD mode is the card's; the file still gets the internal region (the marker goes there)
        for shell in self.each_shell():
            out = self.write_env(shell, **self.COMMON, SIZE=31914967040, INT_SIZE=34776023040, SD_MODE=1,
                           SD_DEV='/dev/block/mmcblk1p1', INTERNAL_EXISTS=1)
            e = self.parse(out)
            self.assertEqual(e['SD_MODE'], '1')
            self.assertEqual(e['SD_DEV'], '/dev/block/mmcblk1p1')
            self.assertEqual(e['INTERNAL_EXISTS'], '1')
            self.assertEqual((e['OFF'], e['SIZE']), ('27762098176', '34776023040'))
            self.assertEqual((e['OFF_S'], e['SIZE_S']), ('54222848', '67921920'))
            self.assertEqual((e['FORMAT'], e['UPDATE']), ('1', '0'))
            self.assertEqual(e['OSES'], '"ubuntu openwrt"')
            self.assertEqual(e['PWHASH'], "'$6$salt$hash/x.y'")
            self.assertEqual(list(e), ['OFF', 'SIZE', 'OFF_S', 'SIZE_S', 'FORMAT', 'OSES', 'WIPE_LEGACY', 'UPDATE',
                                       'BOOT_OS', 'DEFAULT_LINUX', 'BOOT_ATTEMPTS', 'IMPORT_HOTSPOT', 'KERNEL',
                                       'SD_MODE', 'SD_DEV', 'INTERNAL_EXISTS', 'PWHASH'])

    def test_internal_mode(self):
        for shell in self.each_shell():
            common = dict(self.COMMON, FORMAT=0, UPDATE=1)
            out = self.write_env(shell, **common, SIZE=34776023040, INT_SIZE='', SD_MODE=0, SD_DEV='', INTERNAL_EXISTS=1)
            e = self.parse(out)
            self.assertEqual((e['SD_MODE'], e['SD_DEV'], e['INTERNAL_EXISTS']), ('0', '', '1'))
            self.assertEqual((e['OFF'], e['SIZE'], e['OFF_S'], e['SIZE_S']),
                             ('27762098176', '34776023040', '54222848', '67921920'))
            self.assertEqual((e['FORMAT'], e['UPDATE']), ('0', '1'))

    def test_installer_writes_the_env_file_with_it(self):
        src = (TOP / 'install.sh').read_text()
        self.assertIn('write_install_env > "$env"', src)
        self.assertNotIn("printf 'OFF=", src)


class ImportHotspot(ShellTest):
    """tools/android-import-hotspot.sh writes into the installation that boots: the card's when it holds mu300sd
    (found the way reset-password.sh finds it), the internal one otherwise; MU300_SD_DEV still names one by hand."""

    def run_import(self, shell, card, label=None, **env):
        (self.tmp / 'sd').write_text(card)
        if label is not None:
            (self.tmp / 'label').write_text(label)
        else:
            (self.tmp / 'label').unlink(missing_ok=True)
        # adb shell "su -c '...'": the card probe and its superblock, then the import itself (recorded)
        self.stub('adb', 'case "$2" in *"/sys/block/mmcblk[1-9]"*) cat "$STUBLOG/sd" ;; '
                         '*skip=1080*) [ -e "$STUBLOG/label" ] && echo " 53 ef" ;; '
                         '*skip=1144*) cat "$STUBLOG/label" 2>/dev/null ;; '
                         '*WifiConfigStoreSoftAp*) printf %s "$2" > "$STUBLOG/import"; echo imported ;; esac')
        (self.tmp / 'import').unlink(missing_ok=True)
        r = self.script(shell, TOP / 'tools' / 'android-import-hotspot.sh', **env)
        imp = (self.tmp / 'import').read_text() if (self.tmp / 'import').exists() else ''
        return r, imp

    def test_card_installation_is_found_by_itself(self):
        for shell in self.each_shell():
            r, imp = self.run_import(shell, '/dev/block/mmcblk1p1 62333952 SD\n', label='mu300sd')
            self.assertEqual(0, r.returncode, r.stderr)
            self.assertIn('MU300_SD_DEV=/dev/block/mmcblk1p1 sh /data/local/tmp/android-mount-mu300root.sh', imp)

    def test_internal_without_an_installed_card(self):
        for shell in self.each_shell():
            for card, label in (('', None), ('/dev/block/mmcblk1p1 62333952 SD\n', None),
                                ('/dev/block/mmcblk1p1 62333952 SD\n', 'data')):
                r, imp = self.run_import(shell, card, label=label)
                self.assertEqual(0, r.returncode, r.stderr)
                self.assertIn('android-mount-mu300root.sh', imp)
                self.assertNotIn('MU300_SD_DEV', imp, (card, label))

    def test_named_card_still_wins_and_the_emmc_is_refused(self):
        for shell in self.each_shell():
            r, imp = self.run_import(shell, '', MU300_SD_DEV='/dev/block/mmcblk2p1')
            self.assertIn('MU300_SD_DEV=/dev/block/mmcblk2p1 sh', imp)
            r, imp = self.run_import(shell, '/dev/block/mmcblk1p1 62333952 SD\n', label='mu300sd',
                                     MU300_SD_DEV='/dev/block/mmcblk0p1')
            self.assertNotEqual(0, r.returncode)
            self.assertEqual('', imp)

class SdErase(ShellTest):
    """tools/storage.sh's sd_erase (uninstall.sh): the card is erased only when it holds mu300sd, never the eMMC.

    su_do runs the device commands here, with dd, sm and umount as stubs: dd reads the superblock from the files
    label/magic and logs every write, sm lists the volumes in vols, umount drops the line from the mounts file."""

    def setUp(self):
        super().setUp()
        t = self.tmp
        self.stub('dd', 'case "$*" in\n'
                  '  *of=*) echo "dd $*" >> "$STUBLOG/log"; [ -e "$STUBLOG/stuck" ] || rm -f "$STUBLOG/label" ;;\n'
                  '  *skip=1080*) [ -e "$STUBLOG/label" ] && [ ! -e "$STUBLOG/nomagic" ] && printf "\\123\\357" ;;\n'
                  '  *skip=1144*) cat "$STUBLOG/label" 2>/dev/null ;;\n'
                  'esac; true')
        self.stub('sm', 'case $1 in list-volumes) cat "$STUBLOG/vols" ;; *) echo "sm $*" >> "$STUBLOG/log"\n'
                  '  [ -e "$STUBLOG/stuck-sm" ] && exit 1\n'
                  '  grep -v "/vold/$2 " "$STUBLOG/mounts" > "$STUBLOG/m.new"; mv "$STUBLOG/m.new" "$STUBLOG/mounts" ;; esac')
        self.stub('umount', 'echo "umount $*" >> "$STUBLOG/log"; [ -e "$STUBLOG/stuck-mount" ] && exit 1\n'
                  'grep -v " $1 " "$STUBLOG/mounts" > "$STUBLOG/m.new"; mv "$STUBLOG/m.new" "$STUBLOG/mounts"')
        self.stub('sync', 'true')
        (t / 'vols').write_text('private mounted null\npublic:179,1 mounted 1234-ABCD\npublic:8,1 mounted 55AA-1\n')
        (t / 'mounts').write_text('/dev/block/mmcblk0p40 /data f2fs rw 0 0\n'
                                  '/dev/block/mmcblk1p1 /data/local/tmp/mu300root ext4 rw 0 0\n')
        (t / 'log').write_text('')
        for disk in ('mmcblk0', 'mmcblk1'):
            (t / 'sys' / 'block' / disk / 'device').mkdir(parents=True)
        (t / 'sys/block/mmcblk0/device/type').write_text('MMC\n')
        (t / 'sys/block/mmcblk1/device/type').write_text('SD\n')

    def run_erase(self, shell, label='mu300sd', dev='/dev/block/mmcblk1', tail='sd_erase; echo SURVIVED'):
        if label is not None:
            (self.tmp / 'label').write_bytes(label.encode() + b'\0' * (16 - len(label)))
        (self.tmp / 'sd').write_text(f'{dev} {62 * 2 ** 21} SD\n')
        code = (f'TOP="{TOP}"; say() {{ :; }}; die() {{ echo "DIE $*"; exit 1; }}; '
                'gib() { echo "$1"; }; t() { printf "%s" "$1"; }; '
                'su_do() { case $1 in "for b in /sys/block/mmcblk"*) cat "$STUBLOG/sd" ;; *) sh -c "$1" ;; esac; }; '
                f'MU300_SYSFS="{self.tmp}/sys"; MU300_MOUNTS="{self.tmp}/mounts"; '
                '. "$TOP/tools/storage.sh"; sd_probe; ' + tail)
        return self.sh(shell, code).stdout, (self.tmp / 'log').read_text()

    def test_erases_the_mu300sd_card_after_releasing_it(self):
        for shell in self.each_shell():
            (self.tmp / 'mounts').write_text('/dev/block/mmcblk0p40 /data f2fs rw 0 0\n'
                                             '/dev/block/mmcblk1p1 /data/local/tmp/mu300root ext4 rw 0 0\n')
            (self.tmp / 'log').write_text('')
            out, log = self.run_erase(shell, dev='/dev/block/mmcblk1p1')
            self.assertIn('SURVIVED', out)
            self.assertNotIn('DIE', out)
            self.assertIn('sm unmount public:179,1\n', log)
            self.assertNotIn('public:8,1', log)                     # a USB stick is not the card
            self.assertIn('umount /data/local/tmp/mu300root\n', log)
            self.assertNotIn('umount /data\n', log)                 # the eMMC's own mounts stay
            self.assertIn('dd if=/dev/zero of=/dev/block/mmcblk1p1 bs=1048576 count=64 conv=notrunc', log)
            self.assertEqual(log.count('dd '), 1)

    def test_whole_card_without_a_partition_table(self):
        for shell in self.each_shell():
            out, log = self.run_erase(shell, dev='/dev/block/mmcblk1')
            self.assertIn('SURVIVED', out)
            self.assertIn('of=/dev/block/mmcblk1 ', log)

    def test_never_a_card_without_mu300sd(self):
        for shell in self.each_shell():
            for label in (None, 'data', '', 'mu300root'):
                (self.tmp / 'label').unlink(missing_ok=True)
                (self.tmp / 'log').write_text('')
                out, log = self.run_erase(shell, label=label)
                self.assertIn('DIE', out, label)
                self.assertNotIn('dd ', log, label)

    def test_no_card(self):
        for shell in self.each_shell():
            (self.tmp / 'sd').write_text('')
            out, log = self.run_erase(shell, tail='SD_DEV=; sd_erase; echo SURVIVED')
            self.assertIn('DIE', out)
            self.assertNotIn('dd ', log)

    def test_never_the_emmc(self):
        # mmcblk0 is the eMMC Android runs from, whatever its superblock says: refused on the host and, should a
        # command for it ever be built, on the device too
        for shell in self.each_shell():
            for dev in ('/dev/block/mmcblk0p1', '/dev/block/mmcblk0', '/dev/block/sda1', '/dev/block/mmcblk1p1 x'):
                (self.tmp / 'log').write_text('')
                out, log = self.run_erase(shell, tail=f'SD_DEV="{dev}"; sd_erase; echo SURVIVED')
                self.assertIn('DIE', out, dev)
                self.assertNotIn('dd ', log, dev)
            for dev in ('/dev/block/mmcblk0p1', '/dev/block/mmcblk0'):
                out, log = self.run_erase(shell, tail=f'su_do "$(sd_erase_cmd {dev})"')
                self.assertIn('REFUSED', out, dev)
                self.assertNotIn('dd ', log, dev)

    def test_device_side_checks(self):
        for shell in self.each_shell():
            # not an SD card in sysfs (a second eMMC, an SDIO function)
            (self.tmp / 'sys/block/mmcblk1/device/type').write_text('MMC\n')
            out, log = self.run_erase(shell, tail='su_do "$(sd_erase_cmd /dev/block/mmcblk1p1)"')
            self.assertIn('REFUSED', out); self.assertNotIn('dd ', log)
            (self.tmp / 'sys/block/mmcblk1/device/type').write_text('SD\n')
            # the ext4 magic is gone (the label bytes alone are no filesystem)
            (self.tmp / 'nomagic').write_text('')
            out, log = self.run_erase(shell, tail='su_do "$(sd_erase_cmd /dev/block/mmcblk1p1)"')
            self.assertIn('REFUSED', out); self.assertNotIn('dd ', log)
            (self.tmp / 'nomagic').unlink()
            # the label changed between the host check and the erase
            out, log = self.run_erase(shell, label='data', tail='su_do "$(sd_erase_cmd /dev/block/mmcblk1p1)"')
            self.assertIn('REFUSED', out); self.assertNotIn('dd ', log)

    def test_vold_mount_that_stays_is_not_erased(self):
        # vold mounts the card as /dev/block/vold/public:179,N: a failed sm unmount must stop the write too
        vold = '/dev/block/vold/public:179,1 /mnt/media_rw/1234-ABCD vfat rw 0 0\n'
        for shell in self.each_shell():
            (self.tmp / 'mounts').write_text(vold)
            (self.tmp / 'log').write_text('')
            out, log = self.run_erase(shell, dev='/dev/block/mmcblk1p1')
            self.assertIn('SURVIVED', out)                          # sm let go of it: erased
            self.assertIn('dd if=/dev/zero', log)
            (self.tmp / 'stuck-sm').write_text('')
            (self.tmp / 'mounts').write_text(vold)
            (self.tmp / 'log').write_text('')
            out, log = self.run_erase(shell, dev='/dev/block/mmcblk1p1')
            self.assertIn('DIE', out)
            self.assertNotIn('dd ', log)
            (self.tmp / 'stuck-sm').unlink()

    def test_still_mounted_is_not_erased(self):
        for shell in self.each_shell():
            (self.tmp / 'stuck-mount').write_text('')
            (self.tmp / 'mounts').write_text('/dev/block/mmcblk1p1 /data/local/tmp/mu300root ext4 rw 0 0\n')
            out, log = self.run_erase(shell, dev='/dev/block/mmcblk1p1')
            self.assertIn('DIE', out)
            self.assertNotIn('dd ', log)

    def test_a_filesystem_that_survives_the_erase_is_reported(self):
        for shell in self.each_shell():
            (self.tmp / 'stuck').write_text('')
            out, _ = self.run_erase(shell)
            self.assertIn('DIE', out)
            self.assertIn('still', out)

    def test_device_command_has_no_quotes(self):
        # it travels inside su -c '...', and uninstall.ps1 sends the same text, where double quotes are lost
        for shell in self.each_shell():
            out, _ = self.run_erase(shell, tail='sd_erase_cmd /dev/block/mmcblk1p1')
            self.assertTrue(out)
            self.assertNotIn("'", out); self.assertNotIn('"', out)


if __name__ == '__main__':
    unittest.main()
