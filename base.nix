# Compatibility wrapper for the existing Proxmox VM fleet.
{ modulesPath, lib, ... }:
{
  imports = [
    ./modules/common.nix
    (modulesPath + "/profiles/qemu-guest.nix")
  ];

  services.qemuGuest.enable = lib.mkDefault true;
  boot.loader.grub.enable = lib.mkDefault true;
  boot.loader.grub.devices = [ "nodev" ];
  boot.growPartition = lib.mkDefault true;

  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };
}
