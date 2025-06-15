{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  # any global “profiles” you want
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/media.nix
    ../modules/nfs.nix
    ../modules/backup.nix
  ];

  # exactly what you had inline:
  networking.hostName = "media-center";
  custom.media.enable  = true;

  custom.nfs = {
    enable = true;
    mounts = {
      media = {
        device = "192.168.50.154:/MediaCenter";
        owner  = "media";
        group  = "media";
        mode   = "0775";
      };
      backups = {
        device = "192.168.50.154:/Backups";
        owner  = "media";
        group  = "media";
        mode   = "0775";
      };
    };
  };

  custom.backup = {
    enable       = true;
    srcDir       = "/var/lib";
    includePaths = [ "sonarr" "radarr" "readarr" "lidarr" "overseerr" "prowlarr" "plex" "plexpy" ];
    targetDir    = "/mnt/backups/media-center-data";
    interval     = "daily";
    retention = {
      daily   = 5;
      weekly  = 3;
      monthly = 6;
    };
  };
}
