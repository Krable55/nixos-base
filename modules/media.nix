{ config, lib, pkgs, ... }:

let
  cfg = config.custom.media;
in {
  options.custom.media = {
    enable = lib.mkEnableOption "Enable media apps and services";
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.config.allowUnfree = true; # required for plex
    users.groups.media.members = [
      "kyle"
      "sonarr"
      "radarr"
      "lidarr"
      "readarr"
      "prowlarr"
      "tautulli"
      "plex"
    ];

    systemd.tmpfiles.rules = [
      "d /mnt/media 0775 media media -"
    ];

    services.sonarr = {
      enable = true;
      openFirewall = true;
      group = "media";
    };

    services.radarr = {
      enable = true;
      openFirewall = true;
      group = "media";
    };

    services.lidarr = {
      enable = true;
      openFirewall = true;
      group = "media";
    };

    services.readarr = {
      enable = true;
      openFirewall = true;
      group = "media";
    };

    services.prowlarr = {
      enable = true;
      openFirewall = true;
    };

    services.plex = {
      enable = true;
      openFirewall = true;
      group="media";
    };

    services.tautulli = {
      enable = true;
      openFirewall = true;
      group = "media";
      user = "plex";
    };

    boot.supportedFilesystems = [ "nfs" ];
    fileSystems."/mnt/media" = lib.mkForce {
      device = "192.168.50.154:/MediaCenter";
      fsType = "nfs";
      options = [ 
        "x-systemd.automount"
        "noauto"
        "x-systemd.idle-timeout=300"
        "noatime"
        "nfsvers=4.0"
       ];
    };

    virtualisation.docker.enable = true;

    virtualisation.oci-containers.backend = "docker";

    virtualisation.oci-containers.containers.overseerr = {
      image = "lscr.io/linuxserver/overseerr:latest";
      ports = [ "5055:5055" ];
      environment = {
        PGID = "1000";
        PUID = "1000";
        TZ = "America/Los_Angeles";
      };
      volumes = [
        "/var/lib/overseer:/config:rw" # You'll have to premake this directory
      ];
    };

    networking.firewall.allowedTCPPorts = [
      5055 # Overseerr 
      8989 # Sonarr
      7878 # Radarr
      8686 # Lidarr
      8787 # Readarr
      8181 
      9696 # Prowlarr
      32400 # Plex
    ];
  };
}
