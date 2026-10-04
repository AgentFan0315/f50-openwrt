# Device side of the Magisk installer: what only the device can make for its Linux boot image and its systems - the
# misc blocks, the Android files modem_control needs, the firmware, the device ramdisk segment - and the image
# itself, built from Android's own boot image the way mu300-update rebuilds ours. Sourced after
# rootfs/overlay/opt/mu300/bin/mu300-update (MU300_LIB=1), whose bootimg_from_stock and byte helpers it uses.
# Writes only into the directories it is given. The files it collects are proprietary: they stay on this device.
LZ4_MAGIC=02214c18
FIRMWARE='wcnmodem.bin gnssmodem.bin wifi_board_config.ini wifi_board_config_ab.ini bt_configure_pskey.ini bt_configure_rf.ini'

hex_to_bytes() {  # hex_to_bytes HEX: the bytes (octal escapes: dash's printf has no \x)
    _h=$1
    while [ -n "$_h" ]; do
        _p=${_h%"${_h#??}"}; _h=${_h#??}
        printf "\\$(printf %o "0x$_p")"
    done
}
# CRC-32 (zlib) of the bytes of HEX, little endian as the block stores it: gzip ends every stream with exactly that
# value, which saves an implementation (mu300-next-boot does the same)
crc32_hex() { hex_to_bytes "$1" | gzip -c | tail -c 8 | head -c 4 | od -An -tx1 -v | tr -d ' \n'; }

# bc_block LIVE a|b A_META B_META: the live bootloader_control (64 hex digits) with that slot suffix, slot a's and
# slot b's first byte (priority | tries << 4 | successful << 7) and a new CRC - boot/build-boot-image.py's with_slots
bc_block() {
    case $2 in a) _s=5f610000 ;; b) _s=5f620000 ;; *) return 1 ;; esac
    _b="$_s$(printf %s "$1" | cut -c9-24)$3$(printf %s "$1" | cut -c27-28)$4$(printf %s "$1" | cut -c31-56)"
    printf '%s%s' "$_b" "$(crc32_hex "$_b")"
}
bc_valid() {  # bc_valid LIVE: 64 hex digits, magic BCAB, a CRC that matches
    [ ${#1} = 64 ] && [ "$(printf %s "$1" | cut -c9-16)" = 42434142 ] &&
        [ "$(crc32_hex "$(printf %s "$1" | cut -c1-56)")" = "$(printf %s "$1" | cut -c57-64)" ]
}
bc_files() {  # bc_files LIVE DIR: the four blocks of Task 1, byte for byte
    _l=$1 _d=$2
    for _x in 'slot-a a 9f 1e' 'slot-b-trial b 9e 2f' 'slot-b b 1e 9f' 'slot-a-trial a 2f 9e'; do
        set -- $_x
        hex_to_bytes "$(bc_block "$_l" "$2" "$3" "$4")" > "$_d/misc-bc-$1.bin" || return 1
        [ "$(fsize "$_d/misc-bc-$1.bin")" = 32 ] || return 1
    done
}

collect_firmware() {  # collect_firmware DIR: the Wi-Fi/Bluetooth/GNSS firmware of this device; prints what is missing
    mkdir -p "$1"; _miss=
    for _f in $FIRMWARE; do
        _ok=
        for _d in ${MU300_FW_DIRS:-/odm/firmware /vendor/firmware /vendor/etc}; do
            if [ -s "$_d/$_f" ] && cp "$_d/$_f" "$1/$_f"; then _ok=1; break; fi
        done
        [ -n "$_ok" ] || _miss="$_miss $_f"
    done
    [ -z "$_miss" ] || { echo "$_miss"; return 1; }
}
# collect_subset LIST DIR: the files of LIST (android-vendor/subset-files.txt) from this device's /, links followed
# as extract-subset.sh follows them over adb, and the two things it adds. A file this firmware lacks is skipped; the
# two the modem cannot start without are checked.
collect_subset() {
    rm -rf "$2"; mkdir -p "$2"
    (cd "${MU300_ANDROID_ROOT:-/}" && tar -chf - $(grep -v '^#' "$1") 2>/dev/null) | tar -xf - -C "$2" 2>/dev/null
    mkdir -p "$2/system/bin" "$2/linkerconfig"
    ln -sfn /apex/com.android.runtime/bin/linker64 "$2/system/bin/linker64"
    : > "$2/linkerconfig/ld.config.txt"
    [ -s "$2/vendor/bin/modem_control" ] && [ -d "$2/dev/__properties__" ]
}
# collect_gpu LIST DIR: the Mali userspace and its library closure, all of it or nothing (a partial closure only
# fails later, inside OpenCL)
collect_gpu() {
    rm -rf "$2"; mkdir -p "$2"
    for _p in $(grep -v '^#' "$1"); do
        [ -e "${MU300_ANDROID_ROOT:-}/$_p" ] || { rm -rf "$2"; return 1; }
    done
    (cd "${MU300_ANDROID_ROOT:-/}" && tar -chf - $(grep -v '^#' "$1")) | tar -xf - -C "$2" || { rm -rf "$2"; return 1; }
}
# vendor_overlay OS FW SUBSET GPU OUT: what tools/vendor-overlay.py makes on a computer, for android-install.sh to
# unpack over the system: the firmware, the subset under opt/mu300/android with its property area moved out of
# dev/ (a devtmpfs is mounted there), the GPU files where the subset has none. Only leaf directories are named, so
# no entry replaces a directory the system has (Ubuntu's lib is a link to usr/lib).
vendor_overlay() {
    _o=$5.d; rm -rf "$_o"
    case $1 in ubuntu) _fw=usr/lib/firmware ;; openwrt) _fw=lib/firmware ;; *) return 1 ;; esac
    mkdir -p "$_o/$_fw" "$_o/opt/mu300/android" || return 1
    cp "$2"/* "$_o/$_fw/" && cp -a "$3"/. "$_o/opt/mu300/android/" || return 1
    mv "$_o/opt/mu300/android/dev/__properties__" "$_o/opt/mu300/android/dev-properties" &&
        rm -rf "$_o/opt/mu300/android/dev" || return 1
    if [ -n "$4" ]; then
        (cd "$4" && find . ! -type d | sed 's|^\./||') | while read -r _f; do
            [ -e "$_o/opt/mu300/android/$_f" ] || [ -L "$_o/opt/mu300/android/$_f" ] && continue
            mkdir -p "$_o/opt/mu300/android/$(dirname "$_f")" && cp -a "$4/$_f" "$_o/opt/mu300/android/$_f"
        done
    fi
    tar -czf "$5" -C "$_o" "$_fw" opt/mu300/android && rm -rf "$_o"
}

# device_segment DIR OUT: DIR as a newc cpio owned by root, compressed to LZ4 legacy by magiskboot - the format the
# 5.4 kernel takes for every segment (gzip makes it panic) and that no shell tool on the device writes
device_segment() {
    (cd "$1" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort | cpio -o -H newc -R 0:0 2>/dev/null) > "$2.cpio" || return 1
    "${MAGISKBOOT:-magiskboot}" compress=lz4_legacy "$2.cpio" "$2" >/dev/null 2>&1 || return 1
    rm -f "$2.cpio"
    [ "$(od -An -tx1 -N4 "$2" | tr -d ' \n')" = "$LZ4_MAGIC" ]
}
# linux_boot_image STOCK BUNDLE DEVSEG OUT: the device segment first, then the bundle's generic one (init, busybox,
# modules); nothing in a generic segment has the name of a device-segment file, and mu300-update wants an LZ4 frame
# first. Then the header and AVB data of Android's own image around it.
linux_boot_image() {
    [ "$(od -An -tx1 -N4 "$2/ramdisk-generic.lz4" | tr -d ' \n')" = "$LZ4_MAGIC" ] || return 1
    cat "$3" "$2/ramdisk-generic.lz4" > "$4/ramdisk" || return 1
    bootimg_from_stock "$1" "$2/Image" "$4/ramdisk" "$4"
}
