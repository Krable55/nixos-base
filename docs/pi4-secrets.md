# Pi4 bootstrap secret

## Scope and isolation

`modules/pi4-secrets.nix` is imported only by the Colmena `pi4` node in
`flake.nix`. The reusable SD image deliberately does not import it: a fresh
installation generates a different SSH host key and cannot decrypt the current
host-bound ciphertext until its public recipient is added using the recovery
identity.

The existing `modules/sops.nix` is not used. This module uses the options of the
already-pinned sops-nix input; no lock update is required.

Only ciphertext in `secrets/pi4.yaml` is copied into the Nix store. sops-nix uses
`/etc/ssh/ssh_host_ed25519_key` on the Pi at activation/boot to provision:

- Path: `/run/secrets/op-service-account-token`
- Owner/group: `root:root`
- Mode: `0400`
- YAML key: `op_service_account_token`

The host private key never leaves the Pi. The plaintext OP token must not be
placed in Nix strings, environment definitions, command arguments, logs, or Git.
`zeroclaw` must not be able to read this bootstrap secret. An administrator with
root/sudo access can read it; the root-only boundary does not isolate it from
administrators.

This step does not install an OP fetch job, validate service-account permissions,
provision an OpenAI application key, or deploy a ZeroClaw daemon. No consumer
restart/reload units are configured yet. The future root-owned fetcher must
receive this token via a runtime credential/file, fail closed if unavailable,
and deliver only the fetched application key to ZeroClaw.

## Recipients and recovery

`.sops.yaml` encrypts for either of two age recipients:

- Installed Pi's SSH host key:
  `age1ww6gaksz7k2d3uwwrjc04scckc344jkd5gtesdyaxznekqln0vnqulm57y`
- Human-controlled recovery identity:
  `age1x0xfdm6c70lzawwvvlkrqlptednxzyw4l42ntwg2rs4m5zszncrs3ywdd3`

The recovery private identity is in 1Password **Infrastructure Recovery**, item
**Pi4 SOPS age recovery key** (item ID `lnlr72ui67axbk6pjoq4s4reae`), in its
concealed password field. Never grant workload service accounts access to that
vault. Account owners/administrators retain vault-management permissions.

The initial token was entered through a local masked dialog and piped as JSON
to SOPS, with YAML ciphertext output. Recovery decryption was checked in memory;
no plaintext key/token file was created. This verifies encryption integrity, not
token validity or account scope.

After host-key loss/reinstallation, obtain and verify the replacement host's
public key, update the Pi recipient in `.sops.yaml`, and use the recovery identity
with `sops updatekeys secrets/pi4.yaml` before deployment. Keep the recovery
recipient. Merely editing `.sops.yaml` does not change existing ciphertext.
Supply recovery identities through a protected local runtime mechanism; do not
paste them into command arguments or chat. Retire obsolete host-key recipients
after verifying the new host can decrypt.

Application-key rotation happens in 1Password and will require the future
fetcher's explicit refresh/restart procedure, not a SOPS change. Bootstrap
service-account-token rotation requires replacing the encrypted token and
redeploying. Preserve the existing encrypted file if input/encryption fails.

## Validation

Run from the repository root:

```sh
nix eval --impure --no-write-lock-file --json --file tests/pi4-secrets.nix
python3 tests/evaluate.py
nix eval --impure --no-write-lock-file --json --file tests/zeroclaw-account.nix
nix eval --impure --no-write-lock-file --json --file tests/remote-access.nix
```

The evaluation tests check runtime policy, exclude host-bound secrets from the
SD image, preserve all four existing VM derivations and original lock nodes,
and preserve the account/remote-access contracts. An existing nixpkgs
`system`-attribute rename warning is unrelated to this change.

Deploy only `pi4` with the pinned Colmena CLI and a `path:` flake so untracked
files are included. The configured target is `kyle@pi4.local`; check it is
reachable first. This does not require a reboot.

After activation, run the non-secret runtime acceptance test:

```sh
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes kyle@pi4.tail42566.ts.net \
  bash -s < tests/pi4-secrets-runtime.sh
```

It checks only metadata and access results: secret exists and is nonempty,
dereferenced owner/mode is root:root/0400, and `sudo -u zeroclaw test -r` fails.
It also checks memory-backed storage, SSH, Tailscale, Herdr, and failed system
and user units, then prints active/boot profiles and boot ID. Never print or
journal the secret contents.

## Verified deployment

Pinned Colmena `apply build` and `apply switch --impure --on pi4 --no-keys`
succeeded. The active system and boot-default profile both resolve to
`/nix/store/la9m7ix9l4ad2vmn99vw6g69x485h1jr-nixos-system-pi4-26.05pre-git`.
The runtime acceptance script passed: nonempty root:root/0400 secret on ramfs,
zeroclaw read denied, SSH/Tailscale/Herdr active, and no failed system/user units.
Boot ID was unchanged; no reboot was performed. Cold-boot decryption has not yet
been tested. All evaluation/regression tests passed, with the existing
nixpkgs rename warning; Colmena also reported ignored `builders-use-substitutes`
settings without blocking the build or activation.
