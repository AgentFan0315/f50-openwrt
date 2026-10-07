# 跟随上游主线 / Tracking Upstream

本仓库是 [dikeckaan/mu300-linux](https://github.com/dikeckaan/mu300-linux) 的 git 级分支(保留全部历史,我们的改动是独立的 5 个提交)。上游更新非常活跃,本文档说明如何随时跟随主线、并把修复落到设备上。

This repo is a git-level fork of upstream (full history preserved; our changes are a handful of separate commits on top). Upstream moves fast — this document explains how to follow it and get fixes onto your device at any time.

---

## 一、仓库层:跟上上游代码(中文)

```bash
git fetch origin                 # origin = dikeckaan/mu300-linux
git log --oneline HEAD..origin/main   # 看看上游新加了什么
git rebase origin/main           # 把我们的提交叠到最新上游之上
# 冲突面很小:我们只碰 boot/init、install.ps1、kernel/build-all.sh、
# kernel/Dockerfile、kernel/patches/* 和 custom/、docs/ 下的自有文件
```

## 二、基线层:换新 rootfs

`custom/build-clean.sh` 把基线钉死在两个常量上:

```bash
VANILLA_NAME=mu300-openwrt-luci-rootfs.tar.gz
VANILLA_SHA=cbe33098...   # 上游 release 页 SHA256SUMS 里的值
```

上游出新 release 时:下载新 rootfs → 更新这两行 → 重跑构建。**构建脚本里 80+ 项断言/自检会精确告诉你基线的哪一处结构变了**(例如某文件不存在了、某配置段改了名),按提示适配对应步骤即可。如果上游已把某项修复内置(比如防火墙 zone 绑定),直接删掉 build-clean.sh 里对应的步骤。

## 三、内核层:跟内核与补丁

`kernel/build-all.sh` 钉死 `KERNEL_REV` / `MODULES_REV`。上游 bump 内核版本时,`kernel/patches/logspam-quiet.patch`、`wlan_combo-logspam-quiet.patch` 可能需要 rebase——补丁应用失败会在 docker 构建里直接报错(`patch` 非零退出),不会静默通过。补丁只降 printk 级别,rebase 基本就是挪上下文行。

## 四、设备层:把修复落到 F50

设备上**始终保留上游官方系统**(`mu300-os openwrt-luci` 可随时切回),这是跟随主线的锚点:

1. 切到官方系统:`mu300-os openwrt-luci && reboot`
2. 官方系统里 `mu300-update` 还在(f50clean 删了它,官方没删):`mu300-update check && mu300-update apply`
3. 官方系统升到新版后,用它做构建环境参照,或直接在新基线上重跑 `custom/build-clean.sh`
4. 厂商文件有变动时,从跑着官方系统的设备重新打包:`bash custom/make-vendor-tar.sh ssh root@192.168.77.1`
5. 按 [DEPLOY-f50clean.md](DEPLOY-f50clean.md) 部署新构建;旧的 f50clean 会保留为 `f50clean-dir` 供回滚

回滚链:`f50clean 新版 → f50clean-dir → openwrt-luci(官方)→ Android`,每一环都经过验证。

---

## English

### Repository level

```bash
git fetch origin                 # origin = dikeckaan/mu300-linux
git log --oneline HEAD..origin/main
git rebase origin/main
```

The conflict surface is small: we only touch `boot/init`, `install.ps1`, `kernel/build-all.sh`, `kernel/Dockerfile`, `kernel/patches/*`, plus our own files under `custom/` and `docs/`.

### Baseline level

`custom/build-clean.sh` pins the baseline with two constants (`VANILLA_NAME`, `VANILLA_SHA`). On a new upstream release: download the new rootfs, update those two lines, rebuild. The script's 80+ assertions/self-checks will pinpoint exactly which upstream structure changed; adapt the corresponding step — or delete it when upstream has absorbed the fix (e.g. the firewall zone bindings).

### Kernel level

`kernel/build-all.sh` pins `KERNEL_REV` / `MODULES_REV`. When upstream bumps them, the logspam patches may need a rebase — a patch failure fails the docker build loudly, never silently. The patches only demote printk levels, so rebasing is mostly context-line shuffling.

### Device level

Always keep the stock upstream system on the device (`mu300-os openwrt-luci` switches back anytime) — it is your anchor:

1. `mu300-os openwrt-luci && reboot`
2. Stock still has `mu300-update` (f50clean removes it, stock doesn't): `mu300-update check && mu300-update apply`
3. Rebuild f50clean on the new baseline
4. If vendor files changed, repack them from the device running stock: `bash custom/make-vendor-tar.sh ssh root@192.168.77.1`
5. Deploy per [DEPLOY-f50clean.md](DEPLOY-f50clean.md); the previous f50clean is kept as `f50clean-dir` for rollback

Rollback chain: `f50clean new → f50clean-dir → openwrt-luci (stock) → Android` — every link verified.
