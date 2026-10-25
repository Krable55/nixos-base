#!/usr/bin/env python3
"""Local evaluation acceptance; never builds or contacts deployment targets."""
import argparse
import json
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[1]
BASELINE_REV = "87cfeeca46b5817a4723361c2b5b9dac8da7342c"


def main():
    if not __debug__:
        raise SystemExit("Run without Python -O: acceptance assertions must remain enabled")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, default=REPO / "tests/hive-baseline.json")
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    expression = r'''
      let
        f = builtins.getFlake FLAKE;
        h = import (f.inputs.colmena.outPath + "/src/nix/hive/eval.nix") { rawFlake = f; };
      in
        if !(f.colmena ? pi4) then throw "acceptance: missing pi4 hive node"
        else {
          existing = builtins.mapAttrs (_: n: n.config.system.build.toplevel.drvPath)
            (builtins.removeAttrs h.nodes [ "pi4" ]);
          pi4 = h.nodes.pi4.config.system.build.toplevel.drvPath;
          image = f.packages.aarch64-linux.pi4-image.drvPath;
          runtimeContract = import (f.outPath + "/tests/contract.nix") h.nodes.pi4;
          imageContract = import (f.outPath + "/tests/contract.nix") f.nixosConfigurations.pi4-image;
          deployment = h.nodes.pi4.config.deployment;
          assembly = let c = f.nixosConfigurations.pi4-image.config; in {
            expand = c.sdImage.expandOnBoot;
            registrationCondition = c.systemd.services.register-nix-paths.unitConfig.ConditionPathExists;
            expansionCondition = c.systemd.services.expand-root-partition.unitConfig.ConditionPathExists;
            firmwareCommands = c.sdImage.populateFirmwareCommands;
            rootCommands = c.sdImage.populateRootCommands;
            imagePath = c.image.filePath;
          };
          runtimeHasImageAssembly = h.nodes.pi4.config ? sdImage;
        }
    '''.replace("FLAKE", json.dumps("path:" + str(REPO)))
    command = ["nix", "--extra-experimental-features", "nix-command flakes", "eval",
               "--impure", "--no-write-lock-file", "--json", "--expr", expression]
    result = subprocess.run(command, text=True, capture_output=True)
    if result.stderr:
        print(result.stderr, end="")
    if result.returncode:
        raise SystemExit(result.returncode)
    actual = json.loads(result.stdout)
    runtime, image = actual["runtimeContract"], actual["imageContract"]
    differences = {key: {"runtime": runtime[key], "image": image[key]}
                   for key in runtime if runtime[key] != image[key]}
    assert not differences, ("image-to-Colmena persistent contract drift", differences)
    assert runtime["platform"] == "aarch64-linux"
    assert runtime["hostname"] == "pi4"
    assert runtime["stateVersion"] == "26.05"
    assert runtime["root"] == {"device": "/dev/disk/by-label/NIXOS_SD", "fsType": "ext4"}
    assert runtime["firmwareMount"] == {
        "device": "/dev/disk/by-label/FIRMWARE", "fsType": "vfat", "options": ["nofail", "noauto"]}
    assert runtime["extlinux"] and not runtime["grub"] and not runtime["qemuGuest"]
    assert runtime["allHardware"] and runtime["firmware"]
    assert runtime["networkManager"] and not runtime["dhcpcd"]
    assert runtime["firewall"] and 22 in runtime["tcpPorts"]
    assert runtime["ssh"] == {
        "enable": True, "PasswordAuthentication": False, "KbdInteractiveAuthentication": False}
    assert sorted(runtime["key"]) == sorted([
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMh4QcZWNLqRMaj0D5iKH3FDZ8n/rKJR6XFLNQs7bWsa my key for nixos",
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTa6Rd0c7R7Pwg8CSVwF6hLrZ2HIUdIz/hcvcK9o3nU kyll@omarchy-to-tower",
    ]), "Pi must authorize both fleet and workstation keys"
    assert not runtime["rootKeys"] and not runtime["sudoPassword"]
    assert "wheel" in runtime["groups"] and "@wheel" in runtime["trustedUsers"]
    deployment = actual["deployment"]
    assert deployment["targetHost"] == "pi4.local" and deployment["targetUser"] == "kyle"
    assert deployment["privilegeEscalationCommand"] == ["sudo", "-n", "-H", "--"]
    assert deployment["buildOnTarget"] is True and deployment["keys"] == {}
    assembly = actual["assembly"]
    assert assembly["expand"] and not actual["runtimeHasImageAssembly"]
    assert assembly["registrationCondition"] == assembly["expansionCondition"] == "/nix-path-registration"
    assert "u-boot-rpi4.bin" in assembly["firmwareCommands"]
    assert "armstub8-gic.bin" in assembly["firmwareCommands"]
    assert "bcm2711-rpi-4-b.dtb" in assembly["firmwareCommands"]
    assert "extlinux-conf-builder" in assembly["rootCommands"]
    assert assembly["imagePath"] == "sd-image/nixos-pi4.img.zst"
    assert actual["existing"] == baseline, ("VM derivation drift", actual["existing"], baseline)
    old_lock = json.loads(subprocess.check_output(
        ["git", "show", BASELINE_REV + ":flake.lock"], cwd=REPO, text=True))
    new_lock = json.loads((REPO / "flake.lock").read_text())
    assert set(new_lock["nodes"]) - set(old_lock["nodes"]) == {"nixpkgs-pi"}
    for name, node in old_lock["nodes"].items():
        if name == old_lock["root"]:
            for key, value in node["inputs"].items():
                assert new_lock["nodes"][name]["inputs"][key] == value, ("root input drift", key)
        else:
            assert new_lock["nodes"][name] == node, ("existing lock node drift", name)
    print(json.dumps({key: actual[key] for key in ["existing", "pi4", "image"]}, indent=2))
    print(f"PASS: image/host persistent contract; access/deployment policy; {len(baseline)} exact VM drvPaths; existing lock nodes unchanged")


if __name__ == "__main__":
    main()
