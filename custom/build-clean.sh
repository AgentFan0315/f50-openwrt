#!/usr/bin/env bash
# =====================================================================
# f50-clean 纯净版构建(上游 v2026.10.11 openwrt-luci 基线)
#
# 相对基线的改动:
#   1. hostname mu300 → f50(90-mu300 首启)
#   2. 默认 LAN IP 192.168.77.1 → 192.168.0.1(改 mu300-lan-ip 默认值,
#      netifd/90-mu300、lan-start、toolkit 提示全部走这一个来源)
#   2b. default-boot=linux 打进底包(该文件若只在 overlay 上层,出厂重置
#      清空上层后会退回单次试用模式,重启一次掉回 Android)
#   3. 无包管理页、无远程源(留 apk 本体)、无刷机页、无 mu300-update
#   4. 删官方 VPN 组件:wireguard-tools/luci-proto-wireguard/ppp 全家/
#      xl2tpd/gre + 对应 kmod 占位 + mu300-vpn(VLESS 隧道,面板无引用)
#   5. 删 GPU 驱动死文件:mali_kbase.ko / sprd_gpu_cooling.ko
#      (etc/modules.d 无 autoload 条目,系统无任何引用,headless 用不到)
#   6. 语言:删土耳其语(tr)i18n + mu300 面板 Languages 页(上传/装包的
#      语言包机制);保留并预装中文 zh-cn(base/firewall/sqm + mu300 面板),
#      LuCI 可正常中英文切换
#   7. 主题:删 luci-theme-aurora,默认 bootstrap
#   8. 内置防火墙时序修复(lan/wan zone 静态绑定 br-lan/sipa_eth0)
#   9. 日志噪音:LuCI 系统日志页默认过滤展锐厂商内核驱动刷屏(页面有
#      勾选框可临时显示),SSH 登录后 logread 自动过滤(logread-raw 看原始)
#   9b. 内核降噪(方案B):自编译 5.4 内核+模块,厂商驱动刷屏 printk 降级。
#      注意:rootfs /lib/modules 里的 .ko 才是运行时真正加载的,boot 镜像
#      内嵌模块只管 initramfs 阶段 —— 所以 10e 步必须用自编模块覆盖同名文件
#   10f 杂项:luci 语言列表删硬编码 tr 行(下拉不扫 lmo,列表写死在
#      etc/config/luci 的 languages 段);默认语言 zh_cn;删 91-mu300-luci 里
#      首启强制 mediaurlbase=aurora/lang=en 的块(否则重置后顶掉底包设置);
#      删 LED 配置页(leds.js+led-trigger,
#      不碰 mu300-led 硬件服务);默认 WiFi ZTE_BCB57A/1234567890
#      (openwrt-wifi-config 兜底分支,hotspot.conf 存在时仍以其为准);
#      root 默认密码 admin(sha512-crypt);可选装维护公钥(MAINTAINER_KEY 环境变量)
#   10g 死代码清理(全组件盘点结论):删 mu300-accounts(每开机报 not found);
#      mu300-extra 换降级 stub(link 空操作兼容 mu300-post);删 mu300-vpn 悬空
#      符号链接;extra-modules 去掉已删 GPU 驱动的 modprobe;toolkit VPN 菜单
#      改不可用提示;mu300dash 删 lang_get/lang_set 死方法+ACL 收紧;
#      banner/openwrt_release 补 f50 品牌
#
# 保留:全部 mu300-* 硬件胶水服务(vendor/mobile-data/atd/boot-ok/
#   next-boot/led/thermal-guard/lan/hotspot/wifi-client 等)、kanoqwq 面板、
#   sqm、6in4/6rd/ds-lite(IPv6 过渡,非 VPN)。
# 产物:dist/mu300-openwrt-luci-25.12.5-f50clean-rootfs.tar.gz(目录式)
#      dist/mu300-openwrt-luci-25.12.5-f50clean-system.squashfs(镜像式,
#      只读底包,设备上配 data/{upper,work} overlay,出厂重置=清空 data)
# =====================================================================
set -euo pipefail
TOPC=$(cd "$(dirname "$0")/.." && pwd)   # 仓库根(在 cd $WORK 之前解析)

DIST=${DIST:-$TOPC/dist}                    # 产物输出目录(默认 仓库根/dist)
WORK=${MU300_WORK:-$HOME/mu300-build}
# 构建输入(都不在仓库里,见 README「构建输入」一节):
#   VANILLA_SRC  上游官方 rootfs tar.gz 的本地路径(或直接放进 $WORK)
#   VENDOR_TAR   厂商 android/firmware 打包(默认 $WORK/mu300-vendor-openwrt-luci.tar.gz)
#   KERNEL_OUT   自编译内核输出目录(其下 modules/ 用于 10e 降噪模块覆盖;缺省则跳过)
#   MAINTAINER_KEY 维护公钥路径(可选,装进 /etc/dropbear/authorized_keys;仓库不带任何密钥)
VANILLA_NAME=mu300-openwrt-luci-rootfs.tar.gz
VANILLA_SHA=cbe330982a4a0a8d18fa0c0c1d20862a07e938a8d98575ad45e2851327316ebd
FINAL_NAME=mu300-openwrt-luci-25.12.5-f50clean-rootfs.tar.gz

