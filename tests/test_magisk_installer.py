"""android/magisk/installer/mu300-install.sh: the installer a Magisk zip runs on the device. mu300-install.conf is
read, never run; on a fake device (tests/fakedevice.py) it finds the model, the slots, where Linux goes and what is
already there, and a refusal or a dry run writes nothing."""
import hashlib
import io
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
import zipfile
from pathlib import Path

from fakedevice import UBB, FakeDevice
from helpers import TOP, ShellTest
from test_android_boot_image import MAGISKBOOT, fake_android_root
from test_boot_image import HAVE_LZ4

# the zip's mu300/ directory, entry -> source in this repository (None: made per zip). Task 10's zip builder copies
# exactly these; its test compares the two lists.
MU300_FILES = {
    'mu300/install.sh': 'android/magisk/installer/mu300-install.sh',
    'mu300/android-boot-image.sh': 'tools/android-boot-image.sh',
    'mu300/mu300-update': 'rootfs/overlay/opt/mu300/bin/mu300-update',
    'mu300/android-install.sh': 'tools/android-install.sh',
    'mu300/android-mount-mu300root.sh': 'tools/android-mount-mu300root.sh',
    'mu300/storage.sh': 'tools/storage.sh',
    'mu300/i18n.sh': 'tools/i18n.sh',
    'mu300/i18n/tr.tsv': 'i18n/tr.tsv',
    'mu300/i18n/zh.tsv': 'i18n/zh.tsv',
    'mu300/subset-files.txt': 'android-vendor/subset-files.txt',
    'mu300/gpu-files.txt': 'android-vendor/gpu-files.txt',
    'mu300/busybox': None,      # the 5.4 bundle's static busybox; here the fake device's mkpasswd
    'mu300/manifest': None,     # what the zip carries, written by InstallerCase.zip()
}

BUSYBOX = shutil.which('busybox')
INSTALLER_DIR = INSTALLER = None
_staged = None


def stage_mu300(dest):
    """DEST laid out like the zip's mu300/ (without its manifest)"""
    for entry, src in MU300_FILES.items():
        out = dest / entry[len('mu300/'):]
        out.parent.mkdir(parents=True, exist_ok=True)
        if src:
            shutil.copy(TOP / src, out)
    (dest / 'busybox').write_text(UBB)
    (dest / 'busybox').chmod(0o755)


def setUpModule():
    global INSTALLER_DIR, INSTALLER, _staged
    _staged = tempfile.mkdtemp(prefix='mu300-magisk-stage-')
    INSTALLER_DIR = Path(_staged) / 'mu300'
    stage_mu300(INSTALLER_DIR)
    INSTALLER = INSTALLER_DIR / 'install.sh'


