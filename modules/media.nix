{ config, lib, pkgs, ... }:

let
  cfg = config.custom.media;
  storageCfg = config.custom.storage;
in {
  options.custom.media = {
    enable = lib.mkEnableOption "Enable media apps and services";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    # Ensure storage module is enabled with sane defaults
    {
      custom.storage.enable = lib.mkDefault true;
      custom.storage.useMediaMount = lib.mkDefault true;
      custom.storage.group = lib.mkDefault "media";
      custom.storage.groupMembers = lib.mkDefault [
        "kyle"
        "sonarr"
        "radarr"
        "lidarr"
        "readarr"
        "prowlarr"
        "tautulli"
      ];
    }

    {
      # Optional: reinforce group membership for completeness
      users.groups.${storageCfg.group} = {
        members = storageCfg.groupMembers;
      };

      # Media apps
      services.sonarr = {
        enable = true;
        openFirewall = true;
        group = storageCfg.group;
      };
      services.radarr = {
        enable = true;
        openFirewall = true;
        group = storageCfg.group;
      };
      services.lidarr = {
        enable = true;
        openFirewall = true;
        group = storageCfg.group;
      };
      services.readarr = {
        enable = true;
        openFirewall = true;
        group = storageCfg.group;
      };
      services.prowlarr = {
        enable = true;
        openFirewall = true;
        # group = storageCfg.group;
      };
      services.tautulli = {
        enable = true;
        openFirewall = true;
        group = storageCfg.group;
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
