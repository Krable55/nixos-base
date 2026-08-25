{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    # ../modules/dashboards/dashboards.nix
    ../modules/colmena.nix
    ../modules/forgejo.nix
    ../modules/n8n.nix
    ../modules/agenix.nix
    # ../modules/nfs.nix
    # ../modules/backup.nix
  ];

  # Modules for building and managing homelab infra
  custom.colmena.enable = true;
  custom.forgejo.enable = true;

  nixpkgs.config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "n8n" ];
  custom.n8n.enable = true;

  # The Jellyseerr/Sonarr/Radarr -> Signal workflow keys its message state by
  # media id in workflow static data, which n8n reads at execution start and
  # writes at execution end. Concurrent webhooks therefore read the same
  # snapshot and the last writer wins: execution 106 recorded "Added to
  # library", 107 landed 3s later off the same stale read, and 106's line was
  # gone. These arrs fire in bursts, so serialising production executions is
  # what keeps that state coherent; the volume here is a handful of events a
  # day, so there's nothing to gain from parallelism.
  custom.n8n.env.N8N_CONCURRENCY_PRODUCTION_LIMIT = "1";

  networking.hostName = "builder";

  # Agenix secret for Tailscale
  age.secrets.tailscale-authkey = {
    file = ../secrets/global/tailscale-authkey.age;
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

  # custom.nfs = {
  #   enable = true;
  #   mounts = {
  #     backups = {
  #       device = "192.168.50.154:/Backups";
  #       owner  = "forgejo";
  #       group  = "forgejo";
  #       mode   = "0775";
  #     };
  #   };
  # };
  
  # custom.dashboards = {
  #   enable       = true;
  # };

  # custom.backup = {
  #   enable       = true;
  #   srcDir       = "/var/lib";
  #   includePaths = [ "forgejo" "forgejo-runner" ];
  #   targetDir    = "/mnt/backups/mnt/backups/management-data";
  #   interval     = "daily";
  #   retention = {
  #     daily   = 5;
  #     weekly  = 3;
  #     monthly = 6;
  #   };
  # };
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      # 22 # SSH
      # 80
      # 443
      5678 #n8n
      8080
      3005
    ];
  };

  # This host had zero swap, which is why the n8n 2.28.6 build's V8 heap
  # overflow (see modules/n8n.nix) took down the whole build instead of
  # degrading gracefully. Same pattern already used on hosts/lore.nix.
  swapDevices = [{ device = "/swapfile"; size = 6144; }];
}
