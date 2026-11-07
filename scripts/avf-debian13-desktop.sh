#!/bin/bash
# Android AVF Debian 13 ARM64 optional component installer. Run with bash, not POSIX sh.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
MODE=apply
ORIGINAL_ARGS=("$@")
RESET_PASSWORDS=0
ROLLBACK_ID=
usage() {
cat <<'EOF'
Usage: bash avf-debian13-desktop.sh [options]
  --help                 Show help; no changes
  --check                Read-only guest diagnostics (writes only private temp logs)
  --dry-run              Same diagnostics plus proposed plan; no sudo/install/change
  --reset-passwords      Prompt again for VNC password
  --rollback ID          Restore managed configuration from /var/backups/avf-desktop/ID
Defaults: prompt for VNC password once, localhost-only VNC :1, zh_CN.UTF-8.
No OpenSSH server installation. No automatic Android host memory changes.
Interactive secrets bypass all script log capture.
Rollback restores configuration, not packages, accounts, passwords or tailnet state.
EOF
}
while (($#)); do
 case $1 in
  --help|-h) usage; exit 0;;
  --check) MODE=check;;
  --dry-run) MODE=dry-run;;
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
LOGDIR=/tmp/avf-debug
mkdir -p -- "$LOGDIR"
[[ -d $LOGDIR && ! -L $LOGDIR && -O $LOGDIR ]] || { echo "Debug directory must be owned by the current user: $LOGDIR" >&2; exit 1; }
chmod 700 -- "$LOGDIR"
LOGFILE="$LOGDIR/${0##*/}.txt"
[[ ! -L $LOGFILE ]] || { echo 'Refusing symlink debug file' >&2; exit 1; }
: > "$LOGFILE"
chmod 600 -- "$LOGFILE"
STEP=preflight
BACKUP=
WARNINGS=0
note() { printf '%s [%s] %s\n' "$(date -Is)" "$STEP" "$*" | tee -a "$LOGFILE"; }
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
 "$@" 2>&1 | redact | tee -a "$LOGFILE" || rc=$?
 return "$rc"
}
probe() {
 local label=$1; shift
 printf '\n### %s\n' "$label" >> "$LOGFILE"
 "$@" 2>&1 | redact >> "$LOGFILE" || true
}
diagnostics() {
 probe os cat /etc/os-release
 probe kernel uname -srmo
 probe memory free -h
 probe disk df -h / /tmp
 probe inode df -i /
 probe dpkg-audit dpkg --audit
 # shellcheck disable=SC2016 # dpkg-query format, not shell variables
 probe packages dpkg-query -W '-f=${Package} ${Version} ${db:Status-Status}\n' lxqt openbox tigervnc-standalone-server
 probe units systemctl show avf-vnc.service -p Id -p ActiveState -p SubState -p UnitFileState -p Result -p ExecMainStatus
 probe listeners ss -lnt
 probe failed-unit-count systemctl --failed --no-legend --no-pager
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
  echo 'Debug capture deliberately excludes interactive secrets, enrollment URLs and raw journals.'
 } >> "$LOGFILE"
 printf '\nExit=%s; diagnostics/logs: %s\n' "$rc" "$LOGFILE"
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
  note 'Plan: preflight; require initialized droid user; config backup; update APT; install LXQt without recommends; VNC password; Chinese locale/fonts; private VNC systemd; verify.'
  note 'Apply needs Debian 13 arm64, systemd PID1, console TTY, network and >=4 GiB free disk.'
 fi
 exit 0
fi
[[ -r /etc/os-release ]] || { note 'Missing os-release'; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 && $(dpkg --print-architecture) == arm64 ]] || { note 'Requires Debian 13 arm64'; exit 1; }
[[ $(cat /proc/1/comm) == systemd ]] || { note 'Requires systemd as PID1'; exit 1; }
exec 9>/run/avf-init.lock
flock -n 9 || { note 'Another initialization is running'; exit 1; }
BASE=/var/backups/avf-desktop
allowed_path() {
 case $1 in
  /etc/locale.gen|/etc/default/locale|/etc/systemd/system/avf-vnc.service|/usr/local/libexec/avf-lxqt-session) return 0;;
  *) return 1;;
 esac
}
restore() {
 local src=$1 p existed
 [[ -f $src/manifest ]] || { note 'Backup manifest missing'; return 1; }
 systemctl stop avf-vnc.service || true
 while IFS=$'\t' read -r existed p; do
  if ! allowed_path "$p" || [[ $p == *..* ]]; then note 'Invalid manifest path'; return 1; fi
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
if [[ ! -r /dev/tty || ! -w /dev/tty ]] || ! ( : </dev/tty ) 2>/dev/null; then
 note 'Apply requires an interactive terminal'; exit 1
fi
(( $(df -Pk / | awk 'END {print $4}') >= 4194304 )) || { note 'Need >=4 GiB free disk'; exit 1; }
DHOME=$(getent passwd droid | cut -d: -f6 || true)
[[ $DHOME == /home/droid && ! -L $DHOME && $(id -u droid) != 0 ]] || { note 'Run base initialization first: expected non-root droid with /home/droid'; exit 1; }
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
APT=(apt-get --no-install-recommends -o DPkg::Lock::Timeout=120 -o Dpkg::Options::=--force-confold)
export DEBIAN_FRONTEND=noninteractive
STEP=packages
run "${APT[@]}" -o APT::Update::Error-Mode=any update
run "${APT[@]}" --no-remove -y install locales fonts-noto-cjk fonts-noto-color-emoji \
 lxqt openbox dbus-x11 xauth \
 x11-xserver-utils tigervnc-standalone-server tigervnc-tools qterminal pcmanfm-qt iproute2
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
run systemctl is-active avf-vnc.service
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
diagnostics
note 'Desktop completed. VNC: guest localhost:5901. See README for SSH tunneling.'
note 'Rerunning keeps an already running desktop. Restart avf-vnc explicitly to apply session changes.'
