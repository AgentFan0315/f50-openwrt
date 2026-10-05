#!/system/bin/sh
# MU300 Linux from a Magisk zip: the whole installation, on the device, with no computer. customize.sh runs this as
# a child of Magisk's busybox (nothing here can change Magisk's own shell) and turns its exit status into the
# result: 0 installed, 3 dry run (nothing written), anything else refused or failed - the messages say what was and
# was not written.
#
# Everything device-specific - the header and AVB data of Android's boot image, the misc block, the firmware and the
# Android files - is read from this device here; the zip carries none of it. Nothing is written to the eMMC or the
# card before the systems are installed, and misc is armed last.
#
# MU300_LIB=1 defines the functions and runs nothing (tests/, which also set MU300_DIR to a directory laid out like
# the zip's mu300/). The MU300_* paths below point at a fake device there.
set -eu
D=${MU300_DIR:-$(cd "$(dirname "$0")" && pwd)}
# mu300-update first: it defines a say and a die of its own, which the ones below replace. MU300_LIB=1 while it is
# read makes it define its functions only; the caller's value comes back afterwards.
_mu300_lib=${MU300_LIB:-}
MU300_LIB=1
. "$D/mu300-update"
. "$D/android-boot-image.sh"
MU300_LIB=$_mu300_lib
TOP=$D                                   # i18n.sh reads $TOP/i18n
BY=${MU300_BY_NAME:-/dev/block/by-name}
SDCARD=${MU300_SDCARD:-/sdcard}
T=${MU300_TMP:-/data/local/tmp}
W=$T/mu300-magisk
MAGISKBIN=${MAGISKBIN:-/data/adb/magisk}
MAGISKBOOT=${MAGISKBOOT:-$MAGISKBIN/magiskboot}
UBB=${MU300_UBB:-$D/busybox}             # the release's static busybox: its mkpasswd
DEVSH=${MU300_DEVICE_SH:-/system/bin/sh}
ANDROID_SH=${MU300_ANDROID_SH:-/system/bin/sh}
APATH=${MU300_ANDROID_PATH:-/system/bin:/system/xbin:/vendor/bin}
NEED_OPENWRT=$((800 * 1024 * 1024)); NEED_UBUNTU=$((1600 * 1024 * 1024)); NEED_BOTH=$((2400 * 1024 * 1024))
MU300_LANG=${MU300_LANG:-}
. "$D/i18n.sh"
. "$D/storage.sh"

say() { echo "- $*"; }
warn() { echo "! $*"; }
die() { echo "! $*"; exit 1; }
gib() { awk -v b="$1" 'BEGIN { printf "%.1f GiB", b / 1073741824 }'; }
# Android's own shell and toolbox, never Magisk's standalone busybox: its mke2fs makes ext2 only and its losetup has
# no -S. su -c sh gives install.sh exactly this environment.
asw() { env -u ASH_STANDALONE PATH="$APATH" "$@"; }
su_do() { asw "$DEVSH" -c "$1"; }            # storage.sh's way to run a command on the device: here it is local

android_lang() {  # the language of the Android locale: tr, zh or en
    _l=
    for _p in persist.sys.locale persist.sys.locales persist.sys.language ro.product.locale ro.product.locale.language; do
        _l=$(getprop "$_p" 2>/dev/null) && [ -n "$_l" ] && break
    done
    case ${_l%%,*} in tr|tr-*|tr_*) echo tr ;; zh|zh-*|zh_*) echo zh ;; *) echo en ;; esac
}

