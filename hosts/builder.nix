{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/dashboards/dashboards.nix
    ../modules/colmena.nix
    ../modules/forgejo.nix
    ../modules/nfs.nix
    ../modules/backup.nix
  ];

  # Modules for building and managing homelab infra
  custom.colmena.enable = true;
  custom.forgejo.enable = true;

  networking.hostName = "builder";

  custom.nfs = {
    enable = true;
    mounts = {
      backups = {
        device = "192.168.50.154:/Backups";
        owner  = "forgejo";
        group  = "forgejo";
        mode   = "0775";
      };
    };
  };
  
  custom.dashboards = {
    enable       = true;
  };

  custom.backup = {
    enable       = true;
    srcDir       = "/var/lib";
    includePaths = [ "forgejo" "forgejo-runner" ];
    targetDir    = "/mnt/backups/mnt/backups/management-data";
    interval     = "daily";
    retention = {
      daily   = 5;
      weekly  = 3;
      monthly = 6;
    };
  };
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 
      # 22 # SSH
      # 80 
      # 443 
      8080
      3005
    ];
  };
}
