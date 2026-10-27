#!/usr/bin/env python3
"""Local evaluation acceptance; never builds or contacts deployment targets."""
import argparse
import json
from pathlib import Path
import subprocess

REPO = Path(__file__).resolve().parents[1]
BASELINE_REV = "b540883e346d3c551d4e6db9ec1b18749cf88af2"
MAIN_NODES = {"auth", "builder", "lore", "media-center", "networking", "powerball", "trader"}
# Confirmed by evaluating an untouched export of BASELINE_REV.
DERIVATION_EXCLUSIONS = {
    "powerball": "unchanged main cannot evaluate: missing age.secrets.supabase-admin-password"
}


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
        h = f.colmenaHive;
      in
        if !(h.nodes ? pi4) then throw "acceptance: missing pi4 hive node"
        else {
          existingNames = builtins.attrNames (builtins.removeAttrs h.nodes [ "pi4" ]);
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
    '''.replace("FLAKE", json.dumps("git+file://" + str(REPO)))
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
    old_lock = json.loads(subprocess.check_output(
        ["git", "show", BASELINE_REV + ":flake.lock"], cwd=REPO, text=True))
    new_lock = json.loads((REPO / "flake.lock").read_text())
    assert set(new_lock["nodes"]) == set(old_lock["nodes"]) | {"nixpkgs-pi"}
    assert new_lock["nodes"][new_lock["root"]]["inputs"] == {
        **old_lock["nodes"][old_lock["root"]]["inputs"], "nixpkgs-pi": "nixpkgs-pi"}
    for name, node in old_lock["nodes"].items():
        if name == old_lock["root"]:
            for key, value in node["inputs"].items():
                assert new_lock["nodes"][name]["inputs"][key] == value, ("root input drift", key)
        else:
            assert new_lock["nodes"][name] == node, ("existing lock node drift", name)
    print(json.dumps({key: actual[key] for key in ["pi4", "image"]}, indent=2))
    print("PASS: image/host persistent contract; access/deployment policy; existing lock nodes unchanged", flush=True)
    assert actual["existingNames"] == sorted(MAIN_NODES), "VM node set drift"
    assert set(baseline) == MAIN_NODES - DERIVATION_EXCLUSIONS.keys(), "VM baseline set drift"
    print("PASS: full seven-node main VM set", flush=True)
    for name, reason in DERIVATION_EXCLUSIONS.items():
        print(f"EXCLUDED from derivation equality: {name}: {reason}", flush=True)
    failures = []
    for name, expected in baseline.items():
        vm_expression = (
            "let f = builtins.getFlake " + json.dumps("git+file://" + str(REPO)) + "; in "
            "f.colmenaHive.nodes." + json.dumps(name) + ".config.system.build.toplevel.drvPath")
        vm_result = subprocess.run(command[:-1] + [vm_expression], text=True, capture_output=True)
        if vm_result.returncode:
            print(vm_result.stderr, end="")
            failures.append(f"{name}: evaluation failed (baseline: {expected!r})")
        elif json.loads(vm_result.stdout) != expected:
            failures.append(f"{name}: VM derivation drift: {vm_result.stdout.strip()} != {expected}")
        else:
            print(f"PASS: {name} exact VM drvPath", flush=True)
    if failures:
        raise SystemExit("VM acceptance failed:\n" + "\n".join(failures))
    print(f"PASS: {len(baseline)} exact VM drvPaths; powerball explicitly excluded")


if __name__ == "__main__":
    main()
