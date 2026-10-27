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
 networking.hostName = "trader";
 
 custom.supabase = {
  enable = true;
  # Optionally override version, ports, or env:
  # version = "master";
  exposePorts = [ 8000 5432 3000 ];
  adminUser = "kyle";  # Set your preferred admin username
  adminPasswordFile = "../secrets/trader/supabase/admin-password.age";
  postgres = {
    user = "postgres";
    passwordFile = "../secrets/trader/supabase/postgres-password.age";
    database = "postgres";
  };
  secrets = {
    jwtSecretFile = "../secrets/trader/supabase/jwt-secret.age";
    anonKeyFile = "../secrets/trader/supabase/anon-key.age";
    serviceRoleKeyFile = "../secrets/trader/supabase/service-role-key.age";
    secretKeyBaseFile = "../secrets/trader/supabase/secret-key-base.age";
    vaultEncKeyFile = "../secrets/trader/supabase/vault-enc-key.age";
  };
  env = {
    # Add any extra environment variables here
  };
};

custom.claude-code.enable = true;

# Agenix secrets
age.secrets = {
  tailscale-authkey = {
    file = ../secrets/global/tailscale-authkey.age;
    owner = "root";
    group = "root";
    mode = "600";
  };
  
  # Supabase secrets
  supabase-admin-password = {
    file = ../secrets/trader/supabase/admin-password.age;
    owner = "supabase";
    group = "docker";
    mode = "600";
  };
  supabase-postgres-password = {
    file = ../secrets/trader/supabase/postgres-password.age;
    owner = "supabase";
    group = "docker";
    mode = "600";
  };
  supabase-jwt-secret = {
    file = ../secrets/trader/supabase/jwt-secret.age;
    owner = "supabase";
    group = "docker";
    mode = "600";
  };
  supabase-anon-key = {
    file = ../secrets/trader/supabase/anon-key.age;
    owner = "supabase";
    group = "docker";
    mode = "600";
  };
  supabase-service-role-key = {
    file = ../secrets/trader/supabase/service-role-key.age;
    owner = "supabase";
    group = "docker";
    mode = "600";
  };
  supabase-secret-key-base = {
    file = ../secrets/trader/supabase/secret-key-base.age;
    owner = "supabase";
    group = "docker";
    mode = "600";
  };
  supabase-vault-enc-key = {
    file = ../secrets/trader/supabase/vault-enc-key.age;
    owner = "supabase";
    group = "docker";
    mode = "600";
  };
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
