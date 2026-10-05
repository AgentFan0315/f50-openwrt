# MU300 Linux installer zip. Magisk sources this file into its own installer shell, so it changes none of that
# shell's options and never exits: the installation runs as a child process (mu300/install.sh) under Magisk's
# busybox, and its exit status decides - 0 installed, 3 dry run, anything else not installed. Only after success
# does this zip become the "MU300 Linux" switch module (Action button, su -c mu300-linux). The three messages here
# stay English: they are shown before the installer knows the language.
SKIPUNZIP=1
if ! $BOOTMODE; then
    abort "! Install this zip in the Magisk app or with: magisk --install-module <zip> (not from recovery)"
fi
[ "${MAGISK_VER_CODE:-0}" -ge 26000 ] || abort "! This zip needs Magisk 26.0 or newer"
mu300_dir=$TMPDIR/mu300
rm -rf "$mu300_dir"
unzip -o -q "$ZIPFILE" 'mu300/*' -d "$TMPDIR" >&2 || abort "! The zip could not be unpacked"
MU300_DIR=$mu300_dir ZIPFILE=$ZIPFILE MAGISKBIN=${MAGISKBIN:-/data/adb/magisk} \
    "${MAGISKBIN:-/data/adb/magisk}/busybox" sh "$mu300_dir/install.sh"
mu300_rc=$?
rm -rf "$mu300_dir"
case $mu300_rc in
    0) ;;
    3) abort "- Dry run: nothing was written, the module was not installed" ;;
    *) abort "! MU300 Linux was not installed; the messages above say why and what was not changed" ;;
esac
unzip -o -q "$ZIPFILE" module.prop action.sh switch.sh 'system/*' -d "$MODPATH" >&2 || abort "! The switch module could not be installed"
set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/switch.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/system/bin/mu300-linux" 0 0 0755
unset mu300_dir mu300_rc
