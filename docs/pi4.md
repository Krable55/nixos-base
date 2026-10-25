# Pi4 fleet image and deployment

## Current image: workstation SSH access

The Pi-specific host configuration now adds the workstation public key alongside
its existing fleet key, for both image boot and Colmena-managed operation. No
private key was embedded. Evaluation acceptance passed, including unchanged
derivations for all four existing VMs. The rebuilt image passed partition,
firmware, boot-reference and registration-marker inspection; both authorized
public keys were read directly from its filesystem.

Use `/home/kyll/Documents/pi-nix/nixos-pi4-workstation.img` for the next flash
(including balenaEtcher), not the older image below.

- Raw bytes: 4,189,028,352.
- Raw SHA-256: `b10b4653343f6724bb1b736d03eea15193e0e81211d0aefbdc899c12e772acf6`.
- Compressed output: `/home/kyll/Documents/pi-nix/result-pi4-workstation/sd-image/nixos-pi4.img.zst`.
- Inspection: `/home/kyll/Documents/pi-nix/artifact-workstation-inspection.json`.
- Reflashed the reinserted 32GB card (reader serial `121220160204`, diskseq 5).
  All 4,189,028,352 bytes passed SHA-256 read-back verification against the raw
  image above. Card safely powered off; temporary automount inhibition removed.
  Evidence: `/home/kyll/Documents/pi-nix/flash-workstation-pi4.log`.
  Physical boot, SSH, initial reboot, Pi-only Colmena deployment and subsequent
  reboot all passed. See physical acceptance below.

## Scope and ownership

Target: Raspberry Pi 4 Model B, 8GB, hostname `pi4`, Ethernet DHCP, spare/new
microSD. No application role is enabled. The existing `kyle` public key and
passwordless wheel sudo policy are reused; the owner confirmed private-key
control. No private key, Wi-Fi password, root authorized key, or enrollment token
belongs in the image.

- `modules/common.nix`: fleet policy, users, SSH, networking and packages.
- `base.nix`: compatibility wrapper for the existing Proxmox VMs only.
- `hosts/pi4.nix` + `hardware/pi4.nix`: persistent configuration shared by the
  image and Colmena. `system.stateVersion = "26.05"` is for this new installation;
  do not advance it automatically with package updates.
- `images/pi4.nix`: SD assembly, compression, first-boot store registration and
  expansion. The generic installer/rescue package profile is disabled; this is
  the installed host, not rescue media. Broad hardware/firmware support remains.
- `flake.nix`: explicit ARM image output and Pi hive entry. Only Pi uses the
  separate stable `nixpkgs-pi` input. All existing input nodes remain pinned.

This implementation passed local evaluation, full image build, artifact inspection,
and physical boot/SSH/reboot plus Colmena deployment/reboot acceptance.
The artifact below is historical; use the workstation-key image above.

Built artifact: `/home/kyll/Documents/pi-nix/result-pi4/sd-image/nixos-pi4.img.zst`

- Compressed size: 1,566,801,754 bytes; raw image: 4,189,028,352 bytes.
- SHA-256: `a6feccedc3c11b928282485b865bbc3afcb333d354e2c6c5a2cb6f7d45a2eb40`.
- Verified zstd integrity, MBR/FAT/root layout and labels, Pi4 firmware files,
  extlinux kernel/initrd/DTB references, system init path and registration marker.
- Evidence: `/home/kyll/Documents/pi-nix/artifact-inspection.json` and
  `/home/kyll/Documents/pi-nix/pi4-build-resume.log`.
- Initial foreground build was interrupted by the command runner timeout;
  the resumed tracked build completed with exit status 0.

## Physical acceptance completed

Pi reached at `pi4.local` / `192.168.50.237`. Initial SSH host key was accepted
on trust-on-first-use, not verified by an independent console. Its ED25519
fingerprint is `SHA256:duc2glSBhAWkzvkm3G7H11kDq58ZPnD6YK++dcYPREo`.

Authorized pinned Colmena `apply switch --impure --on pi4` completed target
build and activation. Generation 2 is active, and the subsequent reboot changed
boot ID from `040b573d-11e4-442c-8c94-a11e71e15d3c` to
`98830417-7ecc-4c35-a607-fcbcb9d756ce`. Post-reboot system matched:
`/nix/store/1izyg5wyr9rhvs09l2z7yc3ng5cwb8yw-nixos-system-pi4-26.05pre-git`.

