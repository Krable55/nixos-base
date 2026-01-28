{ config, lib, pkgs, ... }:

let
  cfg = config.custom.atuin;
  atuinDataDir = "/var/lib/atuin";
in {
  options.custom.atuin = {
    enable = lib.mkEnableOption "Enable Atuin shell history server";
    
    port = lib.mkOption {
      type = lib.types.port;
      default = 8888;
      description = "Port for Atuin server";
    };
    
    host = lib.mkOption {
      type = lib.types.str;
      default = "0.0.0.0";
      description = "Host address to bind to";
    };
    
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = atuinDataDir;
      description = "Data directory for Atuin server";
    };
    
    openRegistration = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to allow open registration";
    };
    
    jwtSecretFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to file containing JWT secret for authentication";
    };
    
    databaseKeyFile = lib.mkOption {
      type = lib.types.str;
      description = "Path to file containing database encryption key";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.atuin = {
      isSystemUser = true;
      home = cfg.dataDir;
      createHome = true;
      group = "atuin";
    };
    
    users.groups.atuin = {};

    systemd.services.atuin = {
      description = "Atuin shell history server";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "simple";
        User = "atuin";
        Group = "atuin";
        WorkingDirectory = cfg.dataDir;
        
        # Load secrets as credentials
        LoadCredential = [
          "jwt-secret:${cfg.jwtSecretFile}"
          "database-key:${cfg.databaseKeyFile}"
        ];
        
        Environment = [
          "ATUIN_HOST=${cfg.host}"
          "ATUIN_PORT=${toString cfg.port}"
          "ATUIN_OPEN_REGISTRATION=${if cfg.openRegistration then "true" else "false"}"
          "ATUIN_DB_URI=sqlite://${cfg.dataDir}/server.db"
          # Reference the loaded credentials
          "ATUIN_JWT_SECRET_FILE=%d/jwt-secret"
          "ATUIN_DB_ENCRYPTION_KEY_FILE=%d/database-key"
        ];
        
        ExecStart = "${pkgs.atuin}/bin/atuin server start";
        Restart = "always";
        
        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        NoNewPrivileges = true;
      };
      
      # Ensure data dir exists with correct permissions
      preStart = ''
        mkdir -p ${cfg.dataDir}
        chown atuin:atuin ${cfg.dataDir}
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
