{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  # any global “profiles” you want
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/media.nix
    ../modules/nfs.nix
    ../modules/backup.nix
    ../modules/claude-code.nix
    ../modules/agenix.nix
  ];

  # exactly what you had inline:
  networking.hostName = "media-center";
  custom.media.enable  = true;
  custom.claude-code.enable = true;

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
  #     media = {
  #       device = "192.168.50.154:/mnt/user/media";
  #       owner  = "media";
  #       group  = "media";
  #       mode   = "0775";
  #     };
  #     backups = {
  #       device = "192.168.50.154:/Backups";
  #       owner  = "media";
  #       group  = "media";
  #       mode   = "0775";
  #     };
  #   };
  # };

  # custom.backup = {
  #   enable       = true;
  #   srcDir       = "/var/lib";
  #   includePaths = [ "sonarr" "radarr" "readarr" "lidarr" "overseerr" "prowlarr" "plex" "plexpy" ];
  #   targetDir    = "/mnt/backups/media-center-data";
  #   interval     = "daily";
  #   retention = {
  #     daily   = 5;
  #     weekly  = 3;
  #     monthly = 6;
  #   };
  # };
}
