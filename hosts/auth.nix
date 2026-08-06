{ config, pkgs, lib, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/profiles/qemu-guest.nix")
    ../modules/agenix.nix
    ../modules/create-ssh.nix
    ../modules/zitadel.nix
    ../modules/oauth2-proxy.nix
  ];

  networking.hostName = "auth";

  age.secrets = {
    tailscale-authkey = {
      file  = ../secrets/global/tailscale-authkey.age;
      owner = "root";
      group = "root";
      mode  = "600";
    };

    zitadel-master-key = {
      file  = ../secrets/auth/zitadel/master-key.age;
      owner = "zitadel";
      group = "zitadel";
      mode  = "400";
    };

    # Read by the postgresql-zitadel-password unit, which runs as the
    # "postgres" system user (see modules/zitadel.nix).
    zitadel-postgres-password = {
      file  = ../secrets/auth/zitadel/postgres-password.age;
      owner = "postgres";
      group = "postgres";
      mode  = "400";
    };

    zitadel-postgres-admin-password = {
      file  = ../secrets/auth/zitadel/postgres-admin-password.age;
      owner = "postgres";
      group = "postgres";
      mode  = "400";
    };

    # Only read by the root-run zitadel-secrets unit.
    zitadel-admin-password = {
      file  = ../secrets/auth/zitadel/admin-password.age;
      owner = "root";
      group = "root";
      mode  = "400";
    };
  };

  custom.zitadel = {
    enable = true;
    domain = "auth.goobtube.tv";
    port   = 8080;
    masterKeyFile            = config.age.secrets.zitadel-master-key.path;
    initialAdminPasswordFile = config.age.secrets.zitadel-admin-password.path;
    postgres = {
      passwordFile      = config.age.secrets.zitadel-postgres-password.path;
      adminPasswordFile = config.age.secrets.zitadel-postgres-admin-password.path;
    };
  };

  # Stays disabled until Phase 7 (manual Zitadel UI config) produces a real
  # client ID/secret and Phase 8 encrypts them -- clientSecretFile/
  # cookieSecretFile are intentionally left unset here since those secrets
  # don't exist yet, and enable = false means the module never reads them.
  custom.oauth2-proxy = {
    enable        = false;
    zitadelDomain = "auth.goobtube.tv";
    redirectUrl   = "https://oauth.goobtube.tv/oauth2/callback";
    cookieDomain  = ".goobtube.tv";
    clientId      = "";
  };

  services.tailscale = {
    enable             = true;
    useRoutingFeatures = "client";
    authKeyFile        = config.age.secrets.tailscale-authkey.path;
  };

  networking.firewall = {
    enable          = true;
    allowedTCPPorts = [ 22 8080 4180 ];
  };
}
