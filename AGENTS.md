# Repository Guidelines

## Project Structure

This repository provisions a Debian 12 ARM64 guest running under Android AVF. The root contains `avf-debian12-init.sh` (initialization), `avf-debian12-verify.sh` (post-install checks), and `avf-debian12-reset-password.sh` (interactive password reset). `README.md` documents installation and options; `运行后检查说明.md` and `验证记录.md` describe verification. `docs/HANDOFF.md` records operational context. There is no separate source, asset, or automated test directory.

## Development and Verification

Run scripts with Bash, using real files and LF line endings. On a machine with Bash, check syntax before submitting changes:

```bash
bash -n avf-debian12-init.sh avf-debian12-verify.sh avf-debian12-reset-password.sh
shellcheck avf-debian12-init.sh avf-debian12-verify.sh avf-debian12-reset-password.sh
```

ShellCheck is an optional local tool. On a real Debian 12 ARM64 AVF guest with systemd, use `bash avf-debian12-init.sh --check` for diagnostics or `--dry-run` for the proposed plan. Both write private temporary reports but do not perform installation. After initialization, run `sudo bash avf-debian12-verify.sh`; its local checks do not replace manual connection, desktop, and reboot testing. The initializer without these flags changes the guest system.

## Style and Testing

Follow the existing Bash style: `#!/bin/bash`, strict error handling, quoted expansions, descriptive lowercase function names, and uppercase configuration variables. Preserve the surrounding indentation and keep embedded Python consistent with its existing four-space indentation. Name additional scripts `avf-debian12-<purpose>.sh`. Update the Chinese user documentation when commands or behavior change.

No coverage threshold or standalone test framework is configured. Check syntax and relevant safe modes for each change; exercise system-changing behavior only in a suitable test guest. Describe which checks were run and which require real-device validation.

## Commits and Pull Requests

Recent commits use concise Chinese summaries describing the change; follow that pattern and keep each commit focused. Pull requests should explain the problem and behavior, list verification results and remaining manual checks, and link relevant issues. Include screenshots when documentation or visible desktop behavior changes.

## Security and Configuration

Keep VNC bound to localhost and preserve private report and backup permissions. Never log passwords, keys, or Tailscale enrollment links; avoid `bash -x` during secret entry. Preserve the documented download-to-file workflow because privilege escalation must be able to reread the script. Do not push changes without the repository owner’s instruction.