log() { printf '\033[1m== %s\033[0m\n' "$*"; }
die() { printf '\033[31m!! %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "需要 root"
command -v qemu-aarch64-static >/dev/null || die "缺少 qemu-user-static"
if [ ! -f /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    cat /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register 2>/dev/null \
        || die "binfmt 注册失败"
fi

mkdir -p "$WORK"; cd "$WORK"

log "0. 校验基线"
[ -f "$VANILLA_NAME" ] || { [ -n "${VANILLA_SRC:-}" ] && cp "$VANILLA_SRC" .; }
[ -f "$VANILLA_NAME" ] || die "缺基线 $VANILLA_NAME:从上游 release v2026.10.11 下载后放进 $WORK,或用 VANILLA_SRC=<路径> 指定"
echo "$VANILLA_SHA  $VANILLA_NAME" | sha256sum -c - >/dev/null || die "基线 SHA256 不符"

log "1. 解包基线 rootfs"
R=$WORK/rootfs-clean
rm -rf "$R"; mkdir -p "$R"
tar -xzf "$VANILLA_NAME" -C "$R"
[ -x "$R/usr/bin/apk" ] || die "基线里没有 /usr/bin/apk"
export QEMU_LD_PREFIX="$R"
apk() { qemu-aarch64-static "$R/usr/bin/apk" --root "$R" --repositories-file /dev/null --no-cache --allow-untrusted "$@"; }
apk --version >/dev/null || die "镜像自带 apk 无法通过 qemu 运行"

# ---------- 2. hostname mu300 → f50 ----------
log "2. hostname f50"
grep -q "hostname='mu300'" "$R/etc/uci-defaults/90-mu300" || die "90-mu300 里没找到 hostname='mu300'"
sed -i "s/hostname='mu300'/hostname='f50'/" "$R/etc/uci-defaults/90-mu300"

# ---------- 2b. default-boot=linux 打进底包 ----------
# 关键:该文件若只存在于 overlay 上层,出厂重置(清空上层)后系统会退回
# 单次试用模式,重启一次就回 Android。打进底包后,重置=回到默认 Linux。
log "2b. 底包内置 default-boot=linux(出厂重置后仍是默认 Linux)"
mkdir -p "$R/etc/mu300"
echo linux > "$R/etc/mu300/default-boot"

# ---------- 3. 默认 LAN IP → 192.168.0.1 ----------
log "3. 默认 LAN IP 192.168.77.1 → 192.168.0.1(mu300-lan-ip 是唯一来源)"
grep -q 'echo 192.168.77.1' "$R/opt/mu300/bin/mu300-lan-ip" || die "mu300-lan-ip 结构变了"
sed -i 's/echo 192\.168\.77\.1/echo 192.168.0.1/' "$R/opt/mu300/bin/mu300-lan-ip"
sed -i 's/echo 192\.168\.77\.1)/echo 192.168.0.1)/' "$R/opt/mu300/bin/mu300-toolkit"  # toolkit 里仅一处兜底显示
grep -q 'echo 192.168.0.1' "$R/opt/mu300/bin/mu300-lan-ip" || die "IP 替换未生效"

# ---------- 4. 包管理页 + 远程源 ----------
log "4. 删包管理页(i18n 可卸,主包被 luci 元包引用 → 删 4 个文件),清远程源"
apk del luci-i18n-package-manager-zh-cn luci-i18n-package-manager-tr || die "包管理页 i18n 卸载失败"
rm -f "$R/usr/share/luci/menu.d/luci-app-package-manager.json" \
      "$R/usr/share/rpcd/acl.d/luci-app-package-manager.json" \
      "$R/www/luci-static/resources/view/package-manager.js" \
      "$R/usr/libexec/package-manager-call" || die "包管理页文件删除失败"
: > "$R/etc/apk/repositories.d/distfeeds.list"
: > "$R/etc/apk/repositories.d/customfeeds.list"
[ ! -f "$R/etc/apk/repositories" ] || : > "$R/etc/apk/repositories"

# ---------- 5. LuCI 刷机页 ----------
log "5. 移除 LuCI 固件刷写页"
rm -f "$R/www/luci-static/resources/view/system/flash.js" \
      "$R/www/luci-static/resources/view/system/repokeys.js"
python3 - "$R/usr/share/luci/menu.d/luci-mod-system.json" <<'PYEOF'
import json,sys
p=sys.argv[1]
m=json.load(open(p))
for k in ("admin/system/flash","admin/system/repokeys","admin/system/admin/repokeys"):
    m.pop(k,None)
json.dump(m,open(p,"w"),indent=1,ensure_ascii=False)
PYEOF
! grep -q '"admin/system/flash"' "$R/usr/share/luci/menu.d/luci-mod-system.json" || die "flash 菜单项删除失败"

# ---------- 6. mu300-update 清除 ----------
log "6. 移除 mu300-update 及定时入口,toolkit 优雅降级"
rm -f "$R/opt/mu300/bin/mu300-update" "$R/usr/bin/mu300-update" "$R/etc/profile.d/mu300-update.sh"
sed -i '/a newer release: a note at login/d; /procd_open_instance updatenotice/,/procd_close_instance/d' \
    "$R/etc/init.d/mu300-post"
if grep -q updatenotice "$R/etc/init.d/mu300-post"; then die "mu300-post 仍有 updatenotice 残留"; fi
grep -q '^menu_update() {$' "$R/opt/mu300/bin/mu300-toolkit" || die "toolkit 结构变了,守卫插入点找不到"
sed -i '/^menu_update() {$/r /dev/stdin' "$R/opt/mu300/bin/mu300-toolkit" <<'GUARD'
    if [ ! -x /opt/mu300/bin/mu300-update ]; then
        title "Software update"
        printf '  %sThis build has no online updater (mu300-update was removed at build time).%s\n' "$B" "$N"
        printf '  %sUpdate by unpacking a newer rootfs next to this system and switching with mu300-os <name>.%s\n' "$D" "$N"
        pause
        return
    fi
GUARD

# ---------- 6b. mu300-os 支持镜像式系统 ----------
log "6b. mu300-os 认识镜像式系统(容器目录 = system.squashfs + data/)"
python3 - "$R/opt/mu300/bin/mu300-os" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
subs = [
    # is_system: 镜像系统没有外露的 etc/init,认 system.squashfs
    ("""is_system() {
    d=$DISK/$1
    [ -d "$d/etc" ] || return 1""",
     """is_system() {
    d=$DISK/$1
    # an image system keeps its tree in system.squashfs; data/ is the overlay's writable side
    [ -f "$d/system.squashfs" ] && return 0
    [ -d "$d/etc" ] || return 1"""),
    # 版本号:镜像系统的 etc 在底包里,容器级留一份
    ("""        [ -r "$DISK/$n/etc/mu300/image-version" ] && printf ' %s' "$(cat "$DISK/$n/etc/mu300/image-version")\"""",
     """        iv="$DISK/$n/etc/mu300/image-version"; [ -r "$iv" ] || iv="$DISK/$n/image-version"
        [ -r "$iv" ] && printf ' %s' "$(cat "$iv")\""""),
    # default-boot 继承:镜像系统写进 overlay 上层
    ("""        if [ "$DISK" != / ] && [ -d "$DISK/$1/etc" ]; then
            mkdir -p "$DISK/$1/etc/mu300"
            if [ "$(cat "${MU300_SYSROOT:-}/etc/mu300/default-boot" 2>/dev/null)" = linux ]; then echo linux > "$DISK/$1/etc/mu300/default-boot"
            else rm -f "$DISK/$1/etc/mu300/default-boot"; fi
        fi""",
     """        if [ "$DISK" != / ]; then
            etcdir="$DISK/$1/etc"
            [ -f "$DISK/$1/system.squashfs" ] && etcdir="$DISK/$1/data/upper/etc"
            mkdir -p "$etcdir/mu300"
            if [ "$(cat "${MU300_SYSROOT:-}/etc/mu300/default-boot" 2>/dev/null)" = linux ]; then echo linux > "$etcdir/mu300/default-boot"
            else rm -f "$etcdir/mu300/default-boot"; fi
        fi"""),
]
for old, new in subs:
    if s.count(old) != 1:
        sys.stderr.write("mu300-os 结构变了,匹配点不唯一: %r\n" % old[:60]); sys.exit(1)
    s = s.replace(old, new)
open(p, "w").write(s)
PYEOF
grep -q system.squashfs "$R/opt/mu300/bin/mu300-os" || die "mu300-os 补丁未生效"

# ---------- 7. 防火墙时序修复 ----------
log "7. firewall zone 静态绑定(lan→br-lan, wan→sipa_eth0)"
python3 - "$R/etc/config/firewall" <<'PYEOF'
import sys,re
p=sys.argv[1]
s=open(p).read()
def die_exit(z):
    sys.stderr.write("zone %s 找不到\n"%z); sys.exit(1)
def adddev(s,zone,dev):
    # uci 归一化后名字带引号,原始文件不带,两种都匹配
    pat=re.compile(r"(config zone\n(?:\t[^\n]*\n)*?\toption name\s+'?%s'?\n)" % zone)
    m=pat.search(s) or die_exit(zone)
    block_end=s.find("\n\n",m.end())
    block=s[m.start():block_end]
    if "list device '%s'"%dev in block: return s
    return s[:m.end()]+"\tlist device '%s'\n"%dev+s[m.end():]
s=adddev(s,'lan','br-lan')
s=adddev(s,'wan','sipa_eth0')
open(p,"w").write(s)
PYEOF
grep -A3 -E "option name\s+'?lan'?" "$R/etc/config/firewall" | grep -q "list device 'br-lan'" || die "lan zone 绑定失败"
grep -A3 -E "option name\s+'?wan'?" "$R/etc/config/firewall" | grep -q "list device 'sipa_eth0'" || die "wan zone 绑定失败"

# ---------- 8. VPN 组件 ----------
log "8. 删官方 VPN 组件(wireguard/ppp 全家/xl2tpd/gre + kmod 占位 + mu300-vpn)"
# luci-proto-gre 引用 gre,必须一起卸;kmod-gre/gre6 才能随孤儿清理走
VPN_PKGS="wireguard-tools luci-proto-wireguard luci-proto-gre xl2tpd gre \
          ppp-mod-pptp ppp-mod-pppoe ppp \
          kmod-wireguard kmod-l2tp kmod-pptp kmod-pppol2tp kmod-pppoe kmod-ppp kmod-pppox \
          kmod-mppe kmod-slhc kmod-gre kmod-gre6"
apk del $VPN_PKGS || die "VPN 包卸载失败"
# luci-proto-ppp 被 luci-light 元包硬引用,卸不掉 → 删它的 5 个协议视图文件(同包管理页套路)
rm -f "$R/www/luci-static/resources/protocol/"{ppp,pppoe,pppoa,pptp,l2tp}.js || die "luci-proto-ppp 文件删除失败"
# mu300-vpn:raw 文件(不在 apk db),面板无引用,默认无 vpn.conf 从不启动
rm -f "$R/etc/init.d/mu300-vpn" "$R/etc/rc.d/"*mu300-vpn \
      "$R/opt/mu300/bin/mu300-vpn" "$R/etc/mu300/vpn.conf.example"

# ---------- 9. GPU 驱动死文件 ----------
log "9. 删 mali_kbase.ko / sprd_gpu_cooling.ko(无 autoload 条目,headless 用不到)"
rm -f "$R"/lib/modules/*/mali_kbase.ko "$R"/lib/modules/*/sprd_gpu_cooling.ko

# ---------- 10. 语言系统:删土耳其语 + mu300 Languages 页,保留可用中文 ----------
log "10. 删 tr i18n + 面板 Languages 页(保留 zh-cn:base/firewall/sqm + mu300 面板中文)"
apk del luci-i18n-base-tr luci-i18n-firewall-tr luci-i18n-sqm-tr || die "tr i18n 卸载失败"
rm -f "$R/usr/lib/lua/luci/i18n/mu300.tr.lmo"
rm -f "$R/www/luci-static/resources/view/mu300/languages.js"
rm -f "$R/usr/libexec/unisoc-modem/languages"   # mu300dash 仅按需调用,页面没了永不触达
python3 - "$R/usr/share/luci/menu.d/luci-app-mu300.json" <<'PYEOF'
import json,sys
p=sys.argv[1]
m=json.load(open(p))
if "admin/system/mu300-languages" not in m:
    sys.stderr.write("菜单里没有 mu300-languages\n"); sys.exit(1)
del m["admin/system/mu300-languages"]
json.dump(m,open(p,"w"),indent=1,ensure_ascii=False)
PYEOF

# ---------- 10b. 主题:aurora → bootstrap ----------
log "10b. 删 luci-theme-aurora,默认 bootstrap"
apk del luci-theme-aurora || die "aurora 卸载失败"
sed -i "s|option mediaurlbase '/luci-static/aurora'|option mediaurlbase '/luci-static/bootstrap'|" "$R/etc/config/luci"
sed -i "/option Aurora '\/luci-static\/aurora'/d" "$R/etc/config/luci"
grep -q "mediaurlbase '/luci-static/bootstrap'" "$R/etc/config/luci" || die "mediaurlbase 未改"
! grep -qi aurora "$R/etc/config/luci" || die "luci 配置仍有 aurora 残留"

# ---------- 10c. 日志噪音过滤(展锐厂商内核驱动刷屏,运行时无开关只能展示层过滤) ----------
log "10c. LuCI 日志页默认过滤厂商驱动噪音 + SSH logread 过滤别名"
python3 - "$R/www/luci-static/resources/tools/views.js" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
NOISE = "sprd-wlan|sc2355|sc27xx-fgu|charger-manager|sprd_cfg|WCN BASE|WCN PCIE|mdbg_log_cb|loopcheck|lut not found|sipa|sprd_wdt_fiq|sprd_battery|sprd_bc1p2|sprdbt|sprd_pmic_wdt"
tag_filter = "loglines=loglines.filter(line=>{return line.toLowerCase().includes(this.logTagFilter?.toLowerCase());});"
fmax_def = "const filterMaxRows=E('input',{'id':'logMaxRows','type':'number','class':'cbi-input',});"
edits = [
    ("invertLogTextSearch:false,logTagFilter:",
     "invertLogTextSearch:false,showVendorNoise:false,logTagFilter:"),
    (tag_filter,
     tag_filter + "if(!this.showVendorNoise){const nre=/" + NOISE + "/;"
     + "loglines=loglines.filter(line=>!(line.includes(' kern.')&&nre.test(line)));}"),
    (fmax_def,
     fmax_def + "const noiseToggle=E('input',{'id':'vendorNoiseToggle','type':'checkbox','class':'cbi-input-checkbox',});"),
    ("self.fetchMaxRows=Number.parseInt(filterMaxRows.value);self.pollLog();",
     "self.fetchMaxRows=Number.parseInt(filterMaxRows.value);self.showVendorNoise=noiseToggle.checked;self.pollLog();"),
    ("filterMaxRows.addEventListener('change',handleLogFilterChange);",
     "filterMaxRows.addEventListener('change',handleLogFilterChange);noiseToggle.addEventListener('change',handleLogFilterChange);"),
    ("_('Max rows:')),filterMaxRows,])",
     "_('Max rows:')),filterMaxRows,E('label',{'for':'vendorNoiseToggle','style':'margin: 0 5px 0 15px'},_('Show vendor driver noise')),noiseToggle,])"),
]
for old, new in edits:
    if s.count(old) != 1:
        sys.stderr.write("views.js 结构变了,匹配点不唯一: %r\n" % old[:60]); sys.exit(1)
    s = s.replace(old, new)
open(p, "w", encoding="utf-8", newline="").write(s)
PYEOF
grep -q showVendorNoise "$R/www/luci-static/resources/tools/views.js" || die "views.js 噪音过滤补丁未生效"
cat > "$R/etc/profile.d/logread-filter.sh" <<'EOF'
# f50clean: hide sprd vendor kernel driver spam in interactive logread.
# 绕过方式: /sbin/logread 或 logread-raw
logread() {
	/sbin/logread "$@" | grep -vE 'sprd-wlan|sc2355|sc27xx-fgu|charger-manager|sprd_cfg|WCN BASE|WCN PCIE|mdbg_log_cb|loopcheck|lut not found|sipa|sprd_wdt_fiq|sprd_battery|sprd_bc1p2|sprdbt|sprd_pmic_wdt'
}
alias logread-raw='/sbin/logread'
EOF

# ---------- 10d. 出厂重置页 + 后端(自实现清空数据层;firstboot 需 MTD rootfs_data,本机不可用) ----------
log "10d. 装出厂重置:LuCI 页(mu300 域,带中文)+ /usr/libexec/f50-factory-reset 后端"
cat > "$R/usr/libexec/f50-factory-reset" <<'EOF'
#!/bin/sh
# f50 出厂重置:清空 overlay 数据层(upper+work)后重启,回到只读底包出厂状态。
# 仅镜像式系统可用。OpenWrt 自带 factoryreset 依赖 MTD rootfs_data 卷(本机没有,
# 实测静默退出 255),故自实现,语义同 jffs2reset 的 "only erasing files"。
rootfs=$(awk '$2=="/"{print $3}' /proc/mounts)
romfs=$(awk '$2=="/rom"{print $3}' /proc/mounts)
upper=$(awk '$1=="overlay" && $2=="/"{print $4}' /proc/mounts | tr ',' '\n' | sed -n 's/^upperdir=//p')
if [ "$rootfs" != overlay ] || [ "$romfs" != squashfs ] || [ -z "$upper" ]; then
    echo "not an image system (root=$rootfs rom=${romfs:-none}); refusing" >&2
    exit 1
fi
# upperdir 是 init 命名空间的旧路径(/disk/...),当前系统在 /mnt/mu300-disk;
# /overlay 就是 upper 的 bind,直接清 /overlay。work 目录按同源路径推导,尽力清理。
# 注意:后台子 shell 必须 >/dev/null 2>&1 脱离输出管道,否则 rpcd 等管道 EOF
# 不返回,浏览器报 "XHR request aborted"(实际重置已在执行)。
rel=${upper#/disk/}; work=/mnt/mu300-disk/${rel%/upper}/work
( sleep 2
  rm -rf /overlay/* /overlay/.[!.]* /overlay/..?* 2>/dev/null
  [ -d "$work" ] && rm -rf "$work"/* "$work"/.[!.]* "$work"/..?* 2>/dev/null
  sync; reboot ) >/dev/null 2>&1 &
exit 0
EOF
chmod +x "$R/usr/libexec/f50-factory-reset"

cat > "$R/www/luci-static/resources/view/mu300/reset.js" <<'EOF'
'use strict';
'require view';
'require fs';
'require ui';

return view.extend({
	handleFactoryReset: function() {
		ui.showModal(_('Factory Reset'), [
			E('p', _('Really erase all settings and reboot?')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'btn', 'click': ui.hideModal }, _('Cancel')),
				' ',
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, function() {
						ui.showModal(_('Factory Reset'), [
						E('p', { 'class': 'spinning' }, _('The device is resetting and will reboot. Reconnect in about one minute.'))
					]);
					fs.exec('/usr/libexec/f50-factory-reset').then(function(res) {
						if (res && res.code)
							return Promise.reject(new Error(res.stderr || 'refused'));
						return null;
					}).catch(function(e) {
						/* 重置期间连接中断属预期(设备正在重启);8 秒后探测,设备仍在线才报失败 */
						return new Promise(function(r) { setTimeout(r, 8000); }).then(function() {
							return fs.exec('/bin/true').then(function() {
								ui.hideModal();
								ui.addNotification(null, E('p', _('Reset failed') + ': ' + (e.message || e)), 'error');
							}).catch(function() { /* 设备已不可达 = 正在重启,保持提示 */ });
						});
					});
					})
				}, _('Erase everything and reboot'))
			])
		]);
	},

	render: function() {
		return E([], [
			E('h2', _('Factory Reset')),
			E('div', { 'class': 'cbi-section' }, [
				E('p', _('Erase all settings and user data on the writable overlay, then reboot into the pristine system image. The read-only base system is not touched. This cannot be undone.')),
				E('p', _('Works only on image-based systems (squashfs base + overlay data); on a plain directory installation the reset refuses to run.')),
				E('button', {
					'class': 'btn cbi-button-negative',
					'click': ui.createHandlerFn(this, 'handleFactoryReset')
				}, _('Erase everything and reboot'))
			])
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
EOF

# 菜单项:挂进 System 菜单,随 luci-app-mu300 域(中文翻译走 mu300.zh-cn.lmo)
python3 - "$R/usr/share/luci/menu.d/luci-app-mu300.json" <<'PYEOF'
import json,sys
p=sys.argv[1]
m=json.load(open(p))
m["admin/system/f50-reset"]={
 "title":"Factory Reset",
 "order":90,
 "action":{"type":"view","path":"mu300/reset"},
 "depends":{"acl":["luci-app-mu300"]}
}
json.dump(m,open(p,"w"),indent=1,ensure_ascii=False)
PYEOF

# ACL:允许页面执行重置后端
python3 - "$R/usr/share/rpcd/acl.d/luci-app-mu300.json" <<'PYEOF'
import json,sys
p=sys.argv[1]
m=json.load(open(p))
w=m["luci-app-mu300"]["write"]
f=w.setdefault("file",{})
f["/usr/libexec/f50-factory-reset"]=["exec"]
json.dump(m,open(p,"w"),indent=1,ensure_ascii=False)
PYEOF

# 中文:往 v2026.10.11 的 mu300 po 追加本页词条,重编 mu300.zh-cn.lmo
POC="$TOPC/custom/mu300-zh-Hans.po"
[ -f "$POC" ] || die "缺 $POC(v2026.10.11 的 mu300 zh_Hans po)"
cp "$POC" /tmp/mu300-zh-merged.po
cat >> /tmp/mu300-zh-merged.po <<'EOF'

msgid "Factory Reset"
msgstr "恢复出厂设置"

msgid "Erase all settings and user data on the writable overlay, then reboot into the pristine system image. The read-only base system is not touched. This cannot be undone."
msgstr "清空可写数据层中的全部设置与用户数据,然后重启进入出厂只读底包。底包本身不受影响。此操作不可撤销。"

msgid "Works only on image-based systems (squashfs base + overlay data); on a plain directory installation the reset refuses to run."
msgstr "仅适用于镜像式系统(squashfs 底包 + overlay 数据层);目录式安装的系统上,重置会拒绝执行。"

msgid "Really erase all settings and reboot?"
msgstr "确定要清空全部设置并重启吗?"

msgid "Erase everything and reboot"
msgstr "清空全部并重启"

msgid "The device is resetting and will reboot. Reconnect in about one minute."
msgstr "设备正在重置并即将重启,约一分钟后重新连接(地址不变)。"

msgid "Reset failed"
msgstr "重置失败"

msgid "Close"
msgstr "关闭"
EOF
python3 "$TOPC/tools/po2lmo.py" /tmp/mu300-zh-merged.po "$R/usr/lib/lua/luci/i18n/mu300.zh-cn.lmo" || die "lmo 重编失败"
grep -qa "恢复出厂设置" "$R/usr/lib/lua/luci/i18n/mu300.zh-cn.lmo" || die "lmo 缺少重置词条"

# ---------- 10e. 用自编译(降噪)内核模块覆盖 rootfs 同名 .ko ----------
# 关键:boot 镜像内嵌模块只在 initramfs 阶段有效;switch_root 后 OpenWrt 从
# /lib/modules(本 rootfs)加载,不覆盖则降噪补丁对运行时不生效。
log "10e. 自编译内核模块覆盖 /lib/modules 同名 .ko(降噪落地)"
KMODS=${KERNEL_OUT:-$TOPC/out}/modules
if [ -d "$KMODS" ]; then
    replaced=0
    for ko in "$R"/lib/modules/*/*.ko; do
        b=$(basename "$ko"); alt=$(echo "$b" | tr '-' '_')
        for cand in "$KMODS/$b" "$KMODS/$alt"; do
            if [ -f "$cand" ]; then cp "$cand" "$ko"; replaced=$((replaced+1)); break; fi
        done
    done
    # 降噪关键模块必须在覆盖之列(名字规范化比对)
    missed=""
    for m in sprd_wlan_combo wcn_bsp sprd_charger_manager sc27xx_fuel_gauge sprd_wdt_fiq; do
        mn=$(echo "$m" | tr '_' '-')
        found=$(ls "$R"/lib/modules/*/ | grep -ixE "${mn}\.ko|${m}\.ko" | head -1)
        [ -n "$found" ] || missed="$missed $m"
    done
    log "  覆盖 $replaced 个模块;${missed:+rootfs 本无:$missed(视基线而定,非错误)}"
    [ "$replaced" -gt 50 ] || die "覆盖数异常少($replaced),KERNEL_OUT 可能不对"
else
    log "  跳过:无 $KMODS(纯基线模块,无降噪)"
fi

# ---------- 10f. 默认值与杂项:语言列表清 tr、删 LED 配置页、默认 WiFi/root 密码、维护公钥 ----------
log "10f. 语言列表清 tr / 删 LED 页 / 默认 WiFi=ZTE_BCB57A / root 密码=admin / 维护公钥"
python3 - "$R" <<'PYEOF'
import sys, pathlib
R = pathlib.Path(sys.argv[1])

# 1) 语言下拉列表是 /etc/config/luci 里硬编码的 languages 段(不是扫 lmo),删 tr 行;
#    默认语言 auto(跟随浏览器)改 zh_cn(用户要求默认中文,界面仍可手动切英文)
p = R / "etc/config/luci"
lines = p.read_text().splitlines(keepends=True)
n = len(lines)
lines = [l for l in lines if not l.lstrip().startswith("option tr ")]
assert len(lines) == n - 1, "luci 配置里没有 tr 语言行"
s = "".join(lines)
assert s.count("option lang 'auto'") == 1, "luci 配置里没有 lang auto 行"
p.write_text(s.replace("option lang 'auto'", "option lang 'zh_cn'", 1))

# 1b) 首启脚本 91-mu300-luci 会无条件覆盖 mediaurlbase=aurora 和 lang=en,
#     把底包里的 bootstrap/zh_cn 全顶掉 —— 连注释带 batch 整块删掉
#     (脚本其余部分:NDP 安全项 + IPv6 relay 网络配置,全部保留)
p = R / "etc/uci-defaults/91-mu300-luci"
s = p.read_text()
old = """# Aurora is the LuCI theme (Bootstrap stays installed and selectable), and LuCI and the MU300 panel start in English
# (90-mu300 set it already; System > System > Language and Style switches to Turkish, Chinese or a language of the
# lang extra). Runs after 90-mu300 and after the themes' own uci-defaults, which would otherwise pick their own
# default.
uci -q batch <<UCI
set luci.main.mediaurlbase='/luci-static/aurora'
set luci.main.lang='en'
UCI
"""
assert s.count(old) == 1, "91-mu300-luci 结构变了"
p.write_text(s.replace(old, "", 1))

# 2) 默认 WiFi:固定 SSID/密码(openwrt-wifi-config 的兜底分支;hotspot.conf 存在时仍以其为准)
p = R / "opt/mu300/bin/openwrt-wifi-config"
s = p.read_text()
old_ssid = '''[ -n "$SSID" ] || SSID="MU300-$(tr -d : < /sys/class/net/wlan0/address 2>/dev/null | tail -c 5 | tr a-f A-F)"'''
new_ssid = '''[ -n "$SSID" ] || SSID="ZTE_BCB57A"'''
old_psk = '''[ ${#PSK} -ge 8 ] || PSK=$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 12)'''
new_psk = '''[ ${#PSK} -ge 8 ] || PSK=1234567890'''
assert s.count(old_ssid) == 1, "openwrt-wifi-config SSID 行结构变了"
assert s.count(old_psk) == 1, "openwrt-wifi-config PSK 行结构变了"
p.write_text(s.replace(old_ssid, new_ssid).replace(old_psk, new_psk))

# 3) root 默认密码 admin(sha512-crypt,musl crypt 支持;LuCI/dropbear 均可用)
#    注意:必须整行替换。只换前缀会让残留字段粘在行尾,musl 解析失败=账号锁死
#    (v6 实机踩过:登录全拒,修正整行后 ubus session login 通过)
p = R / "etc/shadow"
s = p.read_text()
old_line = "root:::0:99999:7:::"
new_line = "root:$6$XgCnV.WZyhQ9xNl0$zZkmm21Wi00V.5/.uMkHoaopkEKIjWK8zuo9ITgYuuzi4jf/BFzYCBzC2t4fnrDxr3PKMTqiRn25mxCypd6jV0:0:0:99999:7:::"
assert s.count(old_line) == 1, "shadow root 行结构变了"
s = s.replace(old_line, new_line, 1)
root_line = [l for l in s.splitlines() if l.startswith("root:")][0]
assert len(root_line.split(":")) == 9, "shadow root 行字段数不对"
p.write_text(s)
PYEOF

# 4) 删 LED 配置页(led-trigger 目录仅被 leds.js 引用;不碰 mu300-led 硬件胶水服务)
rm -f "$R/www/luci-static/resources/view/system/leds.js"
rm -rf "$R/www/luci-static/resources/view/system/led-trigger"
python3 - "$R/usr/share/luci/menu.d/luci-mod-system.json" <<'PYEOF'
import json,sys
p=sys.argv[1]
m=json.load(open(p))
if "admin/system/leds" not in m:
    sys.stderr.write("菜单里没有 leds\n"); sys.exit(1)
del m["admin/system/leds"]
json.dump(m,open(p,"w"),indent=1,ensure_ascii=False)
PYEOF

# 5) 维护公钥(可选):设了 MAINTAINER_KEY 才装;公开仓库不带任何密钥,
#    不设则镜像里无 authorized_keys,root 靠默认密码 admin 登录
if [ -n "${MAINTAINER_KEY:-}" ] && [ -f "$MAINTAINER_KEY" ]; then
    install -d -m 700 "$R/etc/dropbear"
    install -m 600 "$MAINTAINER_KEY" "$R/etc/dropbear/authorized_keys"
fi

# ---------- 10g. 死代码清理 + 品牌补全(2026-10-07 全组件盘点结论) ----------
log "10g. 死代码清理(accounts/extra stub/toolkit VPN 菜单/dash lang 方法/悬空链接/GPU 噪音)+ f50 品牌"

# 1) mu300-accounts:唯一职责是调已删除的 mu300-update accounts,每次开机报 not found。
#    软件层升级迁移件,非硬件胶水,整删(服务+rc.d 链接+底包 marker)。
rm -f "$R/etc/init.d/mu300-accounts" "$R/etc/rc.d/S11mu300-accounts" "$R/etc/.mu300-accounts-from-image"

# 2) mu300-extra:所有子命令依赖已删的 mu300-update,换成明确降级的 stub
#    (link 被 mu300-post 开机调用,保持空操作成功 —— 不动 mu300-post 本身)
cat > "$R/opt/mu300/bin/mu300-extra" <<'EOF'
#!/bin/sh
# f50clean:extras(vpn/lang 在线安装)已随 mu300-update 一起移除。
# link 子命令被 mu300-post 开机调用,保持空操作成功;其余明确报错。
case "${1:-}" in
link) exit 0 ;;
*) echo "mu300-extra: online extras were removed in this build" >&2; exit 1 ;;
esac
EOF
chmod +x "$R/opt/mu300/bin/mu300-extra"