# ---- answers: mu300-install.conf, read line by line, never sourced (it is a text file anyone with storage access
# can write, and this runs as root). Only these keys are taken.
CONF_KEYS='MU300_STORAGE MU300_SD_ERASE MU300_REGION_OVERWRITE MU300_MODE MU300_BOOT_OS MU300_BOOT MU300_BOOT_ATTEMPTS MU300_HOTSPOT MU300_GPU MU300_PASSWORD MU300_DEVICE MU300_LANG MU300_DRY_RUN'
CONF_FILE=; CONF_SET=
conf_find() { for _f in "$SDCARD/mu300-install.conf" "$SDCARD/Download/mu300-install.conf"; do [ -f "$_f" ] && { echo "$_f"; return 0; }; done; return 0; }
conf_load() {
    [ -n "$1" ] && [ -f "$1" ] || return 0
    CONF_FILE=$1
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line=$(printf '%s' "$_line" | tr -d '\r' | sed 's/^[[:space:]]*//')
        case $_line in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
        _k=$(printf '%s' "${_line%%=*}" | tr -d ' \t'); _v=${_line#*=}
        _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $_v in \"*\") _v=${_v#\"}; _v=${_v%\"} ;; \'*\') _v=${_v#\'}; _v=${_v%\'} ;; esac
        case " $CONF_KEYS " in
            *" $_k "*) eval "$_k=\$_v"; CONF_SET="$CONF_SET $_k" ;;    # $_k is one of CONF_KEYS: the eval is safe
            *) warn "$(t 'mu300-install.conf: {1} is not a setting of this installer; ignored' "$_k")" ;;
        esac
    done < "$1"
}
conf_check() {  # every answer has a value this installer knows, or it stops before anything happens
    _bad() { die "$(t 'mu300-install.conf: {1}={2} is not valid' "$1" "$2")"; }
    case ${MU300_STORAGE:-} in ''|internal|sd) ;; *) _bad MU300_STORAGE "$MU300_STORAGE" ;; esac
    case ${MU300_MODE:-} in ''|update|wipe) ;; *) _bad MU300_MODE "$MU300_MODE" ;; esac
    case ${MU300_BOOT_OS:-} in ''|ubuntu|openwrt) ;; *) _bad MU300_BOOT_OS "$MU300_BOOT_OS" ;; esac
    case ${MU300_BOOT:-} in ''|linux|android) ;; *) _bad MU300_BOOT "$MU300_BOOT" ;; esac
    case ${MU300_BOOT_ATTEMPTS:-} in ''|[1-6]) ;; *) _bad MU300_BOOT_ATTEMPTS "$MU300_BOOT_ATTEMPTS" ;; esac
    for _k in MU300_SD_ERASE MU300_REGION_OVERWRITE; do
        eval "_v=\${$_k:-}"; case $_v in ''|yes) ;; *) _bad "$_k" "$_v" ;; esac
    done
    for _k in MU300_HOTSPOT MU300_GPU; do
        eval "_v=\${$_k:-}"; case $_v in ''|yes|no) ;; *) _bad "$_k" "$_v" ;; esac
    done
    case ${MU300_DEVICE:-} in ''|f50|u30air) ;; *) _bad MU300_DEVICE "$MU300_DEVICE" ;; esac
    case ${MU300_LANG:-} in ''|en|tr|zh) ;; *) _bad MU300_LANG "$MU300_LANG" ;; esac
    case ${MU300_DRY_RUN:-} in ''|1) ;; *) _bad MU300_DRY_RUN "$MU300_DRY_RUN" ;; esac
    if [ -n "${MU300_PASSWORD:-}" ] && [ ${#MU300_PASSWORD} -lt 6 ]; then
        die "$(t 'mu300-install.conf: MU300_PASSWORD must have at least 6 characters')"
    fi
}
src_of() { case " $CONF_SET " in *" $1 "*) t 'mu300-install.conf' ;; *) t 'default' ;; esac; }   # where a value came from

