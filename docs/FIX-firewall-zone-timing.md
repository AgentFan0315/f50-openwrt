# 局域网全断问题根因分析与修复(firewall zone 时序 + 5.4 flowtable bug)

日期:2026-10-07
影响版本:官方 openwrt-luci v2026.10.11(内核 5.4.254),全新安装必现;v2026.10.08 升级后同样出现。
状态:**已修复并验证**(运行时修复 + 重启后开机渲染一次到位)。

## 一、现象

- 升级 v2026.10.11 后:LuCI 管理界面打不开,Wi-Fi 客户端拿不到 IP("有网但进不去管理页")。
- 全新重装官方 openwrt-luci 后完全复现 → 不是残留状态,是系统性问题。
- 手机可以搜到并关联热点 `ZTE_BCB57A`,WPA2 握手完成,但 DHCP 无响应,约 16~18 秒后手机放弃并断开,表现为"连不上"。
- USB 连 PC 同样拿不到地址 / 进不了管理页。

## 二、排查路径与关键证据

分层取证,逐层排除:

| 层 | 方法 | 结果 |
|---|---|---|
| 关联层 | `logread` 观察 hostapd | `AP-STA-CONNECTED` + `EAPOL-4WAY-HS-COMPLETED` → 关联/认证正常 |
| 网卡入口 | `nft` netdev 族 ingress 探针(wlan0,udp dport 67) | 计数 17 → 手机 DHCP 包**已进内核**,驱动/固件无责 |
| IP 层 | `nft insert rule inet fw4 input_lan udp dport 67 counter` | 计数 0 → 包死在 netfilter 之前或规则缺失 |
| 防火墙规则 | `nft list chain inet fw4 input` | **没有 `iifname "br-lan" jump input_lan`**,所有 LAN 流量落 `handle_reject`;`srcnat` 链无 `srcnat_wan` 跳转 → 无 masquerade |
| 渲染 vs 运行 | `fw4 print` | 渲染结果**包含**缺失规则 → 配置正确,是应用失败 |
| 应用失败原因 | `fw4 reload` | `flowtable ft { ... } Error: Resource busy` → 校验失败,整个新规则集被丢弃 |

## 三、根因(两层叠加)

1. **启动时序竞争**:procd 启动顺序 `S19firewall` 先于 `S20network`。fw4 首次渲染时 `br-lan` / `sipa_eth0` 尚未就绪,zone 按 network 解析不出设备,于是 lan 区放行规则和 wan 区 NAT 规则整体缺失。
2. **5.4 厂商内核 flowtable 缺陷**:mu300 默认 `firewall.@defaults[0].flow_offloading='1'`,fw4 在 `sipa_eth0` 上创建 flowtable `ft`。之后每次 reload 需要重建该对象,但 fw4 的 flush 路径不清除 flowtable,同名重建撞出 `EBUSY` → 渲染校验失败 → 新规则集整体丢弃。**接口就绪后的自动自愈 reload 每次都失败,系统永久残缺。**

实测:`nft delete table inet fw4`(整表删除)能真正清掉 flowtable 对象,之后 `fw4 reload` 一次成功。失败仅影响"重建",校验失败时运行表保持不变(静默丢弃新表),不会进一步破坏。

## 四、修复(设备当前状态)

```sh
uci add_list firewall.@zone[0].device='br-lan'       # lan zone 静态绑定
uci add_list firewall.@zone[1].device='sipa_eth0'    # wan zone 静态绑定
uci commit firewall
nft delete table inet fw4 && fw4 reload              # 一次性重建运行表
```

原理:zone 用静态 `device` 绑定后,规则渲染**不依赖接口运行时状态**,S19 首次渲染即完整;flowtable 只随首张表创建一次,重建 bug 不再有机会触发。**软件流卸载保留**,转发性能不受影响。mu300 自带的 `earlyusb` zone 本来就是这种写法(`option device 'usb0' 'rndis0'`),本次修复与其保持一致。

验证:重启后 uptime 1 分钟时检查,`input` 链含 `br-lan` 跳转、`srcnat` 链含 wan 跳转、masquerade 在位;手机连热点 → 拿 IP → 上网 → 进 LuCI,全部通过。

## 五、已知残留(上游修复前注意)

- 运行时执行 `fw4 reload` / LuCI 里保存防火墙改动,仍会触发 flowtable 重建失败 → **改动静默不生效**。解决办法:改完防火墙后 `nft delete table inet fw4 && fw4 reload`,或直接重启。
- 不影响:接口 up/down 触发的自动 reload 失败时运行表不变,开机首张完整表会一直工作。

## 六、对定制固件(G1-G4)的硬性要求

`openwrt/build-rootfs.sh` 的 overlay / uci-defaults **必须内置这两条 zone device 绑定**,否则定制版 rootfs 开局即残(DHCP 和 LuCI 全死)。建议落在 `files/etc/uci-defaults/` 脚本或直接补丁 `files/etc/config/firewall`。

## 七、上游 issue 素材(dikeckaan/mu300-linux)

**标题**:openwrt-luci: LAN firewall/NAT rules missing after every boot (fw4 flowtable reload failure on 5.4 kernel)

**正文草稿**:

> On v2026.10.11 (kernel 5.4.254), every fresh boot leaves the fw4 ruleset incomplete: no `iifname "br-lan" jump input_lan` in `chain input` and no `srcnat_wan` jump in `chain srcnat`. Clients (Wi-Fi and USB) can associate but get no DHCP, no LuCI, no internet.
>
> Root cause is twofold:
> 1. `S19firewall` runs before `S20network`, so the first fw4 render happens while `br-lan`/`sipa_eth0` are not up; zone rules resolved via `network` are omitted.
> 2. Self-healing never works because every later fw4 reload fails: recreating flowtable `ft` (from `flow_offloading='1'`) fails with `Resource busy` on this 5.4 kernel (flush path never removes the flowtable object), so the whole rendered ruleset is discarded.
>
> Workaround (verified, survives reboot): statically bind zone devices so the first render is complete —
> ```
> uci add_list firewall.@zone[0].device='br-lan'      # lan
> uci add_list firewall.@zone[1].device='sipa_eth0'   # wan
> uci commit firewall
> nft delete table inet fw4 && fw4 reload             # one-time fix of the live table
> ```
> Suggested upstream fix (any one): ship static `device` bindings for lan/wan zones (same pattern as the existing `earlyusb` zone); or default `flow_offloading` to off; or make the reload path delete the table instead of flushing so the flowtable is actually freed.
