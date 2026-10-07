#!/bin/sh
# f50clean 镜像式(squashfs+overlay)安装脚本(设备本地原子执行,日志 /mnt/mu300-disk/f50clean-img-install.log)
# 布局: f50clean/{system.squashfs, image-version, data/{upper,work}}
# 任一步失败:不切换、不重启,留在原系统。旧 f50clean(目录式)改名 f50clean-dir 留作回滚。
LOG=/mnt/mu300-disk/f50clean-img-install.log
exec >$LOG 2>&1
set -e
echo "== f50clean image install start =="

DISK=/mnt/mu300-disk
PKG=$DISK/mu300-openwrt-luci-25.12.5-f50clean-system.squashfs
DST=$DISK/f50clean
NEW=$DISK/f50clean.new
OLD=$DISK/f50clean-dir

echo "-- 1. sha256 校验(与 .sha256 边车文件核对)"
[ -f "$PKG" ] || { echo "ABORT: $PKG 不存在"; exit 1; }
[ -f "$PKG.sha256" ] || { echo "ABORT: $PKG.sha256 不存在"; exit 1; }
( cd $DISK && sha256sum -c "$(basename $PKG).sha256" ) || { echo "ABORT: sha256 mismatch"; exit 1; }

echo "-- 2. 试挂载校验(内核必须能读这个 xz squashfs)"
rm -rf /tmp/sqtest; mkdir -p /tmp/sqtest
mount -t squashfs -o ro,loop "$PKG" /tmp/sqtest || { echo "ABORT: 本机内核挂不上该 squashfs"; exit 1; }
[ -x /tmp/sqtest/sbin/init ] || { umount /tmp/sqtest; echo "ABORT: 镜像内无 sbin/init"; exit 1; }
[ -d /tmp/sqtest/opt/mu300/android ] || { umount /tmp/sqtest; echo "ABORT: 镜像内无厂商 android 目录"; exit 1; }
[ -d /tmp/sqtest/rom ] && [ -d /tmp/sqtest/overlay ] || { umount /tmp/sqtest; echo "ABORT: 镜像缺 /rom 或 /overlay 挂载点"; exit 1; }
umount /tmp/sqtest; rmdir /tmp/sqtest

echo "-- 3. 组装 f50clean.new"
rm -rf $NEW
mkdir -p $NEW/data/upper $NEW/data/work
cp "$PKG" $NEW/system.squashfs
echo "v2026.10.11-f50clean-sq" > $NEW/image-version
sync

echo "-- 4. 原子换名(运行中的目录式系统根是 bind 挂载,换名不影响当前运行)"
[ -d $DST ] && { rm -rf $OLD; mv $DST $OLD; echo "   旧目录式系统保留为 f50clean-dir(回滚: mu300-os f50clean-dir)"; }
mv $NEW $DST

echo "-- 5. 配置继承(仅当当前运行系统就是 f50clean 目录式:密码与 uci 配置延续;否则全新出厂)"
CUR_VER=$(cat /etc/mu300/image-version 2>/dev/null)
case "$CUR_VER" in
    *f50clean*)
        mkdir -p $DST/data/upper/etc
        cp -a /etc/config $DST/data/upper/etc/
        cp -a /etc/shadow $DST/data/upper/etc/
        cp -a /etc/shadow- $DST/data/upper/etc/ 2>/dev/null || true
        [ -f /etc/dropbear/authorized_keys ] && { mkdir -p $DST/data/upper/etc/dropbear; cp -a /etc/dropbear/authorized_keys $DST/data/upper/etc/dropbear/; }
        echo "   已从当前 f50clean 继承 /etc/config + 密码"
        ;;
    *) echo "   当前系统($CUR_VER)非 f50clean,不继承,镜像全新出厂" ;;
esac

echo "-- 6. 切换下次启动到 f50clean(直接写 boot-os:本系统的旧 mu300-os 不认识镜像式系统)"
mkdir -p $DISK/.mu300
# default-boot 继承(与 mu300-os 切换逻辑一致):当前是默认 Linux 则镜像系统也继承
if [ "$(cat /etc/mu300/default-boot 2>/dev/null)" = linux ]; then
    mkdir -p $DST/data/upper/etc/mu300
    echo linux > $DST/data/upper/etc/mu300/default-boot
fi
echo f50clean > $DISK/.mu300/boot-os.tmp && mv $DISK/.mu300/boot-os.tmp $DISK/.mu300/boot-os
sync
echo "-- 7. 全部完成,3 秒后重启"
sleep 3
reboot
