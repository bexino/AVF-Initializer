# Android AVF Debian 12 ARM64 初始化脚本

文件：`avf-debian12-init.sh`。它是 **Bash 脚本**，请用 `bash` 运行，不要用 `sh`。文件使用 LF 换行，无需 chmod。面向真实 Debian 12 ARM64、systemd 为 PID 1 的 AVF guest，不能用于 Android shell、Termux 或 PRoot。

## 快速开始

全部命令都在 Debian 的 AVF 终端中执行，在线获取脚本，无需从电脑复制文件。每个示例都会重新下载、检查 Bash 语法，再运行；下载或语法检查失败时不会继续执行。请先将最新脚本提交到仓库，再运行这些命令。

使用加速地址，先检测和预演：

```bash
cd ~ &&
curl -fL --retry 3 'https://fast.bexino.dpdns.org/https://raw.githubusercontent.com/bexino/AVF-Initializer/main/avf-debian12-init.sh' -o avf-debian12-init.sh &&
bash -n avf-debian12-init.sh &&
bash avf-debian12-init.sh --dry-run
```

GitHub 官方直连地址（可替换下文所有加速地址）：

```bash
cd ~ &&
curl -fL --retry 3 'https://raw.githubusercontent.com/bexino/AVF-Initializer/main/avf-debian12-init.sh' -o avf-debian12-init.sh &&
bash -n avf-debian12-init.sh &&
bash avf-debian12-init.sh --dry-run
```

正式初始化：

```bash
cd ~ &&
curl -fL --retry 3 'https://fast.bexino.dpdns.org/https://raw.githubusercontent.com/bexino/AVF-Initializer/main/avf-debian12-init.sh' -o avf-debian12-init.sh &&
bash -n avf-debian12-init.sh &&
bash avf-debian12-init.sh
```

如果已经完成 Tailscale 登录，修复后继续初始化时可跳过登录交互：

```bash
cd ~ &&
curl -fL --retry 3 'https://fast.bexino.dpdns.org/https://raw.githubusercontent.com/bexino/AVF-Initializer/main/avf-debian12-init.sh' -o avf-debian12-init.sh &&
bash -n avf-debian12-init.sh &&
bash avf-debian12-init.sh --skip-login
```

这里在线下载为实际文件后执行，以便脚本在需要 sudo 时可靠地重新读取自身。不要改成 `bash <(curl ...)`；该临时路径可能无法在提权后继续访问。

### 可用参数

```text
--help                 帮助
--check                只读诊断收集
--dry-run              诊断和操作计划
--skip-login           跳过 Tailscale 交互登录
--reset-passwords      重新交互设置密码
--rollback ID          恢复指定备份中的托管配置
```

在线获取并查看帮助：

```bash
cd ~ &&
curl -fL --retry 3 'https://fast.bexino.dpdns.org/https://raw.githubusercontent.com/bexino/AVF-Initializer/main/avf-debian12-init.sh' -o avf-debian12-init.sh &&
bash -n avf-debian12-init.sh &&
bash avf-debian12-init.sh --help
```

在线获取并收集诊断：

```bash
cd ~ &&
curl -fL --retry 3 'https://fast.bexino.dpdns.org/https://raw.githubusercontent.com/bexino/AVF-Initializer/main/avf-debian12-init.sh' -o avf-debian12-init.sh &&
bash -n avf-debian12-init.sh &&
bash avf-debian12-init.sh --check
```

`--check`和 `--dry-run` 不提权、不修改系统设置，只创建私有临时报告。dry-run 是检测和计划展示，不模拟软件包依赖求解，不能保证正式安装必然成功。

正式运行时按需调用 sudo；没有 sudo 时，先在本地终端 `su -`，再运行脚本的完整路径。root、droid、VNC 密码分别通过原生密码程序交互输入，不作为参数或环境变量传递，不进入脚本日志。请勿在外面加 `bash -x`、`script` 会话录制或其他终端录屏/日志工具。

第一次运行会要求设置 root/droid 密码，以及独立 VNC 密码。以后保留密码；主动重设用：

```bash
cd ~ &&
curl -fL --retry 3 'https://fast.bexino.dpdns.org/https://raw.githubusercontent.com/bexino/AVF-Initializer/main/avf-debian12-init.sh' -o avf-debian12-init.sh &&
bash -n avf-debian12-init.sh &&
bash avf-debian12-init.sh --reset-passwords
```

已有 `droid` 必须是非 root、家目录 `/home/droid`。不存在时创建。桌面服务使用用户实际主组，不要求存在同名组。加入 sudo 组，使用系统原有 sudo 策略，不添加 NOPASSWD；现有 AVF 镜像若自带免密 sudo，本脚本不会擅自撤销。

