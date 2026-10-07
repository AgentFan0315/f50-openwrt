# f50-openwrt

**尽可能干净的 OpenWrt 体验,运行在中兴 F50 上。**
**The cleanest possible OpenWrt experience on the ZTE F50.**

---

## 致谢 / Acknowledgements

**本项目是 [dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux) 的衍生分支。** 让中兴 F50(以及 MU300)跑起 Linux 的全部硬核工作——展锐 UMS9620 平台逆向、双系统引导链、Android chroot 保活、基带/Wi-Fi/温控驱动整合、35 节 FINDINGS 逆向档案——全部来自上游作者 [@dikeckaan](https://github.com/dikeckaan) 与上游社区的贡献者。本仓库只是在他们打好的地基上,做了一层"纯净 OpenWrt 体验"的薄定制。**没有上游项目就没有本仓库,请优先给上游点 Star。** 上游原版的完整 README(功能全览、支持设备矩阵、工具箱介绍)原样保留在 [README-upstream.md](README-upstream.md)。

**This project is a derivative fork of [dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux).** All of the hard work — reverse-engineering the Spreadtrum UMS9620 platform, the dual-boot chain, the Android chroot keep-alive, modem/Wi-Fi/thermal integration, and the 35-section FINDINGS archive — was done by upstream author [@dikeckaan](https://github.com/dikeckaan) and the upstream community. This repository is only a thin "clean OpenWrt experience" layer on top of that foundation. **Please star the upstream project first; this repo would not exist without it.** Upstream's full original README (feature overview, supported-device matrix, toolkit) is preserved verbatim in [README-upstream.md](README-upstream.md)。

---

## 这是什么(中文)

上游 mu300-linux 把 F50 变成 Android + Linux 双系统设备,功能强大,但官方 OpenWrt 系统带有在线包管理、自动更新检查、VPN 全家桶等组件。本项目以**上游 v2026.10.11 官方 openwrt-luci rootfs 为基线**,只做少量克制的修改,目标是:

- **纯净**:无在线软件源(保留 apk 本体可装本地包)、无刷机页、无任何自动更新/遥测/后台轮询
- **可重置**:系统改成路由器经典布局——只读 `system.squashfs` 底包 + overlay 可写层,**出厂重置真正可用**(LuCI 一键恢复出厂)
- **安静**:自编译内核把展锐厂商驱动的刷屏 printk 降级(日志 ~700 行/分 → ~10 行/分),LuCI 日志页另有过滤器
- **修复**:内置上游 10.11 防火墙时序缺陷的修复(开机后 DHCP/LuCI/NAT 间歇全死,见 [docs/FIX-firewall-zone-timing.md](docs/FIX-firewall-zone-timing.md))
- **安全默认之外的一切保持上游原样**:全部 `mu300-*` 硬件胶水服务与基线逐项 diff 一致

与上游的完整差异清单(中英双语)见 [CHANGELOG.md](CHANGELOG.md)。

### 默认值(首次登录后请立即修改)

| 项 | 值 |
|---|---|
| 管理地址 | http://192.168.0.1 |
| root 密码 | `admin` |
| WiFi SSID / 密码 | `ZTE_BCB57A` / `1234567890` |
| 默认语言 | 中文(LuCI 可切英文) |

> **安全提醒**:以上都是公开的出厂默认值,任何能连上设备的人都能登录。首次使用请务必修改 root 密码和 WiFi 密码。

### 构建

本仓库**不发布成品固件**(固件内含展锐专有基带固件与 Android vendor 文件,再分发权利不在我们手里)。你需要自行构建,输入全部来自上游官方 release:

1. 准备一台 Linux 环境(WSL2 Ubuntu 即可),需要 root、qemu-user-static、squashfs-tools
2. **构建输入**(详见脚本头部注释):
   - `VANILLA_SRC` — 上游 v2026.10.11 release 的 `mu300-openwrt-luci-rootfs.tar.gz`
   - `VENDOR_TAR` — 厂商 android/firmware 打包。**它不在任何 release 里**(专有文件,只能来自你自己的设备):在跑着任一 mu300 Linux 系统的设备上,一条命令生成——`bash custom/make-vendor-tar.sh ssh root@192.168.0.1`
   - `KERNEL_OUT` — 可选,自编译降噪内核输出(`kernel/build-all.sh` 的产物);不设则使用基线模块
   - `MAINTAINER_KEY` — 可选,你的 SSH 公钥路径,构建进镜像用于密钥登录
3. 构建 rootfs:`bash custom/build-clean.sh`(约 1 分钟,80+ 项自检)
4. 构建 boot 镜像与内核:见上游 `docs/BUILD.md`,本仓库对其的改动只有交叉编译支持与降噪补丁(`kernel/patches/logspam-quiet.patch`、`wlan_combo-logspam-quiet.patch`)
5. 部署到设备:见 [docs/DEPLOY-f50clean.md](docs/DEPLOY-f50clean.md)
6. **跟随上游主线**(新 release 怎么跟、内核补丁怎么 rebase、设备怎么升级):[docs/TRACKING-UPSTREAM.md](docs/TRACKING-UPSTREAM.md)

### 红线(沿自上游,违反可能变砖或断电)

- **禁止改动任何 `mu300-*` 硬件胶水服务**(vendor/mobile-data/atd/boot-ok/next-boot/led/thermal-guard/lan/hotspot/wifi-client)——删掉 `mu300-vendor` 约 290 秒后 PMIC 切断整机电源
- **禁止 sysupgrade、禁止刷任何官方固件镜像**
- **禁止从 OpenWrt 官方源安装 `kernel` / `kmod-*` 包**

---

## What this is (English)

Upstream mu300-linux turns the F50 into an Android + Linux dual-boot device. It's powerful, but the stock OpenWrt system ships with online package management, update checks, a VPN bundle, and more. This fork takes **upstream's official v2026.10.11 openwrt-luci rootfs as the baseline** and makes only a small, restrained set of changes:

- **Clean**: no online package feeds (the `apk` binary stays for local `.apk` installs), no flash/upgrade pages, no auto-updates, no telemetry, no background polling
- **Resettable**: the classic router layout — a read-only `system.squashfs` base plus an overlay data layer — so **factory reset actually works** (one click in LuCI)
- **Quiet**: a self-built kernel demotes the Spreadtrum vendor drivers' printk spam (~700 → ~10 log lines/min), plus an optional filter on the LuCI log page
- **Fixed**: carries a fix for upstream 10.11's firewall timing defect (intermittent total loss of DHCP/LuCI/NAT after boot — see [docs/FIX-firewall-zone-timing.md](docs/FIX-firewall-zone-timing.md))
- **Everything else identical to upstream**: all `mu300-*` hardware glue services are diff-verified against the baseline

The full bilingual change list is in [CHANGELOG.md](CHANGELOG.md).

### Defaults (change them on first login)

| Item | Value |
|---|---|
| Management UI | http://192.168.0.1 |
| root password | `admin` |
| WiFi SSID / password | `ZTE_BCB57A` / `1234567890` |
| Default language | Chinese (English selectable in LuCI) |

> **Security note**: these are public factory defaults — anyone who can reach the device can log in. Change the root and WiFi passwords immediately.

### Build

**No prebuilt firmware is published** (the image contains proprietary Spreadtrum baseband firmware and Android vendor files whose redistribution rights are not ours to grant). Build it yourself — all inputs come from upstream's official releases:

1. A Linux environment (WSL2 Ubuntu works) with root, qemu-user-static and squashfs-tools
2. **Build inputs** (see the header of `custom/build-clean.sh`):
   - `VANILLA_SRC` — `mu300-openwrt-luci-rootfs.tar.gz` from upstream release v2026.10.11
   - `VENDOR_TAR` — the vendor android/firmware tarball. **It is in no release** (proprietary files that can only come from your own device): generate it with one command from a device running any mu300 Linux system — `bash custom/make-vendor-tar.sh ssh root@192.168.0.1`
   - `KERNEL_OUT` — optional, output of a self-built quiet kernel (`kernel/build-all.sh`); falls back to baseline modules when unset
   - `MAINTAINER_KEY` — optional SSH public key baked into the image for key login
3. Build the rootfs: `bash custom/build-clean.sh` (~1 minute, 80+ self-checks)
4. Boot image & kernel: see upstream `docs/BUILD.md`; our only changes there are x86 cross-compile support and the log-spam patches
5. Deploy: [docs/DEPLOY-f50clean.md](docs/DEPLOY-f50clean.md)
6. **Tracking upstream** (new releases, kernel patch rebases, device upgrades): [docs/TRACKING-UPSTREAM.md](docs/TRACKING-UPSTREAM.md)

### Red lines (inherited from upstream — breaking them can brick or power off the device)

- **Never touch any `mu300-*` hardware glue service** — removing `mu300-vendor` makes the PMIC cut power ~290 s later
- **No `sysupgrade`, no flashing stock firmware images**
- **Never install `kernel` / `kmod-*` packages from OpenWrt feeds**

---

## 许可证 / License

[MIT](LICENSE) — 与上游一致,保留上游版权声明。Same as upstream; the upstream copyright notice is retained.
