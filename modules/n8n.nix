{ config, pkgs, lib, ... }:

let
  cfg = config.custom.n8n;
  n8nDataDir = "/var/lib/n8n";
in {
  options.custom.n8n = {
    enable = lib.mkEnableOption "Enable n8n workflow automation server";
    port = lib.mkOption {
      type = lib.types.port;
      default = 5678;
      description = "Port for n8n web interface";
    };
    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:5678/";
      description = "Base URL for n8n";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment variables for n8n";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.n8n = {
      isSystemUser = true;
      home = n8nDataDir;
      createHome = true;
      group = "n8n";
    };
    users.groups.n8n = {};

    systemd.services.n8n = {
      description = "n8n workflow automation";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "n8n";
        Group = "n8n";
        WorkingDirectory = n8nDataDir;
        Environment = [
          "N8N_PORT=${toString cfg.port}"
          "N8N_HOST=0.0.0.0"
          "N8N_PROTOCOL=http"
          "N8N_BASIC_AUTH_ACTIVE=false"
          "N8N_EDITOR_BASE_URL=${cfg.baseUrl}"
          "N8N_DIAGNOSTICS_ENABLED=false"
          "DB_TYPE=sqlite"
          "DB_SQLITE_DATABASE=${n8nDataDir}/database.sqlite"
        ] ++ (lib.attrsets.mapAttrsToList (n: v: "${n}=${v}") cfg.env);
        ExecStart = "${pkgs.n8n}/bin/n8n";
        Restart = "always";
      };
      # Ensure data dir exists
      preStart = ''
        mkdir -p ${n8nDataDir}
        chown n8n:n8n ${n8nDataDir}
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
