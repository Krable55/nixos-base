{ config, lib, pkgs, ... }:

let
  cfg = config.custom.media;
  storageCfg = config.custom.storage or {};
in {
  options.custom.media = {
    enable = lib.mkEnableOption "Enable media apps";
  };

  config = lib.mkMerge [
    (lib.mkIf cfg.enable {
      # If storage isn't already enabled, enable it by default
      custom.storage = {
        enableMediaMount = true;
        enable = true;
        # Only override if not already customized
        group = config.custom.storage.group or "media";
        groupMembers = config.custom.storage.groupMembers or [
          "kyle"
          "sonarr"
          "radarr"
          "lidarr"
          "readarr"
          "prowlarr"
          "tautulli"
        ];
      };
    })

    (lib.mkIf cfg.enable {
      # The rest of your media app configuration
      users.groups.${config.custom.group} = {
        members = config.custom.groupMembers;
      };

      services.sonarr = { enable = true; openFirewall = true; group = config.custom.group; };
      services.radarr = { enable = true; openFirewall = true; group = config.custom.group; };
      services.lidarr = { enable = true; openFirewall = true; group = config.custom.group; };
      services.readarr = { enable = true; openFirewall = true; group = config.custom.group; };
      services.tautulli = { enable = true; openFirewall = true; group = config.custom.group; };

      users.users.prowlarr = {
        isSystemUser = true;
        group = config.custom.group;
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
          Group = config.custom.group;
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
    })
  ];
}
