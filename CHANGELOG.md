# 变更日志 / CHANGELOG

基线 / Baseline:[dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux) **v2026.10.11**(`openwrt-luci`,OpenWrt 25.12.5,内核 5.4.254 厂商稳定版)。

全部改动由 `custom/build-clean.sh` 在构建期完成(80+ 项自检),外加 4 个上游文件的补丁。实机验证通过。
All changes are applied at build time by `custom/build-clean.sh` (80+ self-checks), plus patches to 4 upstream files. Verified on-device.

---

## 新增能力 / New capabilities

### 镜像式系统:真正的出厂重置 / Image-style system: real factory reset
- **CN**:系统改为路由器经典布局:只读 `system.squashfs` 底包 + `data/{upper,work}` overlay 可写层(`boot/init` 新增镜像系统支持,挂载 squashfs→`/rom`、overlay→`/`、`data/upper`→`/overlay`)。OpenWrt 自带 `firstboot` 依赖 MTD `rootfs_data` 卷(本机没有,实测静默退出 255),故自实现重置后端 `/usr/libexec/f50-factory-reset`(直擦 overlay upper+work 后重启;后台任务脱离管道,避免浏览器报 "XHR request aborted")+ LuCI 页面(系统 → 恢复出厂设置,中英双语词条)。出厂重置 = 清空 data/ 即回出厂状态。
- **EN**: Classic router layout: read-only `system.squashfs` base + writable `data/{upper,work}` overlay (`boot/init` gained image-system support: squashfs→`/rom`, overlay→`/`, `data/upper`→`/overlay`). OpenWrt's stock `firstboot` needs an MTD `rootfs_data` volume this device doesn't have (it silently exits 255), so a custom reset backend (`/usr/libexec/f50-factory-reset`: wipe overlay upper+work, reboot; background job detached from the pipe so the browser never sees "XHR request aborted") and a LuCI page (System → Factory Reset, zh/en strings). Factory reset = empty `data/`.

### 内核日志降噪 / Kernel log-spam reduction
- **CN**:新增 `kernel/patches/logspam-quiet.patch`(厂商内核树 5 文件 23 处)与 `wlan_combo-logspam-quiet.patch`(wlan 模块树 5 文件 10 处),只把刷屏的 printk 降为调试级别,不改任何逻辑。效果:开机后日志 ~700 行/分 → ~10 行/分。`kernel/build-all.sh` 增加 x86 宿主交叉编译支持(`CROSS_COMPILE=aarch64-linux-gnu-` + Dockerfile 加 gcc-aarch64 工具链)、wlan 模块每次从纯净树重建(补丁栈上下文交叠会骗过"已应用"判定)、`.scmversion` 保持版本串不变。构建期用自编模块覆盖 rootfs `/lib/modules` 同名 .ko(boot 镜像内嵌模块只管 initramfs 阶段,运行时的 .ko 来自 rootfs——这是降噪生效的关键)。
- **EN**: New `kernel/patches/logspam-quiet.patch` (23 sites in 5 vendor-kernel files) and `wlan_combo-logspam-quiet.patch` (10 sites in 5 wlan-module files) — printk demotion only, zero logic change. Boot log volume drops from ~700 to ~10 lines/min. `kernel/build-all.sh` gains x86-host cross-compile support (`CROSS_COMPILE=aarch64-linux-gnu-` + aarch64 gcc in the Dockerfile), rebuilds the wlan module tree from pristine sources every time (overlapping patch context defeats "already applied" detection), and keeps `.scmversion` stable. At build time the self-built modules replace the same-named `.ko` in rootfs `/lib/modules` — the modules embedded in the boot image only serve the initramfs; the running system loads from the rootfs, which is the key to making the quieting stick.