# ---- the device, its slots and the zip
env_check() {
    [ -n "${MU300_SKIP_ROOT_CHECK:-}" ] || [ "$(id -u)" = 0 ] || die "$(t 'this installer needs root')"
    [ -x "$MAGISKBOOT" ] || die "$(t "Magisk's magiskboot was not found; install this zip with Magisk 26 or newer")"
    chmod 755 "$UBB" 2>/dev/null || true
}
detect_device() {
    _m="$(getprop ro.product.model) / $(getprop ro.product.device)"
    say "$(t 'device: {1}' "$_m")"
    case $_m in
        *U30Air*|*U30_Air*|*"U30 Air"*) DEVICE=u30air ;;
        *MU300*|*F50*|*mu300*) DEVICE=f50 ;;
        *) DEVICE= ;;
    esac
    [ -z "${MU300_DEVICE:-}" ] || DEVICE=$MU300_DEVICE
    [ -n "$DEVICE" ] || die "$(t 'This does not look like a ZTE F50/MU300 or U30 Air. If it is one, set MU300_DEVICE=f50 or u30air in mu300-install.conf.')"
}
hex_at() { dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -tx1 -v | tr -d ' \n'; }
slot_setup() {
    case $(getprop ro.boot.slot_suffix) in
        _a) ANDROID_SLOT=a; LINUX_SLOT=b ;;
        _b) ANDROID_SLOT=b; LINUX_SLOT=a ;;
        *) die "$(t 'cannot tell which slot Android runs from')" ;;
    esac
    MISC=$BY/misc; BOOT_ANDROID=$BY/boot_$ANDROID_SLOT; BOOT_LINUX=$BY/boot_$LINUX_SLOT
    [ -e "$MISC" ] && [ -e "$BOOT_ANDROID" ] && [ -e "$BOOT_LINUX" ] || die "$(t 'this is not an A/B device with misc, boot_a and boot_b')"
    # never the partition Android booted from, whatever the links say
    [ "$(readlink -f "$BOOT_ANDROID")" != "$(readlink -f "$BOOT_LINUX")" ] || die "$(t 'boot_a and boot_b are the same partition')"
    LIVE_BC=$(hex_at "$MISC" 2048 32)
    bc_valid "$LIVE_BC" || die "$(t 'misc holds no valid boot control block; nothing was changed')"
    say "$(t 'Android runs from slot {1}; Linux goes to slot {2} (boot_{2})' "$ANDROID_SLOT" "$LINUX_SLOT")"
}
manifest_load() {  # the zip's manifest, read like the conf file: only these keys
    while IFS='=' read -r _k _v; do
        case $_k in TAG|SYSTEM|OS|UBUNTU|KERNEL|KERNEL_ASSET|ROOTFS_ASSET|SHA256_KERNEL|SHA256_ROOTFS) eval "$_k=\$_v" ;; esac
    done < "$1"
    [ -n "${OS:-}" ] && [ -n "${KERNEL:-}" ] && [ -n "${SHA256_ROOTFS:-}" ] || die "$(t 'the zip is incomplete (no manifest)')"
    OSES=$OS
}
payload_unpack() {  # the two payload files out of the zip, checked against the manifest before anything uses them
    _need=$(( $(unzip -l "$ZIPFILE" "payload/*" | awk 'END { print $1 }') + 512 * 1048576 ))
    # -P: one line per filesystem (busybox puts a long device name on a line of its own)
    _free=$(( $(df -Pk "$T" | awk 'NR == 2 { print $4 }') * 1024 ))
    [ "$_free" -ge "$_need" ] || die "$(t 'not enough free space in {1}: {2} needed, {3} free' "$T" "$(gib "$_need")" "$(gib "$_free")")"
    rm -rf "$W"; mkdir -p "$W/kernel"
    say "$(t 'Unpacking {1} and {2}' "$ROOTFS_ASSET" "$KERNEL_ASSET")"
    unzip -p "$ZIPFILE" "payload/$ROOTFS_ASSET" > "$T/mu300-$OS.tar.gz" &&
        unzip -p "$ZIPFILE" "payload/$KERNEL_ASSET" > "$W/kernel.tar.gz" || die "$(t 'could not unpack the zip')"
    [ "$(sha256sum "$T/mu300-$OS.tar.gz" | cut -d' ' -f1)" = "$SHA256_ROOTFS" ] &&
        [ "$(sha256sum "$W/kernel.tar.gz" | cut -d' ' -f1)" = "$SHA256_KERNEL" ] ||
        die "$(t 'the zip is damaged (checksum mismatch); download it again')"
    tar -xzf "$W/kernel.tar.gz" -C "$W/kernel" && rm -f "$W/kernel.tar.gz" || die "$(t 'could not unpack the kernel bundle')"
    KB=$W/kernel
    grep -qw "$DEVICE" "$KB/devices" 2>/dev/null || die "$(t 'this kernel does not support the {1}' "$DEVICE")"
}
cleanup() {  # every exit: the staging directory holds this device's proprietary files
    [ -n "${MOUNTED:-}" ] && umount_target "$MOUNTED" >/dev/null 2>&1
    rm -rf "$W" "$T/mu300-${OS:-none}.tar.gz" "$T/mu300-vendor-${OS:-none}.tar.gz" "$T/mu300-install.env" 2>/dev/null
    rm -rf "$T/mu300root-magisk" "$T/android-mount-mu300root.sh" 2>/dev/null
}

