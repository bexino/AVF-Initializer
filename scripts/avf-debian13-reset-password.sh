#!/bin/bash
# Reset local account passwords from the AVF guest console.
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
Usage: bash avf-debian13-reset-password.sh [--help]
Choose root, droid, or both interactively; --both sets both without a menu.
Run inside the Debian AVF guest. Root access or working sudo is required.
EOF
}
if (( $# )); then
 if (( $# == 1 )) && [[ $1 == --help || $1 == -h ]]; then usage; exit 0; fi
 if (( $# == 1 )) && [[ $1 == --both ]]; then choice=3; else
  echo 'Error: unsupported arguments. Use --help for usage.' >&2; exit 2
 fi
fi

if ! { exec 3<>/dev/tty; } 2>/dev/null; then
 echo 'Error: an interactive terminal is required.' >&2
 exit 1
fi

if [[ ${choice:-} != 3 ]]; then
 printf '%s\n' 'Which password would you like to reset?' \
  '  1) root password' '  2) user (droid) password' '  3) both passwords' '  0) Cancel' >&3
 while true; do
  printf 'Select [1/2/3/0]: ' >&3
  if ! IFS= read -r choice <&3; then echo 'Cancelled.' >&3; exit 0; fi
  case $choice in
   1|2|3) break ;;
   0|q|quit) echo 'Cancelled.' >&3; exit 0 ;;
   *) echo 'Invalid choice.' >&3 ;;
  esac
 done
fi
case $choice in
 1) accounts=(root) ;;
 2) accounts=(droid) ;;
 3) accounts=(root droid) ;;
esac
for account in "${accounts[@]}"; do
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
done
