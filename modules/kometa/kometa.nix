{ config, lib, pkgs, ... }:

let
  cfg = config.custom.kometa;
in {
  options.custom.kometa = {
    enable = lib.mkEnableOption "Enable Kometa (Plex Meta Manager)";
    
    configFile = lib.mkOption {
      type = lib.types.path;
      default = ./config.yml;
      description = "Path to Kometa configuration file";
    };

    schedule = lib.mkOption {
      type = lib.types.str;
      default = "daily";
      description = "Kometa run schedule (daily, weekly, etc.)";
    };

    user = lib.mkOption {
      type = lib.types.str;
      default = "kometa";
      description = "User to run Kometa as";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "media";
      description = "Group for Kometa user";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/kometa";
      description = "Data directory for Kometa";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure Docker is available
    virtualisation.docker.enable = true;

    # Create kometa user
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
      extraGroups = [ "docker" ];
    };

    # Ensure media group exists
    users.groups.${cfg.group} = {};

    # Create data directory structure
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/config 0755 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/logs 0755 ${cfg.user} ${cfg.group} - -"
    ];

    # Kometa service
    systemd.services.kometa = {
      description = "Kometa - Plex Meta Manager";
      after = [ "docker.service" ];
      wants = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = pkgs.writeShellScript "kometa-run" ''
          USER_ID=$(${pkgs.coreutils}/bin/id -u ${cfg.user})
          GROUP_ID=$(${pkgs.coreutils}/bin/id -g ${cfg.user})
          
          # Always ensure config file exists and is a real file (not symlink)
          echo "Copying config file..."
          ${pkgs.coreutils}/bin/cp ${cfg.configFile} ${cfg.dataDir}/config/config.yml
          ${pkgs.coreutils}/bin/chown ${cfg.user}:${cfg.group} ${cfg.dataDir}/config/config.yml
          echo "Config file copied and permissions set"
          
          echo "Starting Kometa with USER_ID=$USER_ID GROUP_ID=$GROUP_ID"
          echo "Config file exists: $(test -f ${cfg.dataDir}/config/config.yml && echo 'YES' || echo 'NO')"
          echo "Config directory contents:"
          ${pkgs.coreutils}/bin/ls -la ${cfg.dataDir}/config/
          
          ${pkgs.docker}/bin/docker run --rm --name kometa \
            --user "$USER_ID:$GROUP_ID" \
            -v ${cfg.dataDir}/config:/config:rw \
            -v ${cfg.dataDir}/logs:/logs:rw \
            -e PUID="$USER_ID" \
            -e PGID="$GROUP_ID" \
            -e TZ=America/Los_Angeles \
            -e KOMETA_CONFIG=/config/config.yml \
            kometateam/kometa:latest
        '';
        
        # Ensure container is cleaned up
        ExecStartPost = "${pkgs.docker}/bin/docker container prune -f";
      };
    };

    # Timer for scheduled runs
    systemd.timers.kometa = lib.mkIf (cfg.schedule != null) {
      description = "Run Kometa on schedule";
      wantedBy = [ "timers.target" ];
      
      timerConfig = {
        OnCalendar = cfg.schedule;
        Persistent = true;
        RandomizedDelaySec = "5m";
      };
    };

  };
}