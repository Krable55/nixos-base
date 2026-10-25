# Assembly only. Persistent host and boot settings are in hosts/pi4.nix.
{ modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/sd-card/sd-image-aarch64.nix") ];
  # This is the installed fleet host, not a general-purpose rescue image.
  # Avoid image-only filesystem support (including ZFS) and installer tools.
  disabledModules = [ (modulesPath + "/profiles/base.nix") ];
  image.baseName = "nixos-pi4";
  sdImage.compressImage = true;
  sdImage.expandOnBoot = true;
}