# ---- what to do
mount_target() {  # mount_target DIR: the Linux filesystem of the plan, with Android's mount helper
    cp "$D/android-mount-mu300root.sh" "$T/" || return 1
    if [ "$SD_MODE" = 1 ]; then
        asw MU300_SD_DEV="$SD_DEV" "$ANDROID_SH" "$T/android-mount-mu300root.sh" "$1"
    else
        asw MU300_OFF="$INT_OFF" MU300_SIZE="$INT_SIZE" "$ANDROID_SH" "$T/android-mount-mu300root.sh" "$1"
    fi | grep -q '^MOUNTED' && MOUNTED=$1
}
umount_target() { asw "$ANDROID_SH" "$T/android-mount-mu300root.sh" -u "$1" >/dev/null; MOUNTED=; }
need_for() { case $1 in openwrt) echo $NEED_OPENWRT ;; ubuntu) echo $NEED_UBUNTU ;; *) echo $NEED_BOTH ;; esac; }
plan_storage() {
    region_probe || die "$(t 'could not read the partition table')"
    region_find_existing
    INT_OFF=$OFF; INT_SIZE=$SIZE; int_existing=$existing
    sd_probe; sd_ex=no
    [ -n "$SD_DEV" ] && sd_ex=$(sd_existing)
    case ${MU300_STORAGE:-} in
        sd) [ -n "$SD_DEV" ] || die "$(t 'MU300_STORAGE=sd, but there is no usable SD card in the device')"; SD_MODE=1 ;;
        internal)
            # boot/init starts a mu300sd card before anything on the eMMC, and nobody is here to type the word
            # storage.sh's internal_over_card asks for: an installation inside would never start
            [ "$sd_ex" != yes ] || die "$(t 'The SD card ({1}) holds a Linux installation (mu300sd), and the device always starts that one first: an installation to internal storage does not start while this card is in the slot.' "$SD_DEV")