# 3) 悬空符号链接(mu300-vpn 本体已删)
rm -f "$R/usr/bin/mu300-vpn"

# 4) extra-modules:GPU 驱动已删,从加载清单去掉,消除每开机 2 行 modprobe FAILED;注释同步
python3 - "$R/opt/mu300/bin/extra-modules" <<'PYEOF'
import sys
p=sys.argv[1]; s=open(p).read()
old1=" sprd_gpu_cooling mali_kbase; do"
assert s.count(old1)==1, "extra-modules 模块清单结构变了"
s=s.replace(old1,"; do",1)
old2=" and the Mali GPU (/dev/mali0)"
assert s.count(old2)==1, "extra-modules 注释结构变了"
s=s.replace(old2,"",1)
open(p,"w").write(s)
PYEOF

# 5) mu300-toolkit:menu_vpn 整函数替换为不可用提示(菜单入口保留,优雅降级,同 menu_update 套路)
python3 - "$R/opt/mu300/bin/mu300-toolkit" <<'PYEOF'
import re,sys
p=sys.argv[1]; s=open(p).read()
pat=re.compile(r"vpn_enabled\(\) \{.*?\n\}\n(?=\n# Live radio quality)", re.S)
assert len(pat.findall(s))==1, "toolkit menu_vpn 区块定位失败"
new='''menu_vpn() {
    title "VPN (VLESS)"
    printf '  %sThis build has no VPN feature (mu300-vpn was removed at build time).%s\n' "$B" "$N"
    printf '  %sTailscale / ZeroTier are pure userspace; install a local .apk with apk if you need them.%s\n' "$D" "$N"
    pause
}
'''
s=pat.sub(new,s,count=1)
if s.count("VPN_CONF")==1:   # 只剩定义行则一并删
    s=s.replace("VPN_CONF=/etc/mu300/vpn.conf\n","",1)
