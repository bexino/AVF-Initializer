#!/bin/bash
# Upgrade an AVF Debian 12 guest to Debian 13 interactively.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077
LOGDIR=/tmp/avf-debug
mkdir -p -- "$LOGDIR"
[[ -d $LOGDIR && ! -L $LOGDIR && -O $LOGDIR ]] || { echo "Debug directory must be owned by the current user: $LOGDIR" >&2; exit 1; }
chmod 700 -- "$LOGDIR"
LOGFILE="$LOGDIR/${0##*/}.txt"
[[ ! -L $LOGFILE ]] || { echo 'Refusing symlink debug file' >&2; exit 1; }
: > "$LOGFILE"
chmod 600 -- "$LOGFILE"
finish_debug() {
 local rc=$?
 trap - EXIT
 printf 'exit_code=%s\n' "$rc" >> "$LOGFILE"
 printf 'Debug file: %s\n' "$LOGFILE" >&2
}
trap finish_debug EXIT

usage() {
 cat <<'EOF'
Usage: sudo bash debian12-upgrade.sh [--help]
Upgrade Debian 12 arm64 to Debian 13 from the local AVF console.
Back up the entire VM first. Package prompts require an interactive terminal.
EOF
}
if (( $# )); then
 if (( $# == 1 )) && [[ $1 == --help || $1 == -h ]]; then usage; exit 0; fi
 usage >&2; exit 2
fi
[[ $EUID == 0 ]] || { echo 'Run as root using sudo.' >&2; exit 1; }
[[ -t 0 && -t 1 ]] || { echo 'An interactive local console is required.' >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 12 && $(dpkg --print-architecture) == arm64 ]] || { echo 'Requires Debian 12 arm64.' >&2; exit 1; }
[[ $(cat /proc/1/comm) == systemd ]] || { echo 'Requires systemd as PID 1.' >&2; exit 1; }
[[ -z ${SSH_CONNECTION:-} && -z ${SSH_TTY:-} ]] || { echo 'Use the local AVF console, not SSH.' >&2; exit 1; }
command -v apt-mark >/dev/null
command -v dpkg >/dev/null
command -v apt-get >/dev/null
[[ -z $(dpkg --audit) ]] || { echo 'Resolve dpkg --audit issues before upgrading.' >&2; exit 1; }
HELD=$(apt-mark showhold)
[[ -z $HELD ]] || { printf 'Held packages must be reviewed before upgrading:\n%s\n' "$HELD" >&2; exit 1; }
echo 'Back up the entire VM and verify recovery before continuing.'
echo 'Third-party APT sources will be disabled; package changes cannot be rolled back by restoring sources.'
echo 'Review APT package removals and configuration prompts. Do not interrupt the upgrade.'
read -r -p 'Type UPGRADE to continue: ' ANSWER
[[ $ANSWER == UPGRADE ]] || { echo 'Cancelled; no upgrade was started.'; exit 3; }
APT=(apt-get -o DPkg::Lock::Timeout=120)
echo 'Updating Debian 12 packages. Review each APT prompt.'
"${APT[@]}" -o APT::Update::Error-Mode=any update
"${APT[@]}" upgrade
"${APT[@]}" dist-upgrade
[[ -z $(dpkg --audit) ]] || { echo 'Resolve dpkg --audit issues before switching sources.' >&2; exit 1; }
BACKUP_ROOT=/var/backups/avf-upgrade
install -d -m 700 "$BACKUP_ROOT"
chmod 700 "$BACKUP_ROOT"
BACKUP=$(mktemp -d "$BACKUP_ROOT/sources-XXXXXXXX")
mkdir -p "$BACKUP/sources.list.d"
if [[ -e /etc/apt/sources.list ]]; then cp -a /etc/apt/sources.list "$BACKUP/sources.list"; fi
shopt -s nullglob
SOURCES=(/etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources)
for SOURCE in "${SOURCES[@]}"; do cp -a -- "$SOURCE" "$BACKUP/sources.list.d/"; done
printf 'APT source backup: %s\n' "$BACKUP"
restore_sources() {
 rm -f -- /etc/apt/sources.list.d/avf-trixie-upgrade.sources
 for SOURCE in "${SOURCES[@]}"; do cp -a -- "$BACKUP/sources.list.d/${SOURCE##*/}" "$SOURCE"; done
 if [[ -e $BACKUP/sources.list ]]; then cp -a -- "$BACKUP/sources.list" /etc/apt/sources.list; else rm -f -- /etc/apt/sources.list; fi
}
# Stage a canonical signed Debian source; disabled sources remain in the private backup.
for SOURCE in "${SOURCES[@]}"; do rm -f -- "$SOURCE"; done
rm -f -- /etc/apt/sources.list
cat > /etc/apt/sources.list.d/avf-trixie-upgrade.sources <<'EOF'
Types: deb
URIs: https://deb.debian.org/debian
Suites: trixie trixie-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: https://security.debian.org/debian-security
Suites: trixie-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
if ! "${APT[@]}" -o APT::Update::Error-Mode=any update; then
 echo 'Debian 13 index update failed; restoring saved APT sources.' >&2
 restore_sources
 echo 'Sources restored; resolve the error and refresh package indexes before retrying.' >&2
 exit 1
fi
echo 'Debian 13 sources are active. If a later step fails, repair the package state; do not restore old sources blindly.'
"${APT[@]}" upgrade
"${APT[@]}" dist-upgrade
[[ -z $(dpkg --audit) ]] || { echo 'Upgrade completed with dpkg issues; inspect dpkg --audit.' >&2; exit 1; }
echo 'Upgrade complete. Review third-party sources for Debian 13 compatibility, then restart the VM and test access and desktop.'
echo 'After a full VM shutdown and cold start, use the Debian 13 scripts and restore third-party sources as needed.'