$(t 'Take the card out and install the zip again, or install to the card (MU300_STORAGE=sd in /sdcard/mu300-install.conf).')"
            SD_MODE=0 ;;
        *)  # an installation where it is (the card first, as init looks there first), else inside when it fits
            if [ "$sd_ex" = yes ]; then SD_MODE=1
            elif [ "$int_existing" = yes ] || [ "$INT_SIZE" -ge "$(need_for "$OS")" ]; then SD_MODE=0
            elif [ -n "$SD_DEV" ]; then
                die "$(t 'There is too little free space inside for Linux. The SD card ({1}, {2}) can hold it: put MU300_STORAGE=sd and MU300_SD_ERASE=yes into /sdcard/mu300-install.conf (everything on the card is erased).' "$SD_DEV" "$(gib "$SD_BYTES")")"
            else
                die "$(t 'There is too little free space inside for Linux and no SD card. Insert a card (MU300_STORAGE=sd, MU300_SD_ERASE=yes in /sdcard/mu300-install.conf), or make room with the installer for computers.')"
            fi ;;
    esac
    if [ "$SD_MODE" = 1 ]; then
        sd_not_foreign
        existing=$([ "$sd_ex" = yes ] && echo yes || echo no); TARGET_SIZE=$SD_BYTES
        if [ "$existing" = no ] && [ "${MU300_SD_ERASE:-}" != yes ]; then
            die "$(t 'Installing to the SD card ({1}, {2}) erases everything on it. To allow that, put MU300_SD_ERASE=yes into /sdcard/mu300-install.conf.' "$SD_DEV" "$(gib "$SD_BYTES")")"
        fi
    else
        existing=$int_existing; TARGET_SIZE=$INT_SIZE; DIRTY=0
        [ "$INT_SIZE" -ge $((700 * 1024 * 1024)) ] || die "$(t 'There is too little free space inside for Linux and no SD card. Insert a card (MU300_STORAGE=sd, MU300_SD_ERASE=yes in /sdcard/mu300-install.conf), or make room with the installer for computers.')"
        if [ "$existing" = no ]; then
            region_dirty
            [ "$DIRTY" = 0 ] || [ "${MU300_REGION_OVERWRITE:-}" = yes ] ||
                die "$(t 'The free space behind the partitions is not empty ({1} of 16 samples hold data); it may be used by this firmware. To use it anyway, put MU300_REGION_OVERWRITE=yes into /sdcard/mu300-install.conf.' "$DIRTY")"
        fi
    fi
    INTERNAL_EXISTS=0; [ "$int_existing" = yes ] && INTERNAL_EXISTS=1
    FORMAT=0; UPDATE=0
    if [ "$existing" = yes ]; then
        case ${MU300_MODE:-update} in update) UPDATE=1 ;; wipe) FORMAT=1 ;; esac
    else
        FORMAT=1
    fi
}
inspect_target() {  # which systems the existing filesystem holds, and its Ubuntu release
    HAVE_SYSTEMS=; HAVE_UBUNTU=
    [ "$existing" = yes ] && [ "$FORMAT" = 0 ] || return 0
    mount_target "$T/mu300root-magisk" || die "$(t 'could not mount the existing Linux filesystem')"
    for _os in ubuntu openwrt; do [ -d "$T/mu300root-magisk/$_os" ] && HAVE_SYSTEMS="$HAVE_SYSTEMS $_os"; done
    HAVE_UBUNTU=$(sed -n 's/^VERSION_ID="\(.*\)"/\1/p' "$T/mu300root-magisk/ubuntu/usr/lib/os-release" 2>/dev/null | head -n1)
    umount_target "$T/mu300root-magisk"
}
plan_choices() {
    _after=$(printf '%s\n' $HAVE_SYSTEMS "$OS" | sort -u | tr '\n' ' ')
    case $_after in *ubuntu*openwrt*|*openwrt*ubuntu*) _need=$NEED_BOTH ;; *) _need=$(need_for "$OS") ;; esac
    [ "$TARGET_SIZE" -ge "$_need" ] || die "$(t 'that choice needs about {1} MiB and this device has {2} MiB of free space' "$((_need / 1048576))" "$((TARGET_SIZE / 1048576))")"
    if [ "$KERNEL" = 5.4 ] && case " $HAVE_SYSTEMS " in *" ubuntu "*) [ "$HAVE_UBUNTU" = 26.04 ] ;; *) false ;; esac; then
        die "$(t 'Ubuntu 26.04 is installed, and it needs a mainline kernel (6.18 or 7.2): use a zip with one of those kernels, or MU300_MODE=wipe.')"
    fi
    sd_kernel_ok "$KB" || die "$(t 'this kernel cannot read the SD card; use a newer zip')"
    BOOT_OS=${MU300_BOOT_OS:-$OS}
    case " $_after " in *" $BOOT_OS "*) ;; *) die "$(t 'MU300_BOOT_OS={1}, but {1} is not installed' "$BOOT_OS")" ;; esac
    DEFAULT_LINUX=1; [ "${MU300_BOOT:-linux}" = android ] && DEFAULT_LINUX=0
    BOOT_ATTEMPTS=${MU300_BOOT_ATTEMPTS:-5}
    IMPORT_HOTSPOT=1; [ "${MU300_HOTSPOT:-yes}" = no ] && IMPORT_HOTSPOT=0
    GPU=${MU300_GPU:-yes}
    # an if, not an && list: the last command's status is the function's, and set -e would stop main on it
    WIPE_LEGACY=0; if [ "$OS" = ubuntu ] && [ "$FORMAT" = 0 ]; then WIPE_LEGACY=1; fi
}
plan_print() {
    echo
    say "$(t 'Plan')"
    echo "  $(t 'system:         {1} (zip {2}, kernel {3})' "$OS${UBUNTU:+ $UBUNTU}" "$TAG" "$KERNEL")"
    if [ "$SD_MODE" = 1 ]; then
        echo "  $(t 'storage:        SD card {1}, {2} ({3})' "$SD_DEV" "$(gib "$TARGET_SIZE")" "$(src_of MU300_STORAGE)")"
    else
        echo "  $(t 'storage:        internal, offset {1}, {2} ({3})' "$INT_OFF" "$(gib "$TARGET_SIZE")" "$(src_of MU300_STORAGE)")"
    fi
    echo "  $(t 'filesystem:     {1}' "$([ "$FORMAT" = 1 ] && t 'CREATE new ext4 (erases what is there)' || t 'keep: settings and data of {1} are kept' "$OS")")"
    [ -z "$HAVE_SYSTEMS" ] || echo "  $(t 'already there:  {1}' "$HAVE_SYSTEMS")"
    echo "  $(t 'boots:          {1} ({2})' "$BOOT_OS" "$(src_of MU300_BOOT_OS)")"
    echo "  $(t 'default boot:   {1}' "$([ "$DEFAULT_LINUX" = 1 ] && t 'Linux (Android after {1} failed boots in a row)' "$BOOT_ATTEMPTS" || t 'Android, Linux on demand')")"
    echo "  $(t 'writes:         {1}, boot_{2}, 32 bytes of misc (boot_{3}, the partition table and userdata are not touched)' "$([ "$SD_MODE" = 1 ] && echo "$SD_DEV" || t 'the Linux region')" "$LINUX_SLOT" "$ANDROID_SLOT")"
}
write_example() {  # every setting, what it does and the value this run uses: nobody has to type it from a README
    {
        echo "# MU300 Linux Magisk installer settings. Copy to $SDCARD/mu300-install.conf, edit, install the zip again."
        echo "# Values of the last run ($TAG, $(date '+%Y-%m-%d %H:%M')) are shown; a line starting with # is not used."
        echo "#MU300_STORAGE=$([ "${SD_MODE:-0}" = 1 ] && echo sd || echo internal)        # internal or sd"
        echo "#MU300_SD_ERASE=yes            # allow erasing the SD card for Linux"
        echo "#MU300_REGION_OVERWRITE=yes    # use internal free space that holds data"
        echo "#MU300_MODE=update             # update (keep settings and data) or wipe"
        echo "#MU300_BOOT_OS=${BOOT_OS:-$OS}           # ubuntu or openwrt: which system boots"
        echo "#MU300_BOOT=linux              # linux (default boot, Android after failed boots) or android"
        echo "#MU300_BOOT_ATTEMPTS=${BOOT_ATTEMPTS:-5}          # 1-6 failed boots in a row before Android"
        echo "#MU300_HOTSPOT=yes             # copy Android's hotspot name and password"
        echo "#MU300_GPU=yes                 # Mali GPU (OpenCL) files"
        echo "#MU300_PASSWORD=               # 6+ characters; empty: generated"
        echo "#MU300_DEVICE=${DEVICE:-f50}              # f50 or u30air, only when the model is not recognised"
        echo "#MU300_LANG=${MU300_LANG:-en}                # en, tr or zh"
        echo "#MU300_DRY_RUN=1               # only show what would be done"
    } > "$SDCARD/mu300-install.conf.example" 2>/dev/null || true
}

main() {
    conf_load "$(conf_find)"
    conf_check
    [ -n "$MU300_LANG" ] || MU300_LANG=$(android_lang)
    echo "MU300 Linux $(sed -n 's/^TAG=//p' "$D/manifest")"
    [ -z "$CONF_FILE" ] || say "$(t 'settings from {1}:{2}' "$CONF_FILE" "$CONF_SET")"
    env_check
    manifest_load "$D/manifest"
    detect_device
    slot_setup
    trap cleanup EXIT
    payload_unpack
    plan_storage
    inspect_target
    plan_choices
    plan_print
    write_example
    if [ "${MU300_DRY_RUN:-}" = 1 ]; then say "$(t 'Dry run: nothing was written.')"; exit 3; fi
}
[ -z "${MU300_LIB:-}" ] || return 0
main "$@"