assert "mu300-vpn status" not in s, "menu_vpn 替换未生效"
open(p,"w").write(s)
PYEOF

# 6) mu300dash:lang_get/lang_set 的后端(languages 适配器)已删,连方法一起去掉
python3 - "$R/usr/libexec/rpcd/mu300dash" <<'PYEOF'
import re,sys
p=sys.argv[1]; s=open(p).read()
old="#   lang_get, lang_set  LuCI's languages and the lang extra (unisoc-modem/languages, mu300-extra)\n"
assert s.count(old)==1, "mu300dash 头注释结构变了"
s=s.replace(old,"",1)
pat=re.compile(r"# -+ languages\n.*?\n\}\n\n(?=do_list\(\) \{)", re.S)
assert len(pat.findall(s))==1, "mu300dash languages 段定位失败"
s=pat.sub("",s,count=1)
# do_list JSON:删掉 lang 两行后,上一行 usb_net_add 的尾逗号必须一并去掉,否则 JSON 非法
old='\t"usb_net_add": { "iface": "String" },\n\t"lang_get": { },\n\t"lang_set": { "op": "String", "codes": "String", "source": "String" }\n'
assert s.count(old)==1, "mu300dash do_list 结构变了"
s=s.replace(old,'\t"usb_net_add": { "iface": "String" }\n',1)
old='\n        lang_get)     run_m lang_get     m_lang_get ;;\n        lang_set)     run_m lang_set     m_lang_set ;;'
assert s.count(old)==1, "mu300dash dispatch 结构变了"
s=s.replace(old,"",1)
assert "lang_get" not in s and "lang_set" not in s, "mu300dash lang 残留"
open(p,"w").write(s)
PYEOF