需要可用网络、DNS、正确系统时间、Debian archive keyring、可用 HTTPS CA、`/dev/net/tun`，以及至少 4 GiB 可用磁盘空间。若基础 HTTPS/证书已损坏，脚本会停止并恢复本轮源配置，不会关闭证书或 APT 签名验证。请从可信镜像介质修复证书/时钟后重试。

## 具体行为

- 备份并停用**全部现有活动 APT 源**，包含第三方源。新源固定 bookworm/bookworm-updates，使用 `mirror+file:/etc/apt/avf-mirrors.txt`；清华 priority 1，Debian priority 2。security 独立使用 Debian 官方 HTTPS URI。随后添加 Tailscale 官方源。必要的自定义源请审阅后自行恢复。
- 先更新索引，再执行 dpkg configure、APT fix-broken 和 check。保留已有配置文件，禁止为依赖修复删除包；不删除锁文件、不杀包管理进程。遇锁超时后停止，待原任务结束再运行。
- 安装基础命令、LXQt core、Openbox、TigerVNC、中文字体、zh_CN/en_US UTF-8、Fcitx5 中文组件；不拉取推荐包。不执行全系统升级、autoremove、分区调整或自动重启。需要时另行审阅 `sudo apt-get upgrade` 的变更。
- 禁止 APT 安装 openssh-server。发现已安装、已解包或半配置的 OpenSSH server 时提前停止，避免在修复 dpkg 时配置它。必须从 AVF 本地终端自行确认并移除后重跑；不要在唯一远程连接里直接移除。OpenSSH client 不是 server，可用于其他机器连接本 VM。
- 启动 tailscaled，设定 `--accept-dns=false --ssh=true`。不接受 DNS 接管，不改变已有出口节点等其他偏好。设置后读取本地选定字段进行验证，不保存完整 preferences/status。
- 交互式 Tailscale 登录仅显示在终端，限时 300 秒；可用 `--skip-login` 跳过，稍后执行 `sudo tailscale login`。不接收 auth key 参数。未登录时报告待完成，不声称远程可用。
- `avf-vnc.service` 在 Debian 开机后作为 droid 启动 `:1` 的 LXQt 会话；不安装显示管理器、不启用 root 图形登录。Openbox 仅为新的 LXQt 配置播种，保留已有用户桌面配置。
- VNC 强制 localhost、VncAuth 和显式密码文件。验证 5901 的监听地址，发现非回环地址会停止服务。不开放公网/局域网 VNC。不修改防火墙、Android 电池策略或 host 网络。
- 控制 journald 日志容量，默认分辨率 1280×800、24 位；保留现有 swap/zram 和内核资源参数，不重复叠加交换空间。Fcitx5 可在 LXQt 配置中选择拼音；若未自动启动，在 LXQt 会话设置中加入 `fcitx5 -d`。

重复运行会重新验证软件包和托管配置，保留现有密码、账号和已运行的 VNC 会话。修改过服务/会话配置后，需要从本地终端执行 `sudo systemctl restart avf-vnc` 才应用到已有桌面；这会结束当前图形会话。

## VNC 和 Tailscale SSH

在 guest 内连接 `127.0.0.1:5901`。Android 上的 VNC 客户端不能假定 Android localhost 等于 guest localhost；若原生 Terminal 提供端口转发，可把 guest 5901 转发至 Android 本地端口，然后连接该端口，具体入口取决于系统版本。

从另一台已加入同一 tailnet 的机器，使用已安装的 SSH 客户端：

```bash
ssh -N -L 15901:127.0.0.1:5901 droid@<该VM的Tailscale-IP>
```

保持连接，VNC 客户端连接本机 `127.0.0.1:15901`。此处 guest 的 SSH 由 tailscaled 提供，无需 OpenSSH server；转发能否使用还受 Tailscale 版本和 tailnet 策略约束。不要通过关闭 VNC 的 localhost 限制来绕过问题。也可用 `tailscale ssh droid@<VM-IP>` 做普通交互连接测试；它不是本说明的本地转发命令。

管理员需要在 tailnet 策略中允许相应网络访问和 Tailscale SSH 用户/目标规则。启用 SSH 不等于授权已经完成。最终需从第二台设备实际连接验证。root/droid 本地密码不是 Tailscale SSH 的登录认证凭据。`accept-dns=false` 后优先使用 Tailscale IP，不假定 guest 的 MagicDNS 可解析。

## 7.0 GiB：宿主侧能力与操作

