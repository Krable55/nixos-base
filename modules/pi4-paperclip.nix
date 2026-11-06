{ pkgs, lib, ... }:
{
  # Official v2026.1023.0 multi-architecture image, including linux/arm64.
  # Bind only the current LAN address; reserve this address in DHCP.
  # Internet-facing HTTPS routing is a separate change.
  networking.firewall.allowedTCPPorts = [ 3100 ];
  virtualisation.oci-containers = {
    backend = "podman";
    containers.paperclip = {
      image = "ghcr.io/paperclipai/paperclip@sha256:40f46940c4612ead131aebe6079cd4651f8cd1434af49f7c621887f4a452a62e";
      autoStart = true;
      ports = [ "192.168.50.238:3100:3100" ];
      volumes = [ "paperclip-data:/paperclip" ];
      environmentFiles = [ "/var/lib/paperclip-secrets/environment" ];
      environment = {
        PAPERCLIP_DEPLOYMENT_MODE = "authenticated";
        PAPERCLIP_DEPLOYMENT_EXPOSURE = "private";
        PAPERCLIP_AUTH_BASE_URL_MODE = "explicit";
        PAPERCLIP_AUTH_PUBLIC_BASE_URL = "http://192.168.50.238:3100";
        PAPERCLIP_ALLOWED_HOSTNAMES = "192.168.50.238,pi4.local,localhost,127.0.0.1";
        PAPERCLIP_HOME = "/paperclip";
        HOST = "0.0.0.0";
        PORT = "3100";
        SERVE_UI = "true";
        PAPERCLIP_DB_BACKUP_ENABLED = "true";
        # No agents or unattended provider calls during initial installation.
        HEARTBEAT_SCHEDULER_ENABLED = "false";
      };
      extraOptions = [ "--security-opt=no-new-privileges" ];
    };
  };

  # Generate once on the target, never in the Nix store or deployment output.
  systemd.services.paperclip-secrets = {
    description = "Initialize Paperclip authentication secret";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "paperclip-secrets";
      StateDirectoryMode = "0700";
      UMask = "0077";
    };
    script = ''
      set -eu
      if [ ! -s /var/lib/paperclip-secrets/environment ]; then
        secret=$(${pkgs.openssl}/bin/openssl rand -hex 32)
        printf 'BETTER_AUTH_SECRET=%s\n' "$secret" > /var/lib/paperclip-secrets/environment.tmp
        mv /var/lib/paperclip-secrets/environment.tmp /var/lib/paperclip-secrets/environment
      fi
    '';
  };
  systemd.services.podman-paperclip = {
    requires = [ "paperclip-secrets.service" ];
    after = [ "paperclip-secrets.service" ];
    serviceConfig.TimeoutStartSec = lib.mkForce "30min";
  };
}
