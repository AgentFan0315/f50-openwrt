# AGENTS.md — mu300-linux OpenWrt 定制开发

本文件是 AI 开发助手的工作约定。所有事实均来自对上游项目 dikeckaan/mu300-linux 文档（README、docs/BUILD.md、docs/DISTROS.md、docs/FINDINGS.md，2026-10 版本）的核实，禁止凭记忆推翻本文事实；发现矛盾时以仓库内文档为准并提示用户。

## 一、项目背景（必读）

- 本项目把中兴 F50（紫光展锐 UMS9620 / T760，2GB RAM 其中 1.4GB 可用）变成双系统设备：Android + Linux（Ubuntu / OpenWrt），双系统单跑，`mu300-os <name>` 切换，启动失败自动回 Android。
- **本项目不是 OpenWrt 官方项目**。OpenWrt / LEDE / ImmortalWrt 均没有 UMS9620 target，不存在 `make menuconfig` 路线。
- 这里的"构建 OpenWrt"是**组装**：官方 armsr/armv8 现成 tarball + `apk add` 装包 + 注入本项目自己的内核模块 + 覆盖 overlay 文件。入口脚本：`openwrt/build-rootfs.sh`。
- 内核三选一，全部来自本项目：5.4 展锐厂商内核（最稳，长期运行默认选它）/ 6.18 主线（实验性，FINDINGS 31m 记录约 2/50 的启动早期硬挂起）/ 7.2。本项目**不编译 OpenWrt 源码，但编译内核**（docker 中进行）。
- OpenWrt 25.12 用 `apk`，不是 opkg。官方源的 `apk upgrade` 可用，**唯独 `kernel` 和 `kmod-*` 包禁止安装**（内核是自定义构建，版本不匹配直接拒装或崩溃）。
- tailscale / zerotier / shadowsocks 需要的 `/dev/net/tun` 在两个内核上都已具备（项目自带 VPN extra 的 hev-socks5-tunnel 在用），三者均为纯用户态，无 kmod 依赖。
- 文档地图：改构建先看 `docs/BUILD.md`；部署自定义系统看 `docs/DISTROS.md`；动任何硬件相关代码前查 `docs/FINDINGS.md`（35 节逆向档案，含症状→根因→修复）。
- 变体注意：`MU300_FLAVOUR=immortalwrt` 可构建 ImmortalWrt 版 rootfs，但 `MU300_SYSTEM=openwrt-luci` 与 immortalwrt 组合被构建脚本显式拒绝。

## 二、开发环境约定

- 宿主：Windows 11 + WSL2（Ubuntu）。**所有 git 操作和构建都在 WSL 内完成**；克隆前 `git config --global core.autocrlf false`，禁止在 Windows 侧克隆后跨文件系统使用（CRLF 会杀死所有 bash 脚本）。
- Docker Engine 装在 WSL2 内部（非 Docker Desktop）。构建脚本以 docker 容器为执行环境，宿主机只提供 bash + docker。
- 所有 shell 脚本、配置文件保持 LF 行尾。
- 设备物理操作（SPD 刷机、adb、串口）由用户在 Windows 原生环境手动执行，**不属于本 agent 的职责范围**；agent 只产出构建产物和书面操作步骤。

## 三、本次开发目标（终版固件，不做后续更新）

> **已知上游缺陷（2026-10-07 查明，必须在定制构建中内置修复）**：官方 10.11 防火墙因 S19/S20 时序竞争 + 5.4 内核 flowtable 重建 bug，每次开机 lan/wan 区规则缺失（DHCP、LuCI、NAT 全死）。修复：lan/wan zone 静态绑定 `br-lan`/`sipa_eth0`。根因与验证见 `docs/FIX-firewall-zone-timing.md`。设备上已修复；定制 rootfs 必须带同样两条 uci 绑定。

优先级从高到低（基线：**上游 v2026.10.11 openwrt-luci rootfs**，少量修改，其余保持原样）：

1. **G1 品牌**：系统标识 mu300 → f50。范围：`/etc/config/system` hostname、`/etc/banner`、`/etc/openwrt_release` 描述。**不动** board_name/sysinfo（mu300-* 脚本可能依赖），先做最小集再验证。
2. **G2 去除软件包管理与在线安装**：清空 `/etc/apk/repositories`；移除 LuCI 软件管理页相关组件；**保留 apk 二进制**以便装本地 .apk（禁止删 apk 本体）。
3. **G3 去除 OpenWrt 官方更新**：owut / attendedsysupgrade 及 LuCI 对应升级页（sysupgrade 本身属红线，本就不允许用）。
4. **G4 去除 mu300 更新**：`mu300-update` 二进制、定时检查入口、登录提示；`mu300-toolkit` 对应菜单项优雅降级（不可用提示），不能报错循环。
5. **G5 代理组件**：
   - helloworld（fw876）的 **shadowsocksR 完整功能与插件**（luci-app-ssr-plus 全家桶 + simple-obfs / v2ray-plugin / xray-plugin 等）。
   - **硬约束：LuCI 面板（luci-app-ssr-plus）必须可用；面板不可用则整套 SSR 都不装**，不做"只装命令行"的降级。
   - **tailscale、zerotier**（官方 apk 源已有，优先官方源；lean/kenzok8 源仅作备选）。
   - 关键技术约束：25.12 是 **apk** 系统，helloworld/lean 是 **ipk(opkg)** 生态 → 二进制优先取 ImmortalWrt 25.12 apk 源（含 shadowsocksr-libev 等）；luci-app-ssr-plus 为 noarch，可从 ipk 手工解包装入并验证 LuCI 兼容性。
