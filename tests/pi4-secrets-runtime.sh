#!/usr/bin/env bash
# Run over SSH as kyle. Prints metadata/status only, never secret contents.
# Usage: ssh kyle@pi4.tail42566.ts.net bash -s < tests/pi4-secrets-runtime.sh
set -euo pipefail
secret=/run/secrets/op-service-account-token

sudo -n true
if ! sudo -n test -s "$secret"; then
  printf '%s\n' 'FAIL: bootstrap secret is missing or empty' >&2
  exit 1
fi
metadata=$(sudo -n stat -Lc '%U:%G:%a' "$secret")
if [[ "$metadata" != root:root:400 ]]; then
  printf '%s\n' 'FAIL: bootstrap secret owner/group/mode is not root:root:0400' >&2
  exit 1
fi
[[ $(sudo -n -u zeroclaw id -un) == zeroclaw ]]
if sudo -n -u zeroclaw test -r "$secret"; then
  printf '%s\n' 'FAIL: zeroclaw can read the bootstrap secret' >&2
  exit 1
else
  result=$?
  if [[ "$result" != 1 ]]; then
    printf '%s\n' 'FAIL: zeroclaw access test could not execute normally' >&2
    exit 1
  fi
fi
filesystem=$(findmnt -n -o FSTYPE --target "$(sudo -n readlink -f "$secret")")
case "$filesystem" in
  ramfs|tmpfs) ;;
  *) printf '%s\n' 'FAIL: decrypted secret is not on a runtime memory filesystem' >&2; exit 1 ;;
esac
systemctl is-active --quiet sshd
systemctl is-active --quiet tailscaled
systemctl --user is-active --quiet herdr
[[ -z $(systemctl --failed --no-legend --no-pager) ]]
[[ -z $(systemctl --user --failed --no-legend --no-pager) ]]
printf 'PASS: secret nonempty; owner/group/mode=%s; filesystem=%s; zeroclaw read denied\n' "$metadata" "$filesystem"
printf '%s\n' 'PASS: SSH, Tailscale, Herdr active; no failed system/user units'
printf 'active_profile=%s\n' "$(readlink -f /run/current-system)"
printf 'boot_profile=%s\n' "$(readlink -f /nix/var/nix/profiles/system)"
printf 'boot_id=%s\n' "$(</proc/sys/kernel/random/boot_id)"