# 7) ACL 收紧:lang 两个方法 + 语言包上传授权(面板 JS 已无 cgi-io 引用)
python3 - "$R/usr/share/rpcd/acl.d/luci-app-mu300.json" <<'PYEOF'
import json,sys
p=sys.argv[1]
m=json.load(open(p))
a=m["luci-app-mu300"]
a["read"]["ubus"]["mu300dash"].remove("lang_get")
a["write"]["ubus"]["mu300dash"].remove("lang_set")
del a["write"]["cgi-io"]
del a["write"]["file"]["/tmp/mu300-extra-lang.tar.gz"]
json.dump(m,open(p,"w"),indent=1,ensure_ascii=False)
PYEOF

# 8) 品牌补全(G1 收尾):/etc/banner + DISTRIB_DESCRIPTION
cat > "$R/etc/banner" <<'EOF'
  _____ ____   ___
 |  ___|  _ \ / _ \   F50 clean build
 | |_  | | | | | | |  OpenWrt 25.12.5 (mu300-linux v2026.10.11)
 |  _| | |_| | |_| |  LAN http://192.168.0.1
 |_|   |____/ \___/   WiFi ZTE_BCB57A
EOF
sed -i "s|^DISTRIB_DESCRIPTION=.*|DISTRIB_DESCRIPTION='F50 OpenWrt 25.12.5 (f50clean)'|" "$R/etc/openwrt_release"
grep -q "F50 OpenWrt" "$R/etc/openwrt_release" || die "openwrt_release 未改"

