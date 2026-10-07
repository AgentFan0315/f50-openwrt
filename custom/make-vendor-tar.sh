#!/usr/bin/env bash
# make-vendor-tar.sh — 制作 build-clean.sh 需要的厂商包(VENDOR_TAR)
#
# 这些文件是 ZTE/紫光展锐/谷歌的专有财产,不属于本仓库,也不在上游 release 里;
# 每个人必须从自己的设备获得。绝不要把生成的 tar 提交进仓库。
# These files are proprietary (ZTE/Unisoc/Google), belong to no repository and are
# not in upstream's releases — everyone obtains them from their own device.
# NEVER commit the resulting tarball.
#
# 用法 / Usage:
#   make-vendor-tar.sh ssh [root@192.168.0.1] [OUT]   推荐:从运行着任一 mu300 Linux
#                                                     系统(官方或 f50clean)的设备拉取
#   make-vendor-tar.sh dir ANDROID_SUBSET FIRMWARE [OUT]
#                                                     本地目录打包(上游 extract-subset.sh
#                                                     + 固件目录的产物)
set -euo pipefail
die() { printf '!! %s\n' "$*" >&2; exit 1; }

# 设备 chroot 里的 proc/sys/dev/data/tmp/mnt 是运行时挂载点,不是文件,打包必须排除
# (设备 tar 是 BusyBox,无 --exclude,见 ssh 分支的 find -prune 清单法)
# lib/firmware 里只取上游安装的这 6 个厂商固件;regulatory.db* 是 OpenWrt 底包自己的
FW6="lib/firmware/bt_configure_pskey.ini lib/firmware/bt_configure_rf.ini \
lib/firmware/gnssmodem.bin lib/firmware/wcnmodem.bin \
lib/firmware/wifi_board_config.ini lib/firmware/wifi_board_config_ab.ini"

check() {  # check TAR: 基本健全性(注意:管道接 grep -q 会 SIGPIPE 误杀 tar,先落临时文件)
    local list; list=$(mktemp)
    tar -tzf "$1" > "$list" 2>/dev/null || { rm -f "$list"; die "$1 不是有效 tar.gz"; }
    grep -q 'opt/mu300/android/vendor/bin/modem_control$' "$list" \
        || { rm -f "$list"; die "$1 缺 modem_control(缺它开机约 290 秒 PMIC 断电)"; }
    grep -q 'lib/firmware/wcnmodem.bin$' "$list" \
        || { rm -f "$list"; die "$1 缺 wcnmodem.bin"; }
    rm -f "$list"
}

case "${1:-}" in
ssh)
    HOST=${2:-root@192.168.0.1}
    OUT=${3:-mu300-vendor-openwrt-luci.tar.gz}
    SSHOPT="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    [ -n "${SSH_KEY:-}" ] && SSHOPT="$SSHOPT -i $SSH_KEY -o IdentitiesOnly=yes"
    echo ">> 从 $HOST 拉取(设备需运行任一 mu300 Linux 系统)..."
    # 设备是 BusyBox tar:无 --exclude,-T 清单里列了目录又会递归把挂载点拉回来。
    # 用 -X 排除文件:busybox 的 * 可跨 /,所以 "路径" + "路径/*" 两条才完整排除一棵子树
    # (绝不能写 dev* 这类裸前缀——会把 dev-properties 一起误杀,实测 427→67)。
    # shellcheck disable=SC2086
    ssh $SSHOPT "$HOST" "printf '%s\n' \
        'opt/mu300/android/proc' 'opt/mu300/android/proc/*' \
        'opt/mu300/android/sys'  'opt/mu300/android/sys/*' \
        'opt/mu300/android/dev'  'opt/mu300/android/dev/*' \
        'opt/mu300/android/data' 'opt/mu300/android/data/*' \
        'opt/mu300/android/tmp'  'opt/mu300/android/tmp/*' \
        'opt/mu300/android/mnt'  'opt/mu300/android/mnt/*' > /tmp/.vx.\$\$ \
        && cd / && tar -czf - -X /tmp/.vx.\$\$ opt/mu300/android $FW6; \
        rc=\$?; rm -f /tmp/.vx.\$\$; exit \$rc" > "$OUT" \
        || die "ssh 拉取失败(设备在线吗?SSH_KEY 设了吗?)"
    check "$OUT"
    ;;
dir)
    SUB=${2:-}; FW=${3:-}; OUT=${4:-mu300-vendor-openwrt-luci.tar.gz}
    [ -n "$SUB" ] && [ -n "$FW" ] || die "用法: $0 dir ANDROID_SUBSET_DIR FIRMWARE_DIR [OUT.tar.gz]"
    [ -d "$SUB/system" ] && [ -d "$SUB/vendor" ] || die "$SUB 不像 android-subset(缺 system/vendor)"
    [ -f "$SUB/vendor/bin/modem_control" ] || die "$SUB 缺 vendor/bin/modem_control"
    [ -f "$FW/wcnmodem.bin" ] || die "$FW 缺 wcnmodem.bin"
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    mkdir -p "$TMP/opt/mu300" "$TMP/lib/firmware"
    cp -a "$SUB" "$TMP/opt/mu300/android"
    rm -f "$TMP/opt/mu300/android/windows-source.tar.gz"   # 上游放在 subset 里的源码提供包不进固件
    for f in $FW6; do b=$(basename "$f"); [ -f "$FW/$b" ] && cp -a "$FW/$b" "$TMP/lib/firmware/"; done
    tar -czf "$OUT" -C "$TMP" opt lib
    check "$OUT"
    echo ">> 注意:新版上游 extract-subset.sh 的精简子集未经 f50clean 验证;有疑虑请用 ssh 模式"
    ;;
*)
    die "用法: $0 ssh [root@主机] [OUT]  |  $0 dir ANDROID_SUBSET_DIR FIRMWARE_DIR [OUT]"
    ;;
esac
echo "OK: $OUT ($(du -h "$OUT" | cut -f1))"
echo "下一步 / next: VENDOR_TAR=$OUT bash custom/build-clean.sh"
