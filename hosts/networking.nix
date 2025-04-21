{ config, pkgs, lib, modulesPath, ... }:

{
  # Enable Traefik with dynamic config directory
  imports = [ 
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/traefik.nix
    ../modules/cloudflared.nix
  ];
  
  networking.hostName = "network";

  #  Configure the firewall
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 80 443 8080 ];
  };

  custom.traefik = {
    enable = true;
  };

  services.cloudflared = {
    enable          = true;
    name            = "my-tunnel";                       # your tunnel’s name
    credentialsFile = ./secrets/cloudflared-cred.json;   # store path to JSON creds
    configFile      = ./config/cloudflared-config.yml;   # optional YAML rules
    extraArgs       = [ "--edge-ip-version" "4" ];       # your custom flags
  };

}