# ---------- 11. 元数据 + 打包 ----------
log "11. 刷新 packages.txt / image-version 并重打包"
apk list --installed 2>/dev/null | sort > "$R/etc/mu300/packages.txt" || true
printf '%s-f50clean\n' "$(cat "$R/etc/mu300/image-version" 2>/dev/null || echo v2026.10.11)" > "$R/etc/mu300/image-version"
rm -f "$R/tmp/resolv.conf" "$R/tmp/hosts" 2>/dev/null || true
( cd "$R" && tar -czf "$WORK/$FINAL_NAME" . )
log "产物: $WORK/$FINAL_NAME ($(du -h "$WORK/$FINAL_NAME" | cut -f1))"

# ---------- 11b. squashfs 镜像系统(合并厂商文件;底包只读,数据层 overlay) ----------
log "11b. 合并厂商文件并打 squashfs 镜像"
VENDOR_TAR=${VENDOR_TAR:-$WORK/mu300-vendor-openwrt-luci.tar.gz}
[ -f "$VENDOR_TAR" ] || die "缺厂商包 $VENDOR_TAR(从上游 release 提取 android-vendor/firmware 后打包,见 README「构建输入」)"
command -v mksquashfs >/dev/null || die "缺少 mksquashfs(apt install squashfs-tools)"
R2=$WORK/rootfs-img
rm -rf "$R2"; cp -a "$R" "$R2"
tar -xzf "$VENDOR_TAR" -C "$R2"
[ -n "$(ls -A "$R2/opt/mu300/android" 2>/dev/null)" ] || die "厂商 android 文件未合入"
[ -f "$R2/lib/firmware/wcnmodem.bin" ] || die "固件未合入"
SQ_NAME=mu300-openwrt-luci-25.12.5-f50clean-system.squashfs
rm -f "$WORK/$SQ_NAME"
mksquashfs "$R2" "$WORK/$SQ_NAME" -comp xz -b 256k -noappend -no-progress >/dev/null
rm -rf "$R2"
mkdir -p "$DIST"; cp "$WORK/$SQ_NAME" "$DIST/"
( cd "$DIST" && sha256sum "$SQ_NAME" > "$SQ_NAME.sha256" )
log "镜像产物: dist/$SQ_NAME ($(du -h "$WORK/$SQ_NAME" | cut -f1))"

