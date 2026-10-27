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

    # Read by the root-run oauth2-proxy-env unit (see modules/oauth2-proxy.nix).
    oauth2-proxy-client-secret = {
      file  = ../secrets/auth/oauth2-proxy/client-secret.age;
      owner = "root";
      group = "root";
      mode  = "400";
    };

    oauth2-proxy-cookie-secret = {
      file  = ../secrets/auth/oauth2-proxy/cookie-secret.age;
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

  # Phase 7/8 done: Traefik app created in Zitadel (Basic auth method) and
  # both secrets encrypted. Traefik's oauth-auth-redirect/oauth-errors
  # middlewares are still commented out (modules/traefik.nix:91-101) until
  # this deploys and oauth2-proxy is confirmed listening on 4180 -- do not
  # uncomment those until after this host redeploys successfully.
  custom.oauth2-proxy = {
    enable        = true;
    zitadelDomain = "auth.goobtube.tv";
    redirectUrl   = "https://oauth.goobtube.tv/oauth2/callback";
    cookieDomain  = ".goobtube.tv";
    clientId      = "385471465094460029";
    clientSecretFile = config.age.secrets.oauth2-proxy-client-secret.path;
    cookieSecretFile  = config.age.secrets.oauth2-proxy-cookie-secret.path;
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
