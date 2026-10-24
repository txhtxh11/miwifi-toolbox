# R1D / R2D 小米路由器 一键工具箱

一个带菜单的 Shell 脚本，把小米路由器 **R1D / R2D**（以及部分同代机型）最常用的几项折腾一次性做完，自动识别型号并适配。

## 功能

| 菜单 | 功能 | 说明 |
|---|---|---|
| 1 | 状态查询 | 一键检查所有配置是否生效 |
| 2 | Entware + nano + 开机挂载 | 把 `/opt` 绑到硬盘，装 Entware/nano，配置 PATH 和 `/etc/rc.local` 开机自动挂载 |
| 3 | 内网访问 | 放行 WAN 防火墙 + 让 Samba 监听 WAN，二级路由下的设备可访问后台和硬盘 |
| 4 | 全盘共享 | 新增 `[R1D]`/`[R2D]` 共享（`/userdisk/data`），guest 免登录可读写；用 `veto` 屏蔽小米的 3 个隐藏目录 |
| 5 | 安装 MIXBOX | 自动选择安装位置（`/userdisk` 或 `/extdisks/sda1`） |
| 6 | 更新 MIXBOX | 官方 update.sh |
| 7 | 卸载 MIXBOX | 官方 uninstall.sh |
| 8 | 一键全部 | 依次执行 2+3+4+5 |
| 9 | 回滚 | 恢复最近的 Samba / 防火墙备份 |
| 10 | 免登录白名单（可选） | 自动识别当前 SSH 来源的 MAC，也可手动输入；附查询 MAC 的方法。只影响小米自带共享，脚本的 `[R1D]`/`[R2D]` 共享不需要它 |

## 一键运行（SSH 到路由器）

```sh
curl -kfsSL https://cdn.jsdelivr.net/gh/txhtxh11/miwifi-toolbox@main/miwifi-toolbox.sh -o /tmp/r1d.sh && sh /tmp/r1d.sh
```

如果 jsdelivr 不通，用 GitHub raw：

```sh
curl -kfsSL https://raw.githubusercontent.com/txhtxh11/miwifi-toolbox/main/miwifi-toolbox.sh -o /tmp/r1d.sh && sh /tmp/r1d.sh
```

> 路由器上的 busybox `wget` 不支持 HTTPS，必须用 `curl`（R1D/R2D 自带）。

## 非交互用法

```sh
sh /tmp/r1d.sh status              # 只看状态
sh /tmp/r1d.sh entware             # Entware + nano + 开机挂载
sh /tmp/r1d.sh lan                 # 内网访问（防火墙 + Samba WAN）
sh /tmp/r1d.sh smb                 # 全盘共享 + 屏蔽隐藏目录
sh /tmp/r1d.sh mixbox              # 安装 MIXBOX
sh /tmp/r1d.sh mixbox-update       # 更新 MIXBOX
sh /tmp/r1d.sh mixbox-uninstall    # 卸载 MIXBOX
sh /tmp/r1d.sh all                 # 一键全部
sh /tmp/r1d.sh rollback            # 回滚
sh /tmp/r1d.sh whitelist           # 可选：自动识别或手动输入 MAC 到免登录白名单
```

交互式命令会先问 `[y/N]`，可用 `printf 'y\n' | sh /tmp/r1d.sh entware` 自动确认。

## 状态示例

```
------------------------------------------------------------
  设备状态  R1D    (工具版本 1.0.0)
------------------------------------------------------------
  型号      : R1D
  架构/内核 : armv7l / 2.6.36
  固件      : OpenWrt Attitude Adjustment 12.09.1
  数据目录  : /userdisk/data
  WAN 接口  : eth0.2
  Entware源 : armv7sf-k2.6

  [OK] 根目录可写
  [OK] /opt 已挂载 (55.4G 总/54.8G 可用)
  [OK] opkg 已安装
  [OK] nano 已安装 ( GNU nano, version 7.2)
  [OK] PATH 已配置 (/opt/bin)
  [OK] 开机自动挂载已配置
  [OK] WAN 防火墙已放行 (zone[1].input=ACCEPT)
  [OK] Samba 模板已监听 WAN (eth0.2)
  [OK] 445 端口监听: 192.168.31.1:445 192.168.50.21:445
  [OK] 共享 [R1D] 已存在
  [OK] 隐藏目录已屏蔽 (veto)
  [OK] MIXBOX 已安装 (0.1.9.13) @ /userdisk/mixbox
```

## 自动识别与适配

脚本运行时自动检测：