# ---------- 12. 自检 ----------
log "12. 验收自检"
mkdir -p check3; rm -rf check3/*; tar -xzf "$WORK/$FINAL_NAME" -C check3
ok=1
t() { if [ "$2" = "$3" ]; then echo "  [PASS] $1"; else echo "  [FAIL] $1 (期望 $3, 实际 $2)"; ok=0; fi }

echo "-- 标识"
t "hostname=f50" "$(grep -c "hostname='f50'" check3/etc/uci-defaults/90-mu300)" 1
t "lan-ip=192.168.0.1" "$(grep -c 'echo 192.168.0.1' check3/opt/mu300/bin/mu300-lan-ip)" 1
t "无残留 192.168.77.1(mu300-lan-ip)" "$(grep -c '192.168.77' check3/opt/mu300/bin/mu300-lan-ip)" 0
t "default-boot=linux 打进底包" "$(cat check3/etc/mu300/default-boot)" linux

echo "-- 包管理/刷机/更新"
t "distfeeds 空" "$(wc -c < check3/etc/apk/repositories.d/distfeeds.list)" 0
t "apk 本体在" "$([ -x check3/usr/bin/apk ] && echo y)" y
t "包管理菜单无" "$([ -e check3/usr/share/luci/menu.d/luci-app-package-manager.json ] && echo y || echo n)" n
t "flash.js 无" "$([ -e check3/www/luci-static/resources/view/system/flash.js ] && echo y || echo n)" n
t "repokeys 菜单无" "$(grep -c 'repokeys' check3/usr/share/luci/menu.d/luci-mod-system.json)" 0
t "mu300-update 无" "$(ls check3/opt/mu300/bin/mu300-update check3/usr/bin/mu300-update check3/etc/profile.d/mu300-update.sh 2>/dev/null | wc -l)" 0
t "mu300-post 无 updatenotice" "$(grep -c updatenotice check3/etc/init.d/mu300-post)" 0
t "toolkit 守卫在(update+vpn 两处)" "$(grep -c 'removed at build time' check3/opt/mu300/bin/mu300-toolkit)" 2

echo "-- VPN 清除"
for p in wireguard-tools ppp xl2tpd gre luci-proto-wireguard luci-proto-gre; do
    t "db 无 $p" "$(grep -c "^P:$p\$" check3/lib/apk/db/installed)" 0; done
t "ppp 协议视图已删" "$(ls check3/www/luci-static/resources/protocol/ppp*.js check3/www/luci-static/resources/protocol/l2tp.js check3/www/luci-static/resources/protocol/pptp.js 2>/dev/null | wc -l)" 0
t "kmod-wireguard 占位已清" "$(grep -c '^P:kmod-wireguard$' check3/lib/apk/db/installed)" 0
t "mu300-vpn 服务无" "$([ -e check3/etc/init.d/mu300-vpn ] && echo y || echo n)" n
t "mu300-vpn 二进制无" "$([ -e check3/opt/mu300/bin/mu300-vpn ] && echo y || echo n)" n
t "modules.d 无 ppp/wireguard" "$(ls check3/etc/modules.d/ | grep -cE 'ppp|wireguard|l2tp|gre|mppe|slhc|pptp')" 0

echo "-- GPU 清除"
t "mali_kbase.ko 无" "$(ls check3/lib/modules/*/mali_kbase.ko 2>/dev/null | wc -l)" 0
t "sprd_gpu_cooling.ko 无" "$(ls check3/lib/modules/*/sprd_gpu_cooling.ko 2>/dev/null | wc -l)" 0

echo "-- 语言系统:tr 清光,zh-cn 保留,Languages 页删"
t "tr i18n 包全清" "$(grep -c '^P:luci-i18n-.*-tr$' check3/lib/apk/db/installed)" 0
t "zh-cn i18n 三包在" "$(grep -c '^P:luci-i18n-.*-zh-cn$' check3/lib/apk/db/installed)" 3
t "languages.js 无" "$([ -e check3/www/luci-static/resources/view/mu300/languages.js ] && echo y || echo n)" n
t "languages 菜单无" "$(grep -c 'mu300-languages' check3/usr/share/luci/menu.d/luci-app-mu300.json)" 0
t "languages 后端无" "$([ -e check3/usr/libexec/unisoc-modem/languages ] && echo y || echo n)" n
t "mu300 中文 lmo 在" "$([ -f check3/usr/lib/lua/luci/i18n/mu300.zh-cn.lmo ] && echo y)" y
t "mu300 土耳其 lmo 无" "$([ -e check3/usr/lib/lua/luci/i18n/mu300.tr.lmo ] && echo y || echo n)" n

echo "-- 主题:aurora 清除,bootstrap 默认"
t "aurora 包无" "$(grep -c '^P:luci-theme-aurora$' check3/lib/apk/db/installed)" 0
t "mediaurlbase=bootstrap" "$(grep -c "mediaurlbase '/luci-static/bootstrap'" check3/etc/config/luci)" 1
t "luci 配置无 aurora" "$(grep -ci aurora check3/etc/config/luci)" 0

echo "-- mu300-* 硬件服务清单(基线减 mu300-vpn/mu300-accounts,其余不动)"
tar -tzf "$VANILLA_NAME" | grep -oE 'init\.d/mu300-[a-z-]+$' | grep -vE 'mu300-(vpn|accounts)$' | sort > /tmp/vanilla-svc3.txt
( cd check3 && ls etc/init.d | grep '^mu300-' | sed 's|^|init.d/|' | sort ) > /tmp/final-svc3.txt
t "服务清单一致" "$(diff -q /tmp/vanilla-svc3.txt /tmp/final-svc3.txt >/dev/null && echo same)" same

echo "-- 防火墙修复"
t "lan 绑定 br-lan" "$(grep -A3 -E "option name\s+'?lan'?" check3/etc/config/firewall | grep -c "list device 'br-lan'")" 1
t "wan 绑定 sipa_eth0" "$(grep -A3 -E "option name\s+'?wan'?" check3/etc/config/firewall | grep -c "list device 'sipa_eth0'")" 1

echo "-- 日志噪音过滤"
t "views.js 过滤补丁在" "$([ -n "$(grep -s showVendorNoise check3/www/luci-static/resources/tools/views.js)" ] && echo y)" y
t "logread 过滤脚本在" "$([ -f check3/etc/profile.d/logread-filter.sh ] && echo y)" y

