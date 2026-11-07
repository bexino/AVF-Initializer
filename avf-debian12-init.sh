#!/bin/bash
# Android AVF Debian 12 ARM64 bootstrap. Run with bash, not POSIX sh.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
MODE=apply
ORIGINAL_ARGS=("$@")
RESET_PASSWORDS=0
LOGIN=1
ROLLBACK_ID=
usage() {
cat <<'EOF'
Usage: bash avf-debian12-init.sh [options]
  --help                 Show help; no changes
  --check                Read-only guest diagnostics (writes only private temp logs)
  --dry-run              Same diagnostics plus proposed plan; no sudo/install/change
  --skip-login           Do not start interactive Tailscale enrollment
  --reset-passwords      Prompt again for root/droid/VNC passwords
  --rollback ID          Restore managed configuration from /var/backups/avf-init/ID
Defaults: prompt for passwords once, localhost-only VNC :1, zh_CN.UTF-8.
No OpenSSH server installation. No automatic Android host memory changes.
Interactive secrets and Tailscale enrollment bypass all script log capture.
Rollback restores configuration, not packages, accounts, passwords or tailnet state.
EOF
}
while (($#)); do
 case $1 in
  --help|-h) usage; exit 0;;
  --check) MODE=check;;
  --dry-run) MODE=dry-run;;
  --skip-login) LOGIN=0;;
  --reset-passwords) RESET_PASSWORDS=1;;
  --rollback) shift; ROLLBACK_ID=${1:?Missing backup ID}; MODE=rollback;;
  *) printf 'Unknown option: %s\n' "$1" >&2; exit 2;;
 esac
 shift
done
if [[ $MODE == apply || $MODE == rollback ]] && ((EUID != 0)); then
 command -v sudo >/dev/null || { echo 'Run from a root shell (su -), or install/configure sudo first.' >&2; exit 1; }
 exec sudo -- /bin/bash "$(readlink -f -- "$0")" "${ORIGINAL_ARGS[@]}"