**目标值是 `memory_mib: 7168`（7.0 GiB 分配上限），不是保证始终存在 7.0 GiB 的 MemAvailable。** guest 的 `/proc/meminfo` 反映当前可见内存，可能受保留区域和 balloon 影响；cgroup 限额又是另一层限制。脚本不使用 ulimit、swap、内核参数或 guest 限额冒充增加物理 RAM。

AOSP Terminal 的 `ConfigJson.kt` 将 JSON 的 `memory_mib` 转成字节，调用宿主 API `setMemoryBytes`。`InstalledImage.kt` 中配置位于应用私有 files/linux/vm_config.json。部分版本把应用 files 目录共享为 `/mnt/internal`，因此 guest 中可见的 `/mnt/internal/linux/vm_config.json` 可能就是**宿主文件的共享入口**，写它也是改宿主的下一次启动配置，不会立即增加当前 guest RAM。零售系统、厂商分支和更新版本可能不同。

脚本检测两处候选 JSON，只输出 `memory_mib`、balloon 字段、可读性和当前权限，不打印完整 JSON。它无法从 guest 确认 Android launcher 是否使用该文件、Android 当前空闲 RAM或真正可恢复的权限，因此将宿主能力准确标为 UNKNOWN，不自动编辑。此工作环境没有连接用户手机，不能伪造设备实测结论。

操作路径：

1. 若 Android Linux/Terminal 设置有明确的 RAM 选项，选择 **7168 MiB**，完全停止 VM 后重新启动。
2. 若没有 UI，先在电脑 ADB 侧收集只读信息：`adb shell getprop ro.build.fingerprint`、`adb shell pm list packages`、`adb shell cat /proc/meminfo`、`adb shell /apex/com.android.virt/bin/vm help`。它们只供你本地识别系统版本、应用包名、宿主资源及 CLI；不要未经脱敏上传完整输出。普通 ADB shell 通常读不到应用私有文件，`adb root` 也不保证零售设备可用。
3. 对已确认支持自定义配置的 Terminal/AVF launcher，识别**实际使用**的 JSON，完整备份原文件和重要 guest 数据到 Android/电脑，并确认关机后能从宿主恢复原配置。不要把 `/sdcard/linux/vm_config.json` 当作所有版本通用入口，也没有在这里使用未经证实的 `settings put` 属性。
4. 将该 JSON 的 `memory_mib` 单个字段改为整数 `7168`，其他字段完整保留。若仅能在 guest 通过共享入口编辑，则只能在运行中准备下一次启动配置；先确认宿主侧恢复通道，再编辑并正常关闭 guest。宿主可直接访问时，先完全停止 VM 再改。不要在运行中的磁盘上启动第二个 VM。
5. 重新冷启动 VM，运行本脚本 `--check`，比较 memory.txt 的配置和 MemTotal。实际 MemTotal 可以略小于 7 GiB，balloon 还可能降低当前值。Android 必须为自身和其他应用保留足够 RAM；能否分配由宿主硬件/内存压力决定，不可只看手机标称总内存。
6. 若 VM 起不来，从宿主恢复原 JSON，再冷启动。不要清除 Terminal 应用数据，这可能删除虚拟磁盘。没有受支持设置/配置权限或恢复通道时，保留原内存，使用受支持的宿主构建/launcher；guest 脚本无法兑现 7 GiB。

不自动关闭 balloon，也不承诺宿主持续保留所有分配页。

## 日志、失败与恢复

每次运行建立 `/tmp/avf-init.XXXXXXXX/`（目录 0700，文件默认 0600），退出时打印路径，即便安装中断也保留。包含：

- `steps.log`：步骤、警告、失败行号；命令参数不入日志。
- `commands.log`：命令输出，经 URL、tskey、IPv4、邮箱和常见密钥字段的尽力脱敏。
- `diagnostics.txt`：OS/内核、磁盘、内存、所需包版本、dpkg audit、相关服务状态、监听端口、TUN 检测。
- `memory.txt`：内存与宿主配置检测、宿主操作建议。
- `summary.txt`：退出码、最后步骤、警告数、备份位置。

不抓取环境变量、完整进程参数、通用 journal、shadow、Tailscale 状态文件/密钥、VNC 密码文件、用户文档或完整宿主 JSON。密码和登录过程直接走 `/dev/tty`，避开日志管道。APT/dpkg 的第三方维护脚本仍可能输出任意文字，文本脱敏不能保证识别所有格式；对外分享前仍需审阅，尤其是主机标识、IPv6 和第三方错误信息。完整日志是指**本脚本所有非敏感步骤的输出和选定诊断**，不是无差别系统数据转储。

正式运行的日志由 root 持有，例如 `sudo cat /tmp/avf-init.XXXXXXXX/summary.txt`。`/tmp` 在重启/清理后可能消失，需排障时及时保存到你控制的私有目录。

