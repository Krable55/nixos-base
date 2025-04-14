{ config, lib, pkgs, ... }:

{
  options.custom.media = {
    enable = lib.mkEnableOption "Enable media apps";
  };

  config = lib.mkIf config.custom.media.enable (
    let
      storageCfg = config.custom.storage;
    in {
      users.groups.${storageCfg.group} = {
        members = storageCfg.groupMembers;
      };

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
        group = storageCfg.group;
      };
      services.tautulli = {
        enable = true;
        openFirewall = true;
        group = storageCfg.group;
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
          "/mnt/media/apps/overseer:/config:rw"
        ];
      };

      networking.firewall.allowedTCPPorts = [
        5055 8989 7878 8686 8787 8181 9696
      ];
    }
  );
}
