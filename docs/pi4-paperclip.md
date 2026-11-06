# Paperclip on Pi4

Paperclip v2026.1023.0 runs as the official multi-architecture OCI image, pinned by digest in `modules/pi4-paperclip.nix`. NixOS manages Podman and the `podman-paperclip.service` unit. Only the deployed Pi imports this module; the reusable SD image does not.

## Initial access

Open http://192.168.50.238:3100 from the home LAN. The container port is bound to this LAN address and TCP 3100 is allowed by the host firewall. Reserve this address in DHCP; an address change requires updating the binding and canonical auth URL. No router port forwarding is configured. This is unencrypted HTTP: use only on a trusted LAN until HTTPS is configured.

Complete the upstream initial account/board setup yourself. No account credentials are stored in this repository. Authenticated mode is enabled; this is not `local_trusted` mode. Scheduled agent heartbeats are disabled during initial setup. No agent credentials or agents are provisioned by this module.

Public HTTPS and Zitadel integration are not configured. Before public exposure, establish ownership, choose the canonical HTTPS hostname, update auth URLs and allowed hosts, decide signup policy, and restrict backend access to the reverse proxy. Do not merely open port 3100.

## State and secrets

- Named Podman volume `paperclip-data` mounted at `/paperclip`: embedded PostgreSQL, application state, and local storage.
- `/var/lib/paperclip-secrets/environment`: root-only, generated on the Pi once, contains Better Auth secret. Not in the Nix store.
- Built-in database backups are enabled. These remain on the Pi and are not an off-device disaster-recovery backup.
- Never remove the data volume during upgrades. Preserve both the state and auth secret. System rollback does not roll back database migrations; take a consistent database backup before upgrading the image.

The upstream container starts through its entrypoint and drops privileges to its node user. No host home directory, Docker/Podman socket, or existing ZeroClaw credentials are mounted into it.

## Operations

    sudo systemctl status podman-paperclip
    curl http://192.168.50.238:3100/api/health
    sudo podman ps --filter name=paperclip

Do not paste raw logs into chat: onboarding URLs or other credentials may appear in logs.

Evaluation test (includes newly created untracked files through a path flake):

    nix eval --impure --file tests/pi4-paperclip.nix

Deploy with the pinned Colmena binary and `--impure --on pi4 -f path:/absolute/path/to/nixos-base`. The host SSH works with `pi4.local`; the development shell's SSH may lack working mDNS resolution on the workstation.
