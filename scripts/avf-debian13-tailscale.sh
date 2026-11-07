#!/bin/bash
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077
LOGIN=1
case ${1:-} in
 '') ;;
 --skip-login) LOGIN=0 ;;
 --help|-h) echo 'Usage: bash avf-debian13-tailscale.sh [--skip-login]'; exit 0 ;;
 *) echo 'Unknown option' >&2; exit 2 ;;
esac
(( $# <= 1 )) || exit 2
if (( EUID != 0 )); then
 exec sudo -- /bin/bash "$(readlink -f -- "$0")" "$@"
fi
LOGDIR=/tmp/avf-debug
mkdir -p -- "$LOGDIR"
[[ -d $LOGDIR && ! -L $LOGDIR && -O $LOGDIR ]] || { echo "Debug directory must be owned by the current user: $LOGDIR" >&2; exit 1; }
chmod 700 -- "$LOGDIR"
LOGFILE="$LOGDIR/${0##*/}.txt"
[[ ! -L $LOGFILE ]] || { echo 'Refusing symlink debug file' >&2; exit 1; }
: > "$LOGFILE"
chmod 600 -- "$LOGFILE"
finish_debug() {
 local rc=${1:-$?}
 trap - EXIT
 printf 'exit_code=%s\n' "$rc" >> "$LOGFILE"
 printf 'Debug file: %s\n' "$LOGFILE" >&2
}
trap finish_debug EXIT
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == debian && ${VERSION_ID:-} == 13 && $(dpkg --print-architecture) == arm64 ]] || { echo 'Requires Debian 13 arm64' >&2; exit 1; }
[[ $(cat /proc/1/comm) == systemd && -c /dev/net/tun ]] || { echo 'Requires systemd and /dev/net/tun' >&2; exit 1; }
if (( LOGIN )); then
 (: </dev/tty) 2>/dev/null || { echo 'Requires an interactive terminal' >&2; exit 1; }
fi
exec 9>/run/avf-init.lock
flock -n 9 || { echo 'Another initialization is running' >&2; exit 1; }
WORK=$(mktemp -d /tmp/avf-tailscale.XXXXXXXX)
trap 'rc=$?; rm -rf -- "$WORK"; finish_debug "$rc"' EXIT
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=120 -y --no-remove install ca-certificates curl gnupg
curl --proto '=https' --tlsv1.2 -fSL --connect-timeout 20 --max-time 120 -o "$WORK/key" https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg
gpg --batch --show-keys "$WORK/key" >/dev/null 2>&1
install -m 644 "$WORK/key" /usr/share/keyrings/tailscale-archive-keyring.gpg
printf '%s\n' 'deb [arch=arm64 signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/debian trixie main' > /etc/apt/sources.list.d/tailscale.list
apt-get -o DPkg::Lock::Timeout=120 -o APT::Update::Error-Mode=any update
apt-get -o DPkg::Lock::Timeout=120 -y --no-remove install tailscale
systemctl enable --now tailscaled.service
tailscale set --accept-dns=false --ssh=true
if (( LOGIN )); then
 echo 'Complete Tailscale login on the console; login output is not recorded.'
 if ! timeout --foreground 300 tailscale login </dev/tty >/dev/tty 2>&1; then
  echo 'Login incomplete; run sudo tailscale login later.' >&2
 fi
fi
systemctl is-active --quiet tailscaled.service
tailscale debug prefs | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(not(d.get("CorpDNS") is False and d.get("RunSSH") is True))'
if ! tailscale status --json | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin).get("BackendState") != "Running")'; then
 echo 'Tailscale is not running; complete login and check connectivity.' >&2
fi
echo 'Tailscale configured. Verify tailnet access policy and test SSH from another device.'
