{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/colmena.nix
    ../modules/lore.nix
    ../modules/agenix.nix
  ];

  networking.hostName = "lore";

  custom.lore = {
    enable     = true;
    tlsEnabled = true;
  };

  age.secrets = {
    tailscale-authkey = {
      file  = ../secrets/global/tailscale-authkey.age;
      owner = "root";
      group = "root";
      mode  = "600";
    };
    lore-tls-cert = {
      file  = ../secrets/lore/lore/tls-cert.age;
      owner = "lore";
      group = "lore";
      mode  = "600";
    };
    lore-tls-key = {
      file  = ../secrets/lore/lore/tls-key.age;
      owner = "lore";
      group = "lore";
      mode  = "600";
    };
  };

  services.tailscale = {
    enable             = true;
    useRoutingFeatures = "client";
    authKeyFile        = config.age.secrets.tailscale-authkey.path;
  };

  swapDevices = [{ device = "/swapfile"; size = 6144; }];

  networking.firewall = {
    enable          = true;
    allowedTCPPorts = [];
  };
}
