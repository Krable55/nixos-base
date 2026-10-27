# ZeroClaw account preparation

Pi-only `modules/pi4-zeroclaw-account.nix` provisions:

- System user/group `zeroclaw`, locked password, `nologin` shell, no SSH keys,
  no supplementary groups, and no lingering user manager.
- `/var/lib/zeroclaw` as its home, with `.zeroclaw` and `.zeroclaw/workspace`
  subdirectories. All three are owned by `zeroclaw:zeroclaw`, mode 0700.
- No sudo rules, Docker access, credentials, agent binary or running service.

`kyle` remains the administrator and retains existing passwordless sudo. A
future systemd system service should use `User=zeroclaw`, `Group=zeroclaw`,
`HOME=/var/lib/zeroclaw` and `UMask=0077`. Add service sandboxing and resource
limits when installing the runtime; a separate Unix account alone is not a
complete sandbox or an outbound-network restriction. Do not run the agent in
an ordinary `kyle` Herdr pane: that would inherit the administrator account.

Keep future credentials outside Git/the Nix store and make files readable only
by the service identity or root as required. No blanket access to other users'
homes or workspaces is granted. Provision explicit paths only when required.

## Verification

```sh
nix --extra-experimental-features 'nix-command flakes' eval --impure --json --file tests/zeroclaw-account.nix
python3 tests/evaluate.py
```

Both image/runtime account assertions and existing fleet regression checks passed.
Pi-only Colmena apply succeeded. Live verification confirmed the locked account,
only its own primary group, nologin shell, directory ownership/modes, workspace
write permission, and denial of noninteractive sudo. Herdr and Tailscale remained
active and there were no failed system services. No reboot was performed for
this account-only change. Deployment log is outside the repository at
`/home/kyll/Documents/pi-nix/pi4-zeroclaw-account-deploy.log`.
