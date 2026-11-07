#!/bin/bash
# Android AVF Debian 13 ARM64 optional component installer. Run with bash, not POSIX sh.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
MODE=apply
ORIGINAL_ARGS=("$@")
ROLLBACK_ID=
usage() {
cat <<'EOF'
Usage: bash avf-debian13-brave.sh [options]
  --help                 Show help; no changes
  --check                Read-only guest diagnostics (writes only private temp logs)
  --dry-run              Same diagnostics plus proposed plan; no sudo/install/change
  --rollback ID          Restore managed configuration from /var/backups/avf-brave/ID
Install brave-origin from the official APT repository without recommends.
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
 probe packages dpkg-query -W '-f=${Package} ${Version} ${db:Status-Status}\n' brave-origin curl gnupg
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
  note 'Plan: preflight; config backup; install HTTPS tools; add official Brave source; update APT; install brave-origin without recommends; verify.'
  note 'Apply needs Debian 13 arm64, systemd PID1, network and >=4 GiB free disk.'
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
BASE=/var/backups/avf-brave
allowed_path() {
 case $1 in
  /etc/apt/sources.list.d/brave-browser-release.sources|/usr/share/keyrings/brave-browser-archive-keyring.gpg) return 0;;
  *) return 1;;
 esac
}
restore() {
 local src=$1 p existed
 [[ -f $src/manifest ]] || { note 'Backup manifest missing'; return 1; }
 while IFS=$'\t' read -r existed p; do
  if ! allowed_path "$p" || [[ $p == *..* ]]; then note 'Invalid manifest path'; return 1; fi
  if [[ $existed == yes ]]; then
   mkdir -p -- "$(dirname -- "$p")"
   cp -a --remove-destination -- "$src/files$p" "$p"
  elif [[ $existed == no ]]; then rm -f -- "$p"
  else return 1; fi
 done < "$src/manifest"
 note 'Configuration restored. Packages/accounts/passwords/Tailscale identity and preferences are not rolled back.'
}
if [[ $MODE == rollback ]]; then
 [[ $ROLLBACK_ID =~ ^[0-9]{8}T[0-9]{6}-[0-9]+$ ]] || { note 'Invalid backup ID'; exit 2; }
 BACKUP=$BASE/$ROLLBACK_ID
 [[ -d $BACKUP && ! -L $BACKUP && $(stat -c %u "$BACKUP") == 0 ]] || { note 'Invalid backup directory'; exit 1; }
 run restore "$BACKUP"
 exit 0
fi
(( $(df -Pk / | awk 'END {print $4}') >= 4194304 )) || { note 'Need >=4 GiB free disk'; exit 1; }
diagnostics
STEP=backup
install -d -m 700 "$BASE"
BACKUP=$BASE/$(date +%Y%m%dT%H%M%S)-$$
install -d -m 700 "$BACKUP/files"
: > "$BACKUP/manifest"
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
STEP=prerequisites
run "${APT[@]}" -o APT::Update::Error-Mode=any update
run "${APT[@]}" --no-remove -y install ca-certificates curl gnupg
STEP=brave
keytmp=$(mktemp /tmp/avf-brave-key.XXXXXXXX)
sourcetmp=$(mktemp /tmp/avf-brave-source.XXXXXXXX)
run curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 20 --max-time 120 \
 -o "$keytmp" https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
run curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 20 --max-time 120 \
 -o "$sourcetmp" https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
gpg --batch --show-keys "$keytmp" >/dev/null 2>&1 || { note 'Invalid Brave signing key'; exit 1; }
write_file /usr/share/keyrings/brave-browser-archive-keyring.gpg < "$keytmp"
write_file /etc/apt/sources.list.d/brave-browser-release.sources < "$sourcetmp"
rm -f -- "$keytmp" "$sourcetmp"
run "${APT[@]}" -o APT::Update::Error-Mode=any update
run "${APT[@]}" --no-remove -y install brave-origin
STEP=verification
run dpkg-query -W brave-origin
run "${APT[@]}" check
diagnostics
note 'Brave Origin installed. Launch from the desktop as droid.'
note 'Configuration rollback restores only the Brave source/key, not installed packages.'
