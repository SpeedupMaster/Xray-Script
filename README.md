# Xray Manager

基于 Xray Core 的 Linux 一键安装与管理脚本，支持：

- `VLESS + REALITY`
- `Shadowsocks`
- 单独安装任一协议，或同时安装两种协议
- 开启 `BBR + FQ` 网络加速
- 菜单化管理 `安装 / 卸载 / 更新 / 重启 / 查看节点信息 / 更换 SNI / 检查 BBR+FQ / 更新脚本`

安装完成后可直接使用快捷命令：

```bash
xray
```

## 功能特性

- 使用 `Xray Core` 官方内核
- `REALITY` 默认端口为 `443`，安装时支持自定义
- `REALITY` 的 `SNI` 默认从预设域名池随机选择，也支持手动输入
- `Shadowsocks` 默认使用 `2022-blake3-aes-256-gcm`
- 自动生成：
  - `REALITY` 私钥 / 公钥
  - `UUID`
  - `Short ID`
  - `Shadowsocks` 密码
- 自动生成节点信息与分享链接
- 自动创建 `systemd` 服务
- 自动安装 `xray` 管理命令
- 支持在线更新脚本本身

## 系统要求

- Linux
- `systemd`
- `root` 权限
- 可联网访问 GitHub

已适配常见包管理器：

- `apt`
- `dnf`
- `yum`
- `zypper`
- `pacman`

## 一键安装

推荐直接执行：

```bash
bash <(curl -Ls https://raw.githubusercontent.com/SpeedupMaster/Xray-Script/main/xray-manager.sh)
```

或先下载再执行：

```bash
curl -LO https://raw.githubusercontent.com/SpeedupMaster/Xray-Script/main/xray-manager.sh
chmod +x xray-manager.sh
sudo bash xray-manager.sh
```

## 使用方式

首次运行：

```bash
sudo bash xray-manager.sh
```

安装完成后：

```bash
sudo xray
```

也支持命令行子命令：

```bash
sudo xray install
sudo xray uninstall
sudo xray update
sudo xray restart
sudo xray info
sudo xray change-sni
sudo xray check-bbr
sudo xray update-script
sudo xray help
```

## 菜单功能

脚本提供以下菜单：

1. `Install`
2. `Uninstall`
3. `Update Xray core`
4. `Restart Xray`
5. `Show node info`
6. `Change Reality SNI`
7. `Check BBR + FQ status`
8. `Update script`
0. `Exit`

## 安装说明

安装时支持以下选择：

- 仅安装 `VLESS + REALITY`
- 仅安装 `Shadowsocks`
- 同时安装两者

`REALITY` 安装时：

- 默认端口为 `443`
- 可手动修改端口
- 默认随机选择 `SNI`
- 可手动指定 `SNI`

`Shadowsocks` 安装时：

- 默认端口为 `8388`
- 可手动修改端口

## 默认 SNI 域名池

脚本内置以下默认 `SNI` 候选域名，安装时会随机选择其一，也可以手动指定：

```text
gateway.icloud.com
itunes.apple.com
swdist.apple.com
swcdn.apple.com
updates.cdn-apple.com
mensura.cdn-apple.com
osxapps.itunes.apple.com
aod.itunes.apple.com
download-installer.cdn.mozilla.net
addons.mozilla.org
s0.awsstatic.com
d1.awsstatic.com
cdn-dynmedia-1.microsoft.com
www.cloudflare.com
images-na.ssl-images-amazon.com
m.media-amazon.com
dl.google.com
www.google-analytics.com
www.microsoft.com
software.download.prss.microsoft.com
player.live-video.net
one-piece.com
lol.secure.dyn.riotcdn.net
www.lovelive-anime.jp
www.swift.com
academy.nvidia.com
www.cisco.com
www.samsung.com
www.amd.com
```

## 文件与安装位置

脚本默认会使用以下路径：

- Xray 内核目录：`/usr/local/xray`
- Xray 配置文件：`/etc/xray/config.json`
- 管理脚本快捷命令：`/usr/local/bin/xray`
- Xray 二进制软链接：`/usr/local/bin/xray-core`
- systemd 服务：`/etc/systemd/system/xray.service`
- 状态文件：`/etc/xray-manager/agent.conf`
- 节点信息：`/etc/xray-manager/node-info.txt`
- BBR + FQ 配置：`/etc/sysctl.d/99-xray-bbr-fq.conf`

## BBR + FQ

脚本会自动写入并尝试启用：

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

可通过以下命令检查状态：

```bash
sudo xray check-bbr
```

## 更新脚本

脚本已经内置默认在线更新地址：

```text
https://raw.githubusercontent.com/SpeedupMaster/Xray-Script/main/xray-manager.sh
```

可直接执行：

```bash
sudo xray update-script
```

## 注意事项

- 请提前放行你实际使用的端口，例如 `443`、`8388` 或你自定义的端口
- `REALITY` 的目标网站默认使用你选择的 `SNI:443`
- 如果服务器环境较老，`BBR` 是否可用取决于内核支持情况
- 该脚本依赖 `systemd`，不适用于纯 OpenRC 或其他非 systemd 环境
- 若节点无法连接，先检查：
  - 服务器安全组 / 防火墙
  - 端口占用
  - `systemctl status xray`
  - `sudo xray info`

## 仓库地址

- GitHub: [https://github.com/SpeedupMaster/Xray-Script](https://github.com/SpeedupMaster/Xray-Script)
- Raw: [https://raw.githubusercontent.com/SpeedupMaster/Xray-Script/main/xray-manager.sh](https://raw.githubusercontent.com/SpeedupMaster/Xray-Script/main/xray-manager.sh)

## 免责声明

本项目仅供学习与技术研究使用，请在遵守当地法律法规的前提下使用。