| 项目 | 检测方式 | R1D | R2D |
|---|---|---|---|
| 型号 | `nvram get model`、`/proc/mi_modules/mi_sysinfo` | R1D | R2D |
| 架构/内核 | `uname -m` / `uname -r` | armv7l / 2.6.36 → `armv7sf-k2.6` | 同上（若内核 3.x 自动切 `armv7sf-k3.2`） |
| 数据目录 | 依次找 `/userdisk/data` → `/userdisk` → `/extdisks/sda1` | /userdisk/data | 同 |
| Samba 配置 | `/var/etc/smb.conf`（软链）或 `/etc/samba/smb.conf`；模板 `/etc/samba/smb.conf.template` | 有模板 | 有模板则改，无则只改生效文件并提示 |
| WAN 接口 | `uci get network.wan.ifname` | eth0.2 | 同 |
| WAN 防火墙 zone | 按 `firewall.@zone[n].name=wan` 查找 | zone 1 | 自动 |
| MIXBOX 位置 | `/userdisk` → `/extdisks/sda1` | /userdisk | 同 |

## R2D 差异说明

R2D 与 R1D 同属小米硬盘路由，官方开发版 + SSH 后操作方式基本一致，但也有区别：

| 项目 | R1D | R2D |
|---|---|---|
| 固件 | MiWiFi 2.25.213（AA 12.09） | 同代开发版 |
| 数据盘 | `/userdisk/data` | 同（脚本自动探测，找不到则用 `/userdisk` 或 `/extdisks/sda1`） |
| 防火墙 | zone name=wan，REJECT→ACCEPT | 同（脚本按 `name=wan` 定位，不写死索引） |
| Samba 模板 | `/etc/samba/smb.conf.template` | 同（有则改，无则只改生效文件并提示） |
| 内置共享写权限 | 需要 MAC 白名单 `nonLoginMac.cfg` | **同样需要**（R2D 教程也是改这个文件） |
| 外网 IP 变化 | 重启 Samba 生效 | **必须重启 Samba**（脚本配置完会自动重启） |

R2D 有两种共享方式，任选：

1. **脚本的 `[R2D]` 共享**（推荐）：绕过白名单，guest 直接可读写 `\\<IP>\R2D`；
2. **小米自带共享 + 白名单（可选）**：菜单 `10` 自动识别当前 SSH 来源的 MAC（也可手动输入）写进 `nonLoginMac.cfg`，之后 `\\<IP>\共享`、`\\<IP>\XiaoMi` 也能写。脚本会打印查询 MAC 的方法（Windows `ipconfig /all`、手机 WiFi 设置、`cat /tmp/dhcp.leases`、`cat /proc/net/arp`），并列出当前 ARP 在线设备供对照。

## 注意事项

- **先刷开发版并开启 root SSH**（R1D 2.25.213 已验证）。
- Entware 必须用 `armv7sf-k2.6`（R1D 内核 2.6.36）；脚本按内核自动选择，不要手改。
- `guest ok = yes` 意味着**内网任何设备免密码可读写**共享，**不要把 445 暴露到公网**。
- 共享路径是 `/userdisk/data`（不含 `appdata`）。要共享整个盘把脚本里 `path` 改成 `/userdisk`，但风险自负。
- Windows 访问报 `0x80004005` 时（Samba 4.0.21 不支持 SMB 签名），需在 Windows 管理员 PowerShell 执行：
  ```powershell
  Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters' -Name RequireSecuritySignature -Value 0
  Restart-Service LanmanWorkstation -Force
  ```
- 共享名不能叫 `XiaoMi`（与小米自带隐藏共享冲突）。

## 回滚

脚本每次修改前都会备份：

```
/var/etc/smb.conf.bak.<ts>
/etc/samba/smb.conf.template.bak.<ts>
/etc/config/firewall.bak.<ts>
/etc/profile.bak.<ts>
/etc/rc.local.bak.<ts>
```

菜单 `9` 或 `sh /tmp/r1d.sh rollback` 恢复最近备份。

## 已知限制

- 只在 **R1D** 上实测过；R2D 的适配逻辑（型号、内核、数据目录、防火墙 zone、MIXBOX 位置）已按通用规则写好，但未在真机验证。
- 不是所有小米路由器都支持：R3/R3D 等型号的 Entware 源/路径可能不同，脚本会按架构/内核选择，但未覆盖全部机型。
- 根目录写保护依赖 `mount -rw -o remount /`，若固件不同导致失败，脚本会提示。

## License

MIT
