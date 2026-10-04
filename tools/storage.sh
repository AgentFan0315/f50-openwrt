# Where the Linux filesystem goes: the free eMMC region or the SD card. Sourced by install.sh and uninstall.sh
# (su_do, ask, t, die and gib are theirs).
#   sd_probe         SD_DEV / SD_BYTES of the card in the slot (empty without one), SD_SMALL=1 when it is too small
#   sd_existing      yes when the card already holds a mu300sd filesystem, foreign for any other ext4, else no
#   choose_storage   SD_MODE=0|1; MU300_STORAGE=internal|sd answers without asking

SD_MIN=$((700 * 1024 * 1024))

# One line from the device: "<block device> <512-byte sectors> <type>" for the first mmc disk that is not the
# eMMC - its first partition when it has one, the whole card otherwise. The type keeps a second eMMC or an SDIO
# function out.
sd_probe() {
    SD_DEV=; SD_BYTES=0; SD_SMALL=0
    set -- $(su_do 'for b in /sys/block/mmcblk[1-9]; do [ -e $b/device/type ] || continue; n=${b##*/}; if [ -e $b/${n}p1 ]; then echo /dev/block/${n}p1 $(cat $b/${n}p1/size) $(cat $b/device/type); else echo /dev/block/$n $(cat $b/size) $(cat $b/device/type); fi; break; done')
    [ $# -eq 3 ] && [ "$3" = SD ] || return 0
    if [ $(( $2 / 2048 )) -lt $(( SD_MIN / 1048576 )) ]; then SD_SMALL=1; return 0; fi
    SD_DEV=$1; SD_BYTES=$(( $2 * 512 ))
}

sd_existing() {
    m=$(su_do "dd if=$SD_DEV bs=1 skip=1080 count=2 2>/dev/null | od -An -tx1" | tr -d ' ')
    l=$(su_do "dd if=$SD_DEV bs=1 skip=1144 count=16 2>/dev/null" | tr -d '\000')
    # any other ext4, labelled or not, is foreign: android-install.sh's sd_prepare refuses to format it
    if [ "$m" != 53ef ]; then echo no; elif [ "$l" = mu300sd ]; then echo yes; else echo foreign; fi
}

choose_storage() {
    SD_MODE=0
    case ${MU300_STORAGE:-} in
        internal) return 0 ;;
        sd) [ -n "$SD_DEV" ] || die "$(t 'MU300_STORAGE=sd, but there is no usable SD card in the device')"
            SD_MODE=1; sd_not_foreign; return 0 ;;
        '') ;;
        *) die "$(t 'MU300_STORAGE must be internal or sd')" ;;
    esac
    [ -n "$SD_DEV" ] || return 0
    # too little room inside: the card is the way that needs no repartitioning
    _d=internal; [ "$SIZE" -lt "$SD_MIN" ] && _d=sd
    ask _st "$(t 'Where should the Linux filesystem go: internal storage or the SD card ({1}, {2})? (internal/sd)' "$SD_DEV" "$(gib "$SD_BYTES")")" $_d
    case $_st in
        internal) ;;
        sd) SD_MODE=1; sd_not_foreign ;;
        *) die "$(t 'invalid choice')" ;;
    esac
}

# Another Linux filesystem on the card may be someone's data, and the device refuses to format it. Say so now,
# not after the password, the download and the build.
sd_not_foreign() {
    [ "$(sd_existing)" = foreign ] || return 0
    die "$(t 'the SD card ({1}) holds another Linux (ext4) filesystem, and the installer never formats one that is not its own (mu300sd).' "$SD_DEV")
$(t 'Copy off what you need and format the card elsewhere, use another card, or install to internal storage (MU300_STORAGE=internal).')"
}
