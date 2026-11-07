#!/bin/bash
# Read-only post-install verification; only private /tmp report files are written.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
case ${1:-} in
 --help|-h) echo 'Usage: bash avf-debian12-verify.sh [--help]'
 echo 'Run as root/sudo from a real file. No installation, repair or service restart.'
 echo 'Exit: 0=local checks passed (manual tests may remain), 1=failed checks, 2=incomplete/internal error.'; exit 0;;
 '') ;;
 *) echo 'Unknown option' >&2; exit 2;;
esac
if (( $# > 1 )); then echo 'Too many arguments' >&2; exit 2; fi
if (( EUID != 0 )); then
 command -v sudo >/dev/null || { echo 'Run from a root shell or with sudo.' >&2; exit 2; }
 exec sudo -- /bin/bash "$(readlink -f -- "$0")"
fi
command -v python3 >/dev/null || { echo 'python3 is missing; initializer has not completed its package stage.' >&2; exit 2; }
exec python3 - <<'PY'
import collections, configparser, datetime, json, os, pathlib, pwd, re, stat, subprocess, sys, tempfile
os.umask(0o077)
report_dir = pathlib.Path(tempfile.mkdtemp(prefix='avf-verify.', dir='/tmp'))
report = report_dir / 'report.txt'
counts = collections.Counter()
def emit(status, message):
    counts[status] += 1
    line = f'[{status}] {message}'
    print(line, flush=True)
    with report.open('a', encoding='utf-8') as f: f.write(line + '\n')
def check(ok, message): emit('PASS' if ok else 'FAIL', message)
def cmd(*args):
    try:
        p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           text=True, timeout=25, check=False)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired): return 124, ''
def text(path):
    try: return pathlib.Path(path).read_text(encoding='utf-8')
    except (OSError, UnicodeError): return ''
def installed(package):
    rc, value = cmd('dpkg-query', '-W', '-f=${db:Status-Status}', package)
    return rc == 0 and value.strip() == 'installed'
def properties(unit):
    rc, value = cmd('systemctl', 'show', unit, '-p', 'User', '-p', 'Group', '-p', 'ActiveState',
                    '-p', 'SubState', '-p', 'Result', '-p', 'NRestarts', '-p', 'MainPID')
    return dict(line.split('=', 1) for line in value.splitlines() if '=' in line) if rc == 0 else {}
def jsoncmd(*args):
    rc, value = cmd(*args)
    if rc: return {}
    try:
        obj = json.loads(value)
        return obj if isinstance(obj, dict) else {}
    except ValueError: return {}
def apt_config():
    # Inspect expected stanzas semantically, without printing credential-bearing sources.
    raw = text('/etc/apt/sources.list.d/00-avf-debian.sources')
    stanzas = []
    for block in re.split(r'\n\s*\n', raw):
        fields = {}
        for line in block.splitlines():
            if line.startswith('#') or ':' not in line: continue
            key, value = line.split(':', 1); fields[key.lower()] = value.strip()
        if fields: stanzas.append(fields)
    def matches(s, uri, suites):
        return (s.get('types', '').split() == ['deb'] and s.get('uris', '').split() == [uri]
                and set(s.get('suites', '').split()) == set(suites)
                and s.get('signed-by') == '/usr/share/keyrings/debian-archive-keyring.gpg'
                and s.get('architectures') == 'arm64' and s.get('enabled', 'yes') != 'no')
    check(any(matches(s, 'mirror+file:/etc/apt/avf-mirrors.txt', ['bookworm','bookworm-updates']) for s in stanzas),
          'APT 普通更新：mirror+file、bookworm/bookworm-updates、arm64、签名密钥')
    check(any(matches(s, 'https://security.debian.org/debian-security', ['bookworm-security']) for s in stanzas),
          'APT 安全更新：独立 Debian 官方 URI 和 bookworm-security')
    mirrors = text('/etc/apt/avf-mirrors.txt')
    check(bool(re.search(r'^https://mirrors\.tuna\.tsinghua\.edu\.cn/debian/\tpriority:1\s*$', mirrors, re.M))
          and bool(re.search(r'^https://deb\.debian\.org/debian/\tpriority:2\s*$', mirrors, re.M)),
          'APT 镜像优先级：TUNA=1，Debian=2')
    pin = text('/etc/apt/preferences.d/90-avf-no-openssh-server')
    check('Package: openssh-server' in pin and 'Pin-Priority: -1' in pin, 'APT 禁止安装 OpenSSH server 的规则')
    expected = {'00-avf-debian.sources', 'tailscale.list'}
    extras = []
    for p in pathlib.Path('/etc/apt/sources.list.d').glob('*'):
        if p.suffix in ('.list', '.sources') and p.name not in expected and text(p).strip(): extras.append(p)
    if text('/etc/apt/sources.list').strip() or extras:
        emit('WARN', '存在额外 APT 源文件，需人工确认是否重复或偏离预期；未输出源内容')
    source = text('/etc/apt/sources.list.d/tailscale.list')
    check('https://pkgs.tailscale.com/stable/debian bookworm main' in source
          and 'signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg' in source
          and pathlib.Path('/usr/share/keyrings/tailscale-archive-keyring.gpg').is_file(),
          'Tailscale 官方 bookworm 源及独立签名密钥文件')
