{ config, pkgs, lib, inputs, ... }:

let
  cfg = config.custom.n8n;
  n8nDataDir = "/var/lib/n8n";

  # Pulled from a separate, newer nixpkgs pin (see flake.nix) since the
  # main nixpkgs input only has n8n 2.32.6. NODE_OPTIONS raises tsc's V8
  # heap ceiling for the `pnpm build --filter=n8n` step -- confirmed on
  # this exact host that the ~2GB default limit reliably OOMs partway
  # through compiling n8n's CLI package (deterministic, not a fluke: it
  # crashed identically on two separate attempts).
  # legacyPackages is pre-instantiated with default (unfree-disallowed)
  # config, and hosts/builder.nix's allowUnfreePredicate only applies to
  # the main pkgs instance -- re-import with the same predicate here since
  # n8n's license (sustainableUse) is unfree.
  n8nPkgs = import inputs.nixpkgs-n8n {
    system = pkgs.system;
    config.allowUnfreePredicate = p: builtins.elem (lib.getName p) [ "n8n" ];
  };
  n8nPkg = n8nPkgs.n8n.overrideAttrs (old: {
    NODE_OPTIONS = "--max-old-space-size=4096";
  });
in {
  options.custom.n8n = {
    enable = lib.mkEnableOption "Enable n8n workflow automation server";
    port = lib.mkOption {
      type = lib.types.port;
      default = 5678;
      description = "Port for n8n web interface";
    };
    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://localhost:5678/";
      description = "Base URL for n8n";
    };
    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = "Extra environment variables for n8n";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.n8n = {
      isSystemUser = true;
      home = n8nDataDir;
      createHome = true;
      group = "n8n";
    };
    users.groups.n8n = {};

    systemd.services.n8n = {
      description = "n8n workflow automation";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      # n8n 2.x's JS task runner launcher spawns via the bare command
      # `node` (confirmed with N8N_LOG_LEVEL=debug: "spawn node ENOENT"),
      # not an absolute path -- normal for a standard install where
      # node is already on PATH, but nothing put it there for this
      # service. n8nPkg alone (added first, wrongly assumed the launcher
      # used the n8n-task-runner wrapper script) wasn't enough; it also
      # needs the matching nodejs binary itself. Without this, every
      # runner spawn attempt fails instantly and n8n's own
      # restart-loop-detector kills the whole process after ~50 failures
      # in under a second.
      path = [ n8nPkg n8nPkgs.nodejs ];
      serviceConfig = {
        Type = "simple";
        User = "n8n";
        Group = "n8n";
        WorkingDirectory = n8nDataDir;
        Environment = [
          "N8N_PORT=${toString cfg.port}"
          "N8N_HOST=0.0.0.0"
          "N8N_PROTOCOL=http"
          "N8N_BASIC_AUTH_ACTIVE=false"
          "N8N_EDITOR_BASE_URL=${cfg.baseUrl}"
          "N8N_DIAGNOSTICS_ENABLED=false"
          "N8N_SECURE_COOKIE=false" #Disable if exposing to internet
          "DB_TYPE=sqlite"
          "DB_SQLITE_DATABASE=${n8nDataDir}/database.sqlite"
        ] ++ (lib.attrsets.mapAttrsToList (n: v: "${n}=${v}") cfg.env);
        ExecStart = "${n8nPkg}/bin/n8n";
        Restart = "always";
      };
      # Ensure data dir exists
      preStart = ''
        mkdir -p ${n8nDataDir}
        chown n8n:n8n ${n8nDataDir}
      '';
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
