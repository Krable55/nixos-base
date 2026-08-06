{ config, lib, pkgs, ... }:

let
  cfg = config.custom.zitadel;
in {
  options.custom.zitadel = {
    enable = lib.mkEnableOption "Zitadel identity and access management service";

    domain = lib.mkOption {
      type = lib.types.str;
      description = "External domain Zitadel is served at (e.g. auth.example.com)";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Port Zitadel listens on";
    };

    masterKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to a file containing Zitadel's 32-byte master encryption key";
    };

    initialAdminPasswordFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to a file containing the bootstrap password for the initial admin user (must be rotated after first login)";
    };

    postgres = {
      passwordFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to a file containing the password for the 'zitadel' Postgres role";
      };
      adminPasswordFile = lib.mkOption {
        type = lib.types.str;
        description = "Path to a file containing the password for the 'postgres' superuser role";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.postgresql = {
      enable = true;
      package = pkgs.postgresql_16;
      ensureDatabases = [ "zitadel" ];
      ensureUsers = [
        {
          name = "zitadel";
          ensureDBOwnership = true;
        }
      ];
      # Scoped to the zitadel database so the default "local all postgres peer"
      # rule NixOS relies on for its own ensureUsers/ensureDatabases bootstrap
      # keeps working untouched. Added rules are inserted above the module's
      # defaults, so these take precedence for the zitadel database.
      authentication = ''
        local zitadel zitadel  md5
        local zitadel postgres md5
      '';
    };

    # Zitadel's Admin connection authenticates as the "postgres" superuser,
    # so that role needs a known password too, not just "zitadel".
    systemd.services.postgresql-zitadel-password = {
      description = "Set Postgres role passwords for Zitadel from agenix secrets";
      after = [ "postgresql.service" ];
      before = [ "zitadel.service" ];
      wantedBy = [ "zitadel.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "postgres";
      };
      script = ''
        ${config.services.postgresql.package}/bin/psql <<SQL
        ALTER USER zitadel WITH PASSWORD '$(cat ${cfg.postgres.passwordFile})';
        ALTER USER postgres WITH PASSWORD '$(cat ${cfg.postgres.adminPasswordFile})';
        SQL
      '';
    };

    # Keeps DB credentials and the bootstrap admin password out of the world
    # readable Nix store by writing them to a runtime-only file consumed via
    # extraSettingsPaths/extraStepsPaths instead of services.zitadel.settings/steps.
    systemd.services.zitadel-secrets = {
      description = "Generate Zitadel runtime secrets and bootstrap steps files";
      before = [ "zitadel.service" ];
      wantedBy = [ "zitadel.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        umask 077
        install -d -o zitadel -g zitadel -m 0750 /run/zitadel

        cat > /run/zitadel/secrets.yaml <<EOF
        Database:
          postgres:
            User:
              Password: $(cat ${cfg.postgres.passwordFile})
            Admin:
              Password: $(cat ${cfg.postgres.adminPasswordFile})
        EOF

        cat > /run/zitadel/steps.yaml <<EOF
        FirstInstance:
          Org:
            Human:
              UserName: admin
              FirstName: Admin
              LastName: User
              Email:
                Address: admin@${cfg.domain}
                Verified: true
              Password: $(cat ${cfg.initialAdminPasswordFile})
              PasswordChangeRequired: true
        EOF

        chown zitadel:zitadel /run/zitadel/secrets.yaml /run/zitadel/steps.yaml
      '';
    };

    services.zitadel = {
      enable = true;
      openFirewall = true;
      tlsMode = "external";
      masterKeyFile = cfg.masterKeyFile;
      extraSettingsPaths = [ "/run/zitadel/secrets.yaml" ];
      extraStepsPaths = [ "/run/zitadel/steps.yaml" ];
      settings = {
        Port = cfg.port;
        ExternalDomain = cfg.domain;
        ExternalPort = 443;
        ExternalSecure = true;
        Database.postgres = {
          Host = "/run/postgresql";
          Port = 5432;
          Database = "zitadel";
          User.Username = "zitadel";
          User.SSL.Mode = "disable";
          Admin.Username = "postgres";
          Admin.SSL.Mode = "disable";
          # Zitadel's Admin connection targets the "postgres" maintenance DB by
          # default (to CREATE DATABASE on first init). Point it at "zitadel"
          # instead, since NixOS's ensureDatabases already created it -- this
          # keeps the Admin connection matched by the "local zitadel postgres"
          # pg_hba rule below instead of falling through to the untouched
          # "local all postgres peer" default (which peer-auth would reject,
          # since the process runs as OS user "zitadel", not "postgres").
          Admin.ExistingDatabase = "zitadel";
        };
      };
    };
  };
}
