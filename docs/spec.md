## Debian 13 适配说明

升级前使用 `scripts/debian12-upgrade.sh`；`avf-debian13-*.sh` 面向冷启动后的 Debian 13 ARM64。升级前确认完整备份可从宿主恢复、使用本地终端、网络与磁盘可用，并处理 dpkg 未完成状态和锁定的软件包。升级成功后完全停止并冷启动，再按需恢复第三方源并检查。初始化不是升级后的必需步骤，会停用第三方源。不得跨版本恢复包含旧 APT 源的初始化备份。

检查器接受升级脚本的官方 trixie 源或初始化器的镜像源；其他基础初始化要求仍会检查。Debian 13 适配尚需真实 AVF guest 验证。

# 技术规范与维护说明

本文记录实现约束与排障边界；操作步骤见 [README](../README.md)。

## 脚本职责与前提

根目录 `setup.sh` 下载完整仓库归档并检查脚本语法；Debian 12 阶段运行升级脚本并提示冷启动，Debian 13 阶段依次运行初始化、密码（`--both`）、桌面、Brave、Tailscale 和检查。两个阶段使用同一命令，冷启动后需人工再运行一次。内存脚本仅按需单独运行。

- `scripts/avf-debian13-init.sh`：初始化、诊断、计划和托管配置回滚。
- `scripts/avf-debian13-desktop.sh`：独立安装完整 LXQt、中文及 VNC，支持诊断、预演、密码重设和配置回滚。
- `scripts/avf-debian13-brave.sh`：独立添加 Brave 源、安装 Brave Origin，支持诊断、预演和配置回滚。
- `scripts/avf-debian13-tailscale.sh`：安装并配置 Tailscale。
- `scripts/avf-debian13-verify.sh`：独立运行后检查。
- `scripts/avf-debian13-reset-password.sh`：交互重设 root 或 droid 本地密码。
- `scripts/avf-debian13-memory.sh`：检查或修改共享的宿主内存配置。
- `scripts/debian12-upgrade.sh`：交互式将 Debian 12 ARM64 升级到 Debian 13。

升级后脚本面向真实 Debian 13 ARM64 AVF guest，要求 systemd 为 PID 1，不适用于 Android shell、Termux 或 PRoot。脚本使用 Bash、UTF-8 和 LF 换行。

已有 `droid` 必须是非 root、家目录 `/home/droid`。不存在时创建。桌面服务使用用户实际主组，不要求存在同名组。加入 sudo 组，使用系统原有 sudo 策略，不添加 NOPASSWD；现有 AVF 镜像若自带免密 sudo，本脚本不会擅自撤销。

需要可用网络、DNS、正确系统时间、Debian archive keyring、可用 HTTPS CA，以及至少 4 GiB 可用磁盘空间。Tailscale 独立脚本另需 `/dev/net/tun`。若基础 HTTPS/证书已损坏，脚本会停止并恢复本轮源配置，不会关闭证书或 APT 签名验证。请从可信镜像介质修复证书/时钟后重试。

## 具体行为

- 备份并停用**全部现有活动 APT 源**，包含第三方源。新源固定 trixie/trixie-updates，使用 `mirror+file:/etc/apt/avf-mirrors.txt`；清华 priority 1，Debian priority 2。security 独立使用 Debian 官方 HTTPS URI。Brave 独立脚本另行添加官方 stable 源；Tailscale 独立脚本另行添加官方源。必要的自定义源请审阅后自行恢复。
- 先更新索引，再执行 dpkg configure、APT fix-broken 和 check。保留已有配置文件，禁止为依赖修复删除包；不删除锁文件、不杀包管理进程。遇锁超时后停止，待原任务结束再运行。
- 初始化器只安装基础命令工具、创建 droid、限制 journald 容量；不自动调用桌面或 Brave 脚本。
- 桌面独立脚本安装完整 LXQt 元包 `lxqt`、Openbox、TigerVNC、中文字体、zh_CN/en_US UTF-8；通过 `--no-install-recommends` 明确禁用推荐包（同时保留 APT 全局设置）。不执行全系统升级、autoremove、分区调整或自动重启。需要时另行审阅 `sudo apt-get upgrade` 的变更。
- Brave 独立脚本从 Brave 官方 HTTPS 地址下载签名密钥及 deb822 源文件，检查密钥格式，备份后写入受管理路径；更新 APT 索引并安装 `brave-origin`，不拉取推荐包。源文件与签名密钥纳入配置回滚；回滚不卸载浏览器。浏览器以 droid 普通用户从桌面启动，需在真实 ARM64 guest 验证。
- 禁止 APT 安装 openssh-server。发现已安装、已解包或半配置的 OpenSSH server 时提前停止，避免在修复 dpkg 时配置它。必须从 AVF 本地终端自行确认并移除后重跑；不要在唯一远程连接里直接移除。OpenSSH client 不是 server，可用于其他机器连接本 VM。
- 启动 tailscaled，设定 `--accept-dns=false --ssh=true`。不接受 DNS 接管，不改变已有出口节点等其他偏好。设置后读取本地选定字段进行验证，不保存完整 preferences/status。
- 交互式 Tailscale 登录仅显示在终端，限时 300 秒；可用 `--skip-login` 跳过，稍后执行 `sudo tailscale login`。不接收 auth key 参数。未登录时报告待完成，不声称远程可用。
- `avf-vnc.service` 在 Debian 开机后作为 droid 启动 `:1` 的 LXQt 会话；不安装显示管理器、不启用 root 图形登录。Openbox 仅为新的 LXQt 配置播种，保留已有用户桌面配置。
- VNC 强制 localhost、VncAuth 和显式密码文件。验证 5901 的监听地址，发现非回环地址会停止服务。不开放公网/局域网 VNC。不修改防火墙、Android 电池策略或 host 网络。
- 控制 journald 日志容量，默认分辨率 1280×800、24 位；保留现有 swap/zram 和内核资源参数，不重复叠加交换空间。中文输入法暂不安装或配置，后续另行选择方案。

