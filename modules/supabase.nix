{ config, pkgs, lib, ... }:

let
  cfg = config.custom.supabase;
  supabaseDir = "/var/lib/supabase";
  projectDir = "${supabaseDir}/project";
in {
  options.custom.supabase = {
    enable = lib.mkEnableOption "Enable Supabase full stack via Docker Compose";
    version = lib.mkOption {
      type = lib.types.str;
      default = "main"; # Use "main" as default branch
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
    environment.systemPackages = with pkgs; [ git ];
    virtualisation.docker.enable = true;

    users.users.supabase = {
      isSystemUser = true;
      group = "docker";
      home = supabaseDir;
      createHome = true;
    };

    # Ensure data and project directories exist
    systemd.tmpfiles.rules = [
      "d ${supabaseDir} 0750 supabase docker -"
      "d ${projectDir} 0750 supabase docker -"
    ];

    # Setup service: clone, copy, and prepare project directory
    systemd.services.supabase-setup = {
      description = "Supabase initial setup";
      wantedBy = [ "multi-user.target" ];
      before = [ "supabase.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "supabase";
        WorkingDirectory = supabaseDir;
      };
      path = with pkgs; [ git ];
      script = ''
        set -eux
        # Only setup if not already done
        if [ ! -e "${projectDir}/docker-compose.yml" ]; then
          rm -rf supabase
          git clone --depth 1 https://github.com/supabase/supabase.git
          cp -rf supabase/docker/* ${projectDir}
          cp supabase/docker/.env.example ${projectDir}/.env
          rm -rf supabase
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
        WorkingDirectory = projectDir;
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose up";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose down";
        Restart = "always";
        EnvironmentFile = "/etc/supabase.env";
      };
    };

    networking.firewall.allowedTCPPorts = cfg.exposePorts;
  };
}
