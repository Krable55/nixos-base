{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/colmena.nix
    ../modules/supabase.nix
    ../modules/claude-code.nix
    ../modules/agenix.nix
  ];

 # Modules for building and managing powerball webapp
 networking.hostName = "powerball";
 
 custom.supabase = {
  enable = true;
  # Optionally override version, ports, or env:
  # version = "master";
  exposePorts = [ 8000 5432 3000 ];
  env = {
    # Example: POSTGRES_PASSWORD = "yourpassword";
    # Add any extra environment variables here
  };
};

custom.claude-code.enable = true;

# Agenix secret for Tailscale
age.secrets.tailscale-authkey = {
  file = ../tailscale-authkey.age;
  owner = "root";
  group = "root";
  mode = "600";
};

# Tailscale service configuration
services.tailscale = {
  enable = true;
  useRoutingFeatures = "client";
  authKeyFile = config.age.secrets.tailscale-authkey.path;
};
  
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 
      8000 
      5432 
      3000
    ];
  };
}
