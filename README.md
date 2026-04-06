# Sakura VPS IPv6 Script

`sakura-vps-ipv6.sh` 用于在 `Ubuntu/Debian + netplan` 环境下为樱花 VPS 开启 IPv6（自动获取 SLAAC/DHCPv6），并提供备份与失败回滚能力。

## 前提条件

- 系统：`Ubuntu` 或 `Debian`
- 网络管理：`netplan`
- 权限：`root`（或 `sudo`）

## 脚本位置

当前目录下：`./sakura-vps-ipv6.sh`

## 基本用法

```bash
sudo ./sakura-vps-ipv6.sh [options]
```

## 参数说明

- `--iface <name>`：指定网卡（默认自动检测默认路由网卡）
- `--dry-run`：仅预览变更，不写入配置
- `--no-apply`：写入配置但不执行 `netplan apply`
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

3. 指定网卡并写入但不立即生效：

```bash
sudo ./sakura-vps-ipv6.sh --iface ens3 --no-apply --force
```

之后手动生效：

```bash
sudo netplan apply
```

## 回滚说明

脚本会在执行时自动备份 `/etc/netplan` 到类似目录：

`/var/backups/sakura-ipv6/YYYYmmdd-HHMMSS/netplan`

如需回滚，可恢复备份内容后执行：

```bash
sudo netplan apply
```
