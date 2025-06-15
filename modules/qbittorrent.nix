{ config, lib, pkgs, ... }:
##################################
# Headless qBittorrent derivation
##################################
let
  version = "5.0.5_v2.0.11"; # Adjust this as necessary to match the latest release
  qbittorrent-nox-static = pkgs.stdenv.mkDerivation {
    name = "qbittorrent-nox-static-${version}";
    src = pkgs.fetchurl {
      url = "https://github.com/userdocs/qbittorrent-nox-static/releases/download/release-${version}/x86_64-qbittorrent-nox";
      # Download the file and run: shasum -a 256 ~/Downloads/x86_64-qbittorrent-nox
      sha256 = "22b167e8414d46c3d72d54807959e85957a7178effed3add0c7880f2fceb3964";
    };
    
    phases = [ "installPhase" ]; 
    installPhase = ''
      install -D $src $out/bin/qbittorrent-nox
      chmod +x $out/bin/qbittorrent-nox
    '';
    meta = {
      description = "A statically linked qBittorrent-nox binary";
      homepage = "https://github.com/userdocs/qbittorrent-nox-static";
      license = lib.licenses.bsd3;
    };
  };
in
{
  options.custom.qbittorrent = {
    enable = lib.mkEnableOption "Enable qBittorrent-nox service";
    port = lib.mkOption {
      type = lib.types.int;
      default = 8089;
      description = "Port on which qBittorrent-nox will run.";
    };
  };

  config = lib.mkIf config.custom.qbittorrent.enable {
    users.users.qbittorrent = {
      isNormalUser = true;
      home = "/var/lib/qbittorrent";
      createHome = true;
    };

    users.groups.qbittorrent = {};

    networking.firewall.allowedTCPPorts = [ config.custom.qbittorrent.port ];

    systemd.services.qbittorrent-nox = {
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "simple";
        User = "qbittorrent";
        ExecStart = "${qbittorrent-nox-static}/bin/qbittorrent-nox --webui-port=${toString config.custom.qbittorrent.port}";
        Restart = "always";
      };
    };

    environment.systemPackages = [ qbittorrent-nox-static ];
  };
}
