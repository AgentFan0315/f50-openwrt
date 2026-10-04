"""tools/android-boot-image.sh: the parts of the Linux boot image only the device can make - its misc blocks, its
Android files, the device ramdisk segment - checked against boot/build-boot-image.py on the same inputs."""
import importlib.util
import os
import re
import shutil
import stat
import struct
import subprocess
import sys
import unittest

from helpers import BIN, TOP, ShellTest
from test_boot_image import HAVE_LZ4, LIVE_A, cpio_files, fake_misc, fake_stock, unlz4_legacy

LIB = TOP / 'tools' / 'android-boot-image.sh'
spec = importlib.util.spec_from_file_location('bbi', TOP / 'boot' / 'build-boot-image.py')
bbi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bbi)

# magiskboot compress=lz4_legacy IN OUT and decompress IN OUT, done by the builder's own lz4_legacy and the tests'
# unlz4_legacy (the lz4 command or module)
MAGISKBOOT = f'''#!/bin/sh
case $1 in
    compress=lz4_legacy) f='m.lz4_legacy' ;;
    decompress) f='unlz4_legacy' ;;
    *) exit 1 ;;
esac
exec "{sys.executable}" -c "import importlib.util,sys; sys.path.insert(0,'{TOP}/tests'); from test_boot_image import unlz4_legacy; s=importlib.util.spec_from_file_location('b','{TOP}/boot/build-boot-image.py'); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); open(sys.argv[2],'wb').write($f(open(sys.argv[1],'rb').read()))" "$2" "$3"
'''


def cpio_all(data):
    """every newc archive of a byte string (as the kernel reads concatenated segments), later files win"""
    files, i = {}, 0
    while i < len(data):
        if data[i:i + 6] != b'070701':
            i += 1
            continue
        part = cpio_files(data[i:])
        files.update(part)
        i = data.index(b'TRAILER!!!', i) + 10
    return files


def subset_paths():
    lines = (TOP / 'android-vendor' / 'subset-files.txt').read_text().splitlines()
    return [l for l in lines if l.strip() and not l.startswith('#')]


def fake_android_root(root):
    """a / with every file of the subset list (dirs get one file inside) and the firmware"""
    for p in subset_paths():
        f = root / p
        if p.endswith(('bionic', '__properties__')):
            f.mkdir(parents=True, exist_ok=True)
            (f / 'u:object_r:x:s0' if '__properties__' in p else f / 'libc.so').write_bytes(b'data ' + p.encode())
        else:
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_bytes(b'data ' + p.encode())
    os.chmod(root / 'vendor/bin/modem_control', 0o755)
    fw = root / 'vendor/firmware'
    fw.mkdir(parents=True, exist_ok=True)
    for n in ('wcnmodem.bin', 'gnssmodem.bin', 'wifi_board_config.ini', 'wifi_board_config_ab.ini',
              'bt_configure_pskey.ini', 'bt_configure_rf.ini'):
        (fw / n).write_bytes(b'fw ' + n.encode())


def ramdisk_of(img):
    ksz, rsz = struct.unpack_from('<II', img, 8)
    roff = 4096 + (ksz + 4095) // 4096 * 4096
    return img[roff:roff + rsz]


def leaves(files):
    """the regular files and symlinks of cpio_all's result: kind, executable or not, contents"""
    return {n: (stat.S_IFMT(m), bool(m & 0o111), d) for n, (m, d) in files.items()
            if stat.S_ISREG(m) or stat.S_ISLNK(m)}


class Lists(unittest.TestCase):
    def test_subset_list_is_extract_subsets(self):
        sh = (TOP / 'android-vendor' / 'extract-subset.sh').read_text()
        m = re.search(r'tar -cf - (apex/.*?) \| tar -xf -', sh, re.S)
        self.assertEqual(m.group(1).replace('\\\n', ' ').split(), subset_paths())


