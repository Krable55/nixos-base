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
      # "sonarr"
      # "radarr"
      # "lidarr"
      # "readarr"
      # "prowlarr"
      "tautulli"
      # "plex"
    ];

    # systemd.tmpfiles.rules = [
    #   "d /mnt/media 0775 media media -"
    # ];

    # services.sonarr = {
    #   enable = true;
    #   openFirewall = true;
    #   group = "media";
    # };

    # services.radarr = {
    #   enable = true;
    #   openFirewall = true;
    #   group = "media";
    # };

    # services.lidarr = {
    #   enable = true;
    #   openFirewall = true;
    #   group = "media";
    # };

    # services.readarr = {
    #   enable = true;
    #   openFirewall = true;
    #   group = "media";
    # };

    # services.prowlarr = {
    #   enable = true;
    #   openFirewall = true;
    # };
    # Using a dedicated lxc continaer instead
    # services.plex = {
    #   enable = true;
    #   openFirewall = true;
    #   group="media";
    # };

    services.tautulli = {
      enable = true;
      openFirewall = true;
      group = "media";
    };

    # boot.supportedFilesystems = [ "nfs" ];
    # fileSystems."/mnt/media" = lib.mkForce {
    #   device = "192.168.50.154:/mnt/";
    #   fsType = "nfs";
    #   options = [ 
    #     "x-systemd.automount"
    #     "noauto"
    #     "x-systemd.idle-timeout=300"
    #     "noatime"
    #     "nfsvers=4.0"
    #    ];
    # };

    services.jellyseerr = {
      enable = true;
      port = 5055;
      openFirewall = true;
      package = pkgs.jellyseerr; # Use the unstable package if stable is not up-to-date
    };

    networking.firewall.allowedTCPPorts = [
      5055  # Jellyseerr/Overseerr
      # 8989  # Sonarr
      # 7878  # Radarr
      # 8686  # Lidarr
      # 8787  # Readarr
      8181    # Tautulli
      # 9696  # Prowlarr
      # 32400 # Plex
    ];
  };
}