### 防火墙时序修复(上游缺陷)/ Firewall timing fix (upstream defect)
- **CN**:上游 10.11 的防火墙在开机时因 S19/S20 时序竞争 + 5.4 内核 flowtable 重建缺陷,lan/wan zone 规则间歇性整体缺失(DHCP 不分配、LuCI 打不开、NAT 全死,但 ping 通)。修复:lan/wan zone 静态绑定 `br-lan`/`sipa_eth0`,不再依赖运行时接口名解析。完整根因与验证过程:[docs/FIX-firewall-zone-timing.md](docs/FIX-firewall-zone-timing.md)。与上游 issue #45 同症。
- **EN**: On upstream 10.11 an S19/S20 startup race plus a 5.4-kernel flowtable rebuild defect intermittently leaves the lan/wan zone rules missing entirely (no DHCP, LuCI unreachable, NAT dead — while the device still pings). Fix: statically bind the lan/wan zones to `br-lan`/`sipa_eth0` instead of relying on runtime interface-name resolution. Full root cause and verification: [docs/FIX-firewall-zone-timing.md](docs/FIX-firewall-zone-timing.md). Same symptom as upstream issue #45.

### `boot/init` 镜像系统引导 / Image-system booting in `boot/init`
- **CN**:`pick_root` 识别含 `system.squashfs` 的系统目录;挂载失败记入 stage=root-image-FAILED 并回 Android,不静默改道其他系统。新旧两种系统(目录式/镜像式)同一份 init 都认。
- **EN**: `pick_root` recognizes system directories containing `system.squashfs`; a mount failure is logged as `stage=root-image-FAILED` and falls back to Android instead of silently rerouting. One init handles both legacy directory systems and image systems.

## 移除 / Removed

- **CN**:
  - 在线包管理:清空 `/etc/apk/repositories`、删 LuCI 软件管理页(**保留 apk 本体**,可装本地 .apk)
  - LuCI 刷机页(flash.js + repokeys)
  - `mu300-update` 全链(二进制、定时检查、登录提示;toolkit 菜单优雅降级为"不可用"提示)
  - 官方 VPN 全家:wireguard-tools、luci-proto-wireguard、ppp 全家、xl2tpd、gre、mu300-vpn(VLESS 隧道,面板无引用)+ 对应 kmod 占位
  - GPU 驱动死文件(mali_kbase.ko / sprd_gpu_cooling.ko,无 autoload 条目、无任何引用)
  - aurora 主题(默认 bootstrap)、土耳其语 i18n、mu300 面板 Languages 页、LED 配置页(**不碰** mu300-led 硬件服务)
  - 死代码:mu300-accounts(每开机报 not found)、mu300-vpn 悬空符号链接、mu300dash 的 lang_get/lang_set 死方法
- **EN**:
  - Online package management: `/etc/apk/repositories` emptied, LuCI software page removed (**the `apk` binary stays** for local installs)
  - LuCI flash page (flash.js + repokeys)
  - The entire `mu300-update` chain (binary, scheduled checks, login banner; the toolkit menu degrades gracefully to an "unavailable" notice)
  - The stock VPN bundle: wireguard-tools, luci-proto-wireguard, ppp family, xl2tpd, gre, mu300-vpn (VLESS tunnel, unreferenced by the panel) + kmod placeholders
  - Dead GPU driver files (mali_kbase.ko / sprd_gpu_cooling.ko — no autoload entries, no references)
  - aurora theme (bootstrap is default), Turkish i18n, the mu300 panel Languages page, the LED config page (the `mu300-led` hardware service is **untouched**)
  - Dead code: mu300-accounts (logged "not found" every boot), dangling mu300-vpn symlinks, mu300dash's dead lang_get/lang_set methods

## 修改 / Changed

