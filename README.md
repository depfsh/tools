# Sakura VPS IPv6 Script

`sakura-vps-ipv6.sh` 用于在樱花官方原生 Debian（`ifupdown`）环境下按教程方式开启 IPv6，并支持备份与失败回滚。

## 前提条件

- 系统：`Debian 12`（或兼容 `ifupdown` 的 Debian/Ubuntu）
- 网络管理：`/etc/network/interfaces`（`ifupdown`）
- 权限：`root`（或 `sudo`）
- `interfaces` 中存在目标网卡的 `iface <网卡> inet6 static` 配置块（可被注释）

## 脚本位置

当前目录下：`./sakura-vps-ipv6.sh`

## 基本用法

```bash
sudo ./sakura-vps-ipv6.sh [options]
```

## 参数说明

- `--iface <name>`：指定网卡（默认自动检测默认路由网卡）
- `--dry-run`：仅预览变更，不写入配置
- `--no-apply`：仅写入配置，不执行 `sysctl --system` 和 `ip -6` 立即生效命令
- `--force`：跳过交互确认
- `--backup-dir <path>`：自定义备份目录（默认 `/var/backups/sakura-ipv6`）
- `-h, --help`：查看帮助

## 常见场景

1. 预演（不改配置）：

```bash
sudo ./sakura-vps-ipv6.sh --dry-run
```

2. 正式启用 IPv6（推荐）：

```bash
sudo ./sakura-vps-ipv6.sh --force
```

3. 指定网卡并仅写配置（不立即生效）：

```bash
sudo ./sakura-vps-ipv6.sh --iface ens3 --no-apply --force
```

之后手动生效（教程同款）：

```bash
sudo sysctl --system
sudo ip -6 addr add <你的IPv6>/64 dev ens3
sudo ip -6 route replace default via fe80::1 dev ens3
ping6 -c3 ipv6.google.com
```

## 回滚说明

脚本会在执行时自动备份以下文件到类似目录：

- `/etc/sysctl.conf`
- `/etc/network/interfaces`
- `/etc/sysctl.d/` 下包含 `disable_ipv6` 的配置文件（如 `ipv6.conf`）

备份路径示例：

`/var/backups/sakura-ipv6/YYYYmmdd-HHMMSS/`

如需回滚，可恢复备份内容后执行：

```bash
sudo sysctl --system
```

## 脚本做了什么

1. 在 `/etc/sysctl.conf` 中确保以下键为 `0`：
   - `net.ipv6.conf.all.disable_ipv6`
   - `net.ipv6.conf.default.disable_ipv6`
   - `net.ipv6.conf.<iface>.disable_ipv6`
2. 扫描 `/etc/sysctl.d/` 目录，将其中所有 `disable_ipv6 = 1` 修改为 `0`（Sakura VPS 默认在 `/etc/sysctl.d/ipv6.conf` 中禁用 IPv6，该文件优先级高于 `sysctl.conf`）
3. 在 `/etc/network/interfaces` 启用 `iface <iface> inet6 static` 段（取消注释）
4. 执行 `sysctl --system` 加载所有 sysctl 配置（包括 sysctl.d 目录）
5. 从配置中读取 IPv6 地址/网关，执行 `ip -6` 命令立即生效
6. 执行 `ping6 -c3 ipv6.google.com` 验证连通性
7. 若立即生效或连通性验证失败，自动回滚所有配置并输出失败原因
