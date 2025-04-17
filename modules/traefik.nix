{ config, pkgs, lib, ... }:

{
  imports = [
    ../modules/traefik.nix
  ];

  networking.hostName = "edge";
  deployment.targetHost = "edge.local";
  deployment.targetUser = "root";

  services.traefik = {
    enable = true;
    dynamicConfigDir = "/etc/traefik/dynamic";
    logLevel = "INFO";
  };

  # Example config file for Sonarr
  environment.etc."traefik/dynamic/sonarr.yaml".text = ''
    http:
      routers:
        sonarr:
          rule: "Host(`sonarr.example.com`)"
          entrypoints: ["web"]
          service: sonarr
      services:
        sonarr:
          loadBalancer:
            servers:
              - url: "http://media.lan:8989"
  '';

  system.stateVersion = "24.05";
}
