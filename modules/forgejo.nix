{ config, pkgs, lib, ... }:

{
  services.forgejo = {
    enable = true;

    user = "forgejo";
    group = "forgejo";

    settings = {
      server = {
        DOMAIN = "git.local";
        HTTP_PORT = 3000;
        ROOT_URL = "http://git.local:3000/";
      };

      database = {
        DB_TYPE = "sqlite3";
        PATH = "/var/lib/forgejo/data/forgejo.db";
      };

      repository = {
        ROOT = lib.mkForce "/var/lib/forgejo/repos";
      };
    };
  };

  users.users.forgejo = {
    isSystemUser = true;
    home = "/var/lib/forgejo";
    createHome = true;
    group = "forgejo";
  };

  users.groups.forgejo = { };

  # ✅ Correctly placed top-level user declaration
  users.users.forgejo-runner = {
    isSystemUser = true;
    group = "forgejo"; # or "nogroup"
    home = "/var/lib/forgejo-runner";
    createHome = true;
  };

  networking.firewall.allowedTCPPorts = [ 3000 ];
}