{ pkgs, lib, ... }:
let
  # Publish a complete pair with one rename; failed generation leaves the old
  # pair usable. Keep prior generations (small, private) for diagnosis/rollback.
  tlsScript = ''
    set -eu
    umask 0077
    cd /var/lib/hermes-paperclip-tls
    exec 9>.lock
    ${pkgs.util-linux}/bin/flock -x 9
    valid_pair() {
      ${pkgs.openssl}/bin/openssl x509 -in "$1/server.crt" -noout -checkend 2592000 >/dev/null 2>&1 || return 1
      cert_pub=$(${pkgs.openssl}/bin/openssl x509 -in "$1/server.crt" -pubkey -noout) || return 1
      key_pub=$(${pkgs.openssl}/bin/openssl pkey -in "$1/server.key" -passin pass: -pubout 2>/dev/null) || return 1
      [ "$cert_pub" = "$key_pub" ]
    }
    provision_pair() {
      source=.
      if [ -L current ]; then source=current; fi
      if valid_pair "$source"; then
        if [ "$source" = current ]; then return; fi
        preserve=true
      else
        preserve=false
      fi
      stage=$(mktemp -d generation.XXXXXXXX)
      trap 'if [ -n "$stage" ] && [ "$(readlink current || true)" != "$stage" ]; then rm -rf -- "$stage"; fi; rm -f current.next' EXIT
      if $preserve; then
        # Migrate the original flat layout without replacing a healthy cert.
        cp "$source/server.crt" "$source/server.key" "$stage/"
      else
        ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
          -keyout "$stage/server.key" -out "$stage/server.crt" -subj '/CN=hermes-paperclip.internal' \
          -addext 'subjectAltName=IP:10.88.0.1,DNS:hermes-paperclip.internal' \
          -addext 'extendedKeyUsage=serverAuth'
      fi
      valid_pair "$stage"
      chown root:nginx "$stage" "$stage/server.key"
      chmod 0750 "$stage"
      chmod 0640 "$stage/server.key"
      chmod 0644 "$stage/server.crt"
      touch "$stage/restart-required"
      ln -s "$stage" current.next
      mv -Tf current.next current
      stage=
    }
    provision_pair
  '';
in
{
  # Official v2026.1023.0 multi-architecture image, including linux/arm64.
  # Bind only the current LAN address; reserve this address in DHCP.
  # Internet-facing HTTPS routing is a separate change.
  networking.firewall.allowedTCPPorts = [ 3100 ];
  # Private, authenticated TLS entrypoint to the existing host Hermes gateway.
  networking.firewall.interfaces.podman0.allowedTCPPorts = [ 8643 ];
  services.nginx = {
    enable = true;
    virtualHosts."hermes-paperclip.internal" = {
      onlySSL = true;
      listen = [ { addr = "10.88.0.1"; port = 8643; ssl = true; } ];
      sslCertificate = "/var/lib/hermes-paperclip-tls/current/server.crt";
      sslCertificateKey = "/var/lib/hermes-paperclip-tls/current/server.key";
      locations."/" = {
        proxyPass = "http://127.0.0.1:8642";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_buffering off;
          proxy_read_timeout 650s;
        '';
      };
    };
  };
  systemd.services.hermes-paperclip-tls = {
    description = "Provision private Paperclip-to-Hermes TLS certificate";
    before = [ "nginx.service" "podman-paperclip.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "hermes-paperclip-tls";
      StateDirectoryMode = "0755";
      UMask = "0077";
    };
    script = tlsScript + ''
      # Consumers start after this boot prerequisite, so no restart is needed.
      rm -f current/restart-required
    '';
  };
  # Do not restart consumers from their own boot prerequisite: it would form
  # a systemd ordering cycle. This independent, non-remaining unit can rerun.
  systemd.services.hermes-paperclip-tls-renew = {
    description = "Renew private Paperclip-to-Hermes TLS certificate";
    requires = [ "hermes-paperclip-tls.service" ];
    after = [ "hermes-paperclip-tls.service" ];
    serviceConfig = {
      Type = "oneshot";
      UMask = "0077";
      TimeoutStartSec = "35min";
    };
    script = tlsScript + ''
      if [ -e current/restart-required ]; then
        # Recreate the container's single-file bind mount AND restart Node to
        # reread NODE_EXTRA_CA_CERTS. nginx must reopen the rotated pair too.
        # Keep the marker on failure so the next run retries consumer refresh.
        # Use restart, not try-restart: a previous failed refresh may have left
        # a consumer inactive. Both consumers are configured to auto-start.
        ${pkgs.systemd}/bin/systemctl restart podman-paperclip.service nginx.service
        rm -f current/restart-required
      fi
    '';
  };
  systemd.timers.hermes-paperclip-tls-renew = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      RandomizedDelaySec = "1h";
      Persistent = true;
    };
  };
  systemd.services.nginx = {
    requires = [ "hermes-paperclip-tls.service" "podman-paperclip.service" ];
    after = [ "hermes-paperclip-tls.service" "podman-paperclip.service" ];
  };
  virtualisation.oci-containers = {
    backend = "podman";
    containers.paperclip = {
      image = "ghcr.io/paperclipai/paperclip@sha256:40f46940c4612ead131aebe6079cd4651f8cd1434af49f7c621887f4a452a62e";
      autoStart = true;
      ports = [ "192.168.50.238:3100:3100" ];
      volumes = [ "paperclip-data:/paperclip" "/var/lib/hermes-paperclip-tls/current/server.crt:/etc/paperclip/hermes-server.crt:ro" ];
      environmentFiles = [ "/var/lib/paperclip-secrets/environment" ];
      environment = {
        NODE_EXTRA_CA_CERTS = "/etc/paperclip/hermes-server.crt";
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
    requires = [ "paperclip-secrets.service" "hermes-paperclip-tls.service" ];
    after = [ "paperclip-secrets.service" "hermes-paperclip-tls.service" ];
    serviceConfig.TimeoutStartSec = lib.mkForce "30min";
  };
}
