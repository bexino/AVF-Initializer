# AVF Debian 初始化与桌面访问交接

更新：2026-11-07。写给没有本会话上下文的接手者。

## 任务与环境

用户在 Android AVF 的 Debian 12 ARM64 虚拟机中搭建可重复执行的初始化环境，仓库为 `bexino/AVF-Initializer`。Windows 工作区是 `D:\Personal\Documents\ChatGPT\AVF 虚拟机`。用户自行提交代码；不要擅自推送。guest 获取脚本只能在线下载，不能依靠从电脑复制。README 使用 GitHub raw 和加速地址 `https://fast.bexino.dpdns.org/https://raw.githubusercontent.com/bexino/AVF-Initializer/main/`。

原始目标：Debian bookworm/bookworm-updates 的 mirror+file（TUNA 优先、官方兜底），security 独立官方源；修复 dpkg/APT；Tailscale SSH，禁止 OpenSSH server、关闭 Tailscale DNS 接管；LXQt+Openbox、TigerVNC 的 droid systemd 桌面；交互式密码、中文环境、基础工具、诊断和备份；AVF 宿主内存目标 7 GiB。不能把 guest 的 ulimit/swap 当作增加 RAM。

主要文件：`avf-debian12-init.sh` 初始化，`avf-debian12-verify.sh` 运行后验收，`avf-debian12-reset-password.sh` 密码工具，`README.md` 在线运行说明，`运行后检查说明.md` 检查器说明。先读当前文件，用户可能在会话间自行修改或提交。

## 已完成与实测

- guest 是 Debian 12.15、arm64、systemd，磁盘已扩至 32 GiB。APT、基础工具、LXQt/Openbox、TigerVNC、中文环境与 Tailscale 安装完成。服务启用开机自启；是否实际随 Android 重启仍需冷启动验证。
- 运行后检查得到 **35 PASS、0 FAIL、0 WARN**：VNC 仅监听 guest 的 127.0.0.1:5901，Xtigervnc、lxqt-session、openbox 进程存在；Tailscale DNS 未接管、SSH 已启用、后端 Running。检测不能证明桌面画面或输入法可用。
- 用户已从 Windows 用 `ssh root@100.106.135.101` 成功进入 guest；Tailscale SSH 实测成功。此 IP 是当时的地址，未来可能变化。
- 修复过 droid 主组不叫 droid（systemd 不指定 `Group=droid`）、`/usr/local/libexec` 在 umask 077 下被创建为 0700 导致 droid 无法执行会话脚本；初始化脚本已修正目录权限并重置 systemd 失败状态，检查器以 droid 身份检测可执行权限。用户设备上修复后已通过检查。
- 脚本曾在 Windows 上通过 Bash 语法、ShellCheck、检查器内嵌 Python 编译和部分 APT 配置逻辑测试；不可把这些误称为完整实机验收。

## 当前卡点：手机 AVNC 显示桌面

用户已安装 Android AVNC，希望一步步看到 LXQt。**手机必须常开其他 VPN，因此不要要求 Android 安装或连接 Tailscale**；Android 的 VPN 服务可能互相占用。guest 中的 Tailscale 保留，Windows SSH 已可用。

上个回复建议检查 Android Terminal 是否有端口转发：Android 本机端口 15901（或仅支持同端口时 5901）映射 guest 127.0.0.1:5901，AVNC 连 Android `127.0.0.1` 对应端口，输入独立的 VNC 密码。**这是尚未证实的方案，不保证 Terminal 版本支持转发到 guest 回环地址或该 UI/端口映射存在。** 下一位应优先调查该 Android Terminal 版本的实际端口转发实现和安全边界，必要时向用户获取设置截图或只读诊断，再提供具体步骤；考虑手机已有 VPN 对本地回环流量的影响。不要把 guest localhost 和 Android localhost 当作同一网络命名空间。

之前曾错误建议 Android 开 Tailscale 并在 guest 使用 `tailscale serve --bg --tcp=15901 tcp://127.0.0.1:5901`。用户是否实际执行未知；如果执行过，可用 `sudo tailscale serve --tcp=15901 off` 撤销该端口（先查看状态，避免移除用户其他服务）。Tailscale Serve 不解决 Android 不能开第二个 VPN 的约束。Windows SSH 连接成功只证明 Windows 到 guest 的路径，不证明手机到 guest 可用。

## 内存目标未完成

guest `MemTotal` 约 3.835 GiB。root 检查器看到了候选共享宿主配置 `/mnt/internal/linux/vm_config.json` 的 `memory_mib=4096`；普通 droid 先前因权限显示不可见。目标为宿主配置 7168 MiB，但尚未确认当前 launcher 一定使用此文件或宿主恢复能力，也尚未修改。guest 可见共享路径可能是 Android 宿主文件入口；更改影响下次启动而非立即扩容。确认 Android 版本、实际 launcher 配置、宿主 RAM 和可恢复路径，先备份重要数据及原配置，再研究调整、完全停止并冷启动、复测。无宿主恢复手段时不可贸然修改；不要清除 Terminal 应用数据，避免删除虚拟磁盘。MemTotal 略低于分配值可由保留内存或 balloon 造成。

## 不要重踩的坑

- `--check`/`--dry-run` 只收集诊断，不证明安装完成；独立检查器才有 PASS/FAIL/PENDING。0 退出码只代表本地自动检查通过，外部连接、画面、冷启动和宿主内存仍待验证。
- 用 `curl -fL --retry 3 ... -o 文件 && bash -n 文件 && bash 文件` 在线获取后执行。不要用 `bash <(curl ...)` 正式运行：sudo 重新执行时临时 fd 可能不可用。下载地址上的新修复以用户 commit 后为准，不假设线上已经同步。
- 默认备份/报告 root 私有，普通 droid 对 `/tmp/avf-verify.*` 的权限不足是预期现象，可用 `sudo cat .../report.txt`。不要索取或打印密码、VNC 密码文件、Tailscale 登录链接、完整密钥、原始私有备份。日志脱敏是尽力而为，不保证绝对安全。
- VNC 密码独立于 root/droid 密码；VncAuth 只使用前 8 个字符。桌面运行和 5901 监听不等于 AVNC 已连通，也不等于输入法实测通过。维持 VNC 本地监听，避免未经考虑地暴露到局域网或公网。
- 脚本会备份并禁用现有活动 APT 源，包括第三方源；APT 镜像优先级要显式指定，普通源 TUNA priority 1、官方 priority 2，security 另列。不要删除 dpkg 锁文件，也不要配置或安装 OpenSSH server。
- 上一次误建议用户在 Android 连接 Tailscale；用户已明确指出其他 VPN 必须常开。不要再次假设可同时使用两个 Android VPN。

## 下一步

1. 核实 Android Terminal 端口转发的真实功能，给出不占 Android VPN 的 AVNC 连接办法，并以用户提供的实际 UI/错误迭代到看到桌面。
2. 测试中文显示、输入法；完全停止并重启 guest 后复查 VNC/Tailscale 自启。
3. 单独调查并安全处理宿主 7168 MiB 配置及恢复方案；保持现有配置直到证据充分。
4. 如果为 AVNC 增加仓库脚本或文档，延续在线获取方式，验证现有安全默认值，并说明验证范围。用户自行 commit。
