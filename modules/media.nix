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
      services.tautulli = {
        enable = true;
        openFirewall = true;
        group = storageCfg.group;
      };

      users.users.prowlarr = {
        isSystemUser = true;
        group = storageCfg.group;
        home = "/mnt/media/apps/prowlarr";
        createHome = false;
      };

      system.activationScripts.prowlarrSymlink.text = ''
        ln -sfn /mnt/media/apps/prowlarr /var/lib/prowlarr
      '';

      systemd.services.prowlarr = {
        description = "Prowlarr";
        wantedBy = [ "multi-user.target" ];
        after = [ "network.target" "mnt-media.mount" ];
        requires = [ "mnt-media.mount" ];
        serviceConfig = {
          ExecStart = "${pkgs.prowlarr}/bin/Prowlarr -nobrowser -data=/mnt/media/apps/prowlarr";
          WorkingDirectory = "/mnt/media/apps/prowlarr";
          User = "prowlarr";
          Group = storageCfg.group;
          StandardOutput = "journal";
          StandardError = "journal";
        };
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
