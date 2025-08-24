{ config, pkgs, lib, ... }:

let
  cfg = config.custom.faasd;
  
  # faasd binary - we'll need to package this or get it from nixpkgs
  faasdPackage = pkgs.stdenv.mkDerivation rec {
    pname = "faasd";
    version = "0.21.3";
    
    src = pkgs.fetchFromGitHub {
      owner = "openfaas";
      repo = "faasd";
      rev = version;
      sha256 = lib.fakeHash; # We'll fix this after first build attempt
    };
    
    nativeBuildInputs = with pkgs; [ go ];
    
    buildPhase = ''
      export GOCACHE=$TMPDIR/go-cache
      export GOPATH=$TMPDIR/go
      go build -o faasd
    '';
    
    installPhase = ''
      mkdir -p $out/bin
      cp faasd $out/bin/
    '';
    
    meta = with lib; {
      description = "Lightweight & portable faas engine";
      homepage = "https://github.com/openfaas/faasd";
      license = licenses.mit;
      maintainers = [ ];
    };
  };
  
in {
  options.custom.faasd = {
    enable = lib.mkEnableOption "Enable faasd (lightweight OpenFaaS)";
    
    port = lib.mkOption {
      type = lib.types.port;
      default = 8081;
      description = "Port for faasd gateway";
    };
    
    user = lib.mkOption {
      type = lib.types.str;
      default = "faasd";
      description = "User to run faasd as";
    };
    
    group = lib.mkOption {
      type = lib.types.str;
      default = "faasd";
      description = "Group for faasd user";
    };
    
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/faasd";
      description = "Data directory for faasd";
    };
    
    basicAuthUser = lib.mkOption {
      type = lib.types.str;
      default = "admin";
      description = "Basic auth username";
    };
    
    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Whether to open the firewall for faasd";
    };
  };
  
  config = lib.mkIf cfg.enable {
    # Ensure containerd is available (required by faasd)
    virtualisation.containerd.enable = true;
    
    # Agenix secret for basic auth password
    age.secrets.faasd-basic-auth-password = {
      file = ../faasd-basic-auth-password.age;
      owner = cfg.user;
      group = cfg.group;
      mode = "600";
    };
    
    # Create faasd user
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      createHome = true;
    };
    
    users.groups.${cfg.group} = {};
    
    # Create data directory structure
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 ${cfg.user} ${cfg.group} - -"
      "d ${cfg.dataDir}/secrets 0755 ${cfg.user} ${cfg.group} - -"
    ];
    
    # Install faasd package
    environment.systemPackages = [ faasdPackage ];
    
    # faasd systemd service
    systemd.services.faasd = {
      description = "faasd (OpenFaaS for Developers)";
      after = [ "containerd.service" "network.target" ];
      wants = [ "containerd.service" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;
        Restart = "always";
        RestartSec = "2s";
        ExecStart = "${faasdPackage}/bin/faasd up";
        
        # Security settings
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.dataDir "/tmp" ];
        
        # Environment variables
        Environment = [
          "basic_auth_user=${cfg.basicAuthUser}"
          "basic_auth_password_file=${config.age.secrets.faasd-basic-auth-password.path}"
          "secret_mount_path=${cfg.dataDir}/secrets"
          "port=${toString cfg.port}"
        ];
      };
    };
    
    # Open firewall if requested
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
  };
}