- **CN**:
  - 品牌:hostname mu300 → **f50**,`/etc/banner`、`/etc/openwrt_release` 同步(board_name/sysinfo 不动,mu300-* 脚本可能依赖)
  - 默认 LAN IP 192.168.77.1 → **192.168.0.1**(改 mu300-lan-ip 默认值单一来源,netifd/90-mu300、lan-start、toolkit 提示全部跟随)
  - `default-boot=linux` 打进底包(否则出厂重置清空 overlay 后掉回单次试用,重启回 Android)
  - 默认语言中文(删 `91-mu300-luci` 首启强制 en/aurora 的块,重置后不回弹英文);LuCI 语言列表删硬编码 tr 行(列表在 `/etc/config/luci`,不扫 lmo)
  - 默认 WiFi `ZTE_BCB57A` / `1234567890`;root 默认密码 `admin`(sha512-crypt,整行替换 shadow——只换前缀会让 musl 解析失败锁死账号)
  - `mu300-os` 识别镜像系统(is_system/image-version/default-boot 继承三处补丁)
  - `mu300-extra` 换降级 stub(link 空操作兼容 mu300-post);extra-modules 不再 modprobe 已删的 GPU 驱动(消除每开机 2 行 FAILED);toolkit VPN 菜单改不可用提示;mu300dash ACL 收紧
  - LuCI 系统日志页与 `logread` 默认过滤厂商驱动噪音(页面勾选框可临时显示,`logread-raw` 看原始)
  - `install.ps1` 两处健壮性修复:eMMC 末端越界探测守卫(32GB 机型探测必死循环);`tar -xzf mu300-kernel.tar.gz` 静默产空目录时明确报错而非事后才发现 kernel\busybox 缺失
- **EN**:
  - Branding: hostname mu300 → **f50**, `/etc/banner` and `/etc/openwrt_release` updated (board_name/sysinfo untouched — mu300-* scripts may depend on them)
  - Default LAN IP 192.168.77.1 → **192.168.0.1** (single source of truth in mu300-lan-ip; netifd/90-mu300, lan-start and toolkit hints all follow it)
  - `default-boot=linux` baked into the base image (otherwise a factory reset wipes the overlay and drops back to one-shot trial mode, i.e. Android on next boot)
  - Default language Chinese (removed the first-boot block in `91-mu300-luci` that forced en/aurora, which bounced the language back after every reset); hardcoded `tr` entry removed from the LuCI language list (the list lives in `/etc/config/luci`, no lmo scan)
  - Default WiFi `ZTE_BCB57A` / `1234567890`; default root password `admin` (sha512-crypt, whole-line `shadow` replacement — replacing only the prefix breaks musl parsing and locks the account)
  - `mu300-os` recognizes image systems (three patches: is_system / image-version / default-boot inheritance)
  - `mu300-extra` replaced with a degrading stub (link no-op keeps mu300-post working); extra-modules no longer modprobes the removed GPU drivers (kills 2 FAILED lines per boot); toolkit VPN menus show an "unavailable" notice; tighter mu300dash ACL
  - LuCI syslog page and `logread` filter vendor driver noise by default (checkbox on the page shows everything, `logread-raw` gives the raw feed)
  - `install.ps1` robustness: guard against probing past the end of the eMMC (on 32 GB models the probe hit a toybox `dd` lseek path that never finishes); fail loudly when `tar -xzf mu300-kernel.tar.gz` silently produces an empty directory instead of surfacing later as a missing `kernel\busybox`

## 保持不变 / Deliberately untouched

- **CN**:全部 `mu300-*` 硬件胶水服务(vendor/mobile-data/atd/boot-ok/next-boot/led/thermal-guard/lan/hotspot/wifi-client)与基线逐项 diff 一致;kanoqwq 面板、sqm、6in4/6rd/ds-lite(IPv6 过渡,非 VPN);约 10 个 Ubuntu 路径脚本空载携带(无害,保留)。盘点确认:固件无遥测、无后台轮询、无自动联网下载(仅 toolkit 手动测速走 Cloudflare)。
- **EN**: every `mu300-*` hardware glue service (vendor/mobile-data/atd/boot-ok/next-boot/led/thermal-guard/lan/hotspot/wifi-client) is diff-identical to baseline; the kanoqwq panel, sqm, and 6in4/6rd/ds-lite (IPv6 transition, not VPN); ~10 Ubuntu-path scripts ride along inert (harmless, kept). Audit conclusion: no telemetry, no background polling, no automatic downloads (only the manually triggered Cloudflare speed test in the toolkit).