fi
LOGDIR=$(mktemp -d /tmp/avf-init.XXXXXXXX)
chmod 700 "$LOGDIR"
STEP=preflight
BACKUP=
WARNINGS=0
note() { printf '%s [%s] %s\n' "$(date -Is)" "$STEP" "$*" | tee -a "$LOGDIR/steps.log"; }
warn() { WARNINGS=$((WARNINGS+1)); note "WARNING: $*"; }
# Best-effort redaction, plus strict collection minimization. No environment,
# process command lines, shadow, tailscaled.state, VNC files or general journal.
redact() {
 sed -E \
  -e 's#https?://[^[:space:]<>"\x27]+#[URL-REDACTED]#g' \
  -e 's/tskey-[A-Za-z0-9_-]+/[TSKEY-REDACTED]/g' \
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/[EMAIL-REDACTED]/g' \
  -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[IP-REDACTED]/g' \
  -e 's/((password|passwd|token|secret|authorization|cookie|authkey)[[:space:]]*[:=])[[:space:]]*[^[:space:]]+/\1[REDACTED]/Ig'
}
run() {
 local rc=0
 note "Running: $1" # only executable name; never log arguments
 "$@" 2>&1 | redact | tee -a "$LOGDIR/commands.log" || rc=$?
 return "$rc"
}
probe() {
 local label=$1; shift
 printf '\n### %s\n' "$label" >> "$LOGDIR/diagnostics.txt"
 "$@" 2>&1 | redact >> "$LOGDIR/diagnostics.txt" || true
}
memory_report() {
 local kb
 kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
 awk -v k="$kb" 'BEGIN {printf "Guest MemTotal: %.3f GiB; target host allocation: 7168 MiB (7.0 GiB).\n",k/1048576}' | tee "$LOGDIR/memory.txt"
 for f in /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory/memory.limit_in_bytes; do
  if [[ -r $f ]]; then printf '%s: %s\n' "$f" "$(cat "$f")" >> "$LOGDIR/memory.txt"; fi
 done
 if command -v python3 >/dev/null; then
  python3 - <<'PY' >> "$LOGDIR/memory.txt"
import json, os
for p in ('/mnt/internal/linux/vm_config.json', '/mnt/internal/vm_config.json'):
    if not os.path.isfile(p):
        print(p + ': not visible'); continue
    try:
        with open(p) as f: d=json.load(f)
        print(p + ': memory_mib=' + str(d.get('memory_mib', 'missing')) +
              '; auto_memory_balloon=' + str(d.get('auto_memory_balloon', 'missing')) +
              '; writable=' + str(os.access(p, os.W_OK)))
    except (OSError, ValueError): print(p + ': unreadable or invalid JSON')
PY
 else
  echo 'python3 absent: shared host JSON parsing not performed.' >> "$LOGDIR/memory.txt"
 fi
 cat >> "$LOGDIR/memory.txt" <<'EOF'
Host capability verdict: UNKNOWN. Guest cannot establish Android version,
launcher behavior, host free RAM, permissions or whether this JSON is consumed.
No RAM change attempted. Shared JSON, if visible, is HOST configuration, not
a guest memory control. MemAvailable is workload-dependent, not a RAM ceiling.
Host action: stop the VM fully, use a launcher RAM setting if offered (7168 MiB),
or identify the actual launcher-consumed vm_config.json and back it up before
changing ONLY memory_mib to 7168. A rooted/custom AVF launcher can consume JSON
using setMemoryBytes; retail Terminal builds vary and may override configuration.
Do not assume /sdcard/linux/vm_config.json or an adb settings key is supported.
If shared /mnt/internal/linux/vm_config.json is present, verify launcher/build
support and arrange host-side restore before editing it. Recovering a failed VM
may require Android root; never clear Terminal app data as a recovery shortcut.
On an Android ADB host, read-only evidence: adb shell getprop ro.build.fingerprint;
adb shell pm list packages; adb shell cat /proc/meminfo;
adb shell /apex/com.android.virt/bin/vm help
For custom/rooted VMs: inspect vm run help and the actual launch JSON; preserve
all disk/kernel paths. Do not start a second VM on the same writable disk.
Cold-start after changing host configuration; rerun --check. MemTotal can be
slightly below 7 GiB due to reserved memory; ballooning can lower current RAM.
If no supported UI/config access exists, this build cannot be adjusted by this
guest script. Keep current RAM or use a supported host build/launcher.
EOF
}
diagnostics() {
 probe os cat /etc/os-release
 probe kernel uname -srmo
 probe memory free -h
 probe disk df -h / /tmp
 probe inode df -i /
 probe dpkg-audit dpkg --audit
 # shellcheck disable=SC2016 # dpkg-query format, not shell variables
 probe packages dpkg-query -W '-f=${Package} ${Version} ${db:Status-Status}\n' tailscale openssh-server lxqt-core openbox tigervnc-standalone-server
 probe units systemctl show tailscaled.service avf-vnc.service -p Id -p ActiveState -p SubState -p UnitFileState -p Result -p ExecMainStatus
 probe listeners ss -lnt
 probe tun stat -c '%F %a' /dev/net/tun
 probe failed-unit-count systemctl --failed --no-legend --no-pager
 memory_report
}
finish() {
 local rc=$?
 trap - EXIT ERR INT TERM
 set +e
 {
  echo "exit_code=$rc"
  echo "last_step=$STEP"
  echo "warnings=$WARNINGS"
  echo "config_backup=${BACKUP:-none}"
  echo 'memory_target=host action required; see memory.txt'
  echo 'Debug capture deliberately excludes interactive secrets, enrollment URLs and raw journals.'
 } > "$LOGDIR/summary.txt"
 printf '\nExit=%s; diagnostics/logs: %s\n' "$rc" "$LOGDIR"
 [[ -z $BACKUP ]] || printf 'Private configuration backup: %s\n' "$BACKUP"
}
trap finish EXIT
trap 'note "FAILED at line $LINENO (command text omitted)"' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
if [[ $MODE == check || $MODE == dry-run ]]; then
 diagnostics
 note 'Detection only. No system configuration changes or privilege escalation.'
 if [[ $MODE == dry-run ]]; then
  note 'Plan: preflight; config backup; replace active APT sources; repair dpkg/APT; install tools/desktop/Tailscale; passwords; locale; private VNC systemd; verify.'
  note 'Apply needs Debian 12 arm64, systemd PID1, console TTY, network, /dev/net/tun and >=4 GiB free disk.'
 fi
 exit 0
