{ config, pkgs, lib, modulesPath, inputs, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/colmena.nix
    ../modules/supabase.nix
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
  
  # custom.dashboards = {
  #   enable       = true;
  # };

  # custom.backup = {
  #   enable       = true;
  #   srcDir       = "/var/lib";
  #   includePaths = [ "forgejo" "forgejo-runner" ];
  #   targetDir    = "/mnt/backups/mnt/backups/management-data";
  #   interval     = "daily";
  #   retention = {
  #     daily   = 5;
  #     weekly  = 3;
  #     monthly = 6;
  #   };
  # };
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 
      # 22 # SSH
      # 80 
      # 443 
      5678 #n8n
      8080
      3005
    ];
  };
}
