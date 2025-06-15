{ config, pkgs, lib, ... }:

let
  cfg = config.custom.supabase;
  supabaseDir = "/var/lib/supabase";
  composeFile = "${supabaseDir}/docker-compose.yml";
  envFile = "${supabaseDir}/.env";
in {
  options.custom.supabase = {
    enable = lib.mkEnableOption "Enable Supabase full stack via Docker Compose";
    version = lib.mkOption {
      type = lib.types.str;
      default = "latest";
      description = "Supabase Docker Compose version tag or branch";
    };
    exposePorts = lib.mkOption {
      type = lib.types.listOf lib.types.port;
      default = [ 8000 5432 3000 ];
      description = "Ports to expose (Kong API, Postgres, Studio, etc.)";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment variables for Supabase .env file";
    };
  };

  config = lib.mkIf cfg.enable {
    # Ensure Docker is enabled
    services.docker.enable = true;

    users.users.supabase = {
      isSystemUser = true;
      group = "docker";
      home = supabaseDir;
      createHome = true;
    };

    # Create the data directory and fetch Docker Compose files
    systemd.tmpfiles.rules = [
      "d ${supabaseDir} 0750 supabase docker -"
    ];

    # Fetch the latest docker-compose.yml and .env.example if not present
    systemd.services.supabase-setup = {
      description = "Supabase initial setup";
      wantedBy = [ "multi-user.target" ];
      before = [ "supabase.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "supabase";
        WorkingDirectory = supabaseDir;
      };
      script = ''
        set -e
        if [ ! -e docker-compose.yml ]; then
          git clone --depth 1 --branch ${cfg.version} https://github.com/supabase/supabase.git tmp
          cp -rf tmp/docker/* .
          rm -rf tmp
        fi
        if [ ! -e .env ]; then
          cp .env.example .env
        fi
      '';
    };

    # Write/merge .env with user-supplied values
    environment.etc."supabase.env".text = lib.concatStringsSep "\n" (
      lib.mapAttrsToList (k: v: "${k}=${v}") cfg.env
    );

    # Main Supabase stack service
    systemd.services.supabase = {
      description = "Supabase full stack (Docker Compose)";
      after = [ "docker.service" "network.target" "supabase-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "supabase";
        WorkingDirectory = supabaseDir;
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose up";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose down";
        Restart = "always";
        EnvironmentFile = "/etc/supabase.env";
      };
    };

    # Open required ports
    networking.firewall.allowedTCPPorts = cfg.exposePorts;
  };
}
