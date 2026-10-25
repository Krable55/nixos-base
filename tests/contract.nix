# Projection of the persistent contract: compare image with deployed host.
# Deliberately excludes image-only assembly/registration/partition expansion.
{ config, pkgs, ... }:
{
  platform = pkgs.stdenv.hostPlatform.system;
  kernel = config.boot.kernelPackages.kernel.outPath;
  kernelParams = config.boot.kernelParams;
  initrdModules = config.boot.initrd.availableKernelModules;
  allHardware = config.hardware.enableAllHardware;
  firmware = config.hardware.enableRedistributableFirmware;
  grub = config.boot.loader.grub.enable;
  extlinux = config.boot.loader.generic-extlinux-compatible.enable;
  bootPaths = config.boot.loader.generic-extlinux-compatible.mirroredBoots;
  root = {
    inherit (config.fileSystems."/") device fsType;
  };
  firmwareMount = {
    inherit (config.fileSystems."/boot/firmware") device fsType options;
  };
  hostname = config.networking.hostName;
  stateVersion = config.system.stateVersion;
  networkManager = config.networking.networkmanager.enable;
  # The enable option may be true while useDHCP=false omits the service.
  dhcpcd = config.systemd.services ? dhcpcd;
  firewall = config.networking.firewall.enable;
  tcpPorts = config.networking.firewall.allowedTCPPorts;
  qemuGuest = config.services.qemuGuest.enable;
  ssh = {
    inherit (config.services.openssh) enable;
    inherit (config.services.openssh.settings) PasswordAuthentication KbdInteractiveAuthentication;
  };
  # Authorized key order has no authentication semantics.
  key = builtins.sort builtins.lessThan config.users.users.kyle.openssh.authorizedKeys.keys;
  groups = config.users.users.kyle.extraGroups;
  rootKeys = config.users.users.root.openssh.authorizedKeys.keys;
  sudoPassword = config.security.sudo.wheelNeedsPassword;
  trustedUsers = config.nix.settings.trusted-users;
}
