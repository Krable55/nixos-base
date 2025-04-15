{ config, lib, pkgs, ... }:

let
  cfg = config.custom.media;
in {
  options.custom.media = {
    enable = lib.mkEnableOption "Enable media apps and services";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge lib.mkMerge [
  {
    users.groups.media.members = [
      "kyle"
      "sonarr"
      "radarr"
      "lidarr"
      "readarr"
      "prowlarr"
      "tautulli"
    ];

    systemd.tmpfiles.rules = [
      "d /mnt/media 0775 media media -"
    ];

    services = {
      nfs.client.enable = true;

      sonarr = {
        enable = true;
        openFirewall = true;
        group = "media";
      };
      radarr = {
        enable = true;
        openFirewall = true;
        group = "media";
      };
      lidarr = {
        enable = true;
        openFirewall = true;
        group = "media";
      };
      readarr = {
        enable = true;
        openFirewall = true;
        group = "media";
      };
      prowlarr = {
        enable = true;
        openFirewall = true;
        # group = "media";
      };
      tautulli = {
        enable = true;
        openFirewall = true;
        group = "media";
      };
    };

    fileSystems."/mnt/media" = lib.mkForce {
      device = "192.168.50.154:/MediaCenter";
      fsType = "nfs";
      options = [ "x-systemd.automount" "noauto" "_netdev" ];
    };

    virtualisation = {
      docker.enable = true;
      oci-containers.backend = "docker";
      oci-containers.containers.overseerr = {
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
    };

    networking.firewall.allowedTCPPorts = [
      5055 8989 7878 8686 8787 8181 9696
    ];
  }
]);
}
