{ config, pkgs, lib, modulesPath, ... }:

{
  # Enable Traefik with dynamic config directory
  imports = [ 
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/nfs.nix
    ../modules/create-ssh.nix
    ../modules/qbittorrent.nix
    ../modules/wireguard-nord.nix
    ../modules/traefik.nix
    ../modules/cloudflared.nix
  ];
  
  networking.hostName = "network";
  custom.qbittorrent.enable = true;
  custom.wgnord.enable = true;
  custom.cloudflared.enable = true;

  custom.create-ssh.enable = true;
  environment.systemPackages = [
    pkgs.cloudflared
    pkgs.tcpdump
    pkgs.qbittorrent-nox
    pkgs.sabnzbd
  ];

  #  Configure the firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 
      22 # SSH
      80 
      443 
      8080 # Traefik
      8089 # qBittorent
      8090 # Sabnzbd
      45036
      51820
      51822
      5000
    ];
  };

  custom.traefik = {
    enable = true;
  };

  users.groups.downloaders.members = [
    "kyle"
    "sabnzbd"
  ];

  custom.nfs = {
    enable = true;
    mounts = {
      media = {
        device = "192.168.50.154:/mnt/user/media";
        owner  = "downloaders";
        group  = "downloaders";
        mode   = "0775";
      };
    };
  };

  nixpkgs.config.allowUnfree = true;
  services.sabnzbd = {
    enable = true;
    openFirewall = true;
    group = "downloaders";
  };
}