每轮配置备份位于 `/var/backups/avf-init/<ID>/`（root 私有），与可分享日志分开。APT 原始配置可能带仓库凭据，**不要上传该备份目录**。

首次 APT update 失败会自动恢复本轮已更改配置；后续失败停止并保留现场，因为软件包脚本、密码和 tailnet 登录不能安全假装具备事务回滚。修复网络/磁盘/锁或具体报错后可重复运行。需要配置回滚时，从 AVF 本地控制台执行：

```bash
read -r -p "输入退出时打印的备份 ID: " backup_id &&
cd ~ &&
curl -fL --retry 3 'https://fast.bexino.dpdns.org/https://raw.githubusercontent.com/bexino/AVF-Initializer/main/avf-debian12-init.sh' -o avf-debian12-init.sh &&
bash -n avf-debian12-init.sh &&
bash avf-debian12-init.sh --rollback "$backup_id"
```

回滚恢复本轮托管的源、APT 参数、locale、服务和会话脚本文件，以及原 VNC 服务的启用/活动状态；不卸载新软件包、不移除用户、不恢复旧密码、不重置 Tailscale 身份、偏好或服务状态、不恢复用户自己的 LXQt/VNC 文件，也不操作 Android 配置。回滚会停止当前 VNC，保存图形工作后再做。备份按“每次运行之前”的状态保存；重复运行后要回到最初状态，需要选最早的相应备份，且注意后续自行修改会被覆盖。

## 验证与实测边界

脚本在安装后验证 systemd 单元、服务活动、包管理器、无 OpenSSH server、VNC 5901 回环监听以及 Tailscale DNS/SSH 的本地偏好。`--check` 只读收集诊断，不把未安装软件视作可用。完整的独立运行后检查也在线获取并执行：

```bash
cd ~ &&
curl -fL --retry 3 'https://fast.bexino.dpdns.org/https://raw.githubusercontent.com/bexino/AVF-Initializer/main/avf-debian12-verify.sh' -o avf-debian12-verify.sh &&
bash -n avf-debian12-verify.sh &&
bash avf-debian12-verify.sh
```

检查器不安装、不修复、不重启服务，提供逐项 PASS/FAIL/WARN/PENDING，最后打印 `/tmp/avf-verify.XXXXXXXX/` 报告目录。`report.txt` 是逐项结果，`summary.txt` 是数量汇总；终端无法显示全部输出时，提供这两个文件的内容即可。退出码 0 表示本地检查通过（仍可有 PENDING）；1 表示有失败项；2 表示检查器未完整执行。详细说明见 [运行后检查说明](运行后检查说明.md)。

交付检查见 `验证记录.md`。没有 Android 设备或 Debian ARM64 VM 的运行权限环境，因此不声称完成 AVF 实机安装、重启自启或远程端到端测试。启动成功只代表服务起来，不能替代你从第二台设备测试 SSH、VNC、中文输入，以及 Android 完全停止/重新启动 guest 后的验证。Debian 的“开机自启”不代表 Android 会自动启动或在后台永久维持 VM。

## 依据（核实日期：2026-11-07）

- [Debian bookworm apt-transport-mirror](https://manpages.debian.org/bookworm/apt/apt-transport-mirror.1.en.html)：失败切换；数字更小优先；无 priority 时随机选择。
- [Tailscale Debian bookworm 官方软件源](https://pkgs.tailscale.com/stable/#debian-bookworm)。
- [Tailscale DNS 客户端偏好](https://tailscale.com/docs/features/client/manage-preferences)、[Tailscale SSH 和访问策略](https://tailscale.com/docs/features/tailscale-ssh)。
- [Debian TigerVNC server 手册](https://manpages.debian.org/bookworm/tigervnc-standalone-server/tigervncserver.1.en.html)：foreground、localhost、密码文件、xstartup。
- [AOSP ConfigJson.kt](https://android.googlesource.com/platform/packages/modules/Virtualization/+/refs/heads/main/android/TerminalApp/java/com/android/virtualization/terminal/ConfigJson.kt)：memory_mib 与宿主 API。
- [AOSP InstalledImage.kt 固定修订](https://android.googlesource.com/platform/packages/modules/Virtualization/+/dd12ec774f09365d4f898c7739b23356e35198cc/android/TerminalApp/java/com/android/virtualization/terminal/InstalledImage.kt)：应用私有 files/linux 的配置位置。
- [AOSP 自定义 VM 文档](https://android.googlesource.com/platform/packages/modules/Virtualization/+/refs/heads/main/docs/custom_vm.md)：需要对应权限/宿主支持的自定义 VM 启动能力，不等于所有零售 Terminal 都提供设置入口。