class DeviceSide(ShellTest):
    def setUp(self):
        super().setUp()
        self.stub('magiskboot', MAGISKBOOT)

    def lib(self, shell, code, **env):
        pre = f'MU300_LIB=1 . "{BIN}/mu300-update"; . "{LIB}"; '
        return self.sh(shell, pre + code, MAGISKBOOT=self.stubs / 'magiskboot', **env)

    def test_blocks_equal_the_python_builders(self):
        want = dict(zip(('slot-a', 'slot-b-trial', 'slot-b', 'slot-a-trial'),
                        bbi.bootloader_control(bytes(0x800) + LIVE_A)))
        for shell in self.each_shell():
            d = self.tmp / 'etc'
            shutil.rmtree(d, ignore_errors=True); d.mkdir()
            r = self.lib(shell, f'bc_valid {LIVE_A.hex()} && bc_files {LIVE_A.hex()} "{d}"')
            self.assertEqual(r.returncode, 0, r.stderr)
            for n, data in want.items():
                self.assertEqual((d / f'misc-bc-{n}.bin').read_bytes(), data, (shell, n))

    def test_invalid_live_block(self):
        bad = bytearray(LIVE_A); bad[20] ^= 1
        for shell in self.each_shell():
            self.assertNotEqual(self.lib(shell, f'bc_valid {bytes(bad).hex()}').returncode, 0)
            self.assertNotEqual(self.lib(shell, 'bc_valid 00').returncode, 0)

    def test_subset_and_firmware_from_the_device(self):
        root = self.tmp / 'root'
        fake_android_root(root)
        for shell in self.each_shell():
            s, fw = self.tmp / 'subset', self.tmp / 'fw'
            r = self.lib(shell, f'collect_subset "{TOP}/android-vendor/subset-files.txt" "{s}" && collect_firmware "{fw}"',
                         MU300_ANDROID_ROOT=root, MU300_FW_DIRS=f'{root}/odm/firmware {root}/vendor/firmware')
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertTrue((s / 'vendor/bin/modem_control').is_file())
            self.assertEqual(os.readlink(s / 'system/bin/linker64'), '/apex/com.android.runtime/bin/linker64')
            self.assertEqual((s / 'linkerconfig/ld.config.txt').read_bytes(), b'')
            self.assertEqual(sorted(os.listdir(fw)), sorted(os.listdir(root / 'vendor/firmware')))
            shutil.rmtree(fw)
            (root / 'vendor/firmware/gnssmodem.bin').rename(root / 'gnss.bak')
            r = self.lib(shell, f'collect_firmware "{fw}"', MU300_FW_DIRS=f'{root}/vendor/firmware')
            self.assertNotEqual(r.returncode, 0)
            self.assertIn('gnssmodem.bin', r.stdout)
            (root / 'gnss.bak').rename(root / 'vendor/firmware/gnssmodem.bin')
            shutil.rmtree(s); shutil.rmtree(fw, ignore_errors=True)

    def test_vendor_overlay_layout(self):
        # the layout of tools/vendor-overlay.py: firmware, the subset with its property area moved out of dev/
        root = self.tmp / 'root'
        fake_android_root(root)
        for shell in self.each_shell():
            for os_name, fwdir in (('ubuntu', 'usr/lib/firmware'), ('openwrt', 'lib/firmware')):
                out = self.tmp / f'v-{os_name}.tar.gz'
                r = self.lib(shell, f'collect_subset "{TOP}/android-vendor/subset-files.txt" "{self.tmp}/s" && '
                                    f'collect_firmware "{self.tmp}/fw" && vendor_overlay {os_name} "{self.tmp}/fw" "{self.tmp}/s" "" "{out}"',
                             MU300_ANDROID_ROOT=root, MU300_FW_DIRS=f'{root}/vendor/firmware')
                self.assertEqual(r.returncode, 0, r.stderr)
                names = subprocess.run(['tar', '-tzf', str(out)], capture_output=True, text=True).stdout.split()
                names = [n.lstrip('./') for n in names]
                self.assertIn(f'{fwdir}/wcnmodem.bin', names)
                self.assertIn('opt/mu300/android/vendor/bin/modem_control', names)
                self.assertTrue(any(n.startswith('opt/mu300/android/dev-properties/') for n in names))
                self.assertFalse([n for n in names if n.startswith('opt/mu300/android/dev/')])
                # no entry for a directory the system already has: Ubuntu's lib is a link to usr/lib
                self.assertFalse([n for n in names if n.rstrip('/') in ('lib', 'usr', 'usr/lib', 'opt', 'opt/mu300')])
                shutil.rmtree(self.tmp / 's'); shutil.rmtree(self.tmp / 'fw')

    @unittest.skipIf(not HAVE_LZ4, 'no lz4')
    def test_whole_image_holds_what_the_python_builder_puts_in(self):
        # one set of inputs: Android's root, its boot image and misc, the modules and tools of a kernel bundle
        root = self.tmp / 'root'
        fake_android_root(root)
        stock, misc = self.tmp / 'stock.img', self.tmp / 'misc.bin'
        fake_stock(stock)
        fake_misc(misc)
        mods, bundle = self.tmp / 'modules', self.tmp / 'bundle'
        mods.mkdir(); bundle.mkdir()
        for n in (TOP / 'boot' / 'module-order.txt').read_text().split():
            (mods / n).write_bytes(b'\x7fELF base ' + n.encode())
        for f in ('busybox', 'logdw'):
            (self.tmp / f).write_bytes(b'\x7fELF ' + f.encode())
        (bundle / 'Image').write_bytes(b'\x7fkernel' * 1000)
        common = ['--modules', str(mods), '--busybox', str(self.tmp / 'busybox'), '--logdw', str(self.tmp / 'logdw'),
                  '--ueventd-perms', str(TOP / 'android-vendor' / 'ueventd-perms.sh')]
        builder = [sys.executable, str(TOP / 'boot' / 'build-boot-image.py')]
        r = subprocess.run(builder + ['--generic-ramdisk', '--out', str(bundle / 'ramdisk-generic.lz4')] + common,
                           capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

        for shell in self.each_shell():
            work = self.tmp / 'work'
            shutil.rmtree(work, ignore_errors=True)
            seg, out = work / 'seg', work / 'out'
            seg.mkdir(parents=True); out.mkdir()
            # the device side, as the installer does it
            r = self.lib(shell, f'mkdir -p "{seg}/etc" && echo f50 > "{seg}/etc/mu300-device" && '
                                f'echo b > "{seg}/etc/mu300-linux-slot" && bc_files {LIVE_A.hex()} "{seg}/etc" && '
                                f'collect_subset "{TOP}/android-vendor/subset-files.txt" "{seg}/android" && '
                                f'device_segment "{seg}" "{work}/dev.lz4" && '
                                f'linux_boot_image "{stock}" "{bundle}" "{work}/dev.lz4" "{out}"',
                         MU300_ANDROID_ROOT=root)
            self.assertEqual(r.returncode, 0, r.stderr)
            # the same on a computer, with the subset the device collected
            py = work / 'py.img'
            r = subprocess.run(builder + ['--stock-boot', str(stock), '--misc-head', str(misc),
                                          '--kernel', str(bundle / 'Image'),
                                          '--append-ramdisk', str(bundle / 'ramdisk-generic.lz4'),
                                          '--device', 'f50', '--linux-slot', 'b',
                                          '--android-subset', str(seg / 'android'), '--out', str(py)] + common,
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)

            pyimg, new = py.read_bytes(), (out / 'new').read_bytes()
            got = leaves(cpio_all(unlz4_legacy(ramdisk_of(new))))
            self.assertEqual(got, leaves(cpio_all(unlz4_legacy(ramdisk_of(pyimg)))))
            self.assertTrue(got['android/vendor/bin/modem_control'][1], 'modem_control is not executable')
            self.assertEqual(got['etc/mu300-device'][2], b'f50\n')

            # the header page: Android's, with this kernel's and ramdisk's sizes and the marker the switch looks for
            ksz, rsz = struct.unpack_from('<II', new, 8)
            self.assertEqual(ksz, (bundle / 'Image').stat().st_size)
            self.assertEqual(rsz, (work / 'dev.lz4').stat().st_size + (bundle / 'ramdisk-generic.lz4').stat().st_size)
            self.assertEqual(new[44:44 + 1536], b'loglevel=5'.ljust(1536, b'\0'))
            self.assertEqual(new[:8] + new[16:4096], pyimg[:8] + pyimg[16:4096])
            self.assertEqual(len(new) % 4096, 0)
            # Android's vbmeta and its footer, with the sizes of this image
            osz, _, vbs = struct.unpack_from('>QQQ', pyimg, len(pyimg) - 64 + 12)
            self.assertEqual((out / 'vbmeta').read_bytes(), pyimg[osz:osz + vbs])
            foot = (out / 'newfooter').read_bytes()
            self.assertEqual(struct.unpack_from('>QQQ', foot, 12), (len(new), len(new), vbs))
            self.assertEqual(foot[:12] + foot[36:], pyimg[-64:-52] + pyimg[-28:])


if __name__ == '__main__':
    unittest.main()
