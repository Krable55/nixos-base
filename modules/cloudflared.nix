# modules/cloudflared.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.cloudflared;
in
{
  options.custom.cloudflared = {
    enable     = lib.mkEnableOption "Enable Cloudflared tunnel";
  };

  config = lib.mkIf config.custom.cloudflared.enable {
    environment.systemPackages = [ pkgs.cloudflared ];
    systemd.tmpfiles.rules = [
      "d /var/lib/cloudflared 0755 root root -" # Creates directory with the right permissions
      "f /var/lib/cloudflared/tunnel-ID.json 0644 root root -" # Creates an empty environment file if it does not exist
    ];

    # Cloudflare Tunnel configuration
    services.cloudflared = {
      enable = true;
      tunnels = {
        "traefik" = {
          credentialsFile = "/etc/cloudflared/1ddda65a-792a-48fc-a0e0-080dd44d1c96.json";
          ingress = {
            "*.goobtube.tv" = {
              service = "http://localhost:8080";
              path = "/*.(jpg|png|css|js)";
            };
          };
          default = "http_status:404";
        };
      };
    };

    systemd.services.cloudflared = {
      description = "Cloudflare Tunnel Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.cloudflared}/bin/cloudflared tunnel run traefik";
        User = "root";
        Restart = "always";
      };
    };
  };
}
