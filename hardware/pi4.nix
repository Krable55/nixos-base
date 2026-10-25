# Persistent Pi4 boot contract shared by SD image and Colmena.
# Image assembly/first-boot expansion and firmware maintenance live elsewhere.
{ lib, options, ... }:
{
  nixpkgs.hostPlatform = "aarch64-linux";
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.consoleLogLevel = lib.mkDefault 7;
  # The upstream image module already supplies these list entries. Preserve
  # them on deployed systems without appending them twice in image evaluation.
  boot.kernelParams = lib.mkIf (!(options ? sdImage)) [
    "console=ttyS0,115200n8"
    "console=ttyAMA0,115200n8"
    "console=tty0"
  ];

  # Preserve the generic ARM image's drivers/firmware across first deployment.
  # Narrow only after physical SD/USB/network boot verification.
  hardware.enableAllHardware = true;

  fileSystems."/" = {
    device = "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
  };
  # /boot is on the ext4 root, NOT on this firmware partition.
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = lib.mkDefault [ "nofail" "noauto" ];
  };
}