Verified SSH, both public keys, noninteractive sudo, ARM architecture, filesystem
labels, 30G expanded root with 25G free, complete registration, time sync, and no
failed services. Extlinux default points to generation 2; generation 1 remains
available (rollback not exercised). No other nodes were targeted. Existing VM
baseline and lock preservation tests passed. Firmware/EEPROM were not updated.

Evidence in `/home/kyll/Documents/pi-nix/`: `pi4-pre-deploy.txt`,
`pi4-colmena-deploy.log`, `pi4-post-deploy.txt`.

Wi-Fi was subsequently configured locally with NetworkManager. A Wi-Fi-only
reboot passed: SSH returned via `pi4.local`, Ethernet remained disconnected,
and the expected deployed system was running with no failed services. The
root-owned mode-0600 connection profile has autoconnect enabled and credentials
saved locally. Credentials are not in Git or the image; configure Wi-Fi again
after reflashing. Ethernet remains the credential-free bootstrap route.


## Local acceptance and image build

From the repository root:

```sh
python3 tests/evaluate.py
# During this implementation, also compare the originally supplied evidence:
python3 tests/evaluate.py --baseline ../hive-baseline.json
```

Requires installed Python 3, Nix with flakes, and Git history containing baseline
`87cfeeca46b5817a4723361c2b5b9dac8da7342c`. The checked-in baseline fixture is copied
from that review's `hive-baseline.json`. The test uses a **path flake**, so untracked
new files are included without staging. It does not build derivations or contact
SSH targets. Initial runs may fetch the pinned public inputs.

Checks: exact derivation equality for all four old VMs; unchanged existing locked
nodes/input mappings; Pi/image derivation evaluation; matching persistent kernel,
initrd, boot/filesystem and access policy; first-boot assembly services; no VM
QEMU/GRUB settings on Pi. It deliberately does not claim byte-for-byte equality
between the image's system and deployed system: image-only services/tags differ.

Known evaluation warning: the pinned Colmena evaluator accesses deprecated
`npkgs.system` with newer nixpkgs. Both selected outputs evaluate successfully;
the warning is not silenced by changing existing fleet dependencies.

The parent/build operator runs the actual build separately:

```sh
nix --extra-experimental-features 'nix-command flakes' build \
  --no-write-lock-file \
  "path:$PWD#packages.aarch64-linux.pi4-image" \
  --out-link ../result-pi4 --print-build-logs
```

Expected artifact: `../result-pi4/sd-image/nixos-pi4.img.zst`.
The current route uses the already-approved workstation ARM emulation. A successful
small ARM probe or derivation evaluation is not a successful image build.

Before flashing, inspect the **built artifact**, not only Nix configuration:

1. Test/decompress the zstd file and record its checksum and uncompressed size.
2. Inspect its MBR table: FAT `FIRMWARE`, bootable ext4 root `NIXOS_SD`.
3. Inspect FAT for `config.txt`, `u-boot-rpi4.bin`, `armstub8-gic.bin`,
   `bcm2711-rpi-4-b.dtb`, and the firmware files referenced by configuration.
4. Inspect ext4 for `/boot/extlinux/extlinux.conf`, kernel/initrd/DTBs,
   `/nix-path-registration`, and the configured host closure.
5. Confirm the exact microSD device and capacity, inspect current contents, and
   obtain explicit flashing approval. Keep the old installation untouched.

No generic `dd` command is supplied: selecting a spare card is not proof of the
correct block device. Avoid attaching multiple disks bearing `NIXOS_SD` during
boot; duplicated labels can make root selection ambiguous.

## Boot and SSH acceptance (separate authorization)

Connect Ethernet and boot only after artifact inspection and authorized flashing.
Allow first-boot expansion/registration to finish. Verify the expected DHCP lease;
`pi4.local` assumes the operator machine can resolve mDNS. If it cannot, use the
verified DHCP address in `deployment.targetHost` (or an operator SSH alias), not a
guessed IP. NetworkManager owns Ethernet DHCP; no competing dhcpcd service is
configured. No Wi-Fi secrets are needed.

Before first SSH contact, verify the machine/host-key identity through a trusted
local console or equivalent independent route. The pinned Colmena SSH backend
uses `StrictHostKeyChecking=accept-new`; do not confuse that with authenticated
first-contact identity. Never disable host-key checks or blindly delete a changed
known-host entry. Keep the private key outside the repo/store and use the operator's
SSH agent/configuration.

With separate permission, establish and record:

