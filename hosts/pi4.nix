{ ... }:
{
  imports = [
    ../modules/common.nix
    ../hardware/pi4.nix
    ../modules/pi4-remote-access.nix
    ../modules/pi4-zeroclaw-account.nix
  ];

  networking.hostName = "pi4";
  # NetworkManager supplies Ethernet DHCP; no Wi-Fi credentials in the image.
  networking.networkmanager.enable = true;

  # Fresh installation, not a migration of a fleet VM's stateful services.
  system.stateVersion = "26.05";
}
