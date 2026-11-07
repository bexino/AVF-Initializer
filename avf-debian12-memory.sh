#!/bin/bash
# Adjust the Android Terminal host configuration shared with the guest.
set +x
set -Eeuo pipefail
umask 077
config=/mnt/internal/linux/vm_config.json
backup_dir=/var/backups/avf-memory
usage() {
 cat <<'EOF'
Usage: sudo bash avf-debian12-memory.sh --check | --apply | --restore BACKUP
--check: show guest memory and the candidate host allocation.
--apply: back up the candidate configuration and set memory_mib to 8192.
--restore: restore a backup created by this script.
A full VM stop and cold start are required; launcher support is not guaranteed.
EOF
}
[[ $# -ge 1 ]] || { usage; exit 2; }
case $1 in
 --help|-h) usage; exit 0;;
 --check|--apply) [[ $# == 1 ]] || { usage; exit 2; };;
 --restore) [[ $# == 2 ]] || { usage; exit 2; };;
 *) usage; exit 2;;
esac
command -v python3 >/dev/null || { echo 'python3 is required.' >&2; exit 1; }
if [[ $1 != --check && $EUID != 0 ]]; then
 echo 'Run this operation as root with sudo.' >&2; exit 1
fi
python3 - "$1" "$config" "$backup_dir" "${2:-}" <<'PY'
import json
import os
import pathlib
import sys
import tempfile

mode, config, backup_dir, restore = sys.argv[1:]
path = pathlib.Path(config)
try:
    with path.open('rb') as f:
        original = f.read()
    data = json.loads(original)
    if not isinstance(data, dict) or type(data.get('memory_mib')) is not int:
        raise ValueError('configuration must contain an integer memory_mib')
    print('Candidate host memory_mib:', data['memory_mib'], 'MiB')
    with open('/proc/meminfo', encoding='utf-8') as f:
        print(next(line.strip() for line in f if line.startswith('MemTotal:')))
    if mode == '--check':
        print('Configuration is a candidate; launcher use and host capacity are unverified.')
        sys.exit(0)
    directory = pathlib.Path(backup_dir)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(directory, 0o700)
    if mode == '--restore':
        source = pathlib.Path(restore).resolve(strict=True)
        if source.parent != directory.resolve() or not source.is_file():
            raise ValueError('restore file must be a backup in ' + backup_dir)
        replacement = source.read_bytes()
        saved = json.loads(replacement)
        if not isinstance(saved, dict) or type(saved.get('memory_mib')) is not int:
            raise ValueError('invalid backup')
    else:
        data['memory_mib'] = 8192
        replacement = (json.dumps(data, ensure_ascii=False, indent=2) + '\n').encode('utf-8')
    fd, backup = tempfile.mkstemp(prefix='vm_config-', suffix='.json', dir=directory)
    with os.fdopen(fd, 'wb') as f:
        f.write(original)
        f.flush()
        os.fsync(f.fileno())
    print('Original configuration backup:', backup, flush=True)
    # Write through the shared file: replacing its inode may not be supported by
    # the Android shared filesystem. Restore immediately if a write fails.
    try:
        with path.open('r+b') as f:
            f.seek(0)
            f.write(replacement)
            f.truncate()
            f.flush()
            os.fsync(f.fileno())
    except OSError:
        try:
            with path.open('r+b') as f:
                f.write(original)
                f.truncate()
                f.flush()
                os.fsync(f.fileno())
        except OSError:
            print('Automatic restore failed; recover from the backup above.', file=sys.stderr)
        raise
    print('Configuration written. Fully stop the VM, cold start, and verify with free -h.')
except (OSError, ValueError, StopIteration) as e:
    print('Memory operation failed:', e, file=sys.stderr)
    sys.exit(1)
PY
