{ config, pkgs, lib, ... }:

let
  cfg = config.custom.paperclip;
  secretDir = "/var/lib/paperclip-secrets";
  secretFile = "${secretDir}/environment";
in {
  options.custom.paperclip = {
    enable = lib.mkEnableOption "Paperclip AI agent management server";

    bindAddress = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address on which to expose Paperclip.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 3100;
      description = "Port on which to expose Paperclip.";
    };

    publicBaseUrl = lib.mkOption {
      type = lib.types.str;
      description = "Public URL used for Paperclip authentication callbacks.";
    };

    allowedHostnames = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "localhost" "127.0.0.1" ];
      description = "Hostnames accepted by Paperclip.";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = true;
    virtualisation.oci-containers.backend = "podman";

    systemd.services.paperclip-secrets = {
      description = "Initialize Paperclip authentication secret";
      wantedBy = [ "multi-user.target" ];
      before = [ "podman-paperclip.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StateDirectory = "paperclip-secrets";
        StateDirectoryMode = "0700";
        UMask = "0077";
      };
      path = [ pkgs.openssl ];
      script = ''
        set -eu
        if [ ! -s ${secretFile} ]; then
          secret=$(openssl rand -hex 32)
          printf 'BETTER_AUTH_SECRET=%s\n' "$secret" > ${secretFile}.tmp
          mv ${secretFile}.tmp ${secretFile}
        fi
      '';
    };

    virtualisation.oci-containers.containers.paperclip = {
      autoStart = true;
      image = "ghcr.io/paperclipai/paperclip@sha256:40f46940c4612ead131aebe6079cd4651f8cd1434af49f7c621887f4a452a62e";
      ports = [ "${cfg.bindAddress}:${toString cfg.port}:3100" ];
      volumes = [ "paperclip-data:/paperclip" ];
      environmentFiles = [ secretFile ];
      environment = {
        HEARTBEAT_SCHEDULER_ENABLED = "false";
        HOST = "0.0.0.0";
        PAPERCLIP_ALLOWED_HOSTNAMES = lib.concatStringsSep "," cfg.allowedHostnames;
        PAPERCLIP_AUTH_BASE_URL_MODE = "explicit";
        PAPERCLIP_AUTH_PUBLIC_BASE_URL = cfg.publicBaseUrl;
        PAPERCLIP_DB_BACKUP_ENABLED = "true";
        PAPERCLIP_DEPLOYMENT_EXPOSURE = "private";
        PAPERCLIP_DEPLOYMENT_MODE = "authenticated";
        PAPERCLIP_HOME = "/paperclip";
        PORT = "3100";
        SERVE_UI = "true";
      };
      extraOptions = [ "--security-opt=no-new-privileges" ];
    };

    systemd.services.podman-paperclip = {
      requires = [ "paperclip-secrets.service" ];
      after = [ "network-online.target" "paperclip-secrets.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Restart = "on-failure";
        TimeoutStartSec = lib.mkForce "30min";
        TimeoutStopSec = lib.mkForce 120;
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}
