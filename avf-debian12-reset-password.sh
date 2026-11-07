#!/bin/bash
# Reset one local account password from the AVF guest console.
set +x
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

usage() {
 cat <<'EOF'
Usage: bash avf-debian12-reset-password.sh [--help]
Choose the root password or the user (droid) password interactively.
Run inside the Debian AVF guest. Root access or working sudo is required.
EOF
}
if (( $# )); then
 if (( $# == 1 )) && [[ $1 == --help || $1 == -h ]]; then
  usage
  exit 0
 fi
 echo 'Error: unsupported arguments. Use --help for usage.' >&2
 exit 2
fi

if ! { exec 3<>/dev/tty; } 2>/dev/null; then
 echo 'Error: an interactive terminal is required.' >&2
 exit 1
fi

printf '%s\n' 'Which password would you like to reset?' \
 '  1) root password' '  2) user (droid) password' '  0) Cancel' >&3
while true; do
 printf 'Select [1/2/0]: ' >&3
 if ! IFS= read -r choice <&3; then
  echo 'Cancelled.' >&3
  exit 0
 fi
 case $choice in
  1|root) account=root; break ;;
  2|user|droid) account=droid; break ;;
  0|q|quit) echo 'Cancelled.' >&3; exit 0 ;;
  *) echo 'Invalid choice. Enter 1, 2, or 0.' >&3 ;;
 esac
done

if ! account_uid=$(id -u "$account" 2>/dev/null); then
 printf 'Error: account "%s" does not exist.\n' "$account" >&3
 exit 1
fi
if [[ $account == droid && $account_uid == 0 ]]; then
 echo 'Error: droid must be a non-root account.' >&3
 exit 1
fi
command -v passwd >/dev/null || { echo 'Error: passwd is not installed.' >&3; exit 1; }
password_command=(passwd "$account")
if (( EUID != 0 )); then
 command -v sudo >/dev/null || {
  echo 'Error: sudo is unavailable. Run this script from a root shell (su -).' >&3
  exit 1
 }
 password_command=(sudo -- "${password_command[@]}")
fi

printf 'Resetting the password for %s. Password input will not be displayed.\n' "$account" >&3
if "${password_command[@]}" <&3 >&3 2>&3; then
 printf 'Password for %s reset successfully.\n' "$account" >&3
else
 echo 'Error: password reset failed. Please try again.' >&3
 exit 1
fi