def main():
    emit('INFO', 'AVF 初始化运行后检查 ' + datetime.datetime.now(datetime.timezone.utc).isoformat())
    emit('INFO', '只读检查；不更新索引、不安装软件、不改配置、不重启服务。')
    os_release = text('/etc/os-release')
    check(bool(re.search(r'^ID=debian$', os_release, re.M)) and 'VERSION_ID="12"' in os_release
          and cmd('dpkg','--print-architecture')[1].strip() == 'arm64', 'Debian 12 ARM64')
    check(text('/proc/1/comm').strip() == 'systemd', 'systemd 为 PID 1')
    try: tun = stat.S_ISCHR(os.stat('/dev/net/tun').st_mode)
    except OSError: tun = False
    check(tun, 'TUN 字符设备存在（实际 VPN 连通性仍需远程测试）')
    apt_config()
    rc, audit = cmd('dpkg', '--audit')
    check(rc == 0 and not audit.strip(), 'dpkg audit 无异常')
    rc, _ = cmd('apt-get', '-s', '-o', 'Debug::NoLocking=1', '-o', 'Dir::Cache::pkgcache=',
                '-o', 'Dir::Cache::srcpkgcache=', 'check')
    check(rc == 0, 'APT 本地依赖检查（不联网、不更新索引）')
    packages = '''ca-certificates debian-archive-keyring curl gnupg sudo locales fonts-noto-cjk
fonts-noto-color-emoji fcitx5 fcitx5-chinese-addons fcitx5-frontend-qt5 lxqt-core openbox
dbus-x11 xauth x11-xserver-utils tigervnc-standalone-server tigervnc-tools qterminal pcmanfm-qt
htop procps iproute2 iputils-ping dnsutils less nano vim-tiny git rsync unzip zip tar lsof
logrotate python3 tailscale'''.split()
    missing = [p for p in packages if not installed(p)]
    check(not missing, '所需软件包完整' + ('；缺少：' + ', '.join(missing) if missing else ''))
    rc, ssh = cmd('dpkg-query', '-W', '-f=${db:Status-Status}', 'openssh-server')
    check(ssh.strip() in ('', 'not-installed', 'config-files'), '无已安装/解包的 OpenSSH server')
    account = None
    try: account = pwd.getpwnam('droid')
    except KeyError: pass
    check(account is not None and account.pw_uid != 0 and account.pw_dir == '/home/droid', 'droid 非 root，家目录正确')
    if account:
        rc, groups = cmd('id', '-nG', 'droid')
        check(rc == 0 and 'sudo' in groups.split(), 'droid 属于 sudo 组（不判定已有免密策略）')
    for user in ('root', 'droid'):
        rc, value = cmd('passwd', '-S', user)
        fields = value.split()
        check(rc == 0 and len(fields) > 1 and fields[1] == 'P', user + ' 密码已设置且未锁定（不验证密码内容）')
    check(pathlib.Path('/var/lib/avf-init/passwords-configured').is_file(), '初始化密码步骤完成标记')
    try:
        p = pathlib.Path('/home/droid/.vnc/passwd'); info = p.lstat()
        safe = account is not None and stat.S_ISREG(info.st_mode) and info.st_size >= 8 and info.st_uid == account.pw_uid and stat.S_IMODE(info.st_mode) == 0o600
    except OSError: safe = False
    check(safe, 'VNC 密码文件存在、归 droid 所有且权限 0600（不读取内容）')
    check('zh_cn.utf8' in cmd('locale', '-a')[1].lower(), 'zh_CN.UTF-8 locale 已生成')
    check(bool(re.search(r'^LANG=["\x27]?zh_CN\.UTF-8', text('/etc/default/locale'), re.M)), '默认 LANG 为 zh_CN.UTF-8')
    session = text('/usr/local/libexec/avf-lxqt-session')
    check('dbus-run-session -- startlxqt' in session and 'QT_IM_MODULE=fcitx' in session
          and cmd('runuser', '-u', 'droid', '--', 'test', '-r', '/usr/local/libexec/avf-lxqt-session')[0] == 0
          and cmd('runuser', '-u', 'droid', '--', 'test', '-x', '/usr/local/libexec/avf-lxqt-session')[0] == 0,
          '托管 LXQt 会话脚本与输入法环境，且 droid 可读取/执行（含父目录权限）')
    for unit in ('tailscaled.service', 'avf-vnc.service'):
        check(cmd('systemctl', 'is-enabled', unit)[1].strip() == 'enabled', unit + ' 已启用开机启动')
        props = properties(unit)
        check(props.get('ActiveState') == 'active' and props.get('SubState') == 'running', unit + ' 当前正在运行')
        if int(props.get('NRestarts', '0') or '0') > 0: emit('WARN', unit + ' 本次已发生自动重启，需关注稳定性')
        if unit == 'avf-vnc.service':
            check(account is not None and props.get('User') == 'droid'
                  and props.get('Group', '') in ('', 'droid', str(account.pw_gid)),
                  'VNC 服务以 droid 运行；未设置 Group 时使用其实际主组')
    rc, sockets = cmd('ss', '-H', '-lnt', 'sport = :5901')
    addresses = [line.split()[3] for line in sockets.splitlines() if len(line.split()) >= 4]
    check(rc == 0 and bool(addresses) and all(a in ('127.0.0.1:5901', '[::1]:5901', '::1:5901') for a in addresses),
          'VNC 5901 已监听且仅绑定回环地址（不输出 IP）')
    if account:
        # Names and UID only: no command lines, environment, Xauthority or desktop logs.
        rc, names = cmd('ps', '-u', str(account.pw_uid), '-o', 'comm=')
        running = set(names.splitlines())
        for name in ('Xtigervnc', 'lxqt-session', 'openbox'):
            check(rc == 0 and name in running, 'droid 进程存在：' + name + '（不能替代画面验证）')
    prefs = jsoncmd('tailscale', 'debug', 'prefs')
    check(prefs.get('CorpDNS') is False, 'Tailscale 不接管 DNS')
    check(prefs.get('RunSSH') is True, 'Tailscale SSH 已启用')
    state = jsoncmd('tailscale', 'status', '--json')
    check(state.get('BackendState') == 'Running', 'Tailscale 已登录且本地 BackendState=Running')
    mem = re.search(r'^MemTotal:\s+(\d+)', text('/proc/meminfo'), re.M)
    if mem:
        gib = int(mem[1]) / 1048576
        emit('INFO', f'guest MemTotal={gib:.3f} GiB；宿主目标分配 8192 MiB')
        emit('PENDING', '8 GiB 宿主分配尚未证实；MemTotal 和 guest 限额不能证明宿主配置已生效')
    else: emit('WARN', '无法读取 guest MemTotal')
    # Never display whole host JSON.
    for p in ('/mnt/internal/linux/vm_config.json', '/mnt/internal/vm_config.json'):
        try:
            with open(p, encoding='utf-8') as f: host = json.load(f)
            n = host.get('memory_mib')
            emit('INFO', '候选宿主共享配置：memory_mib=' + (str(n) if type(n) is int else '未知'))
        except (OSError, ValueError, AttributeError): pass
    backups = pathlib.Path('/var/backups/avf-init')
    check(backups.is_dir() and any(backups.glob('*/manifest')), '存在初始化配置备份清单')
    journal = text('/etc/systemd/journald.conf.d/90-avf-init.conf')
    check('SystemMaxUse=128M' in journal and 'RuntimeMaxUse=32M' in journal, 'journald 资源限制配置存在')
    emit('PENDING', '从第二台 tailnet 设备实际测试 SSH、SSH 转发和 VNC 画面；访问策略不能由本地服务状态证明')
    emit('PENDING', '在 VNC 桌面测试中文显示和输入法；进程存在不代表桌面可交互')
    emit('PENDING', '完全停止并重新启动 guest 后再次运行检查，验证实际自启；本脚本不主动重启')
    failures = counts['FAIL']
    summary = f'本地检查：PASS={counts["PASS"]} FAIL={failures} WARN={counts["WARN"]}；人工/宿主待验={counts["PENDING"]}'
    emit('INFO', summary)
    emit('INFO', '结论：' + ('初始化存在未完成或异常项目。' if failures else '本地自动检查通过；仍需完成 PENDING 项，不能视为全部实机验收完成。'))
    with (report_dir / 'summary.txt').open('w', encoding='utf-8') as f:
        f.write(summary + '\nexit_code=' + str(int(bool(failures))) + '\n')
    return int(bool(failures))
try:
    result = main()
except Exception:
    # No exception text/traceback: external tool errors might contain credentials.
    emit('ERROR', '检查程序未完整执行；请核对系统依赖和权限。未输出原始异常以避免泄密。')
    result = 2
finally:
    print('报告目录：' + str(report_dir), flush=True)
sys.exit(result)
PY
