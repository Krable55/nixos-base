{ config, pkgs, lib, ... }:

let
  cfg = config.custom.supabase;
  supabaseDir = "/var/lib/supabase";
  projectDir = "${supabaseDir}/project";
  
  # Define protected environment variables that cannot be overridden
  protectedKeys = [
    "DASHBOARD_USERNAME" "DASHBOARD_PASSWORD" 
    "POSTGRES_USER" "POSTGRES_PASSWORD" "POSTGRES_DB" "POSTGRES_PORT"
    "JWT_SECRET" "ANON_KEY" "SERVICE_ROLE_KEY" 
    "SECRET_KEY_BASE" "VAULT_ENC_KEY"
  ];
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
    adminUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Admin username for Supabase dashboard";
    };
    adminPasswordFile = lib.mkOption {
      type = lib.types.str;
      default = "../secrets/trader/supabase/admin-password.age";
      description = "Path to the agenix encrypted admin password file";
    };
    postgres = {
      user = lib.mkOption {
        type = lib.types.str;
        default = "postgres";
        description = "PostgreSQL superuser username";
      };
      passwordFile = lib.mkOption {
        type = lib.types.str;
        default = "../secrets/trader/supabase/postgres-password.age";
        description = "Path to the agenix encrypted PostgreSQL password file";
      };
      database = lib.mkOption {
        type = lib.types.str;
        default = "postgres";
        description = "Default PostgreSQL database name";
      };
    };
    secrets = {
      jwtSecretFile = lib.mkOption {
        type = lib.types.str;
        default = "../secrets/trader/supabase/jwt-secret.age";
        description = "Path to the agenix encrypted JWT secret file (32+ chars)";
      };
      anonKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "../secrets/trader/supabase/anon-key.age";
        description = "Path to the agenix encrypted anonymous API key file";
      };
      serviceRoleKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "../secrets/trader/supabase/service-role-key.age";
        description = "Path to the agenix encrypted service role API key file";
      };
      secretKeyBaseFile = lib.mkOption {
        type = lib.types.str;
        default = "../secrets/trader/supabase/secret-key-base.age";
        description = "Path to the agenix encrypted secret key base file";
      };
      vaultEncKeyFile = lib.mkOption {
        type = lib.types.str;
        default = "../secrets/trader/supabase/vault-enc-key.age";
        description = "Path to the agenix encrypted vault encryption key file (32+ chars)";
      };
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment variables for Supabase .env file";
    };
  };

  config = lib.mkIf cfg.enable {
    # Assertion to prevent override of protected keys
    assertions = [
      {
        assertion = !lib.any (k: lib.hasAttr k cfg.env) protectedKeys;
        message = ''
          Supabase module: Cannot override protected environment variables in cfg.env.
          These are managed by agenix secrets: ${lib.concatStringsSep ", " protectedKeys}.
          Use the dedicated configuration options instead.
        '';
      }
    ];

    environment.systemPackages = with pkgs; [ git ];
    virtualisation.docker.enable = true;

    # Note: Agenix secrets are defined in the host configuration (e.g., hosts/trader.nix)
    # This allows for host-specific secret paths while keeping the module generic
    
    # IMPORTANT: When changing database passwords after initial deployment, you must
    # clear the database volume to force fresh initialization with new credentials:
    # sudo systemctl stop supabase.service
    # sudo rm -rf /var/lib/supabase/project/volumes/db/data
    # sudo systemctl start supabase.service
    # This prevents authentication failures for the supabase_admin user.

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

    # Create a script to generate .env with secret values
    systemd.services.supabase-env-setup = {
      description = "Generate Supabase .env with secrets";
      wantedBy = [ "supabase.service" ];
      before = [ "supabase.service" ];
      after = [ "supabase-setup.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "supabase";
        WorkingDirectory = projectDir;
      };
      script = ''
        # Protected keys (defined in Nix and passed here for clarity)
        PROTECTED_KEYS="${lib.concatStringsSep " " protectedKeys}"
        echo "# Protected keys managed by agenix: $PROTECTED_KEYS" >&2
        
        # Start with the .env.example as base (contains defaults like DOCKER_SOCKET_LOCATION)
        if [ ! -f .env ]; then
          echo "Error: .env file not found. supabase-setup should have created it from .env.example" >&2
          exit 1
        fi
        
        # Create a temporary file with our secrets
        cat > .env.secrets << EOF
        # Dashboard credentials
        DASHBOARD_USERNAME=${cfg.adminUser}
        DASHBOARD_PASSWORD=$(cat ${config.age.secrets.supabase-admin-password.path})
        
        # PostgreSQL credentials  
        POSTGRES_USER=${cfg.postgres.user}
        POSTGRES_PASSWORD=$(cat ${config.age.secrets.supabase-postgres-password.path})
        POSTGRES_DB=${cfg.postgres.database}
        POSTGRES_PORT=5432
        
        # JWT and API keys
        JWT_SECRET=$(cat ${config.age.secrets.supabase-jwt-secret.path})
        ANON_KEY=$(cat ${config.age.secrets.supabase-anon-key.path})
        SERVICE_ROLE_KEY=$(cat ${config.age.secrets.supabase-service-role-key.path})
        
        # Encryption keys
        SECRET_KEY_BASE=$(cat ${config.age.secrets.supabase-secret-key-base.path})
        VAULT_ENC_KEY=$(cat ${config.age.secrets.supabase-vault-enc-key.path})
        EOF
        
        # Merge: remove protected keys from original .env, then append our secrets
        # Use a more explicit approach to ensure we preserve non-protected keys
        
        # Filter out any existing protected keys and empty lines, keep everything else
        grep -v -E "^(${lib.concatStringsSep "|" protectedKeys})=" .env | grep -v "^[[:space:]]*$" > .env.tmp || true
        
        # Append our secrets
        cat .env.secrets >> .env.tmp
        
        # Add additional user environment variables (filtered to prevent override of protected keys)
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "echo '${k}=${v}' >> .env.tmp") 
          (lib.filterAttrs (k: v: !lib.elem k protectedKeys) cfg.env)
        )}
        
        # Replace original .env with merged version
        mv .env.tmp .env
        rm -f .env.secrets
        
        chmod 600 .env
      '';
    };

    # Main Supabase stack service
    systemd.services.supabase = {
      description = "Supabase full stack (Docker Compose)";
      after = [ "docker.service" "network.target" "supabase-setup.service" "supabase-env-setup.service" ];
      wants = [ "supabase-env-setup.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "simple";
        User = "supabase";
        WorkingDirectory = projectDir;
        ExecStart = "${pkgs.docker-compose}/bin/docker-compose up";
        ExecStop = "${pkgs.docker-compose}/bin/docker-compose down";
        Restart = "always";
      };
    };

    networking.firewall.allowedTCPPorts = cfg.exposePorts;
  };
}
