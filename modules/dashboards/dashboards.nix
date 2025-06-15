{ config, lib, pkgs, ... }:

let
  version = "v0.7.13"; # Adjust this as necessary to match the latest release
  glance-static = pkgs.stdenv.mkDerivation {
    name = "glance-static-${version}";
    src = pkgs.fetchurl {
      url = "https://github.com/glanceapp/glance/releases/download/${version}/glance-linux-amd64.tar.gz";
      # Download the file and run: shasum -a 256 ~/Downloads/glance-linux-amd64.tar.gz
      sha256 = "34f99b821288e2e3e45e8380afc1f98e0afbf75aacbb59b57524d573d3f27dea";
    };
    
    phases = [ "installPhase" ]; 
    installPhase = ''
      mkdir -p $out/bin
      tar -xzf $src -C $out/bin
      chmod +x $out/bin/glance
    '';
    meta = {
      description = "A statically linked glance binary";
      homepage = "https://github.com/glanceapp/glance";
      license = lib.licenses.bsd3;
    };
  };
   glanceConfig = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/glanceapp/glance/refs/heads/main/docs/glance.yml";
    sha256 = "7e71495ba4cd90e034aefb1a8d9cf830cf5e3e4dcf1a00764aae7f34f5cd83bf"; # Replace with the correct hash
  };
  cfg = config.custom.dashboards;
in {
  options.custom.dashboards = {
    enable = lib.mkEnableOption "Enable Dashboards for managing NixOS clusters";

    user = lib.mkOption {
      type = lib.types.str;
      default = "dashboard";
      description = "System user to run dashboard commands as (optional)";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "dashboard";
      description = "Group for the dahsboard user";
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d /etc/glance 0755 root root -" # Creates directory with the right permissions
      "L+ /etc/glance/glance.yml - - - - ${glanceConfig}" # Creates an empty yaml config file if it does not exist
    ];

    environment.systemPackages = [ glance-static ];

    users.groups.dashboard = {};

    users.users.${cfg.user} = {
      isNormalUser = true;
      home = "/var/lib/glance";
      createHome = true;
    };


    virtualisation.docker.enable = true;

    virtualisation.oci-containers.backend = "docker";
    virtualisation.oci-containers.containers.homepage = {
      autoStart = true;
      image = "ghcr.io/gethomepage/homepage:latest";
      ports = ["3005:3000"];
      volumes = [
        "/var/lib/homepage:/app/config"
      ];
      environment = {
        HOMEPAGE_ALLOWED_HOSTS = "192.168.50.243:3005";
        PPUID = "1001";
        PGID = "1001";
      };
    };
    systemd.services.glance = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "simple";
        User = "dashboard"; # Ensure this matches exactly with the user created
        ExecStart = "${glance-static}/bin/glance --config /etc/glance/glance.yml";
        Restart = "always";
      };
    };
  };
}
