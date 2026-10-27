{ ... }:
{
  imports = [
    ../modules/common.nix
    ../hardware/pi4.nix
    ../modules/pi4-remote-access.nix
    ../modules/pi4-zeroclaw-account.nix
  ];

  # Keep workstation access in both the image and Colmena-managed system.
  users.users.kyle.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOTa6Rd0c7R7Pwg8CSVwF6hLrZ2HIUdIz/hcvcK9o3nU kyll@omarchy-to-tower"
  ];

  networking.hostName = "pi4";
  # NetworkManager supplies Ethernet DHCP; no Wi-Fi credentials in the image.
  networking.networkmanager.enable = true;

  # Fresh installation, not a migration of a fleet VM's stateful services.
  system.stateVersion = "26.05";
}
