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
# This runs as root. Everything it checks and then uses lives in one directory only root can write (W, made under
# /data/adb): /data/local/tmp belongs to the shell user and /sdcard to every app with storage access, so a file
# there can be replaced between the check and the use. A settings file on /sdcard is read, but it can only choose
# what destroys nothing (see conf_load).
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
WORK_PARENT=${MU300_WORK_PARENT:-/data/adb}
W=                                       # the work directory, made by work_setup
MOUNTS=${MU300_MOUNTS:-/proc/mounts}
# the settings file that may also erase and set the password: only root can write /data/adb
TRUSTED_CONF=${MU300_TRUSTED_CONF:-/data/adb/mu300-install.conf}
# where the password is written (mode 600): root's file, or the shared storage only when a trusted conf says
# MU300_PASSWORD_FILE=sdcard (any app with storage access can read it there)
PW_FILE_ROOT=${MU300_PW_DIR:-/data/adb}/mu300-linux-password.txt
PW_FILE_SDCARD=$SDCARD/mu300-linux-password.txt
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
# no -S. su -c sh gives install.sh exactly this environment. MU300_WORK tells android-install.sh where its files are.
asw() { env -u ASH_STANDALONE PATH="$APATH" MU300_WORK="${W:-}" "$@"; }
su_do() { asw "$DEVSH" -c "$1"; }            # storage.sh's way to run a command on the device: here it is local

android_lang() {  # the language of the Android locale: tr, zh or en
    _l=
    for _p in persist.sys.locale persist.sys.locales persist.sys.language ro.product.locale ro.product.locale.language; do
        _l=$(getprop "$_p" 2>/dev/null) && [ -n "$_l" ] && break
    done
    case ${_l%%,*} in tr|tr-*|tr_*) echo tr ;; zh|zh-*|zh_*) echo zh ;; *) echo en ;; esac
}

