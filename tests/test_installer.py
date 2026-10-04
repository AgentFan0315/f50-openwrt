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

    def run_choose(self, shell, card, internal=30 * GIB, answer='', forced=''):
        # card: None, or (device, sectors, has_partition, type)
        (self.tmp / 'sd').write_text('' if card is None else '%s %s %s\n' % (
            card[0] + ('p1' if card[2] else ''), card[1], card[3]))
        code = (f'TOP="{TOP}"; . "$TOP/tools/i18n.sh"; MU300_LANG=en; '
                'say() { :; }; die() { echo "DIE $*"; exit 1; }; '
                'gib() { echo "$1"; }; '
                'ask() { printf "ASKED[%s] " "$3"; read -r _a; [ -n "$_a" ] || _a=$3; eval "$1=\\$_a"; }; '
                f'su_do() {{ cat "{self.tmp}/sd"; }}; SIZE={internal}; '
                f'{"MU300_STORAGE=" + forced + "; " if forced else "unset MU300_STORAGE; "}'
                '. "$TOP/tools/storage.sh"; sd_probe; choose_storage; '
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


if __name__ == '__main__':
    unittest.main()