fi
[[ -r /etc/os-release ]] || { note 'Missing os-release'; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 12 && $(dpkg --print-architecture) == arm64 ]] || { note 'Requires Debian 12 arm64'; exit 1; }
[[ $(cat /proc/1/comm) == systemd ]] || { note 'Requires systemd as PID1'; exit 1; }
exec 9>/run/avf-init.lock
flock -n 9 || { note 'Another initialization is running'; exit 1; }
BASE=/var/backups/avf-init
allowed_path() {
 case $1 in
  /etc/apt/*|/usr/share/keyrings/tailscale-archive-keyring.gpg|/etc/locale.gen|/etc/default/locale|/etc/systemd/system/avf-vnc.service|/etc/systemd/journald.conf.d/90-avf-init.conf|/usr/local/libexec/avf-lxqt-session|/var/lib/avf-init/passwords-configured) return 0;;
  *) return 1;;
 esac
}
restore() {
 local src=$1 p existed
 [[ -f $src/manifest ]] || { note 'Backup manifest missing'; return 1; }
 systemctl stop avf-vnc.service || true
 while IFS=$'\t' read -r existed p; do
  allowed_path "$p" && [[ $p != *..* ]] || { note 'Invalid manifest path'; return 1; }
  if [[ $existed == yes ]]; then
   mkdir -p -- "$(dirname -- "$p")"
   cp -a --remove-destination -- "$src/files$p" "$p"
  elif [[ $existed == no ]]; then rm -f -- "$p"
  else return 1; fi
 done < "$src/manifest"
 systemctl daemon-reload
 if [[ $(cat "$src/vnc-enabled") == enabled ]]; then systemctl enable avf-vnc.service; else systemctl disable avf-vnc.service || true; fi
 if [[ $(cat "$src/vnc-active") == active ]]; then systemctl start avf-vnc.service; fi
 locale-gen || true
 note 'Configuration restored. Packages/accounts/passwords/Tailscale identity and preferences are not rolled back.'
}
if [[ $MODE == rollback ]]; then
 [[ $ROLLBACK_ID =~ ^[0-9]{8}T[0-9]{6}-[0-9]+$ ]] || { note 'Invalid backup ID'; exit 2; }
 BACKUP=$BASE/$ROLLBACK_ID
 [[ -d $BACKUP && ! -L $BACKUP && $(stat -c %u "$BACKUP") == 0 ]] || { note 'Invalid backup directory'; exit 1; }
 run restore "$BACKUP"
 exit 0
fi
[[ -c /dev/net/tun ]] || { note '/dev/net/tun missing: need host/kernel TUN support for Tailscale SSH'; exit 1; }
if [[ ! -r /dev/tty || ! -w /dev/tty ]] || ! ( : </dev/tty ) 2>/dev/null; then
 note 'Apply requires an interactive terminal'; exit 1
fi
(( $(df -Pk / | awk 'END {print $4}') >= 4194304 )) || { note 'Need >=4 GiB free disk'; exit 1; }
ssh_status=$(dpkg-query -W '-f=${db:Status-Status}' openssh-server 2>/dev/null || true)
if [[ -n $ssh_status && $ssh_status != not-installed && $ssh_status != config-files ]]; then
 note 'Existing openssh-server detected. Remove it explicitly from the AVF console first; this script refuses to configure it or interrupt existing remote access.'
 exit 1
fi
diagnostics
STEP=backup
install -d -m 700 "$BASE"
BACKUP=$BASE/$(date +%Y%m%dT%H%M%S)-$$
install -d -m 700 "$BACKUP/files"
: > "$BACKUP/manifest"
systemctl is-enabled avf-vnc.service > "$BACKUP/vnc-enabled" 2>/dev/null || true
systemctl is-active avf-vnc.service > "$BACKUP/vnc-active" 2>/dev/null || true
save() {
 local p=$1
 allowed_path "$p" || return 1
 if grep -Fqx -- $'yes\t'"$p" "$BACKUP/manifest" || grep -Fqx -- $'no\t'"$p" "$BACKUP/manifest"; then return; fi
 if [[ -e $p || -L $p ]]; then
  mkdir -p -- "$BACKUP/files$(dirname -- "$p")"
  cp -a -- "$p" "$BACKUP/files$p"
  printf 'yes\t%s\n' "$p" >> "$BACKUP/manifest"
 else printf 'no\t%s\n' "$p" >> "$BACKUP/manifest"; fi
}
write_file() {
 local p=$1 t
 save "$p"
 mkdir -p -- "$(dirname -- "$p")"
 t=$(mktemp "$(dirname -- "$p")/.avf-init.XXXXXX")
 cat > "$t"
 chmod 644 "$t"
 mv -fT -- "$t" "$p"
}
STEP=apt-sources
# Disable ALL active lists, including third-party sources, to make the Debian
# repair reproducible. Preserve originals in private backup; never log contents.
shopt -s nullglob
for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
 [[ -e $f || -L $f ]] || continue
 save "$f"
 rm -f -- "$f"
done
write_file /etc/apt/avf-mirrors.txt <<'EOF'
https://mirrors.tuna.tsinghua.edu.cn/debian/	priority:1
https://deb.debian.org/debian/	priority:2
EOF
write_file /etc/apt/sources.list.d/00-avf-debian.sources <<'EOF'
Types: deb
URIs: mirror+file:/etc/apt/avf-mirrors.txt
Suites: bookworm bookworm-updates
Components: main contrib non-free non-free-firmware
Architectures: arm64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: bookworm-security
Components: main contrib non-free non-free-firmware
Architectures: arm64
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
write_file /etc/apt/apt.conf.d/90-avf-init <<'EOF'
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
DPkg::Lock::Timeout "120";
APT::Install-Recommends "false";
EOF
write_file /etc/apt/preferences.d/90-avf-no-openssh-server <<'EOF'
Package: openssh-server
Pin: version *
Pin-Priority: -1
EOF
APT=(apt-get -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive
if ! run "${APT[@]}" -o APT::Update::Error-Mode=any update; then
 warn 'APT update failed; restoring this run configuration automatically.'
 run restore "$BACKUP"
 exit 1
fi
STEP=repair
# Never delete lock files; dpkg itself reports a busy database.
if ! run dpkg --force-confold --configure -a; then warn 'Initial dpkg configure failed; trying dependency repair'; fi
run "${APT[@]}" --no-remove -y --fix-broken install
run dpkg --force-confold --configure -a
run "${APT[@]}" check
STEP=packages
run "${APT[@]}" --no-remove -y install ca-certificates debian-archive-keyring curl gnupg sudo \
 locales fonts-noto-cjk fonts-noto-color-emoji fcitx5 fcitx5-chinese-addons fcitx5-frontend-qt5 \
 lxqt-core openbox dbus-x11 xauth x11-xserver-utils tigervnc-standalone-server tigervnc-tools \
 qterminal pcmanfm-qt htop procps iproute2 iputils-ping dnsutils less nano vim-tiny \
 git rsync unzip zip tar lsof logrotate python3
STEP=tailscale
keytmp=$(mktemp "$LOGDIR/key.XXXXXX")
run curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 20 --max-time 120 \
 -o "$keytmp" https://pkgs.tailscale.com/stable/debian/bookworm.noarmor.gpg
gpg --batch --show-keys "$keytmp" >/dev/null 2>&1 || { note 'Invalid Tailscale signing key'; exit 1; }
write_file /usr/share/keyrings/tailscale-archive-keyring.gpg < "$keytmp"
rm -f "$keytmp"
write_file /etc/apt/sources.list.d/tailscale.list <<'EOF'
deb [arch=arm64 signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian bookworm main
EOF
run "${APT[@]}" -o APT::Update::Error-Mode=any update
run "${APT[@]}" --no-remove -y install tailscale
run systemctl enable --now tailscaled.service
run tailscale set --accept-dns=false --ssh=true
if (( LOGIN )); then
 note 'Tailscale login (console only; URL/output not captured). Ctrl-C cancels. Never paste an auth key into this script.'
 if ! timeout --foreground 300 tailscale login </dev/tty >/dev/tty 2>&1; then warn 'Tailscale enrollment incomplete; later run sudo tailscale login'; fi
fi
STEP='user-and-passwords'
if ! id droid >/dev/null 2>&1; then run useradd -m -s /bin/bash droid; fi
DHOME=$(getent passwd droid | cut -d: -f6)
[[ $DHOME == /home/droid && ! -L $DHOME && $(id -u droid) != 0 ]] || { note 'Expected non-root droid with /home/droid'; exit 1; }
run usermod -aG sudo droid
install -d -m 700 /var/lib/avf-init
if [[ ! -e /var/lib/avf-init/passwords-configured ]] || (( RESET_PASSWORDS )); then
 for user in root droid; do
  note "Set $user password on console (not logged)."
  passwd "$user" </dev/tty >/dev/tty 2>&1
 done
 save /var/lib/avf-init/passwords-configured
 touch /var/lib/avf-init/passwords-configured
fi
# Do not follow user-provided .vnc links as root.
[[ ! -L $DHOME/.vnc ]] || { note 'Refusing symlink .vnc directory'; exit 1; }
run runuser -u droid -- mkdir -p "$DHOME/.vnc"
run runuser -u droid -- chmod 700 "$DHOME/.vnc"
if [[ ! -s $DHOME/.vnc/passwd ]] || (( RESET_PASSWORDS )); then
 note 'Set a separate VNC password (console only; VncAuth uses only the first 8 characters).'
 runuser -u droid -- tigervncpasswd </dev/tty >/dev/tty 2>&1
fi
run runuser -u droid -- chmod 600 "$DHOME/.vnc/passwd"
STEP=locale-and-resources
save /etc/locale.gen
if ! grep -Eq '^zh_CN.UTF-8[[:space:]]+UTF-8' /etc/locale.gen; then echo 'zh_CN.UTF-8 UTF-8' >> /etc/locale.gen; fi
if ! grep -Eq '^en_US.UTF-8[[:space:]]+UTF-8' /etc/locale.gen; then echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen; fi
run locale-gen
save /etc/default/locale
run update-locale LANG=zh_CN.UTF-8
write_file /etc/systemd/journald.conf.d/90-avf-init.conf <<'EOF'
[Journal]
SystemMaxUse=128M
RuntimeMaxUse=32M
EOF
run systemctl restart systemd-journald
# No guessed swap/zram sizes or global kernel tuning. Keep guest/host defaults.
STEP=desktop
# This is a public executable directory, unlike private logs/backups. mkdir -p
# under umask 077 would otherwise create it as 0700 on minimal AVF images.
install -d -m 755 /usr/local/libexec
write_file /usr/local/libexec/avf-lxqt-session <<'EOF'
#!/bin/bash
set -eu
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
export LANG=zh_CN.UTF-8
export XDG_SESSION_TYPE=x11 XDG_CURRENT_DESKTOP=LXQt
export QT_IM_MODULE=fcitx GTK_IM_MODULE=fcitx XMODIFIERS=@im=fcitx
# Keep droid's own LXQt configuration; seed Openbox on a fresh profile.
mkdir -p "$HOME/.config/lxqt"
if [[ ! -e $HOME/.config/lxqt/session.conf ]]; then
 printf '[General]\nwindow_manager=openbox\n' > "$HOME/.config/lxqt/session.conf"
fi
exec dbus-run-session -- startlxqt
EOF
chmod 755 /usr/local/libexec/avf-lxqt-session
run runuser -u droid -- test -x /usr/local/libexec/avf-lxqt-session
write_file /etc/systemd/system/avf-vnc.service <<'EOF'
[Unit]
Description=Private droid TigerVNC LXQt desktop (:1)
After=network.target
StartLimitIntervalSec=120
StartLimitBurst=3

[Service]
Type=simple
User=droid
PAMName=login
WorkingDirectory=/home/droid
Environment=HOME=/home/droid LANG=zh_CN.UTF-8
RuntimeDirectory=avf-vnc
RuntimeDirectoryMode=0700
Environment=XDG_RUNTIME_DIR=/run/avf-vnc
UMask=0077
ExecStart=/usr/bin/tigervncserver :1 -fg -localhost yes -SecurityTypes VncAuth -PasswordFile /home/droid/.vnc/passwd -geometry 1280x800 -depth 24 -autokill yes -xstartup /usr/local/libexec/avf-lxqt-session
Restart=on-failure
RestartSec=5
TimeoutStopSec=20
KillMode=control-group

[Install]
WantedBy=multi-user.target
EOF
run systemctl daemon-reload
run systemd-analyze verify /etc/systemd/system/avf-vnc.service
run systemctl enable avf-vnc.service
run systemctl reset-failed avf-vnc.service
if ! systemctl is-active --quiet avf-vnc.service; then run systemctl start avf-vnc.service; fi
STEP=verification
sleep 5
run systemctl is-active tailscaled.service avf-vnc.service
run "${APT[@]}" check
run dpkg --audit
[[ -z $(dpkg --audit) ]] || { note 'dpkg audit non-empty'; exit 1; }
if dpkg-query -W '-f=${db:Status-Status}' openssh-server 2>/dev/null | grep -qx installed; then note 'Unexpected openssh-server installed'; exit 1; fi
listeners=$(ss -H -lnt 'sport = :5901')
[[ -n $listeners ]] || { note 'VNC port 5901 not listening'; exit 1; }
if printf '%s\n' "$listeners" | awk '{print $4}' | grep -Evq '^(127\.0\.0\.1:5901|\[::1\]:5901|::1:5901)$'; then
 systemctl stop avf-vnc.service
 note 'Unsafe VNC bind detected; stopped VNC'; exit 1
fi
# Inspect selected local preferences/status only; never save full status JSON.
if ! tailscale debug prefs 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not(d.get("CorpDNS") is False and d.get("RunSSH") is True))'; then
 note 'Tailscale DNS/SSH preference verification failed'; exit 1
fi
if ! tailscale status --json 2>/dev/null | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin).get("BackendState")!="Running")'; then
 warn 'Tailscale not Running: enrollment or network action still required. SSH reachability is not verified.'
fi
diagnostics
warn '7 GiB host allocation is not changed or verified by guest; consult memory.txt.'
note 'Completed. VNC: guest localhost:5901. Tailnet SSH requires admin access/SSH policy and an external connection test.'
note 'For remote VNC, use a Tailscale SSH local tunnel; no OpenSSH server required. See README.'
note 'Other active APT sources were disabled and backed up. No full upgrade/autoremove/reboot performed.'
note 'If configuration changes are needed, stop avf-vnc first; rerunning keeps an already running desktop.'
