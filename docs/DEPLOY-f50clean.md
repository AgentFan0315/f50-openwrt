# f50clean 固件部署说明(镜像式:squashfs + overlay)

> English summary below. 基线:[dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux) v2026.10.11 官方 OpenWrt 25.12.5 + 内核 5.4.254(厂商稳定版,可按需自编译降噪)。

本固件相对基线的全部差异见 [CHANGELOG.md](../CHANGELOG.md),构建脚本 `custom/build-clean.sh`(80+ 项自检)。

## 产物(dist/)

| 文件 | 用途 |
|---|---|
| `boot-linux-slotb-f50clean-sq.img` | boot 镜像:内核 5.4.254 + 支持镜像系统的 init(必刷) |
| `mu300-openwrt-luci-25.12.5-f50clean-system.squashfs` | 只读系统底包(已含厂商 android/firmware 文件) |
| `mu300-openwrt-luci-25.12.5-f50clean-rootfs.tar.gz` | 同内容的目录式系统(备用/对比用,无厂商文件) |
| `*.sha256` | 各产物校验值 |

## 部署步骤(两大步,顺序不能反)

### 第一步:刷 boot 镜像(在现有 Linux 系统内 dd,免 fastboot)

boot 镜像替换了内核和 init,必须先刷,否则旧 init 不认识镜像式系统(会继续进目录式系统,不会变砖,但镜像系统用不上)。

```sh
# 推送 dist/boot-linux-slotb-f50clean-sq.img 到设备 /mnt/mu300-disk/ 后,在设备上:
dd if=/mnt/mu300-disk/boot-linux-slotb-f50clean-sq.img of=/dev/block/by-name/boot_b bs=1M
sync
# 回读校验:与 boot-linux-slotb-f50clean-sq.img.sha256 里的值一致才算写入成功
dd if=/dev/block/by-name/boot_b bs=1M count=48 | sha256sum
```

> 校验不符 = 没写进去,重刷;不符就重启可能回 Android(可恢复)。
> 备用法(fastboot):F50 进 bootloader,电脑侧 `fastboot flash boot_b boot-linux-slotb-f50clean-sq.img`。
> 回滚:dd 刷回上游官方 boot 镜像;新 init 同时兼容目录式与镜像式系统。

### 第二步:安装镜像系统(设备 Linux 侧,SSH 操作)

在当前运行的 Linux 系统里:

```sh
# 1. 推送三个文件到 /mnt/mu300-disk/(scp/U盘均可)
#    mu300-openwrt-luci-25.12.5-f50clean-system.squashfs
#    mu300-openwrt-luci-25.12.5-f50clean-system.squashfs.sha256
#    install-f50clean-img-device.sh

# 2. 运行安装脚本
sh /mnt/mu300-disk/install-f50clean-img-device.sh
```

脚本行为(原子,失败不切换不重启,日志 `/mnt/mu300-disk/f50clean-img-install.log`):

- sha256 校验 squashfs → 本机试挂载校验(内核可读、sbin/init、厂商文件、/rom、/overlay)
- 组装 `f50clean.new/` = `system.squashfs` + `image-version` + 空 `data/{upper,work}`
- 现有 `f50clean`(目录式)改名 `f50clean-dir` 留作回滚,`f50clean.new` 顶上
- **配置继承**:当前运行的就是 f50clean 目录式时,/etc/config 与密码自动继承到新系统;否则全新出厂
- 直接写 `boot-os` 切换(绕开旧版 mu300-os 不认识镜像系统的限制),继承 default-boot → 3 秒后自动重启

### 第三步:验证

重启后进 192.168.0.1(或 `ssh root@192.168.0.1`,默认密码 `admin`):

```sh
mount | grep -E 'overlay|squashfs'   # / 是 overlay,/rom 是 squashfs,/overlay 是 upper
mu300-os                             # f50clean 显示 v2026.10.11-f50clean-sq
logread | tail                       # 厂商驱动刷屏应基本消失
```

出厂重置验证(可选,会清空全部设置):LuCI → 系统 → 恢复出厂设置,或 SSH 跑 `/usr/libexec/f50-factory-reset`。

## 回滚

- `mu300-os f50clean-dir` → reboot:回旧目录式 f50clean
- `mu300-os openwrt-luci` → reboot:回官方系统
- 镜像启动失败:boot 计数超限自动回 Android(LK tries 机制),再进 Linux 用 mu300-os 切走

## 目录式 vs 镜像式

| | 目录式 | 镜像式(推荐) |
|---|---|---|
| 系统本体 | 整个活目录 | `system.squashfs` 只读底包 |
| 写入 | 直接写系统目录 | overlay 上层 `data/` |
| 出厂重置 | 不可用(会把系统删成空壳) | 可用(清空 data/ = 回到出厂) |

## 为什么没有 /opt/mu300/android 会断电

PM 协处理器约 290 秒看门狗,只有 Android 的 `modem_control`(chroot)能通过 Trusty 解除(上游 FINDINGS.md 第 5 节)。本镜像的 squashfs **已在构建期合入厂商文件**(opt/mu300/android + lib/firmware),部署时无需再复制。

---

## English

Deploy guide for the f50clean image-style system (squashfs base + overlay data), based on upstream mu300-linux v2026.10.11.

1. **Flash the boot image first** (from a running Linux system on the device): push `dist/boot-linux-slotb-f50clean-sq.img` to `/mnt/mu300-disk/`, then `dd` it to `/dev/block/by-name/boot_b`, `sync`, and read back `dd if=/dev/block/by-name/boot_b bs=1M count=48 | sha256sum` — it must match the shipped `.sha256`. A mismatch means the write did not land: do not reboot.
2. **Install the image system**: push `mu300-openwrt-luci-25.12.5-f50clean-system.squashfs`, its `.sha256`, and `custom/install-f50clean-img-device.sh` to `/mnt/mu300-disk/`, then run `sh /mnt/mu300-disk/install-f50clean-img-device.sh`. The script verifies, assembles `f50clean/` (squashfs + empty `data/{upper,work}`), keeps any old install as `f50clean-dir` for rollback, inherits config when upgrading from directory-style f50clean, switches `boot-os` and reboots.
3. **Verify**: LuCI/SSH at `192.168.0.1` (default root password `admin` — change it). `mount` should show `/` on overlay and `/rom` on squashfs; `mu300-os` shows `v2026.10.11-f50clean-sq`.

Rollback: `mu300-os f50clean-dir` (previous system) or `mu300-os openwrt-luci` (stock). A booting failure auto-falls back to Android via the LK tries mechanism.

The vendor files (`/opt/mu300/android`, `/lib/firmware`) are merged into the squashfs at build time — without them a ~290 s PMIC watchdog powers the device off (upstream FINDINGS.md §5). Never delete `mu300-*` hardware glue services.