# ---- answers: mu300-install.conf, read line by line, never sourced (it is a text file, and this runs as root). Only
# these keys are taken. Two kinds of file:
#   trusted    /data/adb/mu300-install.conf when root owns it and nobody else can write it, and a
#              mu300-install.conf inside the zip (as trusted as the scripts it comes with)
#   untrusted  /sdcard/mu300-install.conf or /sdcard/Download/mu300-install.conf (first found): any app with
#              storage access can write these, so they choose only what destroys nothing and reveals nothing
# Trusted values win.
CONF_KEYS='MU300_STORAGE MU300_SD_ERASE MU300_REGION_OVERWRITE MU300_MODE MU300_BOOT_OS MU300_BOOT MU300_BOOT_ATTEMPTS MU300_HOTSPOT MU300_GPU MU300_PASSWORD MU300_PASSWORD_FILE MU300_DEVICE MU300_LANG MU300_DRY_RUN'
CONF_SET=
conf_find() { for _f in "$SDCARD/mu300-install.conf" "$SDCARD/Download/mu300-install.conf"; do [ -f "$_f" ] && { echo "$_f"; return 0; }; done; return 0; }
# erasing, formatting, overriding the model check and the password: only from a trusted file
conf_trusted_only() {  # conf_trusted_only KEY VALUE
    case $1 in
        MU300_SD_ERASE|MU300_REGION_OVERWRITE|MU300_PASSWORD|MU300_PASSWORD_FILE|MU300_DEVICE) return 0 ;;
        MU300_MODE) [ "$2" = wipe ] ;;
        *) return 1 ;;
    esac
}
conf_trusted() {  # conf_trusted FILE: a regular file that root owns and nobody else can write
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    set -- $(ls -ln "$1")
    [ "${3:-}" = "${MU300_TRUSTED_UID:-0}" ] || return 1
    case $1 in ?????w*|????????w*) return 1 ;; esac
}
conf_load() {  # conf_load FILE [trusted]
    [ -n "$1" ] && [ -f "$1" ] || return 0
    _cf=$1; _tr=${2:-}; _set=; _ign=
    while IFS= read -r _line || [ -n "$_line" ]; do
        _line=$(printf '%s' "$_line" | tr -d '\r' | sed 's/^[[:space:]]*//')
        case $_line in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
        _k=$(printf '%s' "${_line%%=*}" | tr -d ' \t'); _v=${_line#*=}
        _v=$(printf '%s' "$_v" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
        case $_v in \"*\") _v=${_v#\"}; _v=${_v%\"} ;; \'*\') _v=${_v#\'}; _v=${_v%\'} ;; esac
        case " $CONF_KEYS " in
            *" $_k "*)
                if [ "$_tr" != trusted ] && conf_trusted_only "$_k" "$_v"; then
                    _kv=$_k; [ "$_k" != MU300_MODE ] || _kv=$_k=$_v        # never a password's value
                    warn "$(t 'mu300-install.conf: {1} is taken only from {2}, which only root can change; ignored in {3}' "$_kv" "$TRUSTED_CONF" "$_cf")"
                    _ign="$_ign $_k"
                else
                    # $_k is one of CONF_KEYS: the eval is safe, and the value is assigned, never evaluated
                    eval "$_k=\$_v; SRC_$_k=\$_cf"; _set="$_set $_k"
                fi ;;
            *) warn "$(t 'mu300-install.conf: {1} is not a setting of this installer; ignored' "$_k")" ;;
        esac
    done < "$1"
    [ -z "$_set" ] || say "$(t 'settings from {1}:{2}' "$_cf" "$_set")"
    if [ -n "$_ign" ]; then
        if [ "$_cf" = "$TRUSTED_CONF" ]; then _c="su -c 'chown 0:0 $_cf && chmod 600 $_cf'"
        else _c="su -c 'cp $_cf $TRUSTED_CONF && chmod 600 $TRUSTED_CONF'"; fi
        say "$(t 'To use{1}, make the file one only root can change: {2}' "$_ign" "$_c")"
    fi
    CONF_SET="$CONF_SET$_set"
}
conf_read() {  # every settings file there is, the untrusted ones first so that trusted values win
    conf_load "$(conf_find)"
    _adb=
    if [ -e "$TRUSTED_CONF" ]; then
        if conf_trusted "$TRUSTED_CONF"; then _adb=trusted
        else
            warn "$(t '{1} is not owned by root, or others can change it: it is read like a file on /sdcard' "$TRUSTED_CONF")"
            conf_load "$TRUSTED_CONF"
        fi
    fi
    conf_load "$D/mu300-install.conf" trusted
    [ -z "$_adb" ] || conf_load "$TRUSTED_CONF" trusted
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
    case ${MU300_PASSWORD_FILE:-} in ''|sdcard) ;; *) _bad MU300_PASSWORD_FILE "$MU300_PASSWORD_FILE" ;; esac
    case ${MU300_DEVICE:-} in ''|f50|u30air) ;; *) _bad MU300_DEVICE "$MU300_DEVICE" ;; esac
    case ${MU300_LANG:-} in ''|en|tr|zh) ;; *) _bad MU300_LANG "$MU300_LANG" ;; esac
    case ${MU300_DRY_RUN:-} in ''|1) ;; *) _bad MU300_DRY_RUN "$MU300_DRY_RUN" ;; esac
    if [ -n "${MU300_PASSWORD:-}" ] && [ ${#MU300_PASSWORD} -lt 6 ]; then
        die "$(t 'mu300-install.conf: MU300_PASSWORD must have at least 6 characters')"
    fi
}
src_of() { eval "_s=\${SRC_$1:-}"; if [ -n "$_s" ]; then echo "$_s"; else t 'default'; fi; }   # where a value came from

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
    [ -n "$DEVICE" ] || die "$(t 'This does not look like a ZTE F50/MU300 or U30 Air. If it is one, put MU300_DEVICE=f50 or u30air into {1}.' "$TRUSTED_CONF")"
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
# A directory of this run only, which only root can enter: the payload, the scripts that run as root, the settings
# they get, the device's proprietary files and the mount points. A new name each run, so nothing an earlier run left
# behind (a filesystem still mounted after it was killed, say) is ever used or removed.
work_setup() {
    _um=$(umask); umask 077
    W=$(mktemp -d "$WORK_PARENT/mu300-magisk.XXXXXX" 2>/dev/null) || W=
    umask "$_um"
    [ -n "$W" ] && [ -d "$W" ] || { W=; die "$(t 'could not create a work directory in {1}' "$WORK_PARENT")"; }
    chmod 700 "$W"
    W=$(cd "$W" && pwd -P)                   # as /proc/mounts names it
}
payload_unpack() {  # the two payload files copied out of the zip into W, and only those copies checked and used
    _need=$(( $(unzip -l "$ZIPFILE" "payload/*" | awk 'END { print $1 }') + 512 * 1048576 ))
    # -P: one line per filesystem (busybox puts a long device name on a line of its own)
    _free=$(( $(df -Pk "$W" | awk 'NR == 2 { print $4 }') * 1024 ))
    [ "$_free" -ge "$_need" ] || die "$(t 'not enough free space in {1}: {2} needed, {3} free' "$WORK_PARENT" "$(gib "$_need")" "$(gib "$_free")")"
    mkdir "$W/kernel"
    say "$(t 'Unpacking {1} and {2}' "$ROOTFS_ASSET" "$KERNEL_ASSET")"
    unzip -p "$ZIPFILE" "payload/$ROOTFS_ASSET" > "$W/mu300-$OS.tar.gz" &&
        unzip -p "$ZIPFILE" "payload/$KERNEL_ASSET" > "$W/kernel.tar.gz" || die "$(t 'could not unpack the zip')"
    [ "$(sha256sum "$W/mu300-$OS.tar.gz" | cut -d' ' -f1)" = "$SHA256_ROOTFS" ] &&
        [ "$(sha256sum "$W/kernel.tar.gz" | cut -d' ' -f1)" = "$SHA256_KERNEL" ] ||
        die "$(t 'the zip is damaged (checksum mismatch); download it again')"
    tar -xzf "$W/kernel.tar.gz" -C "$W/kernel" && rm -f "$W/kernel.tar.gz" || die "$(t 'could not unpack the kernel bundle')"
    KB=$W/kernel
    grep -qw "$DEVICE" "$KB/devices" 2>/dev/null || die "$(t 'this kernel does not support the {1}' "$DEVICE")"
}

# ---- leaving: W goes, but never a filesystem mounted in it. rm -rf into a mounted mu300root or mu300sd would
# delete the installed systems and everyone's files.
MOUNT_POINTS='mnt mu300root mu300root-internal'    # ours and android-install.sh's: only ever rmdir'd
mounted_at_or_under() {  # PATH: something is mounted on PATH or below it (also when the mount table is unreadable)
    [ -r "$MOUNTS" ] || return 0
    awk -v p="$1" '$2 == p || index($2, p "/") == 1 { f = 1 } END { exit !f }' "$MOUNTS"
}
cleanup() {  # every exit
    set +e
    write_example
    [ -n "${W:-}" ] && [ -d "$W" ] || return 0
    [ -z "${MOUNTED:-}" ] || umount_target "$MOUNTED"
    _left=
    for _e in "$W"/* "$W"/.[!.]*; do
        [ -e "$_e" ] || [ -L "$_e" ] || continue
        case " $MOUNT_POINTS " in *" ${_e##*/} "*) rmdir "$_e" 2>/dev/null || _left=1; continue ;; esac
        if mounted_at_or_under "$_e"; then _left=1; else rm -rf "$_e"; fi
    done
    rmdir "$W" 2>/dev/null || _left=1
    [ -z "$_left" ] || warn "$(t 'A Linux filesystem is still mounted in {1}; it was left as it is. Restart the device before installing again.' "$W")"
}