echo "-- 镜像式系统(squashfs 支持)"
t "mu300-os 认镜像系统(3 处含注释)" "$(grep -c 'system\.squashfs' check3/opt/mu300/bin/mu300-os)" 3
t "reset.js 在" "$([ -f check3/www/luci-static/resources/view/mu300/reset.js ] && echo y)" y
t "reset.js 宽容模式(先弹模态)" "$(grep -c 'spinning' check3/www/luci-static/resources/view/mu300/reset.js)" 1
t "f50-factory-reset 可执行" "$([ -x check3/usr/libexec/f50-factory-reset ] && echo y)" y
t "reset 后端自擦数据层" "$(grep -c 'rm -rf /overlay' check3/usr/libexec/f50-factory-reset)" 1
t "reset 后端不依赖 firstboot" "$(grep -c firstboot check3/usr/libexec/f50-factory-reset)" 0
t "reset 后端脱离管道(立即返回)" "$(grep -c '>/dev/null 2>&1 &' check3/usr/libexec/f50-factory-reset)" 1
t "reset 菜单在" "$(grep -c 'admin/system/f50-reset' check3/usr/share/luci/menu.d/luci-app-mu300.json)" 1
t "reset ACL 在" "$(grep -c 'f50-factory-reset' check3/usr/share/rpcd/acl.d/luci-app-mu300.json)" 1
t "lmo 含恢复出厂设置" "$(grep -qa '恢复出厂设置' check3/usr/lib/lua/luci/i18n/mu300.zh-cn.lmo && echo y)" y
t "底包挂载点 /rom 在 tar 里" "$(tar -tzf "$WORK/$FINAL_NAME" | grep -c '^\./rom/$')" 1
t "底包挂载点 /overlay 在 tar 里" "$(tar -tzf "$WORK/$FINAL_NAME" | grep -c '^\./overlay/$')" 1

echo "-- squashfs 底包内容"
SQ_LIST=$(unsquashfs -ll "$WORK/$SQ_NAME" 2>/dev/null) || die "unsquashfs 读取失败"
t "squashfs 含 sbin/init" "$(printf '%s\n' "$SQ_LIST" | grep -c 'squashfs-root/sbin/init$')" 1
t "squashfs 含 wcnmodem.bin" "$(printf '%s\n' "$SQ_LIST" | grep -c 'lib/firmware/wcnmodem\.bin$')" 1
t "squashfs 含 opt/mu300/android" "$(printf '%s\n' "$SQ_LIST" | grep -c 'squashfs-root/opt/mu300/android$')" 1
t "squashfs 含 /rom 挂载点" "$(printf '%s\n' "$SQ_LIST" | grep -c 'squashfs-root/rom$')" 1
t "squashfs 含 /overlay 挂载点" "$(printf '%s\n' "$SQ_LIST" | grep -c 'squashfs-root/overlay$')" 1

echo "-- 自编译模块覆盖(降噪落地)"
if [ -d "$KMODS" ]; then
    t "sprd_wlan_combo.ko 与自编一致" "$(sha256sum check3/lib/modules/*/sprd_wlan_combo.ko | cut -d' ' -f1)" "$(sha256sum "$KMODS/sprd_wlan_combo.ko" | cut -d' ' -f1)"
    t "wcn_bsp.ko 与自编一致" "$(sha256sum check3/lib/modules/*/wcn_bsp.ko | cut -d' ' -f1)" "$(sha256sum "$KMODS/wcn_bsp.ko" | cut -d' ' -f1)"
fi

echo "-- 默认值与杂项(10f)"
t "luci 语言列表无 tr" "$(grep -c "option tr " check3/etc/config/luci)" 0
t "luci 默认语言=zh_cn" "$(grep -c "option lang 'zh_cn'" check3/etc/config/luci)" 1
t "首启脚本不再强制 en/aurora" "$(grep -c "luci.main.lang='en'\|luci.main.mediaurlbase='/luci-static/aurora'" check3/etc/uci-defaults/91-mu300-luci)" 0
t "默认 SSID=ZTE_BCB57A" "$(grep -c 'SSID="ZTE_BCB57A"' check3/opt/mu300/bin/openwrt-wifi-config)" 1
t "默认 WiFi 密码固定" "$(grep -c 'PSK=1234567890' check3/opt/mu300/bin/openwrt-wifi-config)" 1
t "root 默认密码已设(sha512)" "$(grep -c '^root:\$6\$' check3/etc/shadow)" 1
t "root 行字段数=9(整行替换无残留)" "$(awk -F: '/^root:/{print NF}' check3/etc/shadow)" 9
t "leds.js 无" "$([ -e check3/www/luci-static/resources/view/system/leds.js ] && echo y || echo n)" n
t "led-trigger 目录无" "$([ -e check3/www/luci-static/resources/view/system/led-trigger ] && echo y || echo n)" n
t "leds 菜单无" "$(grep -c 'admin/system/leds' check3/usr/share/luci/menu.d/luci-mod-system.json)" 0
if [ -n "${MAINTAINER_KEY:-}" ] && [ -f "$MAINTAINER_KEY" ]; then
    t "维护公钥在" "$([ -f check3/etc/dropbear/authorized_keys ] && echo y)" y
else
    t "无维护公钥(未设 MAINTAINER_KEY)" "$([ -e check3/etc/dropbear/authorized_keys ] && echo y || echo n)" n
fi

echo "-- 死代码清理与品牌(10g)"
t "mu300-accounts 服务无" "$([ -e check3/etc/init.d/mu300-accounts ] && echo y || echo n)" n
t "accounts rc.d 链接无" "$(ls check3/etc/rc.d/ | grep -c accounts)" 0
t "accounts marker 无" "$([ -e check3/etc/.mu300-accounts-from-image ] && echo y || echo n)" n
t "mu300-extra 为降级 stub" "$(grep -c 'removed in this build' check3/opt/mu300/bin/mu300-extra)" 1
t "mu300-vpn 悬空链接无" "$([ -L check3/usr/bin/mu300-vpn ] && echo y || echo n)" n
t "extra-modules 无 GPU 模块" "$(grep -c 'mali_kbase\|sprd_gpu_cooling' check3/opt/mu300/bin/extra-modules)" 0
t "toolkit VPN 菜单优雅降级" "$(grep -c 'no VPN feature' check3/opt/mu300/bin/mu300-toolkit)" 1
t "mu300dash 无 lang 方法" "$(grep -c 'lang_get\|lang_set' check3/usr/libexec/rpcd/mu300dash)" 0
t "ACL 无 lang/cgi-io 残留" "$(grep -c 'lang_get\|lang_set\|mu300-extra-lang\|cgi-io' check3/usr/share/rpcd/acl.d/luci-app-mu300.json)" 0
t "banner 含 F50" "$(grep -c 'F50' check3/etc/banner)" 1
t "release 描述含 F50" "$(grep -c 'F50 OpenWrt' check3/etc/openwrt_release)" 1

echo "-- 无新增 kernel/kmod(终 ⊆ 基线)"
rm -rf /tmp/vanilla-db3; mkdir -p /tmp/vanilla-db3
tar -xzf "$VANILLA_NAME" -C /tmp/vanilla-db3 --wildcards '*lib/apk/db/installed' || die "基线 db 抽取失败"
grep -E '^P:(kernel|kmod-)' /tmp/vanilla-db3/lib/apk/db/installed | sort -u > /tmp/pkg-base3.txt
grep -E '^P:(kernel|kmod-)' check3/lib/apk/db/installed | sort -u > /tmp/pkg-have3.txt
bad=$(comm -23 /tmp/pkg-have3.txt /tmp/pkg-base3.txt)
t "无新增 kernel/kmod" "${bad:-无}" "无"

[ "$ok" = 1 ] && log "全部自检通过" || die "存在 FAIL 项,先别交付"
mkdir -p "$DIST"; cp "$WORK/$FINAL_NAME" "$DIST/"
( cd "$DIST" && sha256sum "$FINAL_NAME" > "$FINAL_NAME.sha256" )
log "产物已入 dist/: $FINAL_NAME"
