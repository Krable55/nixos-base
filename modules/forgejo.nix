{ config, pkgs, lib, ... }:

let
  cfg = config.custom.forgejo;
in {
  options.custom.forgejo = {
    enable = lib.mkEnableOption "Enable Forgejo server and runner configuration";
  };

  config = lib.mkIf cfg.enable {
    services.forgejo = {
      enable = true;

      user = "forgejo";
      group = "forgejo";

      settings = {
        server = {
          # DOMAIN stays the LAN IP -- it drives the SSH clone URL
          # (ssh://forgejo@.../...), and SSH access still goes straight to
          # this host on port 22, not through Traefik. ROOT_URL is what
          # this "you're viewing through a different URL" warning checks
          # against, and now that git.goobtube.tv is the real public path
          # (behind Zitadel, TLS terminated at Traefik), it needs to match
          # that, not the internal address Traefik forwards to.
          DOMAIN = "192.168.50.243";
          HTTP_PORT = 3000;
          ROOT_URL = "https://git.goobtube.tv/";
        };

        database = {
          DB_TYPE = "sqlite3";
          PATH = "/var/lib/forgejo/data/forgejo.db";
        };

        repository = {
          ROOT = lib.mkForce "/var/lib/forgejo/repos";
        };

        # Closed 2026-08-09: /user/sign_up was reachable and returning 200,
        # meaning anyone who found this instance could self-register.
        service = {
          DISABLE_REGISTRATION = true;
        };
      };
    };

    users.users.forgejo = {
      isSystemUser = true;
      home = "/var/lib/forgejo";
      createHome = true;
      group = "forgejo";
    };

    users.groups.forgejo = {};

    users.users.gitea-runner = {
      isSystemUser = true;
      group = "gitea-runner";
      home = "/var/lib/gitea-runner";
      createHome = true;
    };

    users.groups.gitea-runner = {};

    networking.firewall.allowedTCPPorts = [ 3000 ];

    virtualisation.docker.enable = true;
    
    services.gitea-actions-runner = {
      instances.default = {
        enable = true;
        url = "http://192.168.50.243:3000";
        tokenFile = "/var/lib/gitea-runner/token";
        name = "builder-runner";
        labels = [
          "ubuntu-latest:docker://node:18-bullseye"
          "ubuntu-22.04:docker://node:18-bullseye"
        ];
        settings = {
          runner = {
            capacity = 1;
            timeout = "3h";
          };
          cache = {
            enabled = true;
            dir = "/var/lib/forgejo-runner/cache";
          };
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/gitea-runner 0750 gitea-runner gitea-runner - -"
    ];
  };
}
