#!/usr/bin/env bash
set -uo pipefail
C=$HOME/mu300-build/check
echo "===customfeeds.list==="
cat "$C/etc/apk/repositories.d/customfeeds.list" 2>&1; echo "(bytes: $(wc -c < "$C/etc/apk/repositories.d/customfeeds.list" 2>/dev/null))"
echo "===world 相对基线的新增行==="
tar -xzf "$HOME/mu300-build/mu300-openwrt-rootfs.tar.gz" -O ./etc/apk/world | sort > /tmp/world-vanilla.txt
comm -13 /tmp/world-vanilla.txt <(sort "$C/etc/apk/world")
echo "===installed db: tailscale 段==="
awk '/^P:tailscale$/,/^$/' "$C/lib/apk/db/installed" | head -12
echo "===installed db: 有无远程 URL 记录==="
grep -c "downloads.openwrt.org" "$C/lib/apk/db/installed" || echo "0(无远程源记录)"
echo "===toolkit menu_update 守卫==="
sed -n '/^menu_update() {/,/^}/p' "$C/opt/mu300/bin/mu300-toolkit"
echo "===mu300-post 残留检查==="
grep -n "update" "$C/etc/init.d/mu300-post" || echo "(无 update 字样)"
echo "===init.d mu300 清单 diff(vanilla vs final)==="
tar -tzf "$HOME/mu300-build/mu300-openwrt-rootfs.tar.gz" | grep -oE 'init\.d/mu300-[a-z-]+$' | sort > /tmp/v.txt
( cd "$C" && ls etc/init.d | grep '^mu300-' | sed 's|^|init.d/|' | sort ) > /tmp/f.txt
diff /tmp/v.txt /tmp/f.txt && echo "init.d 无差异"
