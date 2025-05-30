{ config, pkgs, modulesPath, lib, inputs, ... }: 
{
imports = [
  (modulesPath + "/profiles/qemu-guest.nix")
  inputs."sops-nix".nixosModules.sops
];

  # Provide a default hostname
  networking.hostName = lib.mkDefault "base";
  networking.useDHCP = lib.mkDefault true;

  # Enable QEMU Guest for Proxmox
  services.qemuGuest.enable = lib.mkDefault true;

  # Use the boot drive for grub
  boot.loader.grub.enable = lib.mkDefault true;
  boot.loader.grub.devices = [ "nodev" ];

  boot.growPartition = lib.mkDefault true;

  # Allow remote updates with flakes and non-root users
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.networkmanager.enable = true;

  # Enable Tailscale
  # services.tailscale = {
  #   enable = true;
  #   useRoutingFeatures = "client";
  #   authKeyFile = "/var/lib/tailscale/authkey";
  # };

  # Set the time zone.
  time.timeZone = "America/Los_Angeles";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";

  # Allow nfs
#    services.nfs.client.enable = lib.mkDefault true;
  systemd.network.wait-online.enable = true;
  boot.initrd.kernelModules = [ "nfs" "nfs4" ];

  # Enable mDNS for `hostname.local` addresses
  services.avahi.enable = true;
  services.avahi.nssmdns4 = true;
  services.avahi.publish = {
    enable = true;
    addresses = true;
  };

  # Some sane packages we need on every system
  environment.systemPackages = with pkgs; [
    vim
    git
    sops
    age
    htop
    nfs-utils
    tailscale
  ];

  # Don't ask for passwords
  security.sudo.wheelNeedsPassword = false;

  # Enable ssh
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.KbdInteractiveAuthentication = false;
  };
  programs.ssh.startAgent = true;

  # Enable fail2ban
  services.fail2ban = {
    enable = true;
    maxretry = 5;
  };

  # Default user
  users.users.kyle = {
  isNormalUser = true;
  description = "Kyle Rable";
  extraGroups = [ "networkmanager" "wheel" "docker"];
  packages = with pkgs; [
    vim
    git
    htop
    tailscale
  ];
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMh4QcZWNLqRMaj0D5iKH3FDZ8n/rKJR6XFLNQs7bWsa my key for nixos"     
  ];
  };
  
  # Default filesystem
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    autoResize = true;
    fsType = "ext4";
  };

  system.stateVersion = lib.mkDefault "24.11";
}