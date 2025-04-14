{ config, lib, pkgs, ... }:

let
  cfg = config.custom.media;
in {
  options.custom.media = {
    enable = lib.mkEnableOption "Enable media apps and services";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Storage configuration: media group + NFS mount
    {
      # Define media group and members
      users.groups.media.members = [
        "kyle"
        "sonarr"
        "radarr"
        "lidarr"
        "readarr"
        "prowlarr"
        "tautulli"
      ];

      # Create mount point with correct permissions
      systemd.tmpfiles.rules = [
        "d /mnt/media 0775 media media -"
      ];

      # Define the NFS mount
      fileSystems."/mnt/media" = {
        device = "192.168.50.154:/MediaCenter";
        fsType = "nfs";
        options = [ "defaults" "x-systemd.automount" ];
      };
    }

    # Media apps + overseerr config
    {
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
        # group = "media"; # doesn't support custom group yet
      };
      services.tautulli = {
        enable = true;
        openFirewall = true;
        group = "media";
      };

      # Overseerr via Docker
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
          "/mnt/media/apps/overseer:/config:rw"
        ];
      };

      networking.firewall.allowedTCPPorts = [
        5055 8989 7878 8686 8787 8181 9696
      ];
    }
  ]);
}