# ---- what to do
mount_target() {  # mount_target DIR [ro]: the Linux filesystem of the plan, with Android's mount helper
    cp "$D/android-mount-mu300root.sh" "$W/" || return 1
    _ro=; [ "${2:-}" != ro ] || _ro=1
    if [ "$SD_MODE" = 1 ]; then
        asw MU300_RO="$_ro" MU300_SD_DEV="$SD_DEV" "$ANDROID_SH" "$W/android-mount-mu300root.sh" "$1"
    else
        asw MU300_RO="$_ro" MU300_OFF="$INT_OFF" MU300_SIZE="$INT_SIZE" "$ANDROID_SH" "$W/android-mount-mu300root.sh" "$1"
    fi | grep -q '^MOUNTED' && MOUNTED=$1
}
# MOUNTED is cleared only after the helper said it unmounted; under set -e a bare failing call would end the
# function before that line
umount_target() { asw "$ANDROID_SH" "$W/android-mount-mu300root.sh" -u "$1" >/dev/null 2>&1 || return 1; MOUNTED=; }
need_for() { case $1 in openwrt) echo $NEED_OPENWRT ;; ubuntu) echo $NEED_UBUNTU ;; *) echo $NEED_BOTH ;; esac; }
no_room_inside() {  # the refusal when Linux does not fit inside, with the way out this device has
    if [ -n "$SD_DEV" ] && [ "$sd_ex" = foreign ]; then
        die "$(t 'There is too little free space inside for Linux, and the SD card ({1}) holds another Linux (ext4) filesystem, which the installer never formats. Copy off what you need and format the card elsewhere, or use another card.' "$SD_DEV")"
    elif [ -n "$SD_DEV" ]; then
        die "$(t 'There is too little free space inside for Linux. The SD card ({1}, {2}) can hold it: put MU300_STORAGE=sd and MU300_SD_ERASE=yes into {3}, a file only root can change (everything on the card is erased).' "$SD_DEV" "$(gib "$SD_BYTES")" "$TRUSTED_CONF")"
    elif [ "${SD_SMALL:-0}" = 1 ]; then
        die "$(t 'There is too little free space inside for Linux, and the SD card is smaller than 700 MiB. Use a bigger card (MU300_STORAGE=sd and MU300_SD_ERASE=yes in {1}), or make room with the installer for computers.' "$TRUSTED_CONF")"
    else
        die "$(t 'There is too little free space inside for Linux and no SD card. Insert a card (MU300_STORAGE=sd and MU300_SD_ERASE=yes in {1}), or make room with the installer for computers.' "$TRUSTED_CONF")"
    fi
}
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
            else no_room_inside
            fi ;;
    esac
    if [ "$SD_MODE" = 1 ]; then
        sd_not_foreign
        existing=$([ "$sd_ex" = yes ] && echo yes || echo no); TARGET_SIZE=$SD_BYTES
    else
        existing=$int_existing; TARGET_SIZE=$INT_SIZE; DIRTY=0
        [ "$INT_SIZE" -ge $((700 * 1024 * 1024)) ] || no_room_inside
        if [ "$existing" = no ]; then
            region_dirty
            [ "$DIRTY" = 0 ] || [ "${MU300_REGION_OVERWRITE:-}" = yes ] ||
                die "$(t 'The free space behind the partitions is not empty ({1} of 16 samples hold data); it may be used by this firmware. To use it anyway, put MU300_REGION_OVERWRITE=yes into {2}, a file only root can change.' "$DIRTY" "$TRUSTED_CONF")"
        fi
    fi
    INTERNAL_EXISTS=0; [ "$int_existing" = yes ] && INTERNAL_EXISTS=1
    FORMAT=0; UPDATE=0
    if [ "$existing" = yes ]; then
        case ${MU300_MODE:-update} in update) UPDATE=1 ;; wipe) FORMAT=1 ;; esac
    else
        FORMAT=1
    fi
    # a card is formatted only when a trusted file says MU300_SD_ERASE=yes, whatever the reason (a new card, or
    # MU300_MODE=wipe on a mu300sd one); an untrusted file cannot set it
    if [ "$SD_MODE" = 1 ] && [ "$FORMAT" = 1 ] && [ "${MU300_SD_ERASE:-}" != yes ]; then
        if [ "$existing" = yes ]; then
            die "$(t 'MU300_MODE=wipe formats the SD card ({1}, {2}): the installation on it and everything else is erased. To allow that, put MU300_SD_ERASE=yes into {3} as well.' "$SD_DEV" "$(gib "$SD_BYTES")" "$TRUSTED_CONF")"
        fi
        die "$(t 'Installing to the SD card ({1}, {2}) erases everything on it. To allow that, put MU300_SD_ERASE=yes into {3}, a file only root can change.' "$SD_DEV" "$(gib "$SD_BYTES")" "$TRUSTED_CONF")"
    fi
}
inspect_target() {  # which systems the existing filesystem holds, and its Ubuntu release: mounted read-only
    HAVE_SYSTEMS=; HAVE_UBUNTU=
    [ "$existing" = yes ] && [ "$FORMAT" = 0 ] || return 0
    mount_target "$W/mnt" ro || die "$(t 'could not mount the existing Linux filesystem')"
    for _os in ubuntu openwrt; do [ -d "$W/mnt/$_os" ] && HAVE_SYSTEMS="$HAVE_SYSTEMS $_os"; done
    HAVE_UBUNTU=$(sed -n 's/^VERSION_ID="\(.*\)"/\1/p' "$W/mnt/ubuntu/usr/lib/os-release" 2>/dev/null | head -n1)
    umount_target "$W/mnt" || die "$(t 'could not unmount the Linux filesystem from {1}' "$W/mnt")"
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
    PW_FILE=$PW_FILE_ROOT; [ "${MU300_PASSWORD_FILE:-}" != sdcard ] || PW_FILE=$PW_FILE_SDCARD
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
    if [ -n "${MU300_PASSWORD:-}" ]; then
        echo "  $(t 'password:       from {1}, written to {2}' "$(src_of MU300_PASSWORD)" "$PW_FILE")"
    else
        echo "  $(t 'password:       generated, written to {1}' "$PW_FILE")"
    fi
    echo "  $(t 'writes:         {1}, boot_{2}, 32 bytes of misc (boot_{3}, the partition table and userdata are not touched)' "$([ "$SD_MODE" = 1 ] && echo "$SD_DEV" || t 'the Linux region')" "$LINUX_SLOT" "$ANDROID_SLOT")"
}
# Every setting, what it does and the value this run used (or would have: a refused run writes it too, with what
# was known by then), so nobody has to type it from a README. Never written through a link someone put there.
write_example() {
    _ex=$SDCARD/mu300-install.conf.example
    rm -f "$_ex" 2>/dev/null
    ( set -C; {
        echo "# MU300 Linux Magisk installer settings. Copy to $SDCARD/mu300-install.conf, edit, install the zip again."
        echo "# Settings marked (root) are taken only from $TRUSTED_CONF, which only root can change: any app can write"
        echo "# to $SDCARD. Copy this file there with: su -c 'cp $SDCARD/mu300-install.conf $TRUSTED_CONF && chmod 600 $TRUSTED_CONF'"
        echo "# Values of the last run (${TAG:-}, $(date '+%Y-%m-%d %H:%M')) are shown; a line starting with # is not used."
        echo "#MU300_STORAGE=$([ "${SD_MODE:-0}" = 1 ] && echo sd || echo internal)        # internal or sd"
        echo "#MU300_SD_ERASE=yes            # (root) allow formatting the SD card for Linux: everything on it is erased"
        echo "#MU300_REGION_OVERWRITE=yes    # (root) use internal free space that holds data"
        echo "#MU300_MODE=update             # update (keep settings and data), or wipe (root)"
        echo "#MU300_BOOT_OS=${BOOT_OS:-${OS:-}}           # ubuntu or openwrt: which system boots"
        echo "#MU300_BOOT=linux              # linux (default boot, Android after failed boots) or android"
        echo "#MU300_BOOT_ATTEMPTS=${BOOT_ATTEMPTS:-5}          # 1-6 failed boots in a row before Android"
        echo "#MU300_HOTSPOT=yes             # copy Android's hotspot name and password"
        echo "#MU300_GPU=yes                 # Mali GPU (OpenCL) files"
        echo "#MU300_PASSWORD=               # (root) 6+ characters; empty: generated"
        echo "#MU300_PASSWORD_FILE=sdcard    # (root) write the password to $PW_FILE_SDCARD instead of $PW_FILE_ROOT"
        echo "#MU300_DEVICE=${DEVICE:-f50}              # (root) f50 or u30air, only when the model is not recognised"
        echo "#MU300_LANG=${MU300_LANG:-en}                # en, tr or zh"
        echo "#MU300_DRY_RUN=1               # only show what would be done"
    } > "$_ex" ) 2>/dev/null || true
}

main() {
    trap cleanup EXIT
    [ -n "$MU300_LANG" ] || MU300_LANG=$(android_lang)
    echo "MU300 Linux $(sed -n 's/^TAG=//p' "$D/manifest")"
    conf_read
    conf_check
    env_check
    manifest_load "$D/manifest"
    detect_device
    slot_setup
    work_setup
    payload_unpack
    plan_storage
    inspect_target
    plan_choices
    plan_print
    if [ "${MU300_DRY_RUN:-}" = 1 ]; then say "$(t 'Dry run: nothing was written.')"; exit 3; fi
}
[ -z "${MU300_LIB:-}" ] || return 0
main "$@"