- `kyle` public-key login, port 22/firewall reachability and correct hostname.
- `sudo -n true`, Nix daemon/store access, sufficient free storage and ARM system.
- `/` resolves to `NIXOS_SD`; `/boot` is a directory on that ext4 root.
- `/boot/firmware` is the FAT partition and normally not mounted (`noauto,nofail`).
- `register-nix-paths` and `expand-root-partition` completed; the registration
  marker was removed and the root partition/filesystem expanded.

Passwordless wheel sudo and trusted `@wheel` grant root-equivalent authority;
using `kyle` avoids root SSH key provisioning, not administrative privilege.

## Pi-only Colmena operation

Use the repository-pinned Colmena, not an arbitrary current `nix-shell -p colmena`.
Verified invocation from this repository root, with explicit node filtering:

```sh
nix --extra-experimental-features 'nix-command flakes' run \
  github:zhaofengli/colmena/2370d4336eda2a9ef29fce10fa7076ae011983ab -- \
  --config "path:$PWD" apply switch --impure --on pi4
```

This command builds/runs the pinned CLI and **modifies the Pi**; it is documentation,
not standing authorization for future runs. CLI execution, transfer, target build,
activation and subsequent reboot passed. Never use an unfiltered `apply` for Pi work.
The repository's historical fleet-wide instructions are not the Pi acceptance path.

Deployment uses `kyle`, `sudo -n -H --`, and `buildOnTarget=true`. Closure transfer
uses a separate SSH/Nix-store path from escalated activation: validate transfer,
build and activation independently. With `buildOnTarget`, even Colmena's `build`
goal contacts/modifies the target store; it is **not** a local dry run. If target
build resources prove inadequate, an explicitly approved `--no-build-on-target`
run can use the workstation ARM builder. No performance/capacity guarantee is made.

Acceptance requires one node-scoped apply, recording the resulting generation,
then an authorized reboot and renewed SSH. Verify `/run/current-system` is the
intended generation, the expected root/mounts/network/access survive, and extlinux
references the deployed kernel/initrd/DTBs. Preserve the bootable fallback card.

## Firmware boundary and recovery

The stock image assembly places Pi firmware, U-Boot, ARM stub and firmware DTBs on
FAT. Normal extlinux activation updates `/boot/nixos` and
`/boot/extlinux/extlinux.conf` on ext4; it **does not automatically refresh FAT**.
Updating `nixpkgs-pi` and applying Colmena alone therefore does not update all boot
components. Board EEPROM is separate again.

Separate controlled firmware maintenance is the accepted first-release scope,
not an inherent Colmena limitation. There is no automatic firmware updater here.
For each future firmware change:

1. Identify the exact candidate firmware/U-Boot/ARM stub/DTB set and compatible
   kernel. Preserve the previous lock/revision and bootable image; record current
   FAT contents/checksums and EEPROM version/configuration.
2. Arrange local physical access, stable power, known-good spare media, and an
   explicit backup/restore procedure. Board EEPROM maintenance requires a separate
   model-specific recovery plan; do not assume changing cards undoes EEPROM.
3. Prefer building/testing a candidate image on spare media before touching the
   working FAT partition. Never improvise unattended copying into the live boot
   partition as part of ordinary Colmena activation.
4. If in-place maintenance is later selected, authorize its exact target and
   procedure separately; verify backups, complete file set, filesystem integrity
   and physical reboot/recovery before treating it as accepted.

NixOS generation rollback can recover a bad kernel/system generation when the
boot chain remains usable; it does **not** restore FAT firmware or EEPROM. With
physical console access, an older extlinux generation may be selected. If the
boot chain or access is broken, power down safely and use the untouched known-good
card/recovery media; do not repeatedly deploy to an uncertain target. The first
milestone requires demonstrating recovery availability, not pretending every
failure is remotely recoverable.

## Pin maintenance and known unrelated defects

Only update `nixpkgs-pi` in a separately reviewed change. Inspect the lock diff and
rerun evaluation/VM equality tests; do not broadly update all flake inputs. Rebuild
and inspect the image for firmware changes, and account for FAT maintenance before
assuming the running device has the new boot components.

The historical standalone builder/VM package output refers to unexported
`self.nixosModules`; the `overlays` output also references an absent directory.
They are outside this change. Broad `flake check/show` can force those unrelated
outputs; use the explicit selected outputs and acceptance test above. Their prior
failure is not evidence that the successfully evaluated Colmena hive is broken.
