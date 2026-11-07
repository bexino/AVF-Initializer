#!/bin/bash
# Run once before and once after the Debian 12 to 13 cold start.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

[[ $# == 0 ]] || { echo 'Usage: sudo bash setup.sh' >&2; exit 2; }
[[ $EUID == 0 ]] || { echo 'Run with sudo.' >&2; exit 1; }
[[ -t 0 && -t 1 ]] || { echo 'Use the local AVF terminal.' >&2; exit 1; }
# shellcheck source=/dev/null
. /etc/os-release
[[ ${ID:-} == debian && $(dpkg --print-architecture) == arm64 ]] || { echo 'Requires Debian ARM64.' >&2; exit 1; }
[[ $(cat /proc/1/comm) == systemd ]] || { echo 'Requires systemd as PID 1.' >&2; exit 1; }
[[ -z ${SSH_CONNECTION:-} && -z ${SSH_TTY:-} ]] || { echo 'Use the AVF local terminal.' >&2; exit 1; }
[[ ${VERSION_ID:-} == 12 || ${VERSION_ID:-} == 13 ]] || { echo 'Requires Debian 12 or 13.' >&2; exit 1; }

# Download a complete repository snapshot as a real archive; never execute a download stream.
WORK=$(mktemp -d /tmp/avf-setup.XXXXXXXX)
trap 'rm -rf -- "$WORK"' EXIT
curl --proto '=https' --tlsv1.2 -fL --retry 3 \
 https://fast.bexino.dpdns.org/https://github.com/bexino/AVF-Initializer/archive/refs/heads/main.tar.gz \
 -o "$WORK/repository.tar.gz"
tar -tzf "$WORK/repository.tar.gz" > "$WORK/archive-list"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$WORK/archive-list"; then
 echo 'Unsafe archive paths.' >&2; exit 1
fi
tar -xzf "$WORK/repository.tar.gz" -C "$WORK"
REPO=$WORK/AVF-Initializer-main
[[ -f $REPO/scripts/debian12-upgrade.sh && -f $REPO/scripts/avf-debian13-verify.sh ]] || {
 echo 'Incomplete repository archive.' >&2; exit 1;
}
for SCRIPT in "$REPO"/scripts/*.sh; do bash -n "$SCRIPT"; done

if [[ $VERSION_ID == 12 ]]; then
 echo 'Debian 12: upgrade begins. Keep this terminal open and review APT prompts.'
 bash "$REPO/scripts/debian12-upgrade.sh"
 echo 'Upgrade finished. Fully stop the VM, cold start it, then run the same setup command again.'
 exit 0
fi

echo 'Debian 13: initializing base system and accounts.'
bash "$REPO/scripts/avf-debian13-init.sh"
echo 'Set the root password, then the droid password.'
bash "$REPO/scripts/avf-debian13-reset-password.sh" --both
bash "$REPO/scripts/avf-debian13-desktop.sh"
bash "$REPO/scripts/avf-debian13-brave.sh"
bash "$REPO/scripts/avf-debian13-tailscale.sh"
bash "$REPO/scripts/avf-debian13-verify.sh"
echo 'Setup complete. Test the desktop, SSH tunnel and VNC from another device.'