6. **G6 交付物**：可部署 rootfs tar.gz + 一页部署说明（参照 docs/DISTROS.md）。

> **G5 已撤销（2026-10-07 用户决定）**：SSR/tailscale/zerotier 均不预装，最终目标为**纯净版**（f50clean）。三者在官方 apk 源随时可装，设备上自行 `apk add` 即可（/dev/net/tun 已具备）。

## 三点五、镜像式系统与内核降噪（2026-10-07，用户明确批准，红线 4 豁免）

- **镜像式布局（路线 2）**：系统目录从活目录改为 `system.squashfs`（只读底包）+ `data/{upper,work}`（overlay 可写层）。`boot/init` 的 `pick_root` 认 `system.squashfs`，启动时挂 squashfs→`/rom`、overlay→`/`、upper→`/overlay`；挂载失败记 `stage=root-image-FAILED` 并回 Android（不做静默兜底）。`mu300-os` 已补丁：is_system 认镜像、版本号回退读容器级 `image-version`、default-boot 继承写 `data/upper/etc/mu300/`。
- **出厂重置**:OpenWrt 自带 `factoryreset`/`firstboot` 依赖 MTD `rootfs_data` 卷(本机没有,实测静默退出 255,**不可用**);故 `/usr/libexec/f50-factory-reset` 后端自实现——直接清空 overlay 数据层(`data/upper`+`data/work`)后重启,语义同 jffs2reset 的 "only erasing files"。LuCI「系统 → 恢复出厂设置」页走此后端,非镜像系统拒绝执行。`default-boot=linux` 已打进底包(2b 步),否则重置清空 upper 后会退回单次试用模式掉回 Android。**目录式系统上禁止使用 factoryreset/firstboot**(会把系统删成空壳)。两个实现细节:后端后台子 shell 必须 `>/dev/null 2>&1 &` 脱离管道(否则浏览器报 XHR aborted);前端 reset.js 为宽容模式——先弹"正在重置"再发 exec,传输层错误 8 秒后探测设备活性,仍在线才报失败(重置=重启,连接中断是预期行为)。
- **内核降噪（方案 B）**：`kernel/patches/logspam-quiet.patch`（厂商树 5 文件）+ `kernel/patches/wlan_combo-logspam-quiet.patch`（wlan_combo 模块树 4 文件），把展锐驱动刷屏 printk 降级为 debug 级；只改日志级别，不改任何硬件行为。生成脚本留档 `custom/apply-logspam.sh`。
- **x86 宿主交叉编译 5.4 内核必须** `CROSS_COMPILE=aarch64-linux-gnu-`（已写进 `kernel/build-all.sh`；kbuild 镜像已装 gcc-aarch64-linux-gnu）。内核 release 串靠 `.scmversion` 机制保持 `5.4.254-gb50db5b6224c` 不变，模块兼容。
- **构建入口**：`custom/build-clean.sh`（WSL2 root 直跑，qemu+binfmt 操作 arm64 rootfs，82 项自检）；产物 = 目录式 tar.gz + squashfs 镜像 + `dist/boot-linux-slotb-f50clean-sq.img`（boot 镜像构建命令见 `custom/DEPLOY.md` 与 build-boot-image.py 调用处）。设备侧安装脚本 `custom/install-f50clean-img-device.sh`（原子：校验→试挂→f50clean.new→换名→切换→重启；旧目录式系统保留为 `f50clean-dir`）。
- **默认值（10f）**：root 密码 `admin`（sha512-crypt 写进底包 `/etc/shadow`）；可选维护公钥（构建时设 `MAINTAINER_KEY=<公钥路径>` 才装进 `/etc/dropbear/authorized_keys`，仓库不带任何密钥）；默认 WiFi `ZTE_BCB57A`/`1234567890`（改 `openwrt-wifi-config` 兜底分支）；LuCI 语言下拉删硬编码 tr 行（列表在 `/etc/config/luci` 的 languages 段，不扫 lmo）、默认中文；**删 `91-mu300-luci` 里首启强制 `mediaurlbase=aurora`/`lang=en` 的块**（否则重置后顶掉底包设置——实机踩过）；删 LED 配置页（`admin/system/leds`，不碰 mu300-led）。**overlay 特性**：upper 只存改过的文件，`/etc/shadow` 等未改文件直接跟随底包——换 squashfs 底包即换默认密码，无需重置。
- **部署流程**：先 fastboot 刷 boot 镜像（新内核+新 init），再推 squashfs 跑安装脚本。顺序不能反（旧 init 不认识镜像式系统）。
- **死代码清理（10g，2026-10-07 全组件盘点后）**：删 `mu300-accounts`（服务+rc.d+底包 marker；它只调已删的 mu300-update，属软件迁移件非命保护）；`mu300-extra` 换降级 stub（`link` 空操作兼容 mu300-post，其余子命令报错）；删 `/usr/bin/mu300-vpn` 悬空链接；`extra-modules` 去掉 GPU modprobe；toolkit `menu_vpn` 改不可用提示；`mu300dash` 删 `lang_get/lang_set` 死方法（注意 do_list JSON 尾逗号）+ ACL 收紧（lang 方法、cgi-io upload、lang 包上传路径）；`/etc/banner`、`openwrt_release` 补 f50 品牌。盘点结论：固件无遥测/无后台轮询/无自动联网下载（仅 toolkit 手动测速走 Cloudflare）；命保护组件运行态全部核实在位。空载携带（Ubuntu 路径脚本 lan-start/hotspot-* 等约 10 个）保留不拆——与 Ubuntu 共用 bin 目录，不执行不占资源。

