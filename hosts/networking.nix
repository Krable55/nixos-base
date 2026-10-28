{ config, pkgs, lib, modulesPath, ... }:

{
  # Enable Traefik with dynamic config directory
  imports = [ 
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/nfs.nix
    ../modules/create-ssh.nix
    ../modules/qbittorrent.nix
    ../modules/traefik.nix
    ../modules/cloudflared.nix
    ../modules/agenix.nix
    ../modules/nuclio
    ../modules/nuclio/functions.nix
  ];
  
  networking.hostName = "network";
  custom.qbittorrent.enable = true;
  custom.cloudflared.enable = true;

  # Agenix secret for Tailscale
  age.secrets.tailscale-authkey = {
    file = ../secrets/global/tailscale-authkey.age;
    owner = "root";
    group = "root";
    mode = "600";
  };

  # Trader Alpaca secrets
  age.secrets.trader-alpaca-paper-api-key = {
    file = ../secrets/trader/alpaca/paper-api-key.age;
    owner = "root";
    group = "root";
    mode = "600";
  };

  age.secrets.trader-alpaca-paper-api-secret = {
    file = ../secrets/trader/alpaca/paper-api-secret.age;
    owner = "root";
    group = "root";
    mode = "600";
  };

  # Tailscale service configuration
  services.tailscale = {
    enable = true;
    useRoutingFeatures = "client";
    authKeyFile = config.age.secrets.tailscale-authkey.path;
  };
  
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