各脚本可单独重复运行。初始化器保留已有本地密码和账号；桌面脚本要求先有非 root droid（/home/droid），保留已有 VNC 密码和运行中的桌面。独立密码脚本支持交互选择两个账号或 `--both`，桌面脚本的同名参数仅重设 VNC。Brave 安装不要求桌面或交互终端。三个脚本共享 `/run/avf-init.lock`，禁止并发修改。修改过服务/会话配置后，需要从本地终端执行 `sudo systemctl restart avf-vnc` 才应用到已有桌面；这会结束当前图形会话。

## Debian 13 升级边界

升级脚本要求 root、本地交互终端、Debian 12 ARM64 和 systemd；遇到 dpkg 未完成状态或锁定的软件包时停止。确认后先交互更新 Debian 12，然后将原 APT 源备份到 root 私有的 `/var/backups/avf-upgrade/`，停用现有源并配置带签名校验的 Debian 13 官方源。首次更新索引失败时恢复原源；此后失败保留新源及软件包现场，不能将旧源恢复视为系统回滚。升级分最小升级与完整升级，不自动重启、清理软件包或恢复第三方源。APT 保留交互提示，供用户审阅删除项和配置文件选择。完整虚拟机备份与恢复能力必须事先由用户确认。

Tailscale 和其他第三方源停用后不会继续从原源接收更新，应在升级后核对供应商对 Debian 13 的支持并自行配置。桌面、VNC、远程连接和 AVF 冷启动需在真实 guest 验证。

## 连接与权限边界

Tailscale SSH 由 tailscaled 提供。管理员必须允许相应网络访问和 SSH 用户/目标规则，启用 SSH 不代表授权完成；本地账号密码不是 Tailscale SSH 认证凭据。端口转发还受客户端版本和 tailnet 策略约束。`accept-dns=false` 时优先使用 Tailscale IP，不假定 MagicDNS 可用。Android localhost 与 guest localhost 不一定相同。

## 内存配置边界

内存脚本读写 `/mnt/internal/linux/vm_config.json`，仅将 `memory_mib` 改为 8192；原始备份保存在 root 私有的 `/var/backups/avf-memory/`。恢复时也先备份当前配置。脚本不修改 swap、不关闭 balloon，不能确认 launcher 是否采用配置、宿主容量或宿主侧恢复能力。MemTotal 可能因保留内存或 balloon 小于配置值。不要同时启动两个使用同一可写磁盘的虚拟机。

## 日志、失败与恢复

所有脚本使用固定目录 `/tmp/avf-debug/`（目录 0700，文件 0600），每个脚本使用脚本完整文件名加 `.txt`，再次运行覆盖上次内容。目录必须由运行用户持有；按向导统一使用 sudo。基础初始化、桌面和 Brave 合并记录步骤、脱敏命令输出、诊断及退出摘要；检查器将检查结果和摘要写入同一个文件。其他脚本仅记录退出状态，交互输出保留在终端。

不抓取环境变量、完整进程参数、通用 journal、shadow、Tailscale 状态文件/密钥、VNC 密码文件、用户文档或完整宿主 JSON。密码和登录过程直接走 `/dev/tty`，避开日志管道。APT/dpkg 的第三方维护脚本仍可能输出任意文字，文本脱敏不能保证识别所有格式；对外分享前仍需审阅，尤其是主机标识、IPv6 和第三方错误信息。完整日志是指**本脚本所有非敏感步骤的输出和选定诊断**，不是无差别系统数据转储。

正式运行的日志由 root 持有，例如 `sudo cat /tmp/avf-debug/avf-debian13-init.sh.txt`。`/tmp` 在重启/清理后可能消失，需排障时及时保存到你控制的私有目录。

三个脚本的每轮配置备份分别位于 `/var/backups/avf-init/<ID>/`、`/var/backups/avf-desktop/<ID>/`、`/var/backups/avf-brave/<ID>/`（root 私有），与可分享日志分开。APT 原始配置可能带仓库凭据，**不要上传该备份目录**。