## 四、红线（违反可能导致变砖或设备断电，逐条硬约束）

1. **禁止改动任何 `mu300-*` 前缀的硬件胶水服务**，包括但不限于：`mu300-vendor`（Android chroot 守护进程，删除后约 290 秒 PMIC 切断整机电源）、`mu300-mobile-data`、`mu300-atd`、`mu300-boot-ok`、`mu300-next-boot`、`mu300-led`、`thermal-guard`、`mu300-lan`、`mu300-hotspot`、`mu300-wifi-client`。判别原则：维护 misc/slot、供电看门狗、基带通道、温控的 = 命保护，一律不碰；管理"软件"的 = 可拆。
2. **禁止 `sysupgrade`、禁止刷任何官方/标准固件镜像**（会把存储布局整个覆写）。
3. **禁止从 OpenWrt 官方源安装 `kernel` / `kmod-*`**。
4. 禁止修改内核补丁、`boot/` 下引导链相关脚本、`misc` 写入逻辑——除非任务书明确要求并单独评审。
5. 不确定的事明确说不确定；禁止编造未验证的设备行为；引用结论时标注出处文档与章节。

## 五、工作方式与验收

- 动手前先读对应文档章节；每个改动给出：改动理由 → 构建命令 → 部署方法 → 验证命令与预期输出。
- 构建失败先看 docker 环境（镜像是否重建、volume 是否陈旧），再看脚本逻辑。
- 每完成一个 G 目标，输出该项的验收清单自检结果。
- G1 验收：hostname/ banner / openwrt_release 均为 f50 标识；mu300-* 服务与脚本功能不受影响。
- G2/G3/G4 验收：`/etc/apk/repositories` 无远程源；apk 二进制在；LuCI 无软件管理与固件升级页；owut/attendedsysupgrade 不存在；`mu300-update` 不存在且无残留定时入口；toolkit 菜单优雅降级；`mu300-*` 服务清单与原镜像 `diff /etc/init.d` 无差异。
- G5 验收：tar.gz 解包后可见 ssr-plus 的 LuCI 页与 SSR 系列二进制及插件、tailscale、zerotier；`/etc/init.d/` 有对应服务；LuCI 里 ssr-plus 页可打开。
- 通用验收：新固件必须内置 lan/wan zone 静态设备绑定（见上方缺陷注记），部署后热点 DHCP + LuCI + 上网一次通过。

## 六、上次交付(2026-10-06,已被 10.11 基线新目标取代,仅留作实现参考)

- 构建入口:`custom/build-final.sh`(WSL2 Ubuntu 内以 root 跑 `bash ~/mu300-custom/build-final.sh`;基线为上游 v2026.10.10 `mu300-openwrt-rootfs.tar.gz`,SHA256 校验;用镜像自带 arm64 apk + qemu-user-static + binfmt_misc 直接操作解包树,不走 docker)。
- 产物:`dist/mu300-openwrt-25.12.5-final-rootfs.tar.gz`(SHA256 `00cf4c4b…93590ef`)+ `dist/DEPLOY.md`(G4 一页部署说明)。
- 关键实现注记:OpenWrt 25.12 的 apk 在 `/usr/bin/apk`;本地源要把 `-X` 直指 `packages.adb` 文件;kmod-tun 依赖用 `apk add --virtual kmod-tun` 空虚拟包满足(OpenWrt 版 apk 3.0.5 砍掉了 mkpkg);shadowsocks-rust 取自 ImmortalWrt 25.12.2 源(官方源无 shadowsocks 全系列)。
- 复核脚本:`custom/verify.sh`(解包树抽检:world 差异、installed db 无远程 URL、toolkit 守卫、init.d diff)。
