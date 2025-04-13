{ config, lib, pkgs, ... }:

let
  cfg = config.custom.media;
  group = config.custom.group;
in {
  options.custom.media = {
    enable = lib.mkEnableOption "Enable media apps";
  };

  config = lib.mkIf cfg.enable {
    services.sonarr = { enable = true; openFirewall = true; group = group; };
    services.radarr = { enable = true; openFirewall = true; group = group; };
    services.lidarr = { enable = true; openFirewall = true; group = group; };
    services.readarr = { enable = true; openFirewall = true; group = group; };
    services.tautulli = { enable = true; openFirewall = true; group = group; };

    users.users.prowlarr = {
      isSystemUser = true;
      group = group;
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
        Group = group;
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
  };
}