基础初始化首次 APT update 失败会自动恢复本轮已更改配置；独立安装器遇错停止，可使用自己的备份回滚托管配置；后续失败停止并保留现场，因为软件包脚本、密码和 tailnet 登录不能安全假装具备事务回滚。修复网络/磁盘/锁或具体报错后可重复运行。需要配置回滚时，从 AVF 本地控制台执行 README 中的恢复步骤。

基础初始化回滚恢复本轮 APT 配置和 journald 配置；新备份不操作桌面服务。为兼容旧备份，初始化器仍允许恢复旧版包含的桌面、locale 及 Brave 配置；仅当备份含 VNC 状态文件时才停止并恢复 VNC。

桌面回滚仅恢复 locale、托管会话脚本和 VNC 服务配置及其启用/活动状态，会停止当前桌面。Brave 回滚仅恢复源和签名密钥。各脚本必须使用对应备份 ID；不卸载软件包、不恢复密码、不撤销用户文件、Tailscale 身份或 Android 配置。备份按每次运行前状态保存，恢复更早版本可能覆盖后续修改。桌面密码直接交互输入，不进入报告或配置备份。

## 检查器与验证边界

初始化器的 `--check` 只收集诊断，退出 0 不代表安装完成；`--dry-run` 不模拟依赖求解。独立检查器不安装、不修复、不更新索引、不重启服务，只创建私有报告；不读取密码内容，不保存完整 Tailscale JSON、进程参数或 journal。账号密码仅通过 `passwd -S` 判断状态。

检查器根据软件包或托管文件是否存在判断可选组件；未安装桌面、Brave、Tailscale 时跳过其检查，部分安装会继续报告缺失项。完整验收前应确认已运行所需独立脚本，跳过不表示该组件安装成功。

检查范围：系统、架构、TUN、APT 源及签名路径、镜像优先级、dpkg/本地 APT 依赖、所需软件包、OpenSSH server 缺席、账号与密码状态、VNC 文件权限、locale、会话、服务与进程、5901 回环监听、Tailscale 登录及偏好、备份与日志容量。配置符合预期不代表联网故障切换已实测。

退出码：0 为本地检查通过（仍可有 PENDING）；1 为存在 FAIL；2 为未完整执行或缺少权限/依赖。PASS 表示本项通过，FAIL 表示异常，WARN 表示需关注，PENDING 表示需人工验证。

必须在目标设备验证安装、桌面交互、中文显示、第二台设备 SSH/转发/VNC、内存分配及冷启动自启。Debian 服务自启不代表 Android 会自动启动或永久保持 VM。历史对话中的检查结果不作为当前版本的实机验证结论。

## 维护检查

在具备 Bash 的环境中，对所有脚本运行 `bash -n`；可用时再运行 ShellCheck。检查帮助和非法参数，相关行为变更需验证对应安全模式；系统变更仅在合适的测试 guest 上执行。报告实际完成的检查和待实机验证项。

## 参考资料

- [Debian 13 LXQt 元包](https://packages.debian.org/trixie/lxqt)。
- [Brave Origin 官方 Linux 安装说明](https://brave.com/origin/linux/)。

- [Debian 13 从 Debian 12 升级](https://www.debian.org/releases/trixie/release-notes/upgrading.en.html)。

以下沿用项目资料，未重新联网核实：

- [Debian trixie apt-transport-mirror](https://manpages.debian.org/trixie/apt/apt-transport-mirror.1.en.html)：失败切换；数字更小优先；无 priority 时随机选择。
- [Tailscale Debian trixie 官方软件源](https://pkgs.tailscale.com/stable/#debian-trixie)。
- [Tailscale DNS 客户端偏好](https://tailscale.com/docs/features/client/manage-preferences)、[Tailscale SSH 和访问策略](https://tailscale.com/docs/features/tailscale-ssh)。
- [Debian TigerVNC server 手册](https://manpages.debian.org/trixie/tigervnc-standalone-server/tigervncserver.1.en.html)：foreground、localhost、密码文件、xstartup。
- [AOSP ConfigJson.kt](https://android.googlesource.com/platform/packages/modules/Virtualization/+/refs/heads/main/android/TerminalApp/java/com/android/virtualization/terminal/ConfigJson.kt)：memory_mib 与宿主 API。
- [AOSP InstalledImage.kt 固定修订](https://android.googlesource.com/platform/packages/modules/Virtualization/+/dd12ec774f09365d4f898c7739b23356e35198cc/android/TerminalApp/java/com/android/virtualization/terminal/InstalledImage.kt)：应用私有 files/linux 的配置位置。
- [AOSP 自定义 VM 文档](https://android.googlesource.com/platform/packages/modules/Virtualization/+/refs/heads/main/docs/custom_vm.md)：需要对应权限/宿主支持的自定义 VM 启动能力，不等于所有零售 Terminal 都提供设置入口。