def tearDownModule():
    shutil.rmtree(_staged, ignore_errors=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fake_ext4_bytes(label):
    """the start of an ext4 filesystem as sd_existing reads it: the magic and the label"""
    data = bytearray(4096)
    data[1080:1082] = b'\x53\xef'
    data[1144:1144 + len(label)] = label.encode()
    return bytes(data)


def tar_gz(files):
    """{name: bytes} -> a .tar.gz as the release makes them (./ names)"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode='w:gz') as t:
        for name, data in files.items():
            info = tarfile.TarInfo('./' + name)
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    return buf.getvalue()


_generic = {}


def generic_ramdisk():
    """the bundle's ramdisk-generic.lz4, built once from fake modules with build-boot-image.py --generic-ramdisk"""
    if 'data' not in _generic:
        tmp = tempfile.mkdtemp(prefix='mu300-generic-')
        try:
            t = Path(tmp)
            (t / 'mods').mkdir()
            for n in (TOP / 'boot' / 'module-order.txt').read_text().split():
                (t / 'mods' / n).write_bytes(b'\x7fELF base ' + n.encode())
            for f in ('busybox', 'logdw'):
                (t / f).write_bytes(b'\x7fELF ' + f.encode())
            r = subprocess.run([sys.executable, str(TOP / 'boot' / 'build-boot-image.py'), '--generic-ramdisk',
                                '--modules', str(t / 'mods'), '--busybox', str(t / 'busybox'),
                                '--logdw', str(t / 'logdw'),
                                '--ueventd-perms', str(TOP / 'android-vendor' / 'ueventd-perms.sh'),
                                '--out', str(t / 'ramdisk-generic.lz4')], capture_output=True, text=True)
            assert r.returncode == 0, r.stderr
            _generic['data'] = (t / 'ramdisk-generic.lz4').read_bytes()
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
    return _generic['data']


ROOTFS_ASSET = {'openwrt': 'mu300-openwrt-rootfs.tar.gz', 'ubuntu-24.04': 'mu300-ubuntu-rootfs.tar.gz',
                'ubuntu-26.04': 'mu300-ubuntu-26.04-rootfs.tar.gz'}


class Conf(ShellTest):
    def load(self, shell, text):
        f = self.tmp / 'mu300-install.conf'
        f.write_bytes(text.encode())
        # the installer sets -u: a key the file does not give stays unset
        return self.sh(shell, f'MU300_LIB=1 MU300_DIR="{INSTALLER_DIR}" . "{INSTALLER}"; conf_load "{f}"; '
                              'echo "S=${MU300_STORAGE:-} E=${MU300_SD_ERASE:-} B=${MU300_BOOT:-} P=${MU300_PASSWORD:-}"')

    def test_values_quotes_crlf_comments(self):
        for shell in self.each_shell():
            r = self.load(shell, '# a comment\r\nMU300_STORAGE=sd\r\nMU300_SD_ERASE="yes"\n  MU300_BOOT = android\n'
                                 "MU300_PASSWORD='p a$s'\n")
            self.assertIn("S=sd E=yes B=android P=p a$s", r.stdout)

    def test_unknown_keys_are_reported_not_set(self):
        for shell in self.each_shell():
            r = self.load(shell, 'PATH=/nowhere\nMU300_STORAGE=internal\n')
            self.assertIn('S=internal', r.stdout)
            self.assertIn('PATH', r.stdout + r.stderr)   # reported
            self.assertNotEqual(r.returncode, 127)       # PATH was not replaced

    def test_conf_is_never_executed(self):
        for shell in self.each_shell():
            r = self.load(shell, f'MU300_BOOT=$(touch {self.tmp}/ran)\nMU300_STORAGE=`touch {self.tmp}/ran2`\n')
            self.assertFalse((self.tmp / 'ran').exists())
            self.assertFalse((self.tmp / 'ran2').exists())

    def test_check_refuses_bad_values(self):
        for shell in self.each_shell():
            for bad in ('MU300_STORAGE=usb', 'MU300_BOOT_ATTEMPTS=9', 'MU300_PASSWORD=short', 'MU300_MODE=maybe'):
                f = self.tmp / 'c.conf'; f.write_text(bad + '\n')
                r = self.sh(shell, f'MU300_LIB=1 MU300_DIR="{INSTALLER_DIR}" . "{INSTALLER}"; conf_load "{f}"; conf_check')
                self.assertNotEqual(r.returncode, 0, bad)


@unittest.skipIf(not BUSYBOX, 'no busybox (the installer runs under Magisk\'s busybox)')
@unittest.skipIf(not HAVE_LZ4, 'neither the lz4 command nor the lz4 Python module is installed')
class InstallerCase(ShellTest):
    """a zip (mu300/ beside a real zip of payload/) and a FakeDevice; run_installer() runs install.sh as Magisk's
    busybox would"""

    def setUp(self):
        super().setUp()
        self.stub('magiskboot', MAGISKBOOT)
        self.reset()

    def reset(self):
        self.zip()
        self.device()

    def device(self, **kw):
        shutil.rmtree(self.tmp / 'fake', ignore_errors=True)
        self.fake = FakeDevice(self.tmp, self.stubs, **kw)
        fake_android_root(self.fake.root / 'android')
        (self.fake.root / 'magisk/busybox').symlink_to(BUSYBOX)

    def zip(self, system='openwrt', kernel='6.18', features=('sdcard',), devices='f50 u30air', corrupt=False):
        """mu300/ with its manifest, and the zip with the payload of SYSTEM and KERNEL"""
        self.mu300 = self.tmp / 'zip' / 'mu300'
        shutil.rmtree(self.tmp / 'zip', ignore_errors=True)
        shutil.copytree(INSTALLER_DIR, self.mu300, symlinks=True)
        self.zip_args = dict(system=system, kernel=kernel, features=features, devices=devices)
        self.kernel_release = f'{kernel}.0-mu300' if kernel != '5.4' else '5.4.254-mu300'
        kasset = 'mu300-kernel.tar.gz' if kernel == '5.4' else f'mu300-kernel-{kernel}.tar.gz'
        rasset = ROOTFS_ASSET[system]
        os_, _, ubuntu = system.partition('-')
        kb = tar_gz({'Image': b'\x7fkernel' * 1000, 'ramdisk-generic.lz4': generic_ramdisk(),
                     'modules/mu300-test.ko': b'\x7fELF test module', 'kernel.release': (self.kernel_release + '\n').encode(),
                     'devices': (devices + '\n').encode(), 'features': ''.join(f + '\n' for f in features).encode()})
        rootfs = tar_gz({'etc/os-release': f'ID={os_}\n'.encode()})
        (self.mu300 / 'manifest').write_text(
            f'TAG=v2026.10.06\nSYSTEM={system}\nOS={os_}\nUBUNTU={ubuntu}\nKERNEL={kernel}\nKERNEL_ASSET={kasset}\n'
            f'ROOTFS_ASSET={rasset}\nSHA256_KERNEL={hashlib.sha256(kb).hexdigest()}\n'
            f'SHA256_ROOTFS={hashlib.sha256(rootfs).hexdigest()}\n')
        self.zipfile = self.tmp / 'zip' / 'mu300-magisk.zip'
        with zipfile.ZipFile(self.zipfile, 'w') as z:
            z.writestr(f'payload/{kasset}', kb, compress_type=zipfile.ZIP_STORED)
            z.writestr(f'payload/{rasset}', rootfs + (b'x' if corrupt else b''), compress_type=zipfile.ZIP_STORED)

    def corrupt_payload(self):
        self.zip(**self.zip_args, corrupt=True)

    def existing_filesystem(self, systems=('ubuntu',), ubuntu=None):
        """an installed mu300root in the free eMMC region holding SYSTEMS (and Ubuntu's release)"""
        last_end = 2048 + (8 << 21)
        start = (last_end // 4096 + 1) * 4096
        end = (((16 << 21) - 34) // 4096 - 1) * 4096
        off = start * 512
        with open(self.fake.root / 'dev/block/mmcblk0', 'r+b') as f:
            f.truncate(16 << 30)
            f.seek(off + 1028); f.write(((end - start) * 512 // 4096).to_bytes(4, 'little'))
            f.seek(off + 1080); f.write(b'\x53\xef')
            f.seek(off + 1144); f.write(b'mu300root')
        if ubuntu and 'ubuntu' not in systems:
            systems = tuple(systems) + ('ubuntu',)
        for s in systems:
            (self.fake.root / 'fs' / s / 'etc').mkdir(parents=True, exist_ok=True)
        if ubuntu:
            rel = self.fake.root / 'fs/ubuntu/usr/lib/os-release'
            rel.parent.mkdir(parents=True, exist_ok=True)
            rel.write_text(f'NAME="Ubuntu"\nVERSION_ID="{ubuntu}"\n')

    def snapshot(self):
        r = self.fake.root
        snap = {n: sha(r / 'dev/block/by-name' / n) for n in ('boot_a', 'boot_b', 'misc')}
        for d in ('mmcblk0', 'mmcblk1'):
            p = r / 'dev/block' / d
            if p.exists():
                st = p.stat()
                snap[d] = (st.st_size, st.st_mtime_ns)
        return snap

    def nothing_written(self):
        return self.snapshot() == self.before and not (self.fake.root / 'tmp/mu300-magisk').exists()

    def run_installer(self, conf=None, extra_env=None):
        c = self.fake.root / 'sdcard/mu300-install.conf'
        if conf is None:
            c.unlink(missing_ok=True)
        else:
            c.write_text(conf)
        self.before = self.snapshot()
        env = self.fake.env(self.mu300, self.stubs / 'magiskboot')
        env['ZIPFILE'] = self.zipfile
        env.update(extra_env or {})
        return subprocess.run([BUSYBOX, 'sh', str(self.mu300 / 'install.sh')], capture_output=True, text=True,
                              env=self.env(**env), timeout=120)


class Plan(InstallerCase):
    def test_defaults_internal_region(self):
        r = self.run_installer(conf='MU300_DRY_RUN=1\n')
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn('internal', r.stdout)
        self.assertTrue(self.nothing_written())

    def test_card_with_mu300sd_is_the_default(self):
        self.device(card=fake_ext4_bytes('mu300sd'))
        r = self.run_installer(conf='MU300_DRY_RUN=1\n')
        self.assertEqual(r.returncode, 3, r.stdout + r.stderr)
        self.assertIn('/mmcblk1', r.stdout)

    def test_internal_while_a_mu300sd_card_is_in_the_slot_is_refused(self):
        # boot/init starts the card first: an internal installation would never start, and nobody can type the word
        self.device(card=fake_ext4_bytes('mu300sd'))
        r = self.run_installer(conf='MU300_STORAGE=internal\nMU300_DRY_RUN=1\n')
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn('mu300sd', r.stdout)
        self.assertIn('MU300_STORAGE=sd', r.stdout)      # the way out is named
        self.assertTrue(self.nothing_written())

    def test_card_is_never_erased_without_consent(self):
        self.device(card=bytes(1 << 20), region=False)
        r = self.run_installer(conf='MU300_STORAGE=sd\n')
        self.assertEqual(r.returncode, 1)
        self.assertIn('MU300_SD_ERASE=yes', r.stdout)
        self.assertTrue(self.nothing_written())

    def test_foreign_ext4_card_is_refused_even_with_consent(self):
        self.device(card=fake_ext4_bytes('photos'))
        r = self.run_installer(conf='MU300_STORAGE=sd\nMU300_SD_ERASE=yes\n')
        self.assertEqual(r.returncode, 1)
        self.assertIn('mu300sd', r.stdout)
        self.assertTrue(self.nothing_written())

    def test_card_with_a_kernel_that_cannot_read_it(self):
        self.device(card=fake_ext4_bytes('mu300sd'))
        self.zip(features=())
        r = self.run_installer(conf='MU300_DRY_RUN=1\n')
        self.assertEqual(r.returncode, 1)
        self.assertIn('SD card', r.stdout)
        self.assertTrue(self.nothing_written())

    def test_no_room_no_card(self):
        self.device(region=False)
        r = self.run_installer()
        self.assertEqual(r.returncode, 1)
        self.assertIn('MU300_STORAGE=sd', r.stdout)      # the way out is named
        self.assertTrue(self.nothing_written())

    def test_unknown_model(self):
        self.device(model='Pixel 7')
        self.assertEqual(self.run_installer().returncode, 1)
        self.assertEqual(self.run_installer(conf='MU300_DEVICE=f50\nMU300_DRY_RUN=1\n').returncode, 3)

    def test_android_on_slot_b_puts_linux_on_a(self):
        self.device(slot='_b')
        r = self.run_installer(conf='MU300_DRY_RUN=1\n')
        self.assertEqual(r.returncode, 3)
        self.assertIn('boot_a', r.stdout)

    def test_corrupt_payload(self):
        self.corrupt_payload()
        self.assertEqual(self.run_installer().returncode, 1)
        self.assertTrue(self.nothing_written())

    def test_ubuntu_2604_and_a_54_zip(self):
        self.existing_filesystem(ubuntu='26.04')
        self.zip(kernel='5.4', system='openwrt')
        r = self.run_installer()
        self.assertEqual(r.returncode, 1)
        self.assertIn('26.04', r.stdout)

    def test_example_conf_written(self):
        self.run_installer(conf='MU300_DRY_RUN=1\n')
        ex = (self.fake.root / 'sdcard/mu300-install.conf.example').read_text()
        for k in ('MU300_STORAGE', 'MU300_SD_ERASE', 'MU300_BOOT', 'MU300_PASSWORD', 'MU300_DRY_RUN'):
            self.assertIn(k, ex)


if __name__ == '__main__':
    unittest.main()
