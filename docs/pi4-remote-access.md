# Pi4 remote access

`hosts/pi4.nix` imports `modules/pi4-remote-access.nix` for both image and
Colmena deployments. Existing VM nodes do not import it.

- Tailscale daemon enabled, with its UDP firewall opening. No exit-node/subnet
  routing, embedded auth key, or Tailscale SSH is configured.
- Herdr 0.9.5 is packaged from the official static Linux ARM64 release with a
  fixed SHA-256. Upgrade through Nix, not `herdr update`.
- A systemd user service starts the default Herdr session for `kyle`.
  Linger enables startup without an interactive login and survival after logout.
  Panes run as `kyle`, which already has passwordless sudo; this is not an agent
  sandbox. Service restarts/reboots can terminate running pane processes.
- SSH is the transport; Herdr does not need a public TCP listener.

## Enrollment

Run `sudo tailscale up` on the Pi and complete the printed login URL yourself.
No credentials belong in this repository. Tailscale state lives on the Pi and
must be enrolled again after a fresh image installation. Confirm with
`tailscale status` and `tailscale ip -4`.

On each client with SSH access and Herdr installed:

```sh
herdr machine add kyle@pi4.local --label pi4 --remote-session default
herdr machine status pi4 --json
```

For remote/off-LAN clients, replace `pi4.local` with the enrolled Pi's Tailscale
IP or MagicDNS name and ensure the client's tailnet policy permits SSH. Each
client still needs an authorized SSH key. The workstation profile initially uses
LAN mDNS, so it is not yet an off-LAN connection.

## Validation

```sh
nix --extra-experimental-features 'nix-command flakes' eval --impure --json --file tests/remote-access.nix
python3 tests/evaluate.py
```

Initial deployment via pinned Colmena `apply switch --impure --on pi4` passed.
Verified Herdr 0.9.5 server running, user service enabled, linger enabled,
tailscaled active, no failed system units, and remote workspace API accessible
from the workstation's saved `pi4` profile. Tailscale enrollment completed;
MagicDNS name is `pi4.tail42566.ts.net`, IPv4 `100.87.219.4`. SSH over the
Tailscale addresses and Herdr server status passed using the existing trusted
LAN host-key alias. An authorized post-deployment reboot passed: boot ID changed
from `aeebdafa-7a8f-41aa-9156-596863fa2abe` to
`fd0e75e3-e2f5-4ec1-84f8-d663505a07a2`; SSH returned over Tailscale,
Wi-Fi reconnected with Ethernet disconnected, tailscaled and Herdr were active,
linger remained enabled, and neither system nor user services reported failures.
Herdr machine reachability and remote workspace listing also passed after reboot.
Actual off-LAN connectivity has not been tested. After user host-key acceptance, the workstation's saved
`pi4` Herdr profile was switched to `kyle@pi4.tail42566.ts.net` and verified
reachable with a successful remote workspace-list API call. The old LAN-only
profile was removed without stopping the remote server or its sessions.
